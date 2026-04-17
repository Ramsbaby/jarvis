#!/usr/bin/env bash
set -euo pipefail
# runtime-rag-backup.sh — runtime/rag/ 주간 백업 (disaster recovery)
# 시나리오 D 방어: runtime 전체 삭제 시 RAG DB 2.2GB 복구 가능.
# 매주 일요일 03:00 tar.gz 생성, 4주 retention.

BOT_HOME="${BOT_HOME:-$HOME/jarvis/runtime}"
RAG_SRC="$BOT_HOME/rag"
BACKUP_DIR="$HOME/backup/runtime-rag"
LOG="$BOT_HOME/logs/runtime-rag-backup.log"
RETENTION_DAYS=28

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if [[ ! -d "$RAG_SRC" ]]; then
    log "SKIP: $RAG_SRC 없음"
    exit 0
fi

TS=$(date '+%Y-%m-%d')
ARCHIVE="$BACKUP_DIR/rag-${TS}.tar.gz"

log "=== RAG 백업 시작 ==="
src_size=$(du -sh "$RAG_SRC" 2>/dev/null | awk '{print $1}')
log "source: $RAG_SRC ($src_size)"

# 진행 중 write 충돌 방지: /tmp에 먼저 만들고 원자적 mv
TMP_ARCHIVE="/tmp/rag-${TS}-$$.tar.gz"
# write.lock 파일은 제외 (실행 중이면 깨진 스냅샷 될 수 있음)
if tar --exclude='write.lock' --exclude='*.tmp' -czf "$TMP_ARCHIVE" -C "$(dirname "$RAG_SRC")" "$(basename "$RAG_SRC")" 2>>"$LOG"; then
    mv "$TMP_ARCHIVE" "$ARCHIVE"
    archive_size=$(du -sh "$ARCHIVE" 2>/dev/null | awk '{print $1}')
    log "OK: $ARCHIVE ($archive_size)"
else
    rm -f "$TMP_ARCHIVE"
    log "ERROR: tar 실패"
    exit 1
fi

# retention (4주)
deleted=0
while IFS= read -r old; do
    rm -f "$old"
    log "DELETE: $old (>${RETENTION_DAYS}일)"
    deleted=$((deleted + 1))
done < <(find "$BACKUP_DIR" -name 'rag-*.tar.gz' -mtime +${RETENTION_DAYS} 2>/dev/null)

log "완료: 생성 1개, 삭제 $deleted개"
echo "rag-backup: $ARCHIVE ($archive_size), deleted $deleted"
