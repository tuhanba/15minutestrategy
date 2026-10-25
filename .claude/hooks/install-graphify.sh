#!/bin/bash
# Ensure the graphify CLI is available in cloud sessions (skill + PreToolUse hooks depend on it).
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

export PATH="$HOME/.local/bin:$PATH"

if ! command -v graphify >/dev/null 2>&1 || [ "$(graphify --version 2>/dev/null | awk '{print $2}')" != "0.9.95" ]; then
  uv tool install --force "graphifyy[all]==0.9.95" >/dev/null 2>&1 \
    || uv tool install --force "graphifyy[mcp,pdf,watch,office,svg,leiden,sql]==0.9.95" >/dev/null 2>&1 \
    || uv tool install --force "graphifyy==0.9.95"
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$HOME/.local/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi
