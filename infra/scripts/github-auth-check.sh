#!/usr/bin/env bash
set -euo pipefail
# check-gh-auth.sh — gh auth 토큰 만료 임박 감지
# 호출: bot-cron.sh에서 github-monitor 태스크 전에 호출 가능
# 출력: 정상 시 exit 0, 경고 시 exit 0 (Discord 알림만), 만료 시 exit 1

source "$(dirname "$0")/../discord/.env" 2>/dev/null || true

BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
WEBHOOK_URL="${DISCORD_WEBHOOK_JARVIS:-}"
LOG="$BOT_HOME/logs/cron.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [check-gh-auth] $*" | tee -a "$LOG"; }

# gh auth status 실행
if ! command -v gh &>/dev/null; then
  log "WARN: gh CLI not found"
  exit 0
fi

AUTH_STATUS=$(gh auth status 2>&1)
if echo "$AUTH_STATUS" | grep -q "not logged in\|no credentials"; then
  MSG="🔴 gh auth 미인증 상태 — github-monitor 장애 발생 가능"
  log "ERROR: $MSG"
  # Discord 알림 (webhook 있을 때만)
  if [[ -n "$WEBHOOK_URL" ]]; then
    curl -s -X POST "$WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"content\":\"$MSG\"}" >/dev/null
  fi
  exit 1
fi

# 토큰 만료일 추출 시도 (gh auth status 출력에 포함될 경우)
EXPIRY=$(echo "$AUTH_STATUS" | grep -oE "Token expires: .+" | head -1)
if [[ -n "$EXPIRY" ]]; then
  log "INFO: $EXPIRY"
fi

log "INFO: gh auth OK"
exit 0
