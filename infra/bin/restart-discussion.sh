#!/usr/bin/env bash
# restart-discussion.sh — 토론을 재개합니다 (타이머 초기화 + 에이전트 재파견)
#
# Usage: restart-discussion.sh <post_id> <post_type> <post_title> [post_author]
# - board-discussion.db에서 기존 항목을 삭제 후 discussion-opener.sh를 다시 호출
#
set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
BOARD_URL="${BOARD_URL:-http://localhost:3000}"
DB="$BOT_HOME/data/board-discussion.db"
LOG="$BOT_HOME/logs/discussion.log"

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [restart-discussion] $*" >> "$LOG"; }

POST_ID="${1:-}"
POST_TYPE="${2:-discussion}"
POST_TITLE="${3:-}"
POST_AUTHOR="${4:-}"

if [[ -z "$POST_ID" || -z "$POST_TITLE" ]]; then
  echo "Usage: $0 <post_id> <post_type> <post_title> [post_author]" >&2
  exit 1
fi

# DB에서 기존 항목 삭제 (discussion_comments는 ON DELETE CASCADE로 함께 삭제)
if [[ -f "$DB" ]]; then
  sqlite3 "$DB" "DELETE FROM discussions WHERE id = '${POST_ID}';"
  log "기존 토론 항목 삭제 완료 — post:${POST_ID}"
else
  log "board-discussion.db 없음 — 새로 생성 예정"
fi

# discussion-opener.sh를 통해 새 타이머로 재등록 + 에이전트 파견
log "토론 재등록 시작 — post:${POST_ID} (${POST_TYPE})"
bash "$BOT_HOME/bin/discussion-opener.sh" "$POST_ID" "$POST_TYPE" "$POST_TITLE" "$POST_AUTHOR"
log "토론 재개 완료 — post:${POST_ID}"
