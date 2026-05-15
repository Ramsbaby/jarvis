#!/usr/bin/env bash
# post-news-briefing-enqueue.sh
# news-briefing 결과 파일에서 JSON 인사이트 블록 파싱 → dev-queue에 'pending'으로 propose
# 자동 실행 X. 주인님이 검토 후 /promote 또는 /reject로 결정.
#
# 사용:
#   post-news-briefing-enqueue.sh [BRIEFING_FILE]
# 인자 없으면 가장 최근 news-briefing 결과 파일 자동 선택.

set -euo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
RESULTS_DIR="${JARVIS_HOME}/runtime/results/news-briefing"
LOG_FILE="${JARVIS_HOME}/runtime/logs/post-news-briefing.log"
TASK_STORE="${JARVIS_HOME}/infra/lib/task-store.mjs"

mkdir -p "$(dirname "$LOG_FILE")"

_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

BRIEFING_FILE="${1:-}"
if [[ -z "$BRIEFING_FILE" ]]; then
  BRIEFING_FILE=$(ls -t "$RESULTS_DIR"/*.md 2>/dev/null | head -1)
fi

if [[ -z "$BRIEFING_FILE" || ! -f "$BRIEFING_FILE" ]]; then
  _log "no briefing file found in $RESULTS_DIR"
  exit 0
fi

_log "parsing: $BRIEFING_FILE"

JSON=$(awk '/```json_insights/{flag=1; next} /```/{flag=0} flag' "$BRIEFING_FILE" 2>/dev/null || true)

if [[ -z "$JSON" ]]; then
  _log "no JSON insights block found (LLM may not have output structured form)"
  exit 0
fi

if ! echo "$JSON" | jq -e '.insights' >/dev/null 2>&1; then
  _log "JSON parse failed — silently skip"
  exit 0
fi

PROPOSED=0
SKIPPED=0

while IFS= read -r item; do
  ID=$(echo "$item" | jq -r '.id // empty')
  TITLE=$(echo "$item" | jq -r '.title // empty')
  REASON=$(echo "$item" | jq -r '.reason // ""')
  DEV_QUEUE=$(echo "$item" | jq -r '.dev_queue // false')

  if [[ -z "$ID" || -z "$TITLE" || "$DEV_QUEUE" != "true" ]]; then
    continue
  fi

  PROMPT="기술 도입 검토: ${TITLE}

사유: ${REASON}

자동 실행 안 됨. 주인님 검토 후 결정:
  - 도입 진행: node ${TASK_STORE} promote ${ID}
  - 거절: node ${TASK_STORE} reject ${ID} \"<사유>\""

  RESULT=$(node "$TASK_STORE" propose \
    --id "$ID" \
    --title "$TITLE" \
    --prompt "$PROMPT" \
    --source news-briefing 2>&1)

  if echo "$RESULT" | grep -q '"action":"proposed"'; then
    PROPOSED=$((PROPOSED + 1))
    _log "proposed: $ID — $TITLE"
  else
    SKIPPED=$((SKIPPED + 1))
    _log "skipped: $ID ($RESULT)"
  fi
done < <(echo "$JSON" | jq -c '.insights[]?')

_log "done: proposed=$PROPOSED, skipped=$SKIPPED"
