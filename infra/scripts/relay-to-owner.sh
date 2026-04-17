#!/usr/bin/env bash
# relay-to-owner.sh — 보람 채널에서 정우님(jarvis 채널)으로 실제 메시지 전송
# Usage: relay-to-owner.sh "전달 내용"
# 보람 페르소나가 정우님께 에스컬레이션 필요 시 이 스크립트를 직접 호출한다.

set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/jarvis/runtime}"
MSG="${1:-}"

if [[ -z "$MSG" ]]; then
  echo "Usage: relay-to-owner.sh '전달 메시지'" >&2
  exit 1
fi

WEBHOOK=$(jq -r '.webhooks["jarvis"] // empty' "${BOT_HOME:-$HOME/jarvis/runtime}/config/monitoring.json" 2>/dev/null)
[[ -z "$WEBHOOK" ]] && { echo "ERROR: jarvis webhook not found" >&2; exit 1; }

PAYLOAD=$(python3 -c "import json, sys; print(json.dumps({'content': sys.argv[1]}))" "📞 **[보람님 채널 → 정우님]**
$MSG")

curl -sS -X POST "$WEBHOOK" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  -o /dev/null

echo "[$(TZ=Asia/Seoul date '+%F %T')] relay-to-owner: 전송 완료 — $MSG" >> "$BOT_HOME/logs/cron.log"