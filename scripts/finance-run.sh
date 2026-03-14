#!/usr/bin/env bash
# finance-run.sh — 파이낸스팀 일일 모니터링 래퍼
# Usage: finance-run.sh
# Cron: 0 8 * * 1-5 (평일 08:00)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
CRON_LOG="$BOT_HOME/logs/cron.log"
NODE="/opt/homebrew/bin/node"
AGENT="$BOT_HOME/discord/lib/company-agent.mjs"
LOG="$BOT_HOME/logs/company-agent.log"

log() {
    echo "[$(date '+%F %T')] [finance-run] $1" | tee -a "$CRON_LOG"
}

if [[ ! -f "$AGENT" ]]; then
    log "ERROR: company-agent.mjs not found: $AGENT"
    exit 1
fi

log "START — 파이낸스팀 모니터링"
"$NODE" "$AGENT" --team finance >> "$LOG" 2>&1
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    log "SUCCESS — 파이낸스 모니터링 완료"
else
    log "WARN — company-agent exit $EXIT_CODE"
    exit $EXIT_CODE
fi
