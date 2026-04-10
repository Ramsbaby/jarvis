#!/usr/bin/env bash
# db-backup.sh — Board SQLite + RAG LanceDB 자동 백업
#
# Cron:
#   Board: 0 2 * * *  (매일 02:00 — WAL checkpoint 후 백업)
#   RAG:   30 3 * * 0 (일요일 03:30 — rag-compact-safe.sh 30분 전)
#
# 보존 정책: Board 30일, RAG 2개 (최신 2개만 유지)

set -euo pipefail

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BOARD_DB="${BOARD_DIR:-${BOT_HOME}/board}/data/board.db"
BOARD_BACKUP_DIR="${BOARD_DIR:-${BOT_HOME}/board}/data/backups"
RAG_DIR="${BOT_HOME}/rag/lancedb"
RAG_BACKUP_DIR="${BOT_HOME}/backups"

LOG="${BOT_HOME}/logs/db-backup.log"
mkdir -p "$(dirname "$LOG")" "$BOARD_BACKUP_DIR" "$RAG_BACKUP_DIR"

log() { printf '[%s] [db-backup] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

BACKUP_TYPE="${1:-board}"

# ── Board DB 백업 ─────────────────────────────────────────────────────────────
if [[ "$BACKUP_TYPE" == "board" || "$BACKUP_TYPE" == "all" ]]; then
  if [[ ! -f "$BOARD_DB" ]]; then
    log "WARN board.db 없음: $BOARD_DB"
  else
    STAMP=$(date '+%Y%m%d-%H%M%S')
    DEST="${BOARD_BACKUP_DIR}/board-${STAMP}.db"

    # WAL checkpoint: 깨끗한 상태로 복사
    sqlite3 "$BOARD_DB" "PRAGMA wal_checkpoint(RESTART);" 2>>"$LOG" \
      && log "INFO WAL checkpoint 완료" \
      || log "WARN WAL checkpoint 실패 — 복사 계속"

    cp "$BOARD_DB" "$DEST"
    SIZE=$(wc -c < "$DEST" 2>/dev/null || echo 0)
    log "INFO Board DB 백업 완료: ${DEST} (${SIZE} bytes)"

    # 30일 초과 파일 삭제
    DELETED=$(find "$BOARD_BACKUP_DIR" -name 'board-*.db' -mtime +30 -print -delete 2>/dev/null | wc -l || echo 0)
    if (( DELETED > 0 )); then
      log "INFO 오래된 Board 백업 ${DELETED}개 삭제"
    fi
  fi
fi

# ── RAG LanceDB 백업 ──────────────────────────────────────────────────────────
if [[ "$BACKUP_TYPE" == "rag" || "$BACKUP_TYPE" == "all" ]]; then
  if [[ ! -d "$RAG_DIR" ]]; then
    log "WARN RAG 디렉토리 없음: $RAG_DIR"
  else
    # 쓰기 잠금 확인 — 진행 중이면 백업 건너뜀
    if [[ -f "/tmp/jarvis-rag-write.lock" ]]; then
      log "WARN RAG 쓰기 잠금 활성 — 백업 건너뜀 (다음 주기 재시도)"
      exit 0
    fi

    STAMP=$(date '+%Y%m%d-%H%M%S')
    DEST="${RAG_BACKUP_DIR}/rag-lancedb-${STAMP}.tar.gz"

    log "INFO RAG 백업 시작 (1.3GB 예상, 수분 소요)..."
    tar czf "$DEST" -C "$(dirname "$RAG_DIR")" "$(basename "$RAG_DIR")" 2>>"$LOG"
    SIZE=$(wc -c < "$DEST" 2>/dev/null || echo 0)
    log "INFO RAG 백업 완료: ${DEST} (${SIZE} bytes)"

    # 최신 2개만 보존 (RAG는 큰 파일이므로 2개로 제한)
    BACKUPS_SORTED=$(ls -t "${RAG_BACKUP_DIR}"/rag-lancedb-*.tar.gz 2>/dev/null || true)
    COUNT=0
    while IFS= read -r f; do
      COUNT=$((COUNT + 1))
      if (( COUNT > 2 )); then
        rm -f "$f"
        log "INFO 오래된 RAG 백업 삭제: $(basename "$f")"
      fi
    done <<< "$BACKUPS_SORTED"
  fi
fi

log "INFO 백업 완료 (type: ${BACKUP_TYPE})"
