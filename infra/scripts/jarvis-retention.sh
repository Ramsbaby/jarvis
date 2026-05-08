#!/usr/bin/env bash
# jarvis-retention.sh — ledger 90일↑ 자동 archive (gzip)
# 매월 1일 03:00 KST
#
# 대상:
#   - runtime/state/*.jsonl (90일 이상 된 라인 → archive 디렉토리)
#   - runtime/logs/*.log (90일 이상 → gzip 압축)

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
ARCHIVE_DIR="$JARVIS_HOME/runtime/state/archive/$(date +%Y-%m)"
LOG_FILE="$JARVIS_HOME/runtime/logs/jarvis-retention.log"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"

mkdir -p "$ARCHIVE_DIR" "$(dirname "$LOG_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

CUTOFF_ISO=$(date -v-90d +%Y-%m-%dT 2>/dev/null || date -d '-90 days' +%Y-%m-%dT)

# 1. JSONL — 90일 이상 라인 분리
ARCHIVED_LINES=0
for f in "$JARVIS_HOME/runtime/state"/*.jsonl; do
    [ -f "$f" ] || continue
    BASE=$(basename "$f")
    OLD_LINES=$(awk -v c="$CUTOFF_ISO" -F'"ts":"' 'NF>1 && $2 < c' "$f" | wc -l | tr -d ' ')
    if [ "$OLD_LINES" -gt 0 ]; then
        # 멱등성 fix (verify 잔여): 파일명 = 날짜 기반 (재실행 시 같은 파일 덮어쓰기)
        ARCHIVE_FILE="$ARCHIVE_DIR/${BASE}.$(date +%Y-%m-%d).gz"
        if [ -f "$ARCHIVE_FILE" ]; then
            _log "skip (이미 archived 오늘): $BASE"
            continue
        fi
        # 90일 이상 → archive로 이동
        awk -v c="$CUTOFF_ISO" -F'"ts":"' 'NF>1 && $2 < c' "$f" | gzip > "$ARCHIVE_FILE"
        # 원본은 90일 이내만 남기기
        awk -v c="$CUTOFF_ISO" -F'"ts":"' 'NF>1 && $2 >= c' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
        ARCHIVED_LINES=$((ARCHIVED_LINES + OLD_LINES))
        _log "archived: $BASE ($OLD_LINES lines → $ARCHIVE_FILE)"
    fi
done

# 2. 로그 — 90일 이상 mtime 파일 gzip (이미 gz 제외)
ARCHIVED_LOGS=0
for f in "$JARVIS_HOME/runtime/logs"/*.log; do
    [ -f "$f" ] || continue
    MTIME=$(stat -f %m "$f" 2>/dev/null || echo 0)
    CUTOFF_EPOCH=$(date -v-90d +%s 2>/dev/null || date -d '-90 days' +%s)
    if [ "$MTIME" -lt "$CUTOFF_EPOCH" ]; then
        gzip -f "$f" 2>/dev/null && {
            mv "${f}.gz" "$ARCHIVE_DIR/" 2>/dev/null || true
            ARCHIVED_LOGS=$((ARCHIVED_LOGS + 1))
        }
    fi
done

_log "retention: jsonl_lines=$ARCHIVED_LINES, logs=$ARCHIVED_LOGS"

if [ -f "$DISCORD_VISUAL" ] && [ $((ARCHIVED_LINES + ARCHIVED_LOGS)) -gt 0 ]; then
    PAYLOAD=$(jq -nc \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        --arg lines "$ARCHIVED_LINES" \
        --arg logs "$ARCHIVED_LOGS" \
        --arg dir "$ARCHIVE_DIR" \
        '{title:"🗄️ 월간 Retention", data:{"JSONL archive":$lines,"로그 archive":$logs,"위치":$dir}, timestamp:$ts}')
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
