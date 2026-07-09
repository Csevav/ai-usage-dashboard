---
name: ai-usage-dashboard
description: 生成并打开本地 AI 用量看板，用于查看 Codex 和 Claude Code 的 token 使用量、费用趋势、按对话排行，以及按天/周/月切换的明细视图。用户想打开本地 dashboard、刷新或重建页面、比较 Codex 和 Claude Code 用量、排查看板为何空白或部分数据缺失时使用。
version: 0.1.7
tags:
  - usage
  - dashboard
  - codex
  - claude
  - analytics
dependencies:
  - name: ccusage
    kind: cli
    source:
      type: npm
      package: ccusage
    detect:
      version_command: "ccusage --version"
---

# AI Usage Dashboard

Use this skill when the user wants the browser dashboard itself, not just a one-line terminal total. Trigger it for requests to open the local AI usage dashboard, compare Codex and Claude Code side by side, refresh or rebuild the dashboard page, inspect day/week/month trends, or investigate why panels are empty.

Do not use this skill for a simple terminal-only total, a single date lookup with no dashboard output, or generic frontend work unrelated to usage analytics.

## Trigger requests

- Open the local AI usage dashboard in the browser
- Compare Claude Code and Codex usage side by side
- Inspect daily, weekly, monthly, or yearly cost trends
- View per-conversation rankings instead of a terminal-only total
- Diagnose why the dashboard opened but some panels are empty
- Refresh or rebuild the dashboard after new local usage data was created

## Workflow

Run the bundled builder:

```bash
bash ai-usage-dashboard/build.sh
```

Use these options when needed:

```bash
bash ai-usage-dashboard/build.sh --no-open
bash ai-usage-dashboard/build.sh --no-open --no-summary
```

If the skill is installed in the local Codex skills directory, run it from the installed path so the copied runtime files stay in sync.

Execute in this order:

- If the user asks to open the dashboard, run with default options
- If the user asks for data only, run with `--no-open`
- If the user asks for quiet mode, add `--no-summary`
- If rebuild is requested during a session, re-run the same command instead of changing data sources

After execution, always report:

- Whether build succeeded
- Whether the dashboard opened
- If any panel is empty, the likely reason
- Whether the issue is a missing local history problem, a data command failure, or a local refresh server problem

## Requirements

Environment:

- `node` 18+
- `python3`
- network access for `npx --yes ccusage`

CLI dependency:

- `ccusage` is the required external CLI for both sources
- Claude data uses `ccusage claude ...`
- Codex data uses the `ccusage codex ...` subcommand, not a separate `ccusage-codex` package
- use a recent `ccusage` version that exposes the `codex` focused command

Quick preflight:

```bash
ccusage --version
ccusage --help
python3 --version
```

Optional local install when `npx` download is blocked or too slow:

```bash
npm install -g ccusage
```

Local data dependency:

- Claude history under `~/.claude/projects`
- Codex history under `~/.codex/sessions`

Bundled file dependency:

- `template.html`
- `scripts/dashboard_server.py`

## Diagnosis Order

When the dashboard opens but data looks wrong, diagnose in this order:

1. Check whether the build completed or exited early.
2. Check whether `ccusage` or `ccusage codex` failed and fell back to empty data.
3. Check whether the machine actually has local usage history under `~/.claude/projects` or `~/.codex/sessions`.
4. Check whether the local refresh server is healthy and serving the regenerated page.
5. Re-run the same build command before changing data sources or editing the HTML.

## Expected result

- Dashboard HTML is regenerated in the local dashboard workspace
- A local web address is served by the script
- If open mode is enabled, browser opens to the served dashboard page
- User can switch day/week/month and inspect per-conversation rankings

## Troubleshooting

- If `ccusage` or `ccusage codex` returns empty data, the dashboard can still open, but some panels may be blank.
- If `ccusage codex` fails with `Command not found: codex`, upgrade `ccusage` first. Older releases do not expose the Codex focused command yet.
- If local port is occupied, stop the stale process first or set `AI_USAGE_DASHBOARD_PORT` before running.
- If `template.html` or `scripts/dashboard_server.py` is missing from the installed copy, reinstall or sync the skill/package files before retrying.
- If command execution fails, show the exact failing step and retry command rather than only saying "failed".
- If only one source has data, keep rendering available panels and explain which source is missing.
- If refresh succeeds but the data still looks old, verify the regenerated `index.html` timestamp and then reload the served page instead of inspecting the raw template.
