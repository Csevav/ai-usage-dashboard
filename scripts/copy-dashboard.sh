#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${HOME}/.claude/dashboard"
mkdir -p "$DEST"

cp "${SCRIPT_DIR}/build.sh"      "$DEST/build.sh"
cp "${SCRIPT_DIR}/template.html" "$DEST/template.html"
chmod +x "${DEST}/build.sh"

VERSION="$(node -p "require('${SCRIPT_DIR}/package.json').version" 2>/dev/null || echo "unknown")"
echo "Dashboard files installed to $DEST (v${VERSION})"
