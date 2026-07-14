import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SH = ROOT / "build.sh"
BUILD_PS1 = ROOT / "build.ps1"
BUILD_PY = ROOT / "scripts" / "build_dashboard.py"
INSTALL_JS = ROOT / "scripts" / "install.js"
PACKAGE_JSON = ROOT / "package.json"
TEMPLATE_HTML = ROOT / "template.html"


class BuildScriptRegressionTest(unittest.TestCase):
    def test_unix_wrapper_calls_python_core(self):
        text = BUILD_SH.read_text(encoding="utf-8")
        self.assertIn('exec python3 "${SCRIPT_DIR}/scripts/build_dashboard.py"', text)
        self.assertIn('--source-dir "${SCRIPT_DIR}"', text)
        self.assertIn('--home "${HOME_DIR}"', text)

    def test_powershell_wrapper_exists_for_windows(self):
        text = BUILD_PS1.read_text(encoding="utf-8")
        self.assertIn('$ScriptDir/scripts/build_dashboard.py', text)
        self.assertIn('Get-Command py', text)
        self.assertIn('Get-Command python', text)

    def test_python_core_prefers_local_ccusage_and_falls_back_to_npx(self):
        text = BUILD_PY.read_text(encoding="utf-8")
        self.assertIn('if shutil.which("ccusage")', text)
        self.assertIn('return ["ccusage"]', text)
        self.assertIn('if shutil.which("npx")', text)
        self.assertIn('return ["npx", "--yes", "ccusage"]', text)
        self.assertIn("未检测到 ccusage，也未检测到 npx", text)

    def test_python_core_uses_ccusage_focused_commands(self):
        text = BUILD_PY.read_text(encoding="utf-8")
        self.assertIn('["claude", "daily", "--json", "--breakdown"]', text)
        self.assertIn('["claude", "weekly", "--json", "--breakdown"]', text)
        self.assertIn('["claude", "monthly", "--json", "--breakdown"]', text)
        self.assertIn('["claude", "session", "--json"]', text)
        self.assertIn('["codex", "daily", "--json"]', text)
        self.assertIn('["codex", "monthly", "--json"]', text)
        self.assertIn('["codex", "session", "--json"]', text)

    def test_python_core_normalizes_period_rows_and_builds_projects(self):
        text = BUILD_PY.read_text(encoding="utf-8")
        self.assertIn("def normalize_period_rows(rows: list[Any], grain: str)", text)
        self.assertIn('key_by_grain = {"daily": "date", "weekly": "week", "monthly": "month"}', text)
        self.assertIn("def build_project_rows(sessions: list[dict[str, Any]])", text)
        self.assertIn('bucket["models"].update(session.get("models") or [])', text)
        self.assertIn("except ImportError", text)
        self.assertIn('["netstat", "-ano", "-p", "tcp"]', text)
        self.assertIn('["taskkill", "/PID", pid, "/F"]', text)
        self.assertIn('["ss", "-ltnp"]', text)

    def test_python_core_renders_combined_summary(self):
        text = BUILD_PY.read_text(encoding="utf-8")
        self.assertIn('"combined": {', text)
        self.assertIn('build_summary("claude", mixed_daily_rows, mixed_weekly_rows, mixed_monthly_rows', text)
        self.assertIn('html = html.replace("__DATA__", dump_json_for_script(payload))', text)

    def test_install_script_is_cross_platform(self):
        text = INSTALL_JS.read_text(encoding="utf-8")
        self.assertIn('const homeDir = process.env.AI_USAGE_DASHBOARD_HOME', text)
        self.assertIn('copyFile(path.join(root, "commands", "ai-usage.md")', text)
        self.assertIn('const rootCompatFiles = ["dashboard_daemon.sh"]', text)
        self.assertIn('build_dashboard.py', text)
        self.assertIn('dashboard_daemon.py', text)
        self.assertIn('manage_daemon.py', text)

    def test_package_uses_node_launcher_and_cross_platform_install(self):
        package = json.loads(PACKAGE_JSON.read_text(encoding="utf-8"))
        self.assertEqual(package["bin"]["ai-usage-dashboard"], "./bin/ai-usage-dashboard.js")
        self.assertEqual(package["bin"]["ai-usage-dashboard-daemon"], "./bin/ai-usage-dashboard-daemon.js")
        self.assertEqual(package["scripts"]["copy-dashboard"], "node ./scripts/install.js --dashboard")
        self.assertEqual(package["scripts"]["copy-command"], "node ./scripts/install.js --command")
        self.assertIn("build.ps1", package["files"])
        self.assertIn("scripts/build_dashboard.py", package["files"])
        self.assertIn("scripts/dashboard_daemon.py", package["files"])
        self.assertIn("scripts/install.js", package["files"])
        self.assertIn("scripts/manage_daemon.py", package["files"])

    def test_template_has_project_first_detail_tabs_for_all_scopes(self):
        text = TEMPLATE_HTML.read_text(encoding="utf-8")
        self.assertIn('data-i18n="detail_claude_title">Claude 明细', text)
        self.assertIn('data-i18n="detail_codex_title">Codex 明细', text)
        self.assertIn('data-i18n="detail_combined_title">综合明细', text)
        self.assertIn('class="detail-tabs" data-target="combined"', text)
        self.assertGreaterEqual(text.count('<button class="dtab active" data-mode="project"'), 3)
        self.assertIn('wireDetailCard("combined")', text)
        self.assertIn('refreshDetailForScope("combined")', text)


if __name__ == "__main__":
    unittest.main()
