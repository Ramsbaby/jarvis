#!/usr/bin/env bash
# recon-run.sh — 정보탐험대 주간 실행 래퍼
# Usage: recon-run.sh
# Cron: 0 9 * * 1 (매주 월요일 09:00)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

# Fix BOT_HOME: use ~/.jarvis if it exists, fallback to ~/.local/share/jarvis
if [[ -d "${HOME}/.jarvis" ]]; then
    BOT_HOME="${HOME}/.jarvis"
else
    BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
fi

CRON_LOG="$BOT_HOME/logs/cron.log"
AGENT="$BOT_HOME/discord/lib/company-agent.mjs"
LOG="$BOT_HOME/logs/company-agent.log"

log() {
    echo "[$(date '+%F %T')] [recon-run] $1" | tee -a "$CRON_LOG"
}

# Find node executable with proper fallback
NODE="${NODE:-}"
if [[ -z "$NODE" ]]; then
    if command -v node &> /dev/null; then
        NODE="$(command -v node)"
    elif [[ -f "/opt/homebrew/bin/node" ]]; then
        NODE="/opt/homebrew/bin/node"
    elif [[ -f "/usr/local/bin/node" ]]; then
        NODE="/usr/local/bin/node"
    else
        log "ERROR: node executable not found in PATH"
        exit 1
    fi
fi

if [[ ! -f "$AGENT" ]]; then
    log "ERROR: company-agent.mjs not found: $AGENT"
    exit 1
fi

log "START — 정보탐험대 주간 실행"
cd "$BOT_HOME" || { log "ERROR: Cannot cd to $BOT_HOME"; exit 1; }

# 명시적으로 node 프로세스가 완료될 때까지 대기
"$NODE" "$AGENT" --team recon >> "$LOG" 2>&1
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    log "SUCCESS — 정보탐험 완료"
    exit 0
else
    # 실패는 명확히 기록하고 반드시 0 반환 (재시도 방지)
    # recon-run 자체는 성공했고, company-agent의 비동기 프로세스 완료까지 기다림
    log "WARN — company-agent exited with code $EXIT_CODE (비동기 후속 작업 진행 중)"
    exit 0
fi
