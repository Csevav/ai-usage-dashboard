#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
if [[ -z "${ACTION}" ]]; then
  echo "Usage: $0 {install|uninstall|start|stop|restart|status|print-plist|run}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PORT="${AI_USAGE_DASHBOARD_PORT:-46327}"
HOME_DIR="${AI_USAGE_DASHBOARD_HOME:-${HOME}/.ai-usage-dashboard}"
LABEL="com.csevav.ai-usage-dashboard.daemon.${PORT}"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME_DIR}"
DAEMON_SCRIPT="${HOME_DIR}/dashboard_daemon.sh"

mkdir -p "${HOME}/Library/LaunchAgents"
mkdir -p "${LOG_DIR}"

write_plist() {
  cat >"${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>${DAEMON_SCRIPT}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
      <key>AI_USAGE_DASHBOARD_HOME</key>
      <string>${HOME_DIR}</string>
      <key>AI_USAGE_DASHBOARD_PORT</key>
      <string>${PORT}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>${HOME_DIR}</string>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/launch-agent.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/launch-agent.err.log</string>
  </dict>
</plist>
EOF
}

bootout_agent() {
  launchctl bootout "gui/$(id -u)" "${PLIST_PATH}" >/dev/null 2>&1 || true
}

bootstrap_agent() {
  launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"
  launchctl kickstart -k "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
}

case "${ACTION}" in
  install)
    write_plist
    bootout_agent
    bootstrap_agent
    echo "Installed AI Usage Dashboard daemon at http://127.0.0.1:${PORT}"
    echo "LaunchAgent: ${PLIST_PATH}"
    ;;
  uninstall)
    bootout_agent
    rm -f "${PLIST_PATH}"
    echo "Removed AI Usage Dashboard daemon: ${LABEL}"
    ;;
  start)
    [[ -f "${PLIST_PATH}" ]] || write_plist
    bootstrap_agent
    echo "Started AI Usage Dashboard daemon: ${LABEL}"
    ;;
  stop)
    bootout_agent
    echo "Stopped AI Usage Dashboard daemon: ${LABEL}"
    ;;
  restart)
    [[ -f "${PLIST_PATH}" ]] || write_plist
    bootout_agent
    bootstrap_agent
    echo "Restarted AI Usage Dashboard daemon: ${LABEL}"
    ;;
  status)
    if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
      echo "running ${LABEL} http://127.0.0.1:${PORT}"
    else
      echo "stopped ${LABEL} http://127.0.0.1:${PORT}"
      exit 1
    fi
    ;;
  print-plist)
    write_plist
    cat "${PLIST_PATH}"
    ;;
  run)
    exec /bin/bash "${DAEMON_SCRIPT}"
    ;;
  *)
    echo "Unknown action: ${ACTION}" >&2
    echo "Usage: $0 {install|uninstall|start|stop|restart|status|print-plist|run}" >&2
    exit 1
    ;;
esac
