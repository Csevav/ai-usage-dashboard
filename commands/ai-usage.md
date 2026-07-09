---
description: 在 Claude Code 里打开 AI Usage Dashboard，查看可视化的 Claude + Codex 用量看板
---

这个看板按 `ccusage >= 20.0.6` 适配。
如果 Codex 面板为空，先运行 `ccusage --version` 和 `ccusage --help`；如果版本低于 `20.0.6`，或者当前版本还没有 `codex` 子命令，请先升级 `ccusage` 再重试。

!bash ~/.ai-usage-dashboard/build.sh
