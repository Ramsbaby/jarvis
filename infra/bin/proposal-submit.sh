#!/bin/bash
# proposal-submit.sh — 팀에서 개발팀(Claude Code)에 작업 제안 등록
# Usage: proposal-submit.sh --from sre --title "제목" --what "무엇" --why "왜" --effect "효과"
set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
PROPOSALS_FILE="$BOT_HOME/state/proposals.jsonl"
MONITORING_CONFIG="$BOT_HOME/config/monitoring.json"

FROM="" TITLE="" WHAT="" WHY="" EFFECT="" SEVERITY="normal"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)    FROM="$2";     shift 2 ;;
    --title)   TITLE="$2";   shift 2 ;;
    --what)    WHAT="$2";    shift 2 ;;
    --why)     WHY="$2";     shift 2 ;;
    --effect)  EFFECT="$2";  shift 2 ;;
    --severity) SEVERITY="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$FROM" || -z "$TITLE" || -z "$WHAT" ]]; then
  echo "Usage: proposal-submit.sh --from <team> --title <title> --what <what> [--why <why>] [--effect <effect>] [--severity normal|high|critical]" >&2
  exit 1
fi

TS=$(date "+%Y-%m-%d %H:%M KST")
ID="proposal-$(date +%Y%m%d%H%M%S)-${FROM}"

jq -nc \
  --arg id "$ID" \
  --arg from "$FROM" \
  --arg title "$TITLE" \
  --arg what "$WHAT" \
  --arg why "$WHY" \
  --arg effect "$EFFECT" \
  --arg severity "$SEVERITY" \
  --arg submitted_at "$TS" \
  '{id:$id, from:$from, title:$title, what:$what, why:$why, effect:$effect, severity:$severity, status:"pending", submitted_at:$submitted_at, resolved_at:null}' \
  >> "$PROPOSALS_FILE"

echo "[proposal-submit] ✅ 등록: $ID — $TITLE"

# Discord 알림 (실패해도 무시)
send_discord_notification() {
  [[ -f "$MONITORING_CONFIG" ]] || return 0
  local webhook_url
  webhook_url=$(jq -r '.webhooks["jarvis-dev"] // .webhooks["jarvis-system"] // ""' "$MONITORING_CONFIG" 2>/dev/null || echo "")
  [[ -z "$webhook_url" ]] && return 0

  local payload
  payload=$(jq -nc \
    --arg title "📋 개발팀 제안 접수 [$FROM → dev]" \
    --arg desc "**$TITLE**\n\n**무엇**: $WHAT\n**왜**: $WHY\n**효과**: $EFFECT\n\n_Claude Code 세션 시작 시 자동 표시됩니다_" \
    --argjson color 3447003 \
    '{embeds:[{title:$title, description:$desc, color:$color}]}')
  curl -s -o /dev/null -X POST "$webhook_url" \
    -H "Content-Type: application/json" \
    -d "$payload" || true
}
send_discord_notification
