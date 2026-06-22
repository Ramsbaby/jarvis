#!/usr/bin/env bash
set -euo pipefail
# runtime-rag-backup.sh — runtime/rag/ 주간 백업 (disaster recovery)
# 시나리오 D 방어: runtime 전체 삭제 시 RAG DB(현재 약 21GB) 복구 가능.
# 매주 일요일 03:00 tar.gz 생성, 7일 retention(최근 1개만 유지 — 디스크 절약).
# RAG는 재인덱싱으로 재생성 가능한 파생 데이터라 안전망 1개면 충분.

BOT_HOME="${BOT_HOME:-$HOME/jarvis/runtime}"
RAG_SRC="$BOT_HOME/rag"
BACKUP_DIR="$HOME/backup/runtime-rag"
LOG="$BOT_HOME/logs/runtime-rag-backup.log"
RETENTION_DAYS=7

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

# retention (최신 1개만 유지 — 개수 기반. mtime+7일은 1주간 2개 공존 → 디스크 압박. 2026-06-22 keep-1 전환)
deleted=0
_keep=0
while IFS= read -r old; do
    _keep=$((_keep + 1))
    if (( _keep > 1 )); then
        rm -f "$old"
        log "DELETE: $old (keep-1 retention)"
        deleted=$((deleted + 1))
    fi
done < <(ls -t "$BACKUP_DIR"/rag-*.tar.gz 2>/dev/null)

log "완료: 생성 1개, 삭제 $deleted개"
echo "rag-backup: $ARCHIVE ($archive_size), deleted $deleted"
