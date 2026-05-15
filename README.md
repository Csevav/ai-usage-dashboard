# @csevav/ai-usage-dashboard

> 一个可视化的 **Claude Code + OpenAI Codex** 用量看板。基于 [`ccusage`](https://www.npmjs.com/package/ccusage) 增强，新增 Codex 数据、按对话排行、中文界面、系统本地时区等功能。当前主要支持 **Codex** 和 **Claude Code**。
>
> A visual usage dashboard for **Claude Code + OpenAI Codex** — built on top of [`ccusage`](https://www.npmjs.com/package/ccusage), with Codex support, per-conversation ranking, Chinese UI, and system-local timezone display. It currently targets **Codex** and **Claude Code** workflows.

![status: WIP](https://img.shields.io/badge/status-WIP-orange) ![license: MIT](https://img.shields.io/badge/license-MIT-blue)

---

## ✨ 功能 / Features

| | 原版 `ccusage-ui-dashboard` | 本项目 |
|---|:---:|:---:|
| Claude Code 用量 | ✅ | ✅ |
| OpenAI Codex 用量 | ❌ | ✅ |
| Claude vs Codex 综合对比 | ❌ | ✅ |
| 按**对话**统计 / 排行（带标题） | ❌ | ✅ |
| 「时段 / 对话」明细可切换 | ❌ | ✅ |
| 表头点击排序 | ❌ | ✅ |
| 缓存命中 hover 说明 | ❌ | ✅ |
| 中文 UI | ❌ | ✅ |
| 系统本地时区显示 | ❌ | ✅ |
| 周柱状图按周一日期标注 | ❌ | ✅ |

---

## 📦 安装 / Install

```bash
npm install -g @csevav/ai-usage-dashboard
```

安装后会自动：

1. 把模板和构建脚本拷到 `~/.ai-usage-dashboard/`
2. 在 `~/.claude/commands/` 创建 `ai-usage.md`，作为 Claude Code 的快捷集成

## 🚀 使用 / Usage

推荐用法：在 **Codex** 或终端里直接运行：

```bash
bash ~/.ai-usage-dashboard/build.sh
```

这是面向 **Codex / shell workflow** 的直接入口。

也支持直接用 `npx` 运行：

```bash
npx @csevav/ai-usage-dashboard
```

例如：

```bash
npx @csevav/ai-usage-dashboard --no-open
```

如果你在用 **Claude Code**，也可以直接输入：

```
/ai-usage
```

会自动构建并在浏览器打开看板。

支持参数：
- `--no-open` — 只生成 HTML，不自动打开浏览器
- `--no-summary` — 不在终端打印 markdown 摘要

## Skill 用法 / Use as a Codex skill

这个仓库现在也可以直接作为 **Codex skill** 使用。

核心入口是：

```bash
bash ~/.codex/skills/usage-dashboard/build.sh
```

当用户表达这些意图时，这个 skill 很适合触发：

- 想打开可视化用量看板
- 想看 Codex / Claude Code 的 token 或费用趋势
- 想按对话查看用量排行
- 想要浏览器里的 dashboard，而不是纯终端输出

如果你是本地维护这个 skill，关键文件是：

- `SKILL.md` — skill 触发说明
- `agents/openai.yaml` — skill 的界面名称和默认提示词
- `build.sh` — 实际构建入口

## 🔧 依赖 / Requirements

- **Node.js** ≥ 18（用于 `npx`）
- **Python 3**（用于解析本地日志）
- **macOS / Linux**（用了 bash + `open` 命令；Windows 暂未测试）
- 至少装了下面其中一个：
  - [`ccusage`](https://www.npmjs.com/package/ccusage) — Claude Code 用量数据来源
  - [`@ccusage/codex`](https://www.npmjs.com/package/@ccusage/codex) — Codex 用量数据来源

`build.sh` 会自动通过 `npx --yes` 调用上述包，无需额外安装。

> 当前这份包主要面向两种使用方式：**Codex 里直接运行 shell 命令**，以及 **Claude Code 里的 slash command 集成**。

## 🗂 数据来源 / Data sources

- **Claude Code**：扫描 `~/.claude/projects/*/*.jsonl`（每个文件 = 一次对话），按消息 ID 去重，使用 Anthropic 当前 Claude 4 定价表本地计算每段对话费用
- **OpenAI Codex**：调用 `npx @ccusage/codex session --json` 拿到对话级用量；从 `~/.codex/sessions/.../rollout-*.jsonl` 提取首条用户输入作为对话标题
- 时间跟随使用者的系统本地时区展示

## 🤝 致谢 / Credits

- 灵感和基础结构来自 [`ccusage-ui-dashboard`](https://www.npmjs.com/package/ccusage-ui-dashboard) by okrasn
- 数据采集依赖 [`ccusage`](https://www.npmjs.com/package/ccusage) by ryoppippi 和 [`@ccusage/codex`](https://www.npmjs.com/package/@ccusage/codex)

## 📄 License

MIT © Luke Mei
