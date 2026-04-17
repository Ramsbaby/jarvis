#!/usr/bin/env bash
set -euo pipefail

# log-rotate.sh — 자비스 로그 로테이션
#
# 로그 파일 명명 정책 (SSoT — 이 주석이 유일한 출처):
#   {task-id}.log       — 태스크 stdout/결과 (주 로그)
#   {task-id}-err.log   — 태스크 stderr (에러 전용)
#   {task-id}.out / .err — launchd stdout/stderr (discord-bot, watchdog 전용)
#   *.jsonl             — 구조화 로그 (ask-claude, task-runner)
#
# 보존 정책:
#   plain log (≤2MB)    → 보존 (미로테이션)
#   plain log (>2MB)    → 날짜 suffix + gzip → RETENTION_DAYS 후 삭제
#   err log (>512KB)    → 날짜 suffix + gzip → RETENTION_DAYS 후 삭제
#   .gz archives        → RETENTION_DAYS 후 삭제
#   launchd .out/.err   → 3MB 초과 시 tail -1000 truncate (무한 증가 방지)
#
# Schedule: daily 03:05 (e2e 03:30 이전, gen-indexes 06:17 이전)

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG_DIR="${BOT_HOME}/logs"
RETENTION_DAYS=7
LOG="${LOG_DIR}/log-rotate.log"

log() { echo "[$(date '+%F %T')] [log-rotate] $1" | tee -a "$LOG"; }

# ── 1. JSONL 로그 로테이션 (task-runner, ask-claude 등) ─────────────────────
for logfile in "$LOG_DIR"/*.jsonl; do
    [[ -f "$logfile" ]] || continue
    size=$(stat -f %z "$logfile" 2>/dev/null || stat -c '%s' "$logfile" 2>/dev/null || echo "0")
    if [[ "$size" -gt 1048576 ]]; then  # 1MB
        mv "$logfile" "${logfile}.$(date +%F)"
        gzip "${logfile}.$(date +%F)" 2>/dev/null || true
        log "JSONL rotated: $(basename "$logfile") (${size}B)"
    fi
done

# ── 2. 일반 .log 로테이션 ───────────────────────────────────────────────────
for logfile in "$LOG_DIR"/*.log; do
    [[ -f "$logfile" ]] || continue
    size=$(stat -f %z "$logfile" 2>/dev/null || stat -c '%s' "$logfile" 2>/dev/null || echo "0")
    if [[ "$size" -gt 2097152 ]]; then  # 2MB
        mv "$logfile" "${logfile}.$(date +%F)"
        gzip "${logfile}.$(date +%F)" 2>/dev/null || true
        touch "$logfile"
        log "Log rotated: $(basename "$logfile") (${size}B)"
    fi
done

# ── 3. -err.log 로테이션 (에러 로그 별도 정책) ──────────────────────────────
for logfile in "$LOG_DIR"/*-err.log; do
    [[ -f "$logfile" ]] || continue
    size=$(stat -f %z "$logfile" 2>/dev/null || stat -c '%s' "$logfile" 2>/dev/null || echo "0")
    if [[ "$size" -gt 524288 ]]; then  # 512KB — err 로그는 더 작은 임계값
        mv "$logfile" "${logfile}.$(date +%F)"
        gzip "${logfile}.$(date +%F)" 2>/dev/null || true
        touch "$logfile"
        log "Err rotated: $(basename "$logfile") (${size}B)"
    fi
done

# ── 4. 오래된 압축 파일 삭제 ────────────────────────────────────────────────
find "$LOG_DIR" -name "*.gz" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
find "$LOG_DIR" -name "*.log.*" -not -name "*.gz" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true

# Rotate launchd stdout/stderr logs (these grow unbounded)
for logfile in "$LOG_DIR"/discord-bot.out.log "$LOG_DIR"/discord-bot.err.log \
               "$LOG_DIR"/watchdog.out.log "$LOG_DIR"/watchdog.err.log; do
    [[ -f "$logfile" ]] || continue
    size=$(stat -f %z "$logfile" 2>/dev/null || stat -c '%s' "$logfile" 2>/dev/null || echo "0")
    if [[ "$size" -gt 3145728 ]]; then  # 3MB (이전 10MB에서 낮춤)
        # Keep last 1000 lines, truncate the rest
        tail -1000 "$logfile" > "${logfile}.tmp"
        mv "${logfile}.tmp" "$logfile"
        log "Truncated: $(basename "$logfile") (was ${size} bytes)"
    fi
done

log "Log rotation complete"