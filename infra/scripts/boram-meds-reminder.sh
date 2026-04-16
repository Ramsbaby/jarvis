#!/usr/bin/env bash
# boram-meds-reminder.sh — 보람님 약 복용 알림
# Usage: boram-meds-reminder.sh [아침|점심|저녁]
# 매일 아침(08:00) / 점심(12:00) / 저녁(19:00) launchd에서 자동 실행

set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
TIMING="${1:-아침}"
WEBHOOK=$(jq -r '.webhooks["jarvis-boram"] // empty' "${BOT_HOME}/config/monitoring.json" 2>/dev/null)
[[ -z "$WEBHOOK" ]] && { echo "ERROR: jarvis-boram webhook not found" >&2; exit 1; }
LOGFILE="$BOT_HOME/logs/boram-meds.log"

log() { echo "[$(TZ=Asia/Seoul date '+%F %T')] boram-meds-reminder($TIMING): $*" >> "$LOGFILE"; }

send_discord() {
  local msg="$1"
  local payload
  payload=$(python3 -c "import json, sys; print(json.dumps({'content': sys.argv[1]}))" "$msg")
  curl -sS -X POST "$WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    -o /dev/null
}

case "$TIMING" in
  아침)
    EMOJI="🌅"
    LABEL="아침 약"
    ;;
  점심)
    EMOJI="☀️"
    LABEL="점심 약"
    ;;
  저녁)
    EMOJI="🌙"
    LABEL="저녁 약"
    ;;
  *)
    log "Unknown timing: $TIMING"
    exit 1
    ;;
esac

NOW=$(TZ=Asia/Seoul date '+%H:%M')
MSG="${EMOJI} **${LABEL}** 드실 시간이에요, 보람님! (${NOW})"

send_discord "$MSG"
log "OK — $MSG"
