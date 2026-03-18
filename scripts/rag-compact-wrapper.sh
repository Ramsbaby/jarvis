#!/usr/bin/env bash
set -uo pipefail
BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
NODE="${NODE:-$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)}"
# shellcheck source=/dev/null
source "${BOT_HOME}/discord/.env" 2>/dev/null || true
"${NODE}" "${BOT_HOME}/bin/rag-compact.mjs" >> "${BOT_HOME}/logs/rag-compact.log" 2>&1
