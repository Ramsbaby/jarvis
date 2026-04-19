#!/bin/bash
# proposal-list.sh — 개발팀 제안 큐 조회 / 상태 변경
# Usage: proposal-list.sh [--status pending|approved|rejected|done] [--approve <id>] [--reject <id>] [--done <id>]
set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
PROPOSALS_FILE="$BOT_HOME/state/proposals.jsonl"

[[ -f "$PROPOSALS_FILE" ]] || { echo "제안 큐 없음 ($PROPOSALS_FILE)"; exit 0; }

FILTER_STATUS=""
ACTION="" ACTION_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)  FILTER_STATUS="$2"; shift 2 ;;
    --approve) ACTION="approved"; ACTION_ID="$2"; shift 2 ;;
    --reject)  ACTION="rejected"; ACTION_ID="$2"; shift 2 ;;
    --done)    ACTION="done";     ACTION_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# 상태 변경
if [[ -n "$ACTION" && -n "$ACTION_ID" ]]; then
  TS=$(date "+%Y-%m-%d %H:%M KST")
  TMP=$(mktemp)
  trap 'rm -f "$TMP"' EXIT
  jq -c --arg id "$ACTION_ID" --arg status "$ACTION" --arg ts "$TS" \
    'if .id == $id then .status = $status | .resolved_at = $ts else . end' \
    "$PROPOSALS_FILE" > "$TMP"
  mv "$TMP" "$PROPOSALS_FILE"
  echo "✅ $ACTION_ID → $ACTION"
  exit 0
fi

# 조회
STATUS="${FILTER_STATUS:-pending}"
echo "=== 개발팀 제안 큐 [$STATUS] ==="
COUNT=0
while IFS= read -r line; do
  s=$(echo "$line" | jq -r '.status')
  [[ "$s" != "$STATUS" ]] && continue
  COUNT=$((COUNT + 1))
  id=$(echo "$line" | jq -r '.id')
  from=$(echo "$line" | jq -r '.from')
  title=$(echo "$line" | jq -r '.title')
  what=$(echo "$line" | jq -r '.what')
  why=$(echo "$line" | jq -r '.why')
  effect=$(echo "$line" | jq -r '.effect')
  severity=$(echo "$line" | jq -r '.severity')
  submitted=$(echo "$line" | jq -r '.submitted_at')
  echo ""
  echo "[$COUNT] $id"
  echo "  출처: $from | 중요도: $severity | 접수: $submitted"
  echo "  제목: $title"
  echo "  무엇: $what"
  echo "  왜: $why"
  echo "  효과: $effect"
done < "$PROPOSALS_FILE"

[[ $COUNT -eq 0 ]] && echo "(없음)"
echo ""
echo "승인: proposal-list.sh --approve <id>"
echo "거절: proposal-list.sh --reject <id>"
echo "완료: proposal-list.sh --done <id>"
