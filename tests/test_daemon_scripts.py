import json
import tempfile
import unittest
from pathlib import Path

import sys
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_JSON = ROOT / "package.json"
DAEMON_SH = ROOT / "scripts" / "dashboard_daemon.sh"
DAEMON_PY = ROOT / "scripts" / "dashboard_daemon.py"
MANAGER_PY = ROOT / "scripts" / "manage_daemon.py"
README = ROOT / "README.md"
sys.path.insert(0, str(ROOT / "scripts"))

from manage_daemon import (  # noqa: E402
    linux_service_content,
    linux_service_name,
    manage_linux,
    manage_windows,
    plist_content,
    windows_runner_cmd,
    windows_task_name,
)


class DaemonScriptRegressionTest(unittest.TestCase):
    def test_package_exposes_daemon_binary_and_scripts(self):
        package = json.loads(PACKAGE_JSON.read_text(encoding="utf-8"))
        self.assertEqual(
            package["bin"]["ai-usage-dashboard-daemon"],
            "./bin/ai-usage-dashboard-daemon.js",
        )
        self.assertIn("scripts/dashboard_daemon.py", package["files"])
        self.assertIn("scripts/manage_daemon.py", package["files"])
        self.assertIn("scripts/dashboard_daemon.sh", package["files"])

    def test_daemon_runs_fixed_port_server_without_auto_refresh_loop(self):
        text = DAEMON_SH.read_text(encoding="utf-8")
        self.assertIn('exec python3 "${SCRIPT_DIR}/scripts/manage_daemon.py"', (ROOT / "bin" / "ai-usage-dashboard-daemon").read_text(encoding="utf-8"))
        py_text = DAEMON_PY.read_text(encoding="utf-8")
        self.assertIn("ensure_token(paths.token_file)", py_text)
        self.assertIn("build_if_missing(paths)", py_text)
        self.assertIn("dashboard_server.py", py_text)

    def test_daemon_manager_supports_macos_and_windows(self):
        text = MANAGER_PY.read_text(encoding="utf-8")
        self.assertIn('choices=["install", "uninstall", "start", "stop", "restart", "status", "print-config", "run"]', text)
        self.assertIn('["schtasks", "/Create"', text)
        self.assertIn('["launchctl", "bootstrap"', text)
        self.assertIn('AIUsageDashboardDaemon-', text)
        self.assertIn('com.csevav.ai-usage-dashboard.daemon.', text)

    def test_windows_runner_and_task_name_are_stable(self):
        self.assertEqual(windows_task_name(46327), "AIUsageDashboardDaemon-46327")
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            runner = windows_runner_cmd(home, home)
            self.assertTrue(runner.exists())
            text = runner.read_text(encoding="utf-8")
            self.assertIn("dashboard_daemon.py", text)
            self.assertIn(str(home), text)

    def test_macos_plist_targets_python_daemon(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            plist = plist_content("com.example.ai-usage", home, 46327)
            self.assertIn("dashboard_daemon.py", plist)
            self.assertIn("<key>RunAtLoad</key>", plist)
            self.assertIn("<key>KeepAlive</key>", plist)
            self.assertIn("46327", plist)

    def test_linux_systemd_service_targets_python_daemon(self):
        self.assertEqual(linux_service_name(46327), "ai-usage-dashboard-daemon-46327.service")
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            service = linux_service_content(home, 46327)
            self.assertIn("dashboard_daemon.py", service)
            self.assertIn("Restart=always", service)
            self.assertIn("WantedBy=default.target", service)
            self.assertIn("46327", service)

    @mock.patch("manage_daemon.run_checked")
    def test_windows_install_uses_schtasks_and_reports_success(self, run_checked):
        run_checked.return_value = mock.Mock(returncode=0, stdout="", stderr="")
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            rc = manage_windows("install", home, home, 46327)
            self.assertEqual(rc, 0)
            calls = [call.args[0] for call in run_checked.call_args_list]
            self.assertEqual(calls[0][:2], ["schtasks", "/Create"])
            self.assertEqual(calls[1][:2], ["schtasks", "/Run"])

    @mock.patch("manage_daemon.run_checked")
    @mock.patch("manage_daemon.shutil.which", return_value="/usr/bin/systemctl")
    def test_linux_install_uses_systemctl_user_service(self, which_mock, run_checked):
        run_checked.return_value = mock.Mock(returncode=0, stdout="", stderr="")
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            with mock.patch("manage_daemon.systemd_user_dir", return_value=home / ".config" / "systemd" / "user"):
                rc = manage_linux("install", home, 46327)
                self.assertEqual(rc, 0)
                calls = [call.args[0] for call in run_checked.call_args_list]
                self.assertEqual(calls[0], ["systemctl", "--user", "daemon-reload"])
                self.assertEqual(calls[1][:4], ["systemctl", "--user", "enable", "--now"])

    def test_readme_documents_fixed_local_address(self):
        text = README.read_text(encoding="utf-8")
        self.assertIn("http://127.0.0.1:46327", text)
        self.assertIn("ai-usage-dashboard-daemon install", text)
        self.assertIn("只有点击页面里的刷新按钮，才会重新执行统计命令", text)
        self.assertIn("Task Scheduler", text)
        self.assertIn("systemd", text)


if __name__ == "__main__":
    unittest.main()
