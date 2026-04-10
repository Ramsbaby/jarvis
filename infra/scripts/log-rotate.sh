#!/usr/bin/env bash
set -euo pipefail

# log-rotate.sh - Rotate bot log files
# Usage: cron daily at 03:00
# Keeps last 7 days of logs, compresses older ones

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_DIR="${BOT_HOME}/logs"
RETENTION_DAYS=7

log() {
    echo "[$(date '+%F %T')] [log-rotate] $1"
}

# Rotate JSONL logs (task-runner, retry, discord-bot)
for logfile in "$LOG_DIR"/*.jsonl; do
    [[ -f "$logfile" ]] || continue
    size=$(stat -f %z "$logfile" 2>/dev/null || stat -c '%s' "$logfile" 2>/dev/null || echo "0")
    # Only rotate if > 1MB
    if [[ "$size" -gt 1048576 ]]; then
        mv "$logfile" "${logfile}.$(date +%F)"
        gzip "${logfile}.$(date +%F)" 2>/dev/null || true
        log "Rotated: $(basename "$logfile") (${size} bytes)"
    fi
done

# Rotate plain text logs
for logfile in "$LOG_DIR"/*.log; do
    [[ -f "$logfile" ]] || continue
    size=$(stat -f %z "$logfile" 2>/dev/null || stat -c '%s' "$logfile" 2>/dev/null || echo "0")
    if [[ "$size" -gt 2097152 ]]; then  # 2MB (이전 5MB에서 낮춤 — 현재 로그 평균 수백KB)
        mv "$logfile" "${logfile}.$(date +%F)"
        gzip "${logfile}.$(date +%F)" 2>/dev/null || true
        touch "$logfile"
        log "Rotated: $(basename "$logfile") (${size} bytes)"
    fi
done

# Delete old compressed logs
find "$LOG_DIR" -name "*.gz" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
find "$LOG_DIR" -name "*.log.*" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true

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
