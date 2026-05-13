#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

DIR="${AI_USAGE_DASHBOARD_HOME:-${HOME}/.ai-usage-dashboard}"
OUT="${DIR}/index.html"
TEMPLATE="${DIR}/template.html"
SERVER_PORT="${AI_USAGE_DASHBOARD_PORT:-46327}"
SERVER_URL="http://127.0.0.1:${SERVER_PORT}"
SERVER_SCRIPT="${DIR}/scripts/dashboard_server.py"
TOKEN_FILE="${DIR}/.refresh-token"
LAUNCH_LABEL="com.csevav.ai-usage-dashboard.${SERVER_PORT}"

NO_OPEN=0
NO_SUMMARY=0
FROM_SERVER=0
for arg in "$@"; do
  case "$arg" in
    --no-open)    NO_OPEN=1 ;;
    --no-summary) NO_SUMMARY=1 ;;
    --from-server) FROM_SERVER=1 ;;
    *)
      echo "Unknown option: $arg" >&2
      echo "Usage: $0 [--no-open] [--no-summary]" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Template not found: $TEMPLATE" >&2
  echo "Run the installer first so ${DIR} is populated." >&2
  exit 1
fi

ensure_refresh_token() {
  mkdir -p "$DIR"
  if [[ ! -s "$TOKEN_FILE" ]]; then
    python3 - "$TOKEN_FILE" <<'PY'
import os
import secrets
import sys

path = sys.argv[1]
with open(path, "w", encoding="utf-8") as fh:
    fh.write(secrets.token_urlsafe(32))
os.chmod(path, 0o600)
PY
  fi
}

stop_stale_server() {
  local pids
  if [[ "$(uname -s)" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1; then
    launchctl remove "$LAUNCH_LABEL" >/dev/null 2>&1 || true
  fi
  if ! command -v lsof >/dev/null 2>&1; then
    return 0
  fi
  pids="$(lsof -tiTCP:"$SERVER_PORT" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -z "$pids" ]]; then
    return 0
  fi
  kill $pids 2>/dev/null || true
  for _ in {1..20}; do
    sleep 0.1
    if ! lsof -tiTCP:"$SERVER_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
  done
}

start_server() {
  local python_bin
  python_bin="$(command -v python3)"
  if [[ "$(uname -s)" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1; then
    launchctl remove "$LAUNCH_LABEL" >/dev/null 2>&1 || true
    launchctl submit \
      -l "$LAUNCH_LABEL" \
      -o "${DIR}/dashboard-server.out.log" \
      -e "${DIR}/dashboard-server.err.log" \
      -- "$python_bin" "$SERVER_SCRIPT" --dir "$DIR" --port "$SERVER_PORT" --token-file "$TOKEN_FILE"
    return
  fi
  nohup "$python_bin" "$SERVER_SCRIPT" --dir "$DIR" --port "$SERVER_PORT" --token-file "$TOKEN_FILE" \
    >"${DIR}/dashboard-server.out.log" 2>"${DIR}/dashboard-server.err.log" &
}

ensure_server() {
  if [[ ! -f "$SERVER_SCRIPT" ]]; then
    echo "Refresh server script not found: $SERVER_SCRIPT" >&2
    return 1
  fi
  if command -v curl >/dev/null 2>&1; then
    health="$(curl -fsS "${SERVER_URL}/__health__" 2>/dev/null || true)"
    if [[ "$health" == *'"refreshAuth": "token"'* || "$health" == *'"refreshAuth":"token"'* ]]; then
      return 0
    fi
    if [[ "$health" == *'"ok": true'* || "$health" == *'"ok":true'* ]]; then
      stop_stale_server
    fi
  fi
  start_server
  for _ in {1..20}; do
    sleep 0.2
    if command -v curl >/dev/null 2>&1; then
      health="$(curl -fsS "${SERVER_URL}/__health__" 2>/dev/null || true)"
    else
      health=""
    fi
    if [[ "$health" == *'"refreshAuth": "token"'* || "$health" == *'"refreshAuth":"token"'* ]]; then
      return 0
    fi
  done
  echo "Failed to start local dashboard server on ${SERVER_URL}" >&2
  return 1
}

ensure_refresh_token
DASHBOARD_REFRESH_TOKEN="$(<"$TOKEN_FILE")"
export DASHBOARD_REFRESH_TOKEN

export DAILY=$(npx --yes ccusage daily --json --breakdown)
export WEEKLY=$(npx --yes ccusage weekly --json --breakdown)
export MONTHLY=$(npx --yes ccusage monthly --json --breakdown)
export CODEX_DAILY=$(npx --yes @ccusage/codex@latest daily --json 2>/dev/null || echo '{"daily":[]}')
export CODEX_WEEKLY=$(npx --yes @ccusage/codex@latest weekly --json 2>/dev/null || echo '{"weekly":[]}')
export CODEX_MONTHLY=$(npx --yes @ccusage/codex@latest monthly --json 2>/dev/null || echo '{"monthly":[]}')
export CODEX_SESSIONS=$(npx --yes @ccusage/codex@latest session --json 2>/dev/null || echo '{"sessions":[]}')
export CLAUDE_SESSIONS=$(python3 -c '
import os, json, glob

# Per-million-token pricing (USD) for Claude 4.x family.
# Falls back to sonnet pricing if model is unrecognised.
PRICING = {
    "opus":   {"input":  5.0, "output": 25.0, "cache_write_5m":  6.25, "cache_write_1h": 10.0, "cache_read": 0.50},
    "sonnet": {"input":  3.0, "output": 15.0, "cache_write_5m":  3.75, "cache_write_1h":  6.0, "cache_read": 0.30},
    "haiku":  {"input":  1.0, "output":  5.0, "cache_write_5m":  1.25, "cache_write_1h":  2.0, "cache_read": 0.10},
}
def price_for(model_name: str):
    m = (model_name or "").lower()
    if "opus" in m:   return PRICING["opus"]
    if "haiku" in m:  return PRICING["haiku"]
    return PRICING["sonnet"]

out = []
for f in sorted(glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))):
    sid = os.path.basename(f).replace(".jsonl", "")
    first_ts = None
    title = None
    cost = 0.0
    total_tokens = 0
    models = set()
    seen_msg = set()
    try:
        with open(f, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("type") == "ai-title" and d.get("aiTitle"):
                    title = d["aiTitle"]
                if not first_ts and d.get("timestamp"):
                    first_ts = d["timestamp"]
                msg = d.get("message") or {}
                usage = msg.get("usage") or {}
                if not usage: continue
                # Dedupe: the same assistant message id can appear many times
                # (streaming chunks, retries, etc). Count only the first occurrence.
                mid = msg.get("id") or d.get("uuid")
                if mid is not None:
                    if mid in seen_msg: continue
                    seen_msg.add(mid)
                model = msg.get("model") or ""
                if model: models.add(model)
                p = price_for(model)
                inp   = usage.get("input_tokens", 0) or 0
                out_t = usage.get("output_tokens", 0) or 0
                cr    = usage.get("cache_read_input_tokens", 0) or 0
                # split cache creation into 5m / 1h if breakdown is available
                cc_breakdown = usage.get("cache_creation") or {}
                cw5 = cc_breakdown.get("ephemeral_5m_input_tokens", 0) or 0
                cw1 = cc_breakdown.get("ephemeral_1h_input_tokens", 0) or 0
                if not (cw5 or cw1):
                    # fall back to total cache_creation; treat as 5m
                    cw5 = usage.get("cache_creation_input_tokens", 0) or 0
                cost += (
                    inp   * p["input"]
                  + out_t * p["output"]
                  + cw5   * p["cache_write_5m"]
                  + cw1   * p["cache_write_1h"]
                  + cr    * p["cache_read"]
                ) / 1_000_000
                total_tokens += inp + out_t + cw5 + cw1 + cr
    except Exception:
        continue
    if first_ts:
        out.append({
            "sessionId": sid,
            "date": first_ts[:10],
            "timestamp": first_ts,
            "title": title or sid[:8],
            "costUSD": round(cost, 6),
            "totalTokens": total_tokens,
            "models": sorted(models),
        })
print(json.dumps(out))
')
export GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
export DASHBOARD_SERVER_URL="$SERVER_URL"

if [[ "$FROM_SERVER" -eq 0 ]]; then
  ensure_server
fi

if [[ -z "${USER_NAME:-}" ]]; then
  USER_NAME="$(
    python3 - <<'PY'
import json
import os
import pwd
import subprocess
import sys


def run_text(*args):
    try:
        proc = subprocess.run(args, capture_output=True, text=True, check=False)
    except Exception:
        return ""
    return (proc.stdout or "").strip()


def clean_name(value):
    text = " ".join(str(value or "").strip().split())
    if not text:
        return ""
    for bad in ("unknown", "user", "none", "null"):
        if text.lower() == bad:
            return ""
    return text


def title_from_email(email):
    local = (email or "").split("@", 1)[0].strip()
    if not local:
        return ""
    parts = [p for p in local.replace(".", " ").replace("_", " ").replace("-", " ").split() if p]
    if not parts:
        return ""
    return " ".join(p[:1].upper() + p[1:] for p in parts)


def claude_name():
    try:
        proc = subprocess.run(
            ["claude", "auth", "status", "--json"],
            capture_output=True,
            text=True,
            check=False,
        )
    except Exception:
        return ""
    raw = (proc.stdout or "").strip()
    if not raw:
        return ""
    try:
        data = json.loads(raw)
    except Exception:
        return ""
    for key in ("name", "fullName", "displayName", "userName"):
        value = clean_name(data.get(key))
        if value:
            return value
    email_name = title_from_email(data.get("email"))
    if email_name:
        return email_name
    return ""


def system_name():
    for command in (("id", "-F"),):
        value = clean_name(run_text(*command))
        if value:
            return value
    try:
        gecos = pwd.getpwuid(os.getuid()).pw_gecos.split(",", 1)[0]
    except Exception:
        gecos = ""
    value = clean_name(gecos)
    if value:
        return value
    return ""


def git_name():
    return clean_name(run_text("git", "config", "--global", "user.name"))


for getter in (claude_name, system_name, git_name):
    value = getter()
    if value:
        print(value)
        sys.exit(0)

print("User")
PY
  )"
fi
export USER_NAME

python3 - "$TEMPLATE" "$OUT" <<'PY' >/dev/null
import html as html_lib
import json, sys, os
template_path, out_path = sys.argv[1], sys.argv[2]

_codex_title_cache = {}
def codex_title(s):
    """Extract the first real user prompt from a Codex rollout file."""
    fn = s.get("sessionFile") or ""
    if not fn: return None
    if fn in _codex_title_cache: return _codex_title_cache[fn]
    # Sessions live under either ~/.codex/sessions/<dir>/<file>.jsonl or archived_sessions/
    candidates = []
    direc = s.get("directory") or ""
    home = os.path.expanduser("~")
    fname = fn if fn.endswith(".jsonl") else f"{fn}.jsonl"
    if direc:
        candidates.append(os.path.join(home, ".codex", "sessions", direc, fname))
    candidates += [
        os.path.join(home, ".codex", "sessions", fname),
        os.path.join(home, ".codex", "archived_sessions", fname),
    ]
    path = next((p for p in candidates if os.path.exists(p)), None)
    if not path:
        # Last-resort glob search
        import glob
        hits = glob.glob(os.path.join(home, ".codex", "**", fname), recursive=True)
        path = hits[0] if hits else None
    if not path:
        _codex_title_cache[fn] = None
        return None
    title = None
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                p = e.get("payload") or {}
                if e.get("type") != "response_item": continue
                if p.get("type") != "message" or p.get("role") != "user": continue
                for c in (p.get("content") or []):
                    t = c.get("text") or ""
                    if not t: continue
                    stripped = t.strip()
                    if stripped.startswith("<") or stripped.startswith("# AGENTS.md"):
                        continue
                    if stripped.startswith("# .pen ") or stripped.startswith("## Memory"):
                        continue
                    if stripped.startswith("# Files mentioned"):
                        continue
                    first = stripped.split("\n", 1)[0].strip()
                    if not first: continue
                    if first.startswith("[$") and "SKILL.md" in first:
                        continue
                    # shorten long URLs to domain + path hint
                    if first.startswith("http://") or first.startswith("https://"):
                        import re as _re
                        m = _re.match(r"https?://(?:www\.)?([^/]+)(/[^?#]*)?", first)
                        if m:
                            first = m.group(1) + (m.group(2) or "")
                            if len(first) > 50: first = first[:47] + "..."
                    if first:
                        title = first[:80]
                        break
                if title: break
    except Exception:
        pass
    _codex_title_cache[fn] = title
    return title

def load_env_json(name, default):
    raw = os.environ.get(name, "")
    try:
        return json.loads(raw)
    except Exception:
        return default

def dump_json_for_script(value):
    return (
        json.dumps(value, ensure_ascii=False)
        .replace("&", "\\u0026")
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
        .replace("</", "<\\/")
    )

d = load_env_json("DAILY", {"daily": []})
w = load_env_json("WEEKLY", {"weekly": []})
m = load_env_json("MONTHLY", {"monthly": []})
claude_sessions = load_env_json("CLAUDE_SESSIONS", [])
codex_daily = load_env_json("CODEX_DAILY", {"daily": []})
codex_weekly = load_env_json("CODEX_WEEKLY", {"weekly": []})
codex_monthly = load_env_json("CODEX_MONTHLY", {"monthly": []})
codex_sessions = load_env_json("CODEX_SESSIONS", {"sessions": []})
payload = {
    "daily":   d.get("daily", []),
    "weekly":  w.get("weekly", []),
    "monthly": m.get("monthly", []),
    "totals":  m.get("totals", {}),
    "sessions": claude_sessions,
    "codex": {
        "daily":   codex_daily.get("daily", []),
        "weekly":  codex_weekly.get("weekly", []),
        "monthly": codex_monthly.get("monthly", []),
        "sessions": [
            {
                "sessionId": s.get("sessionId"),
                "date": (s.get("lastActivity") or "")[:10],
                "timestamp": s.get("lastActivity") or "",
                "title": codex_title(s) or (s.get("sessionFile") or "")[-12:],
                "costUSD": s.get("costUSD") or 0,
                "totalTokens": s.get("totalTokens") or 0,
                "models": sorted(list((s.get("models") or {}).keys())),
            }
            for s in codex_sessions.get("sessions", [])
        ],
    },
    "generatedAt": os.environ["GENERATED_AT"],
}
with open(template_path, "r", encoding="utf-8") as f:
    html = f.read()
html = html.replace("__DATA__", dump_json_for_script(payload))
html = html.replace("__USER_NAME__", html_lib.escape(os.environ.get("USER_NAME", "User")))
html = html.replace("__SERVER_URL__", os.environ.get("DASHBOARD_SERVER_URL", "http://127.0.0.1:46327"))
html = html.replace("__REFRESH_TOKEN__", json.dumps(os.environ.get("DASHBOARD_REFRESH_TOKEN", "")))
with open(out_path, "w", encoding="utf-8") as f:
    f.write(html)
PY

if [[ "$NO_SUMMARY" -eq 0 ]]; then
python3 - <<'PY'
import json, os, re
from datetime import datetime, timedelta

daily   = json.loads(os.environ["DAILY"]).get("daily", [])
monthly = json.loads(os.environ["MONTHLY"]).get("monthly", [])

now = datetime.now()
today_str = now.strftime("%Y-%m-%d")
this_month = now.strftime("%Y-%m")
cutoff_7d = (now - timedelta(days=6)).strftime("%Y-%m-%d")

today_row = next((r for r in daily if r["date"] == today_str), None)
month_row = next((r for r in monthly if r["month"] == this_month), None)
last7 = [r for r in daily if r["date"] >= cutoff_7d]
sum_cost_7d   = sum(r["totalCost"]   for r in last7)
sum_tokens_7d = sum(r["totalTokens"] for r in last7)
all_cost   = sum(r["totalCost"]   for r in monthly)
all_tokens = sum(r["totalTokens"] for r in monthly)

model_costs = {}
for r in monthly:
    for b in r.get("modelBreakdowns", []):
        model_costs[b["modelName"]] = model_costs.get(b["modelName"], 0) + b["cost"]
top_models = sorted(model_costs.items(), key=lambda x: -x[1])[:5]

def fmt_usd(x): return f"${x:.2f}"
def fmt_n(x):   return f"{x:,}"
def short(m):   return re.sub(r"-\d{8}$", "", m.replace("claude-", ""))

print()
print("## Claude Usage — quick summary")
print()
print("| Period | Cost | Tokens |")
print("|---|---:|---:|")
if today_row:
    print(f"| Today ({today_str}) | {fmt_usd(today_row['totalCost'])} | {fmt_n(today_row['totalTokens'])} |")
else:
    print(f"| Today ({today_str}) | $0.00 | 0 |")
print(f"| Last 7 days | {fmt_usd(sum_cost_7d)} | {fmt_n(sum_tokens_7d)} |")
if month_row:
    print(f"| This month ({this_month}) | {fmt_usd(month_row['totalCost'])} | {fmt_n(month_row['totalTokens'])} |")
else:
    print(f"| This month ({this_month}) | $0.00 | 0 |")
print(f"| All time | {fmt_usd(all_cost)} | {fmt_n(all_tokens)} |")
print()
if top_models:
    print("### Top models by cost (all time)")
    print()
    print("| Model | Cost |")
    print("|---|---:|")
    for m, c in top_models:
        print(f"| {short(m)} | {fmt_usd(c)} |")
    print()
PY
fi

echo "Dashboard regenerated: ${OUT}"

if [[ "${TERM_PROGRAM:-}" == "vscode" ]]; then
  echo ""
  echo "Inside VS Code? Open in Simple Browser instead of a separate window:"
  echo "  Cmd+Shift+P → 'Simple Browser: Show' → file://${OUT}"
fi

if [[ "$NO_OPEN" -eq 0 ]]; then
  if [[ "$FROM_SERVER" -eq 0 ]]; then
    TARGET_URL="${SERVER_URL}/index.html?t=$(date +%s)"
    if command -v open >/dev/null 2>&1; then
      open "$TARGET_URL"
    else
      echo "Dashboard ready: ${TARGET_URL}"
    fi
  elif command -v open >/dev/null 2>&1; then
    open "$OUT"
  else
    echo "Open skipped: no 'open' command found. File is ready at ${OUT}"
  fi
fi
