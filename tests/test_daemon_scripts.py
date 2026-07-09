import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_JSON = ROOT / "package.json"
DAEMON_SH = ROOT / "scripts" / "dashboard_daemon.sh"
AGENT_SH = ROOT / "scripts" / "manage_launch_agent.sh"
README = ROOT / "README.md"


class DaemonScriptRegressionTest(unittest.TestCase):
    def test_package_exposes_daemon_binary_and_scripts(self):
        package = json.loads(PACKAGE_JSON.read_text(encoding="utf-8"))
        self.assertEqual(
            package["bin"]["ai-usage-dashboard-daemon"],
            "./bin/ai-usage-dashboard-daemon",
        )
        self.assertIn("scripts/dashboard_daemon.sh", package["files"])
        self.assertIn("scripts/manage_launch_agent.sh", package["files"])

    def test_daemon_runs_fixed_port_server_without_auto_refresh_loop(self):
        text = DAEMON_SH.read_text(encoding="utf-8")
        self.assertIn('export AI_USAGE_DASHBOARD_PORT="${AI_USAGE_DASHBOARD_PORT:-46327}"', text)
        self.assertIn('if [[ ! -f "${INDEX_FILE}" ]]; then', text)
        self.assertIn('bash "${DIR}/build.sh" --no-open --no-summary', text)
        self.assertNotIn("while true", text)
        self.assertIn('exec python3 "${SERVER_SCRIPT}" --dir "${DIR}" --port "${PORT}" --token-file "${TOKEN_FILE}"', text)

    def test_launch_agent_keeps_local_daemon_alive(self):
        text = AGENT_SH.read_text(encoding="utf-8")
        self.assertIn('LABEL="com.csevav.ai-usage-dashboard.daemon.${PORT}"', text)
        self.assertIn("<key>RunAtLoad</key>", text)
        self.assertIn("<key>KeepAlive</key>", text)
        self.assertIn('launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"', text)
        self.assertIn('launchctl bootout "gui/$(id -u)" "${PLIST_PATH}"', text)

    def test_readme_documents_fixed_local_address(self):
        text = README.read_text(encoding="utf-8")
        self.assertIn("http://127.0.0.1:46327", text)
        self.assertIn("ai-usage-dashboard-daemon install", text)
        self.assertIn("只有点击页面里的刷新按钮，才会重新执行统计命令", text)


if __name__ == "__main__":
    unittest.main()
