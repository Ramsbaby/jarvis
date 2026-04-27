#!/bin/bash
# error-ledger-rotate.sh — error-ledger.jsonl 일별 archive (Harness P0-2 가드)
#
# 매일 03:00 KST 실행: 어제까지의 error-ledger.jsonl을 gzip archive로 분리.
# 7일 보관, 그 이상은 자동 삭제.
# silent-error-spike-monitor가 매시간 readFileSync 전체 로드하므로 OOM 위험 차단.

set -euo pipefail

BOT_HOME="${BOT_HOME:-$HOME/jarvis/runtime}"
LEDGER="$BOT_HOME/state/error-ledger.jsonl"
ARCHIVE_DIR="$BOT_HOME/state/error-ledger-archive"
RETENTION_DAYS=7
LOG="$BOT_HOME/logs/error-ledger-rotate.log"

ts() { TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

mkdir -p "$ARCHIVE_DIR" "$(dirname "$LOG")"

if [[ ! -f "$LEDGER" ]]; then
  log "ledger 부재 — skip ($LEDGER)"
  exit 0
fi

# 어제 날짜로 archive (rotation은 자정 직후라 어제 데이터 종료된 상태)
YESTERDAY=$(TZ=Asia/Seoul date -v-1d '+%Y-%m-%d' 2>/dev/null || TZ=Asia/Seoul date -d 'yesterday' '+%Y-%m-%d')
ARCHIVE_FILE="$ARCHIVE_DIR/error-ledger.${YESTERDAY}.jsonl.gz"

# 현재 ledger 크기 측정
LINES_BEFORE=$(wc -l < "$LEDGER" 2>/dev/null || echo 0)
SIZE_BEFORE=$(wc -c < "$LEDGER" 2>/dev/null || echo 0)

# atomic move + gzip — race 방지
TMPFILE="$LEDGER.rotating.$$"
mv "$LEDGER" "$TMPFILE"
touch "$LEDGER"  # 새 빈 파일로 즉시 교체 (recordSilentError 계속 append 가능)

gzip -c "$TMPFILE" > "$ARCHIVE_FILE"
rm -f "$TMPFILE"

log "archive 생성: $ARCHIVE_FILE (lines=$LINES_BEFORE, $SIZE_BEFORE bytes)"

# RETENTION_DAYS 이전 archive 삭제
find "$ARCHIVE_DIR" -name "error-ledger.*.jsonl.gz" -type f -mtime "+$RETENTION_DAYS" -print -delete 2>&1 | tee -a "$LOG"

log "rotation 완료 — 보관: ${RETENTION_DAYS}일"
