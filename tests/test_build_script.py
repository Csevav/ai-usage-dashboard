import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SH = ROOT / "build.sh"
TEMPLATE_HTML = ROOT / "template.html"


class BuildScriptRegressionTest(unittest.TestCase):
    def test_capture_json_command_keeps_build_alive_on_source_failure(self):
        text = BUILD_SH.read_text(encoding="utf-8")
        match = re.search(r"capture_json_command\(\) \{(.*?)\n\}", text, re.DOTALL)
        self.assertIsNotNone(match, "capture_json_command() not found in build.sh")
        body = match.group(1)
        self.assertIn('printf -v "$target_var" \'%s\' "$fallback"', body)
        self.assertIn("return 0", body)
        self.assertNotIn('return "$status"', body)

    def test_build_script_normalizes_period_rows(self):
        text = BUILD_SH.read_text(encoding="utf-8")
        self.assertIn("def normalize_period_rows(rows, grain):", text)
        self.assertIn('fixed.get("period")', text)
        self.assertIn('"daily": "date"', text)
        self.assertIn('"weekly": "week"', text)
        self.assertIn('"monthly": "month"', text)

    def test_build_script_uses_ccusage_claude_focused_commands(self):
        text = BUILD_SH.read_text(encoding="utf-8")
        self.assertIn('"${CCUSAGE_CMD[@]}" claude daily --json --breakdown', text)
        self.assertIn('"${CCUSAGE_CMD[@]}" claude weekly --json --breakdown', text)
        self.assertIn('"${CCUSAGE_CMD[@]}" claude monthly --json --breakdown', text)
        self.assertIn('"${CCUSAGE_CMD[@]}" claude session --json', text)
        self.assertIn('launch_json_command DAILY', text)
        self.assertIn('launch_json_command WEEKLY', text)
        self.assertIn('launch_json_command MONTHLY', text)
        self.assertIn("launch_json_command DAILY '{\"daily\":[]}' CLAUDE_TOOL_NOTICE_SENT \\", text)
        self.assertIn("launch_json_command WEEKLY '{\"weekly\":[]}' CLAUDE_TOOL_NOTICE_SENT \\", text)
        self.assertIn("launch_json_command MONTHLY '{\"monthly\":[]}' CLAUDE_TOOL_NOTICE_SENT \\", text)

    def test_build_script_uses_ccusage_codex_focused_command(self):
        text = BUILD_SH.read_text(encoding="utf-8")
        self.assertIn('"${CCUSAGE_CMD[@]}" codex daily --json', text)
        self.assertIn('"${CCUSAGE_CMD[@]}" codex monthly --json', text)
        self.assertIn('"${CCUSAGE_CMD[@]}" codex session --json', text)
        self.assertNotIn("ccusage-codex", text)

    def test_build_script_prefers_local_ccusage_and_falls_back_to_npx(self):
        text = BUILD_SH.read_text(encoding="utf-8")
        self.assertIn("resolve_ccusage_command()", text)
        self.assertIn("command -v ccusage", text)
        self.assertIn("CCUSAGE_CMD=(ccusage)", text)
        self.assertIn("CCUSAGE_CMD=(npx --yes ccusage)", text)
        self.assertIn("未检测到 ccusage，也未检测到 npx", text)
        self.assertIn('if [[ "$CCUSAGE_AVAILABLE" -eq 1 ]]; then', text)

    def test_build_script_uses_ccusage_claude_session_totals_not_local_pricing(self):
        text = BUILD_SH.read_text(encoding="utf-8")
        self.assertIn('claude_sessions_raw = load_env_json("CLAUDE_SESSIONS", {"sessions": []})', text)
        self.assertIn('for s in claude_sessions_raw.get("sessions", [])', text)
        self.assertNotIn("PRICING = {", text)
        self.assertNotIn("title or sid[:8]", text)

    def test_build_script_exports_project_rollups(self):
        text = BUILD_SH.read_text(encoding="utf-8")
        self.assertIn("def build_project_rows(sessions):", text)
        self.assertIn('"project": claude_project_label(s.get("projectPath"))', text)
        self.assertIn('"project": codex_project(s)', text)
        self.assertIn('"projects": build_project_rows(claude_session_rows)', text)
        self.assertIn('"projects": build_project_rows(codex_session_rows)', text)
        self.assertIn('p.get("cwd")', text)

    def test_template_has_project_first_detail_tabs_for_all_scopes(self):
        text = TEMPLATE_HTML.read_text(encoding="utf-8")
        self.assertIn('data-i18n="detail_claude_title">Claude 明细', text)
        self.assertIn('data-i18n="detail_codex_title">Codex 明细', text)
        self.assertIn('data-i18n="detail_combined_title">综合明细', text)
        self.assertIn('class="detail-tabs" data-target="combined"', text)
        self.assertGreaterEqual(text.count('<button class="dtab active" data-mode="project"'), 3)
        self.assertIn('wireDetailCard("combined")', text)
        self.assertIn('refreshDetailForScope("combined")', text)

    def test_build_script_builds_summary_from_ccusage_totals(self):
        text = BUILD_SH.read_text(encoding="utf-8")
        self.assertNotIn("def command_totals(scope, since=None, until=None):", text)
        self.assertIn('INCLUDE_MIXED_TOTALS="${AI_USAGE_DASHBOARD_INCLUDE_MIXED:-0}"', text)
        self.assertIn('if [[ "$INCLUDE_MIXED_TOTALS" == "1" ]]; then', text)
        self.assertIn('"${CCUSAGE_CMD[@]}" daily --json --breakdown', text)
        self.assertIn('"${CCUSAGE_CMD[@]}" weekly --json --breakdown', text)
        self.assertIn('"${CCUSAGE_CMD[@]}" monthly --json --breakdown', text)
        self.assertIn('"combined": {', text)
        self.assertIn('"summary": build_summary("claude", mixed_daily_rows, mixed_weekly_rows, mixed_monthly_rows, mixed_monthly.get("totals", {}))', text)

    def test_build_script_limits_parallelism_and_overlaps_server_start(self):
        text = BUILD_SH.read_text(encoding="utf-8")
        self.assertIn('MAX_JSON_PARALLEL="${AI_USAGE_DASHBOARD_MAX_PARALLEL:-4}"', text)
        self.assertIn('while [[ "${#JSON_RUNNING_PIDS[@]}" -ge "$MAX_JSON_PARALLEL" ]]; do', text)
        self.assertIn('ensure_server &', text)
        self.assertIn('SERVER_READY_PID="$!"', text)
        self.assertIn('wait "$SERVER_READY_PID"', text)


if __name__ == "__main__":
    unittest.main()
