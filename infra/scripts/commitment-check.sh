#!/usr/bin/env bash
# commitment-check.sh — 24h+ 초과 미이행 약속 Discord 알림
# LaunchAgent에 의해 정기 실행 (1시간 간격 권장)
set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
COMMIT_FILE="$BOT_HOME/state/commitments.jsonl"
WEBHOOK_FILE="$BOT_HOME/config/monitoring.json"

# commitments.jsonl 없으면 조용히 종료
if [[ ! -f "$COMMIT_FILE" ]]; then exit 0; fi

NOW=$(date +%s)
OVERDUE_SEC=86400  # 24h

# jq 필요 여부 체크
if ! command -v jq &>/dev/null; then
  echo "jq not found — skipping commitment check" >&2
  exit 0
fi

# open + 24h 초과 항목 수집
OVERDUE_ITEMS=()
while IFS= read -r line; do
  if [[ -z "$line" ]]; then continue; fi
  status=$(echo "$line" | jq -r '.status // "open"' 2>/dev/null) || continue
  if [[ "$status" != "open" ]]; then continue; fi

  created_raw=$(echo "$line" | jq -r '.created_at // ""' 2>/dev/null) || continue
  if [[ -z "$created_raw" ]]; then continue; fi

  # ISO8601 → epoch
  if [[ "$(uname)" == "Darwin" ]]; then
    created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${created_raw%%.*}" +%s 2>/dev/null) || continue
  else
    created_epoch=$(date -d "$created_raw" +%s 2>/dev/null) || continue
  fi

  age=$(( NOW - created_epoch ))
  if [[ $age -lt $OVERDUE_SEC ]]; then continue; fi

  text=$(echo "$line" | jq -r '.text // .commitment // .content // "내용 없음"' 2>/dev/null)
  age_h=$(( age / 3600 ))
  OVERDUE_ITEMS+=("🔴 ${age_h}h — ${text:0:120}")
done < "$COMMIT_FILE"

# 초과 항목 없으면 조용히 종료
if [[ ${#OVERDUE_ITEMS[@]} -eq 0 ]]; then exit 0; fi

# Discord Webhook 가져오기
WEBHOOK_URL=""
if [[ -f "$WEBHOOK_FILE" ]]; then
  WEBHOOK_URL=$(jq -r '.webhooks.jarvis // .webhooks.main // "" | select(. != "")' "$WEBHOOK_FILE" 2>/dev/null || true)
fi

COUNT=${#OVERDUE_ITEMS[@]}
BODY="## 📌 Jarvis가 아직 처리 못 한 약속이 있어요 (${COUNT}건)\n"
for item in "${OVERDUE_ITEMS[@]}"; do
  BODY+="- ${item}\n"
done
BODY+="\n처리됐으면 무시하시거나, \`/commitments\` 로 목록 확인 후 완료 처리할 수 있습니다."

if [[ -n "$WEBHOOK_URL" ]]; then
  # Discord Webhook 전송
  PAYLOAD=$(jq -n --arg content "$(printf '%b' "$BODY")" '{"content": $content}')
  curl -sS -X POST -H "Content-Type: application/json" \
    -d "$PAYLOAD" "$WEBHOOK_URL" >/dev/null || echo "Webhook 전송 실패 (curl 오류)" >&2
  echo "Commitment alert sent via webhook: ${COUNT} overdue items"
else
  # Webhook 없으면 로그만 (디렉토리 보장)
  mkdir -p "$BOT_HOME/logs"
  echo "COMMITMENT OVERDUE (${COUNT}): ${OVERDUE_ITEMS[*]}" >> "$BOT_HOME/logs/commitment-check.log"
  echo "No webhook configured — logged to commitment-check.log"
fi