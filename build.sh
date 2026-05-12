#!/usr/bin/env bash
set -euo pipefail

DIR="${HOME}/.claude/dashboard"
OUT="${DIR}/index.html"
TEMPLATE="${DIR}/template.html"

NO_OPEN=0
NO_SUMMARY=0
for arg in "$@"; do
  case "$arg" in
    --no-open)    NO_OPEN=1 ;;
    --no-summary) NO_SUMMARY=1 ;;
  esac
done

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

if [[ -z "${USER_NAME:-}" ]]; then
  USER_NAME="User"
  if command -v claude >/dev/null 2>&1; then
    AUTH_JSON=$(claude auth status --json 2>/dev/null || true)
    if [[ -n "$AUTH_JSON" ]]; then
      DETECTED=$(echo "$AUTH_JSON" | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
    e = (d.get("email") or "").split("@")[0]
    print((e[:1].upper() + e[1:]) if e else "")
except Exception:
    print("")
' 2>/dev/null || true)
      [[ -n "$DETECTED" ]] && USER_NAME="$DETECTED"
    fi
  fi
fi
export USER_NAME

python3 - "$TEMPLATE" "$OUT" <<'PY' >/dev/null
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
                if p.get("type") != "message" or p.get("role") not in ("user", "developer"): continue
                for c in (p.get("content") or []):
                    t = c.get("text") or ""
                    if not t: continue
                    # skip env/system XML wrappers and AGENTS.md preambles
                    stripped = t.strip()
                    if stripped.startswith("<") or stripped.startswith("# AGENTS.md"):
                        continue
                    first = stripped.split("\n", 1)[0].strip()
                    if first:
                        title = first[:80]
                        break
                if title: break
    except Exception:
        pass
    _codex_title_cache[fn] = title
    return title

d = json.loads(os.environ["DAILY"])
w = json.loads(os.environ["WEEKLY"])
m = json.loads(os.environ["MONTHLY"])
payload = {
    "daily":   d.get("daily", []),
    "weekly":  w.get("weekly", []),
    "monthly": m.get("monthly", []),
    "totals":  m.get("totals", {}),
    "sessions": json.loads(os.environ["CLAUDE_SESSIONS"]),
    "codex": {
        "daily":   json.loads(os.environ["CODEX_DAILY"]).get("daily", []),
        "weekly":  json.loads(os.environ["CODEX_WEEKLY"]).get("weekly", []),
        "monthly": json.loads(os.environ["CODEX_MONTHLY"]).get("monthly", []),
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
            for s in json.loads(os.environ["CODEX_SESSIONS"]).get("sessions", [])
        ],
    },
    "generatedAt": os.environ["GENERATED_AT"],
}
with open(template_path, "r", encoding="utf-8") as f:
    html = f.read()
html = html.replace("__DATA__", json.dumps(payload))
html = html.replace("__USER_NAME__", os.environ.get("USER_NAME", "User"))
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
cutoff_7d = (now - timedelta(days=7)).strftime("%Y-%m-%d")

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
  open "$OUT"
fi
