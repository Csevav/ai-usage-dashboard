---
name: usage-dashboard
description: Build and open a local AI usage dashboard for Codex and Claude Code. Use this when the user wants to view token usage, cost, daily or weekly trends, or per-conversation rankings in a browser dashboard instead of a plain terminal summary.
version: 0.1.3
tags:
  - codex
  - claude-code
  - usage
  - dashboard
  - cost
category: developer-tools
files:
  - agents/openai.yaml
  - build.sh
  - template.html
  - scripts/dashboard_server.py
---

# Usage Dashboard

## When to use

Use this skill when the user asks for any of these outcomes:

- Open a visual usage dashboard for Codex or Claude Code
- View token usage or cost trends in a browser
- Compare Codex and Claude Code usage side by side
- Check per-conversation usage rankings instead of only a terminal table
- Refresh or rebuild the local usage dashboard HTML

Typical phrases include:

- "open usage dashboard"
- "show my Codex usage visually"
- "看一下用量看板"
- "打开 token/cost dashboard"
- "按会话看用量排行"

## What it does

This skill reuses the bundled `build.sh` script to:

1. Collect Claude Code usage via `ccusage`
2. Collect Codex usage via `@ccusage/codex`
3. Build a local HTML dashboard
4. Start a tiny local refresh server
5. Open the dashboard in the browser unless `--no-open` is used

## Workflow

Run the local builder:

```bash
bash usage-dashboard/build.sh
```

Useful options:

```bash
bash usage-dashboard/build.sh --no-open
bash usage-dashboard/build.sh --no-open --no-summary
```

If the skill is installed under `~/.codex/skills/usage-dashboard`, the equivalent absolute-path form is:

```bash
bash ~/.codex/skills/usage-dashboard/build.sh
```

## Requirements

- `node` 18+
- `python3`
- network access for `npx --yes ccusage` and `npx --yes @ccusage/codex@latest`
- local usage data from at least one of:
  - `~/.codex/sessions`
  - `~/.claude/projects`

## Expected result

After running the script, the dashboard HTML is generated under:

```text
~/.ai-usage-dashboard/index.html
```

The script also serves it locally on:

```text
http://127.0.0.1:46327
```

If the user asked to open it, prefer opening that local URL and confirm the actual address that came up.

## Troubleshooting

- If `ccusage` or `@ccusage/codex` returns empty data, the dashboard can still open, but some panels may be blank.
- If port `46327` is already occupied, stop the stale process first or set `AI_USAGE_DASHBOARD_PORT` before running.
- If `template.html` or `scripts/dashboard_server.py` is missing from the installed copy, reinstall or sync the skill/package files before retrying.
