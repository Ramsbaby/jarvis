#!/usr/bin/env bash
# Duplicate Request Cache Monitor (Cluster cl-3d5ba801bdad1df9)
# 목적: 캐시 파일 크기, 라인 수, 만료율을 모니터링하고 통계 기록
# 사용: bash duplicate-request-cache-monitor.sh [--alert-threshold-mb 10]

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
CACHE_FILE="${BOT_HOME}/state/duplicate-request-cache.jsonl"
MONITOR_LOG="${BOT_HOME}/logs/duplicate-request-cache-monitor.log"
ALERT_THRESHOLD_MB="${1:-10}"  # 기본값: 10MB 이상이면 경고

# [1] 캐시 파일 상태 확인
if [[ ! -f "$CACHE_FILE" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] MONITOR: cache file not found (first run)" >> "$MONITOR_LOG" 2>/dev/null
    exit 0
fi

FILE_SIZE_BYTES=$(stat -f%z "$CACHE_FILE" 2>/dev/null || stat -c%s "$CACHE_FILE" 2>/dev/null || echo 0)
FILE_SIZE_MB=$(echo "scale=2; $FILE_SIZE_BYTES / 1048576" | bc 2>/dev/null || echo 0)
LINE_COUNT=$(wc -l < "$CACHE_FILE" 2>/dev/null | tr -d ' ' || echo 0)

# [2] TTL 만료 항목 비율 계산
NOW_MS=$(date +%s)000
WINDOW_MINUTES=2
TTL_MS=$((WINDOW_MINUTES * 60 * 1000 * 2))  # cleanup과 동일한 TTL

EXPIRED_COUNT=0
FRESH_COUNT=0

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    CREATED_AT=$(echo "$line" | jq -r '.created_at // 0' 2>/dev/null || echo 0)
    AGE=$((NOW_MS - CREATED_AT))
    if [[ $AGE -gt $TTL_MS ]]; then
        ((EXPIRED_COUNT++))
    else
        ((FRESH_COUNT++))
    fi
done < "$CACHE_FILE"

TOTAL=$((EXPIRED_COUNT + FRESH_COUNT))
if [[ $TOTAL -gt 0 ]]; then
    EXPIRED_RATE=$((EXPIRED_COUNT * 100 / TOTAL))
else
    EXPIRED_RATE=0
fi

# [3] 통계 기록
mkdir -p "$(dirname "$MONITOR_LOG")"
{
    printf '[%s] SIZE=%s (%.2f MB) LINES=%d FRESH=%d EXPIRED=%d (%d%%) ALERT_THRESHOLD=%.1f MB\n' \
        "$(date -u +%FT%TZ)" \
        "$FILE_SIZE_BYTES" \
        "$FILE_SIZE_MB" \
        "$LINE_COUNT" \
        "$FRESH_COUNT" \
        "$EXPIRED_COUNT" \
        "$EXPIRED_RATE" \
        "$ALERT_THRESHOLD_MB"
} >> "$MONITOR_LOG" 2>/dev/null || true

# [4] 경고 발생 (임계값 초과)
if (( $(echo "$FILE_SIZE_MB > $ALERT_THRESHOLD_MB" | bc -l 2>/dev/null || echo 0) )); then
    {
        printf '[%s] ALERT: Cache file size %.2f MB exceeds threshold %.1f MB (lines=%d, expired_rate=%d%%)\n' \
            "$(date -u +%FT%TZ)" \
            "$FILE_SIZE_MB" \
            "$ALERT_THRESHOLD_MB" \
            "$LINE_COUNT" \
            "$EXPIRED_RATE"
    } >> "$MONITOR_LOG" 2>/dev/null || true

    # stderr로 경고 출력 (드래곤의 감시 가능하도록)
    printf '[%s] DUPLICATE_REQUEST_CACHE_ALERT: size=%.2fMB expired_rate=%d%%\n' \
        "$(date '+%F %H:%M:%S')" \
        "$FILE_SIZE_MB" \
        "$EXPIRED_RATE" >&2

    exit 1
fi

exit 0
