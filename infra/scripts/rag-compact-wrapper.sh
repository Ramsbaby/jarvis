#!/usr/bin/env bash
set -uo pipefail
BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
# shellcheck source=/dev/null
source "${BOT_HOME}/discord/.env" 2>/dev/null || true
# rag-compact-safe.sh: rag-index 실행 중이면 건너뜀 (concurrent compact → manifest corruption 방지)
exec /bin/bash "${BOT_HOME}/scripts/rag-compact-safe.sh"
