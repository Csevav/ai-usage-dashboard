#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${HOME}/.claude/commands"
mkdir -p "$DEST"

cp "${SCRIPT_DIR}/commands/ai-usage.md" "${DEST}/ai-usage.md"

VERSION="$(node -p "require('${SCRIPT_DIR}/package.json').version" 2>/dev/null || echo "unknown")"
echo "Slash command installed to ${DEST}/ai-usage.md (v${VERSION})"
echo "It will be available as /ai-usage in any Claude Code session."
