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
ENV_NOTICES='[]'
CLAUDE_TOOL_NOTICE_SENT=0
CODEX_TOOL_NOTICE_SENT=0
INCLUDE_MIXED_TOTALS="${AI_USAGE_DASHBOARD_INCLUDE_MIXED:-0}"
MAX_JSON_PARALLEL="${AI_USAGE_DASHBOARD_MAX_PARALLEL:-4}"
CCUSAGE_AVAILABLE=0
CCUSAGE_CMD=()

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

append_notice() {
  local level="$1"
  local zh="$2"
  local en="$3"
  ENV_NOTICES="$(
    python3 - "$ENV_NOTICES" "$level" "$zh" "$en" <<'PY'
import json
import sys

items = json.loads(sys.argv[1])
items.append({
    "level": sys.argv[2],
    "zh": sys.argv[3],
    "en": sys.argv[4],
})
print(json.dumps(items, ensure_ascii=False))
PY
  )"
}

print_notice_line() {
  local level="$1"
  local message="$2"
  printf '[%s] %s\n' "$level" "$message" >&2
}

check_required_tools() {
  local failed=0
  if ! command -v node >/dev/null 2>&1; then
    print_notice_line "ERROR" "未检测到 Node.js。这个 dashboard 需要 Node.js 18+ 作为 npx fallback，并用于读取包版本。"
    failed=1
  else
    local node_major
    node_major="$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0)"
    if [[ "$node_major" -lt 18 ]]; then
      print_notice_line "ERROR" "当前 Node.js 版本过低（检测到 $(node -v 2>/dev/null || echo unknown)）。请升级到 Node.js 18 或更高版本。"
      failed=1
    fi
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    print_notice_line "ERROR" "未检测到 python3。这个 dashboard 需要 python3 来生成页面和本地刷新服务。"
    failed=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    echo "前提环境不完整，已停止构建。" >&2
    exit 1
  fi
}

resolve_ccusage_command() {
  CCUSAGE_AVAILABLE=0
  CCUSAGE_CMD=()

  if command -v ccusage >/dev/null 2>&1; then
    CCUSAGE_CMD=(ccusage)
    CCUSAGE_AVAILABLE=1
    return 0
  fi

  if command -v npx >/dev/null 2>&1; then
    CCUSAGE_CMD=(npx --yes ccusage)
    CCUSAGE_AVAILABLE=1
    append_notice "warning" \
      "未检测到本机 ccusage，已改用 npx 临时运行 ccusage。首次运行需要能访问 npm；如果 npm 登录态、代理或网络异常，数据面板会为空。" \
      "No local ccusage binary was found, so the dashboard will run ccusage through npx. The first run needs npm access; stale npm credentials, proxy issues, or network failures can leave data panels empty."
    print_notice_line "WARN" "未检测到本机 ccusage，已改用 npx 临时运行 ccusage。"
    return 0
  fi

  append_notice "error" \
    "未检测到 ccusage，也未检测到 npx。看板可以打开，但无法拉取 Claude Code / Codex 用量数据。请安装 ccusage：npm install -g ccusage，或安装 Node.js/npm 以启用 npx fallback。" \
    "Neither ccusage nor npx was found. The dashboard can open, but it cannot load Claude Code / Codex usage data. Install ccusage with: npm install -g ccusage, or install Node.js/npm to enable the npx fallback."
  print_notice_line "ERROR" "未检测到 ccusage，也未检测到 npx。看板将生成空数据页面。"
  return 0
}

add_data_source_notices() {
  if [[ ! -d "${HOME}/.claude/projects" ]]; then
    append_notice "warning" \
      "未检测到 ~/.claude/projects，所以 Claude Code 面板大概率会为空。" \
      "No ~/.claude/projects directory was found, so the Claude Code panels will likely be empty."
  elif ! find "${HOME}/.claude/projects" -name '*.jsonl' -print -quit 2>/dev/null | grep -q .; then
    append_notice "warning" \
      "检测到了 ~/.claude/projects，但里面还没有对话记录，所以 Claude Code 面板会为空。" \
      "The ~/.claude/projects directory exists, but no conversation records were found, so the Claude Code panels will be empty."
  fi

  if [[ ! -d "${HOME}/.codex/sessions" ]]; then
    append_notice "warning" \
      "未检测到 ~/.codex/sessions，所以 Codex 面板大概率会为空。" \
      "No ~/.codex/sessions directory was found, so the Codex panels will likely be empty."
  elif ! find "${HOME}/.codex/sessions" -name 'rollout-*.jsonl' -print -quit 2>/dev/null | grep -q .; then
    append_notice "warning" \
      "检测到了 ~/.codex/sessions，但里面还没有会话记录，所以 Codex 面板会为空。" \
      "The ~/.codex/sessions directory exists, but no session records were found, so the Codex panels will be empty."
  fi
}

capture_json_command() {
  local target_var="$1"
  local fallback="$2"
  local flag_var="$3"
  local zh="$4"
  local en="$5"
  shift 5

  local err_file output status error_text
  err_file="$(mktemp)"
  if output="$("$@" 2>"$err_file")"; then
    rm -f "$err_file"
    if [[ -n "$output" ]]; then
      printf -v "$target_var" '%s' "$output"
    else
      printf -v "$target_var" '%s' "$fallback"
    fi
    return 0
  fi

  status=$?
  error_text="$(tr '\n' ' ' <"$err_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  rm -f "$err_file"

  if [[ "${!flag_var}" -eq 0 ]]; then
    append_notice "warning" "$zh" "$en"
    if [[ -n "$error_text" ]]; then
      print_notice_line "WARN" "${zh} 原因：${error_text}"
    else
      print_notice_line "WARN" "$zh"
    fi
    printf -v "$flag_var" 1
  fi

  printf -v "$target_var" '%s' "$fallback"
  # Keep building the dashboard even if one data source is unavailable.
  return 0
}

JSON_JOB_FILES=()
JSON_RUNNING_PIDS=()

reap_json_running_pids() {
  local pid active=()
  for pid in "${JSON_RUNNING_PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      active+=("$pid")
    fi
  done
  JSON_RUNNING_PIDS=("${active[@]}")
}

launch_json_command() {
  local target_var="$1"
  local fallback="$2"
  local flag_var="$3"
  local zh="$4"
  local en="$5"
  shift 5

  local out_file err_file status_file
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  status_file="$(mktemp)"
  (
    if "$@" >"$out_file" 2>"$err_file"; then
      printf '0' >"$status_file"
    else
      printf '%s' "$?" >"$status_file"
    fi
  ) &
  local pid="$!"
  JSON_JOB_FILES+=("${target_var}"$'\t'"${fallback}"$'\t'"${flag_var}"$'\t'"${zh}"$'\t'"${en}"$'\t'"${out_file}"$'\t'"${err_file}"$'\t'"${status_file}"$'\t'"${pid}")
  JSON_RUNNING_PIDS+=("$pid")
  while [[ "${#JSON_RUNNING_PIDS[@]}" -ge "$MAX_JSON_PARALLEL" ]]; do
    wait -n || true
    reap_json_running_pids
  done
}

finish_json_command_jobs() {
  local job
  for job in "${JSON_JOB_FILES[@]}"; do
    local target_var fallback flag_var zh en out_file err_file status_file pid
    IFS=$'\t' read -r target_var fallback flag_var zh en out_file err_file status_file pid <<<"$job"
    wait "$pid" || true

    local status output error_text
    output="$(cat "$out_file" 2>/dev/null || true)"
    status="$(cat "$status_file" 2>/dev/null || echo 1)"
    error_text="$(tr '\n' ' ' <"$err_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    rm -f "$out_file" "$err_file" "$status_file"

    if [[ "$status" == "0" ]]; then
      if [[ -n "$output" ]]; then
        printf -v "$target_var" '%s' "$output"
      else
        printf -v "$target_var" '%s' "$fallback"
      fi
      continue
    fi

    if [[ "${!flag_var}" -eq 0 ]]; then
      append_notice "warning" "$zh" "$en"
      if [[ -n "$error_text" ]]; then
        print_notice_line "WARN" "${zh} 原因：${error_text}"
      else
        print_notice_line "WARN" "$zh"
      fi
      printf -v "$flag_var" 1
    fi

    printf -v "$target_var" '%s' "$fallback"
  done
  JSON_JOB_FILES=()
}

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

check_required_tools
ensure_refresh_token
DASHBOARD_REFRESH_TOKEN="$(<"$TOKEN_FILE")"
export DASHBOARD_REFRESH_TOKEN
add_data_source_notices
resolve_ccusage_command
SERVER_READY_PID=""
if [[ "$FROM_SERVER" -eq 0 ]]; then
  ensure_server &
  SERVER_READY_PID="$!"
fi

if [[ "$CCUSAGE_AVAILABLE" -eq 1 ]]; then
  launch_json_command DAILY '{"daily":[]}' CLAUDE_TOOL_NOTICE_SENT \
    'Claude Code 用量数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 Claude Code 使用记录。' \
    'Claude Code metrics could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have Claude Code usage records yet.' \
    "${CCUSAGE_CMD[@]}" claude daily --json --breakdown
  launch_json_command WEEKLY '{"weekly":[]}' CLAUDE_TOOL_NOTICE_SENT \
    'Claude Code 用量数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 Claude Code 使用记录。' \
    'Claude Code metrics could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have Claude Code usage records yet.' \
    "${CCUSAGE_CMD[@]}" claude weekly --json --breakdown
  launch_json_command MONTHLY '{"monthly":[]}' CLAUDE_TOOL_NOTICE_SENT \
    'Claude Code 用量数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 Claude Code 使用记录。' \
    'Claude Code metrics could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have Claude Code usage records yet.' \
    "${CCUSAGE_CMD[@]}" claude monthly --json --breakdown
  launch_json_command CLAUDE_SESSIONS '{"sessions":[]}' CLAUDE_TOOL_NOTICE_SENT \
    'Claude Code 对话数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 Claude Code 使用记录。' \
    'Claude Code session data could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have Claude Code usage records yet.' \
    "${CCUSAGE_CMD[@]}" claude session --json
  if [[ "$INCLUDE_MIXED_TOTALS" == "1" ]]; then
    launch_json_command MIXED_DAILY '{"daily":[]}' CLAUDE_TOOL_NOTICE_SENT \
      '综合总用量数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 AI 使用记录。' \
      'Combined usage totals could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have AI usage records yet.' \
      "${CCUSAGE_CMD[@]}" daily --json --breakdown
    launch_json_command MIXED_WEEKLY '{"weekly":[]}' CLAUDE_TOOL_NOTICE_SENT \
      '综合总用量数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 AI 使用记录。' \
      'Combined usage totals could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have AI usage records yet.' \
      "${CCUSAGE_CMD[@]}" weekly --json --breakdown
    launch_json_command MIXED_MONTHLY '{"monthly":[]}' CLAUDE_TOOL_NOTICE_SENT \
      '综合总用量数据加载失败。可能无法运行 ccusage，当前网络/npm 不可用，或这台电脑上还没有 AI 使用记录。' \
      'Combined usage totals could not be loaded. ccusage may fail to run, npm/network access may be blocked, or this machine may not have AI usage records yet.' \
      "${CCUSAGE_CMD[@]}" monthly --json --breakdown
  else
    MIXED_DAILY='{"daily":[]}'
    MIXED_WEEKLY='{"weekly":[]}'
    MIXED_MONTHLY='{"monthly":[]}'
  fi
  launch_json_command CODEX_DAILY '{"daily":[]}' CODEX_TOOL_NOTICE_SENT \
    'Codex 用量数据加载失败。可能无法运行 ccusage codex，当前网络/npm 不可用，或这台电脑上还没有 Codex 使用记录。' \
    'Codex metrics could not be loaded. ccusage codex may fail to run, npm/network access may be blocked, or this machine may not have Codex usage records yet.' \
    "${CCUSAGE_CMD[@]}" codex daily --json
  CODEX_WEEKLY='{"weekly":[]}'
  launch_json_command CODEX_MONTHLY '{"monthly":[]}' CODEX_TOOL_NOTICE_SENT \
    'Codex 用量数据加载失败。可能无法运行 ccusage codex，当前网络/npm 不可用，或这台电脑上还没有 Codex 使用记录。' \
    'Codex metrics could not be loaded. ccusage codex may fail to run, npm/network access may be blocked, or this machine may not have Codex usage records yet.' \
    "${CCUSAGE_CMD[@]}" codex monthly --json
  launch_json_command CODEX_SESSIONS '{"sessions":[]}' CODEX_TOOL_NOTICE_SENT \
    'Codex 用量数据加载失败。可能无法运行 ccusage codex，当前网络/npm 不可用，或这台电脑上还没有 Codex 使用记录。' \
    'Codex metrics could not be loaded. ccusage codex may fail to run, npm/network access may be blocked, or this machine may not have Codex usage records yet.' \
    "${CCUSAGE_CMD[@]}" codex session --json
else
  DAILY='{"daily":[]}'
  WEEKLY='{"weekly":[]}'
  MONTHLY='{"monthly":[]}'
  CLAUDE_SESSIONS='{"sessions":[]}'
  MIXED_DAILY='{"daily":[]}'
  MIXED_WEEKLY='{"weekly":[]}'
  MIXED_MONTHLY='{"monthly":[]}'
  CODEX_DAILY='{"daily":[]}'
  CODEX_WEEKLY='{"weekly":[]}'
  CODEX_MONTHLY='{"monthly":[]}'
  CODEX_SESSIONS='{"sessions":[]}'
fi
finish_json_command_jobs
export DAILY WEEKLY MONTHLY CLAUDE_SESSIONS MIXED_DAILY MIXED_WEEKLY MIXED_MONTHLY CODEX_DAILY CODEX_WEEKLY CODEX_MONTHLY CODEX_SESSIONS
export GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
export DASHBOARD_SERVER_URL="$SERVER_URL"
export ENV_NOTICES

if [[ -n "$SERVER_READY_PID" ]]; then
  wait "$SERVER_READY_PID"
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
from datetime import date, timedelta
template_path, out_path = sys.argv[1], sys.argv[2]

_codex_meta_cache = {}
_claude_title_cache = None

def clean_title(value, limit=80):
    text = " ".join(str(value or "").replace("\r", "\n").split())
    if not text:
        return None
    return text[:limit]

def claude_title_map():
    global _claude_title_cache
    if _claude_title_cache is not None:
        return _claude_title_cache
    import glob
    title_map = {}
    for path in sorted(glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))):
        sid = os.path.basename(path).replace(".jsonl", "")
        ai_title = None
        last_prompt = None
        first_user = None
        first_timestamp = None
        last_timestamp = None
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    try:
                        entry = json.loads(line)
                    except Exception:
                        continue
                    ts = entry.get("timestamp")
                    if ts:
                        if not first_timestamp:
                            first_timestamp = ts
                        last_timestamp = ts
                    if not ai_title and entry.get("type") == "ai-title" and entry.get("aiTitle"):
                        ai_title = clean_title(entry.get("aiTitle"))
                    if not last_prompt and entry.get("type") == "last-prompt" and entry.get("lastPrompt"):
                        last_prompt = clean_title(entry.get("lastPrompt"))
                    if first_user:
                        continue
                    if entry.get("type") != "user":
                        continue
                    message = entry.get("message") or {}
                    content = message.get("content")
                    text = None
                    if isinstance(content, str):
                        text = content
                    elif isinstance(content, list):
                        parts = []
                        for item in content:
                            if not isinstance(item, dict):
                                continue
                            if item.get("type") == "text" and item.get("text"):
                                parts.append(item.get("text"))
                        if parts:
                            text = "\n".join(parts)
                    text = clean_title(text)
                    if text:
                        first_user = text
        except Exception:
            continue
        title_map[sid] = {
            "title": ai_title or last_prompt or first_user,
            "first_timestamp": first_timestamp,
            "last_timestamp": last_timestamp,
        }
    _claude_title_cache = title_map
    return title_map

def claude_project_label(raw):
    bits = [part for part in str(raw or "").split("-") if part]
    return bits[-1] if bits else "claude"

def codex_project_label(raw):
    text = str(raw or "").rstrip("/")
    if not text:
        return "codex"
    return os.path.basename(text) or text

def codex_session_path(s):
    fn = s.get("sessionFile") or ""
    if not fn:
        return None
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
        return None
    return path

def codex_metadata(s):
    """Extract display title and project from a Codex rollout file."""
    fn = s.get("sessionFile") or ""
    cache_key = fn or s.get("sessionId") or json.dumps(s, sort_keys=True)
    if cache_key in _codex_meta_cache:
        return _codex_meta_cache[cache_key]

    title = None
    project = None
    path = codex_session_path(s)
    try:
        if path:
            with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                for line in fh:
                    try:
                        e = json.loads(line)
                    except Exception:
                        continue
                    p = e.get("payload") or {}
                    if not project and e.get("type") == "session_meta":
                        cwd = p.get("cwd")
                        if cwd:
                            project = codex_project_label(cwd)
                    if title or e.get("type") != "response_item":
                        continue
                    if p.get("type") != "message" or p.get("role") != "user":
                        continue
                    for c in (p.get("content") or []):
                        t = c.get("text") or ""
                        if not t:
                            continue
                        stripped = t.strip()
                        if stripped.startswith("<") or stripped.startswith("# AGENTS.md"):
                            continue
                        if stripped.startswith("# .pen ") or stripped.startswith("## Memory"):
                            continue
                        if stripped.startswith("# Files mentioned"):
                            continue
                        first = stripped.split("\n", 1)[0].strip()
                        if not first:
                            continue
                        if first.startswith("[$") and "SKILL.md" in first:
                            continue
                        # shorten long URLs to domain + path hint
                        if first.startswith("http://") or first.startswith("https://"):
                            import re as _re
                            m = _re.match(r"https?://(?:www\.)?([^/]+)(/[^?#]*)?", first)
                            if m:
                                first = m.group(1) + (m.group(2) or "")
                                if len(first) > 50:
                                    first = first[:47] + "..."
                        if first:
                            title = first[:80]
                            break
                    if title and project:
                        break
    except Exception:
        pass

    if not project:
        project = codex_project_label(
            s.get("project")
            or s.get("projectPath")
            or s.get("cwd")
            or s.get("workspace")
            or ""
        )

    meta = {"title": title, "project": project}
    _codex_meta_cache[cache_key] = meta
    return meta

def codex_title(s):
    return codex_metadata(s).get("title")

def codex_project(s):
    return codex_metadata(s).get("project") or "codex"

def build_project_rows(sessions):
    projects = {}
    for s in sessions or []:
        name = s.get("project") or "unknown"
        bucket = projects.setdefault(name, {
            "project": name,
            "sessions": 0,
            "costUSD": 0,
            "totalTokens": 0,
            "lastTimestamp": "",
            "models": set(),
        })
        bucket["sessions"] += 1
        bucket["costUSD"] += s.get("costUSD") or 0
        bucket["totalTokens"] += s.get("totalTokens") or 0
        ts = s.get("timestamp") or s.get("date") or ""
        if ts > bucket["lastTimestamp"]:
            bucket["lastTimestamp"] = ts
        bucket["models"].update(s.get("models") or [])
    out = []
    for item in projects.values():
        fixed = dict(item)
        fixed["models"] = sorted(fixed["models"])
        fixed["date"] = (fixed["lastTimestamp"] or "")[:10]
        out.append(fixed)
    return sorted(out, key=lambda r: (r.get("costUSD") or 0, r.get("totalTokens") or 0), reverse=True)

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
claude_sessions_raw = load_env_json("CLAUDE_SESSIONS", {"sessions": []})
codex_daily = load_env_json("CODEX_DAILY", {"daily": []})
codex_weekly = load_env_json("CODEX_WEEKLY", {"weekly": []})
codex_monthly = load_env_json("CODEX_MONTHLY", {"monthly": []})
codex_sessions = load_env_json("CODEX_SESSIONS", {"sessions": []})
mixed_daily = load_env_json("MIXED_DAILY", {"daily": []})
mixed_weekly = load_env_json("MIXED_WEEKLY", {"weekly": []})
mixed_monthly = load_env_json("MIXED_MONTHLY", {"monthly": []})

def normalize_period_rows(rows, grain):
    key_by_grain = {
        "daily": "date",
        "weekly": "week",
        "monthly": "month",
    }
    primary_key = key_by_grain[grain]
    out = []
    for row in rows or []:
        if not isinstance(row, dict):
            out.append(row)
            continue
        fixed = dict(row)
        period = fixed.get("period")
        if period and not fixed.get(primary_key):
            fixed[primary_key] = period
        out.append(fixed)
    return out

def normalize_summary(scope, totals):
    totals = totals or {}
    if scope == "claude":
        return {
            "cost": totals.get("totalCost", 0) or 0,
            "tokens": totals.get("totalTokens", 0) or 0,
            "cacheRead": totals.get("cacheReadTokens", 0) or 0,
        }
    return {
        "cost": totals.get("costUSD", 0) or 0,
        "tokens": totals.get("totalTokens", 0) or 0,
        "cacheRead": totals.get("cachedInputTokens", 0) or 0,
    }

def summarize_rows(scope, rows):
    rows = rows or []
    if scope == "claude":
        return {
            "cost": sum((r.get("totalCost", 0) or 0) for r in rows),
            "tokens": sum((r.get("totalTokens", 0) or 0) for r in rows),
            "cacheRead": sum((r.get("cacheReadTokens", 0) or 0) for r in rows),
        }
    return {
        "cost": sum((r.get("costUSD", 0) or 0) for r in rows),
        "tokens": sum((r.get("totalTokens", 0) or 0) for r in rows),
        "cacheRead": sum((r.get("cachedInputTokens", 0) or 0) for r in rows),
    }

def rows_for_year(rows, year):
    prefix = f"{year}-"
    return [r for r in rows if str(r.get("date") or "").startswith(prefix)]

def current_week_key():
    today = date.today()
    week_start = today - timedelta(days=today.isoweekday() - 1)
    return week_start.isoformat()

def current_month_key():
    today = date.today()
    return f"{today.year}-{today.month:02d}"

def row_by_key(rows, key_name, expected):
    for row in rows or []:
        if str(row.get(key_name) or "") == expected:
            return row
    return None

def build_summary(scope, daily_rows, weekly_rows, monthly_rows, all_totals):
    today = date.today()

    summary = {
        "all": normalize_summary(scope, all_totals),
        "ranges": {},
        "years": {},
    }

    today_row = row_by_key(daily_rows, "date", today.isoformat())
    summary["ranges"]["today"] = summarize_rows(scope, [today_row] if today_row else [])

    if scope == "claude":
        week_row = row_by_key(weekly_rows, "week", current_week_key())
        month_row = row_by_key(monthly_rows, "month", current_month_key())
        summary["ranges"]["week"] = summarize_rows(scope, [week_row] if week_row else [])
        summary["ranges"]["month"] = summarize_rows(scope, [month_row] if month_row else [])
    else:
        week_start = today - timedelta(days=today.isoweekday() - 1)
        week_end = week_start + timedelta(days=6)
        month_prefix = current_month_key() + "-"
        summary["ranges"]["week"] = summarize_rows(
            scope,
            [r for r in daily_rows if week_start.isoformat() <= str(r.get("date") or "") <= week_end.isoformat()],
        )
        month_row = row_by_key(monthly_rows, "month", current_month_key())
        if month_row:
            summary["ranges"]["month"] = summarize_rows(scope, [month_row])
        else:
            summary["ranges"]["month"] = summarize_rows(
                scope,
                [r for r in daily_rows if str(r.get("date") or "").startswith(month_prefix)],
            )

    years = sorted({str(r.get("date", ""))[:4] for r in daily_rows if r.get("date")}, reverse=True)
    for year in years:
        if monthly_rows:
            summary["years"][year] = summarize_rows(
                scope,
                [r for r in monthly_rows if str(r.get("month") or "").startswith(f"{year}-")],
            )
        else:
            summary["years"][year] = summarize_rows(scope, rows_for_year(daily_rows, year))
    return summary

claude_daily = normalize_period_rows(d.get("daily", []), "daily")
claude_weekly = normalize_period_rows(w.get("weekly", []), "weekly")
claude_monthly = normalize_period_rows(m.get("monthly", []), "monthly")
codex_daily_rows = normalize_period_rows(codex_daily.get("daily", []), "daily")
codex_weekly_rows = normalize_period_rows(codex_weekly.get("weekly", []), "weekly")
codex_monthly_rows = normalize_period_rows(codex_monthly.get("monthly", []), "monthly")
mixed_daily_rows = normalize_period_rows(mixed_daily.get("daily", []), "daily")
mixed_weekly_rows = normalize_period_rows(mixed_weekly.get("weekly", []), "weekly")
mixed_monthly_rows = normalize_period_rows(mixed_monthly.get("monthly", []), "monthly")
claude_titles = claude_title_map()

claude_session_rows = [
    {
        "sessionId": s.get("sessionId"),
        "date": ((claude_titles.get(s.get("sessionId")) or {}).get("last_timestamp") or s.get("lastActivity") or "")[:10],
        "timestamp": (claude_titles.get(s.get("sessionId")) or {}).get("last_timestamp") or s.get("lastActivity") or "",
        "title": ((claude_titles.get(s.get("sessionId")) or {}).get("title")) or f"{claude_project_label(s.get('projectPath'))} · {(s.get('sessionId') or '')[:8]}",
        "project": claude_project_label(s.get("projectPath")),
        "costUSD": s.get("totalCost") or 0,
        "totalTokens": s.get("totalTokens") or 0,
        "models": s.get("modelsUsed") or [],
    }
    for s in claude_sessions_raw.get("sessions", [])
]
codex_session_rows = [
    {
        "sessionId": s.get("sessionId"),
        "date": (s.get("lastActivity") or "")[:10],
        "timestamp": s.get("lastActivity") or "",
        "title": codex_title(s) or (s.get("sessionFile") or "")[-12:],
        "project": codex_project(s),
        "costUSD": s.get("costUSD") or 0,
        "totalTokens": s.get("totalTokens") or 0,
        "models": sorted(list((s.get("models") or {}).keys())),
    }
    for s in codex_sessions.get("sessions", [])
]

payload = {
    "daily":   claude_daily,
    "weekly":  claude_weekly,
    "monthly": claude_monthly,
    "totals":  m.get("totals", {}),
    "summary": build_summary("claude", claude_daily, claude_weekly, claude_monthly, m.get("totals", {})),
    "sessions": claude_session_rows,
    "projects": build_project_rows(claude_session_rows),
    "codex": {
        "daily":   codex_daily_rows,
        "weekly":  codex_weekly_rows,
        "monthly": codex_monthly_rows,
        "totals": codex_monthly.get("totals", {}),
        "summary": build_summary("codex", codex_daily_rows, codex_weekly_rows, codex_monthly_rows, codex_monthly.get("totals", {})),
        "sessions": codex_session_rows,
        "projects": build_project_rows(codex_session_rows),
    },
    "generatedAt": os.environ["GENERATED_AT"],
    "notices": load_env_json("ENV_NOTICES", []),
    "combined": {
        "summary": build_summary("claude", mixed_daily_rows, mixed_weekly_rows, mixed_monthly_rows, mixed_monthly.get("totals", {})),
    },
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
import json
import os

notices = json.loads(os.environ.get("ENV_NOTICES", "[]"))
if notices:
    print()
    print("## Environment notices")
    print()
    for item in notices:
        msg = (item.get("en") or item.get("zh") or "").strip()
        if msg:
            print(f"- {msg}")
PY
python3 - <<'PY'
import json, os, re
from datetime import datetime, timedelta

def normalize_period_rows(rows, grain):
    key_by_grain = {
        "daily": "date",
        "weekly": "week",
        "monthly": "month",
    }
    primary_key = key_by_grain[grain]
    out = []
    for row in rows or []:
        if not isinstance(row, dict):
            out.append(row)
            continue
        fixed = dict(row)
        period = fixed.get("period")
        if period and not fixed.get(primary_key):
            fixed[primary_key] = period
        out.append(fixed)
    return out

daily   = normalize_period_rows(json.loads(os.environ["DAILY"]).get("daily", []), "daily")
monthly = normalize_period_rows(json.loads(os.environ["MONTHLY"]).get("monthly", []), "monthly")

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
