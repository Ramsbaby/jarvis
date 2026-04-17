#!/usr/bin/env bash
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/jarvis/runtime}}/lib/compat.sh" 2>/dev/null || true
set -euo pipefail

# sync-discord-token.sh — Discord 봇 토큰 업데이트 후 재시작
# 사용법: sync-discord-token.sh <새토큰>

SCRIPT_NAME="sync-discord-token"
NEW_TOKEN="${1:?사용법: $0 <새Discord봇토큰>}"
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
BOT_ENV="$BOT_HOME/discord/.env"
LOG="$BOT_HOME/logs/sync-discord-token.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$SCRIPT_NAME] $*" | tee -a "$LOG"; }

log "토큰 동기화 시작"

# 1. .env 업데이트
if [[ -f "$BOT_ENV" ]]; then
    sed -i.bak "s|^DISCORD_TOKEN=.*|DISCORD_TOKEN=${NEW_TOKEN}|" "$BOT_ENV"
    rm -f "${BOT_ENV}.bak"
    log ".env 업데이트 완료"
else
    log "WARN: .env 없음 — .env.example에서 복사 후 재시도"
    exit 1
fi

# 2. Discord Bot 재시작
log "Discord Bot 재시작..."
if $IS_MACOS; then
  launchctl kickstart -k "gui/$(id -u)/ai.discord-bot" 2>/dev/null || true
else
  # Linux/Docker: pm2로 봇 재시작
  if command -v pm2 &>/dev/null; then
    pm2 restart jarvis-bot 2>/dev/null || pm2 restart all 2>/dev/null || true
  else
    echo "[sync-token] INFO: Token updated. Manual bot restart required (pm2 not found)."
  fi
fi
sleep 3

log "완료"
echo "토큰 동기화 완료"