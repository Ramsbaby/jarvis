#!/usr/bin/env bash
# discord-presence-check.sh — Discord 오너 온라인 여부 추정
#
# Discord API의 presence 엔드포인트는 bot scope 없이는 접근 불가.
# 대신 오늘 날짜의 discord-history 파일 존재 여부로 활동 여부를 추정.
#
# Returns:
#   exit 0 — 오늘 채팅 기록 존재 → 오너가 활동 중(온라인)으로 간주
#   exit 1 — 오늘 채팅 기록 없음 → 오너가 오프라인으로 간주
#
# Usage:
#   discord-presence-check.sh

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
CRON_LOG="$BOT_HOME/logs/cron.log"

log() {
    echo "[$(date '+%F %T')] [discord-presence] $1" >> "$CRON_LOG"
}

# --- KST 기준 오늘 날짜 계산 (UTC+9) ---
TODAY=$(TZ=Asia/Seoul date +%Y-%m-%d 2>/dev/null || date -u -v+9H +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)

HISTORY_FILE="$BOT_HOME/context/discord-history/${TODAY}.md"

if [[ -f "$HISTORY_FILE" ]] && [[ -s "$HISTORY_FILE" ]]; then
    log "ONLINE — 오늘($TODAY) 채팅 기록 있음: $HISTORY_FILE"
    exit 0
else
    log "OFFLINE — 오늘($TODAY) 채팅 기록 없음"
    exit 1
fi
