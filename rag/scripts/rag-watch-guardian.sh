#!/usr/bin/env bash
set -euo pipefail

INFRA_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
LOG="$INFRA_HOME/logs/rag-watch-guardian.log"
mkdir -p "$(dirname "$LOG")"
THRESHOLD_MB=500

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

pids=$(pgrep -f "rag-watch.mjs" 2>/dev/null || true)
if [[ -z "$pids" ]]; then
    log "rag-watch not running"
    exit 0
fi

# 모든 인스턴스 메모리 합산 (동시 실행 시 head -1로 누락 방지)
total_mb=0
for pid in $pids; do
    mem_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0")
    total_mb=$(( total_mb + mem_kb / 1024 ))
done
instance_count=$(echo "$pids" | wc -w | tr -d ' ')

if (( total_mb >= THRESHOLD_MB )); then
    log "rag-watch ${instance_count}instance(s) total ${total_mb}MB >= ${THRESHOLD_MB}MB — killing all"
    for pid in $pids; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 2
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    log "rag-watch terminated. launchd (KeepAlive) will restart it automatically."
else
    log "rag-watch ${instance_count}instance(s) total ${total_mb}MB — OK"
fi
