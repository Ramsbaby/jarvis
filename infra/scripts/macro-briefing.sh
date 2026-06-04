#!/usr/bin/env bash
# macro-briefing.sh — 시장 매크로 분석 스크립트
# 이 스크립트는 Jarvis bot-cron.sh의 macro-briefing 태스크를 독립적으로 실행합니다.
# 일정: 월~금 23:30 KST (UTC 14:30)
# 실행: claude -p macro-briefing

set -euo pipefail

# === Environment Setup ===
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

# Claude Max subscription mode — no API key needed
unset ANTHROPIC_API_KEY 2>/dev/null || true

# Batch mode optimization for cron tasks
export JARVIS_BATCH_MODE="${JARVIS_BATCH_MODE:-1}"

# Working directories
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime/runtime}"
LOG_DIR="${BOT_HOME}/logs"
RESULT_FILE="${LOG_DIR}/macro-briefing-result.json"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# === Functions ===

log() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [macro-briefing] $msg" | tee -a "${LOG_DIR}/macro-briefing.log"
}

error_exit() {
    local msg="$1"
    log "ERROR: $msg"
    exit 1
}

# === Task Execution ===

log "START"

# Verify bot-cron.sh exists and is executable
if [[ ! -x "${HOME}/jarvis/runtime/infra/bin/bot-cron.sh" ]]; then
    error_exit "bot-cron.sh not found or not executable at ${HOME}/jarvis/runtime/infra/bin/bot-cron.sh"
fi

# Delegate to bot-cron.sh wrapper (the canonical task executor)
log "Executing via bot-cron.sh wrapper"
"${HOME}/jarvis/runtime/infra/bin/bot-cron.sh" "macro-briefing" || {
    rc=$?
    error_exit "bot-cron.sh failed with exit code $rc"
}

log "SUCCESS"
exit 0
