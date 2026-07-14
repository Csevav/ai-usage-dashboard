#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${AI_USAGE_DASHBOARD_HOME:-${HOME}/.ai-usage-dashboard}"
SCRIPTS_DEST="${DEST}/scripts"
mkdir -p "$DEST"
mkdir -p "$SCRIPTS_DEST"

cp "${SCRIPT_DIR}/build.sh"      "$DEST/build.sh"
cp "${SCRIPT_DIR}/build.ps1"     "$DEST/build.ps1"
cp "${SCRIPT_DIR}/template.html" "$DEST/template.html"
cp "${SCRIPT_DIR}/scripts/dashboard_daemon.sh" "$DEST/dashboard_daemon.sh"
cp "${SCRIPT_DIR}/scripts/build_dashboard.py" "$SCRIPTS_DEST/build_dashboard.py"
cp "${SCRIPT_DIR}/scripts/dashboard_daemon.py" "$SCRIPTS_DEST/dashboard_daemon.py"
cp "${SCRIPT_DIR}/scripts/dashboard_server.py" "$SCRIPTS_DEST/dashboard_server.py"
cp "${SCRIPT_DIR}/scripts/manage_daemon.py" "$SCRIPTS_DEST/manage_daemon.py"
chmod +x "${DEST}/build.sh"
chmod +x "${DEST}/dashboard_daemon.sh"
chmod +x "${SCRIPTS_DEST}/build_dashboard.py"
chmod +x "${SCRIPTS_DEST}/dashboard_daemon.py"
chmod +x "${SCRIPTS_DEST}/manage_daemon.py"

VERSION="$(node -p "require('${SCRIPT_DIR}/package.json').version" 2>/dev/null || echo "unknown")"
echo "Dashboard files installed to $DEST (v${VERSION})"
