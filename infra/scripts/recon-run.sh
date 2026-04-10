#!/usr/bin/env bash
# recon-run.sh — 정보탐험대 주간 실행 래퍼
# Usage: recon-run.sh
# Cron: 0 9 * * 1 (매주 월요일 09:00)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
CRON_LOG="$BOT_HOME/logs/cron.log"
NODE="${NODE:-$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)}"
AGENT="$BOT_HOME/discord/lib/company-agent.mjs"
LOG="$BOT_HOME/logs/company-agent.log"

log() {
    echo "[$(date '+%F %T')] [recon-run] $1" | tee -a "$CRON_LOG"
}

if [[ ! -f "$AGENT" ]]; then
    log "ERROR: company-agent.mjs not found: $AGENT"
    exit 1
fi

log "START — 정보탐험대 주간 실행"
"$NODE" "$AGENT" --team recon >> "$LOG" 2>&1
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    log "SUCCESS — 정보탐험 완료"
else
    log "WARN — company-agent exit $EXIT_CODE (결과는 채널 확인)"
    exit $EXIT_CODE
fi
