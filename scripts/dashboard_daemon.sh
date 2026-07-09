#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

export AI_USAGE_DASHBOARD_HOME="${AI_USAGE_DASHBOARD_HOME:-${HOME}/.ai-usage-dashboard}"
export AI_USAGE_DASHBOARD_PORT="${AI_USAGE_DASHBOARD_PORT:-46327}"

if [[ -f "${ROOT_DIR}/scripts/copy-dashboard.sh" ]]; then
  bash "${ROOT_DIR}/scripts/copy-dashboard.sh" >/dev/null
fi

DIR="${AI_USAGE_DASHBOARD_HOME}"
PORT="${AI_USAGE_DASHBOARD_PORT}"
SERVER_SCRIPT="${DIR}/scripts/dashboard_server.py"
TOKEN_FILE="${DIR}/.refresh-token"
INDEX_FILE="${DIR}/index.html"

if [[ ! -f "${TOKEN_FILE}" ]]; then
  python3 - "${TOKEN_FILE}" <<'PY'
import secrets
import sys

path = sys.argv[1]
with open(path, "w", encoding="utf-8") as fh:
    fh.write(secrets.token_hex(32))
PY
fi

if [[ ! -f "${INDEX_FILE}" ]]; then
  bash "${DIR}/build.sh" --no-open --no-summary
fi

exec python3 "${SERVER_SCRIPT}" --dir "${DIR}" --port "${PORT}" --token-file "${TOKEN_FILE}"
