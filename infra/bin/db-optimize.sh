#!/usr/bin/env bash
# db-optimize.sh — SQLite WAL checkpoint + 최적화
# 스케줄: 주 2회 (일, 목 02:00) crontab 등록
set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
DB_PATH="$BOT_HOME/state/messages.db"
LOG_FILE="$BOT_HOME/logs/db-optimize.log"

log() { echo "[$(date '+%F %T')] [db-optimize] $1" | tee -a "$LOG_FILE"; }

if [[ ! -f "$DB_PATH" ]]; then
  log "SKIP: $DB_PATH 없음"
  exit 0
fi

BEFORE=$(stat -f %z "$DB_PATH" 2>/dev/null || stat -c '%s' "$DB_PATH" 2>/dev/null || echo "0")
WAL_PATH="${DB_PATH}-wal"
WAL_BEFORE=$(stat -f %z "$WAL_PATH" 2>/dev/null || stat -c '%s' "$WAL_PATH" 2>/dev/null || echo "0")

log "시작 — DB: ${BEFORE} bytes, WAL: ${WAL_BEFORE} bytes"

sqlite3 "$DB_PATH" << 'SQL'
PRAGMA optimize;
PRAGMA wal_checkpoint(RESTART);
SQL

AFTER=$(stat -f %z "$DB_PATH" 2>/dev/null || stat -c '%s' "$DB_PATH" 2>/dev/null || echo "0")
WAL_AFTER=$(stat -f %z "$WAL_PATH" 2>/dev/null || stat -c '%s' "$WAL_PATH" 2>/dev/null || echo "0")

log "완료 — DB: ${AFTER} bytes, WAL: ${WAL_AFTER} bytes (WAL 감소: $((WAL_BEFORE - WAL_AFTER)) bytes)"
