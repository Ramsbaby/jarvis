#!/usr/bin/env bash
# e2e-cron.sh - E2E 자가 진단 크론 래퍼 (L1: 자동 실행, 실패 시만 ntfy 에스컬레이션)
# Usage: e2e-cron.sh
# Schedule: 30 3 * * * (매일 03:30, rag-health 03:00 이후 실행)
set -uo pipefail

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# .env 로딩 — 크론 환경에 OPENAI_API_KEY 등 누락 방지
if [[ -f "${BOT_HOME}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${BOT_HOME}/.env"
  set +a
fi

LOG_FILE="${BOT_HOME}/logs/e2e-cron.log"
RESULT_FILE="${BOT_HOME}/results/e2e-health/$(date +%F).txt"
MONITORING="${BOT_HOME}/config/monitoring.json"

mkdir -p "$(dirname "$RESULT_FILE")" "$(dirname "$LOG_FILE")"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(timestamp)] $1" >> "$LOG_FILE"; }

log "START"

# E2E 테스트 실행 (색상 코드 제거)
OUTPUT=$("${BOT_HOME}/scripts/e2e-test.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g') || true
EXIT_CODE=$?

# 결과 파일 저장
echo "$OUTPUT" > "$RESULT_FILE"

# 통계 추출
PASS_COUNT=$(echo "$OUTPUT" | grep -c "✅ PASS" || true)
FAIL_COUNT=$(echo "$OUTPUT" | grep -c "❌ FAIL" || true)
SKIP_COUNT=$(echo "$OUTPUT" | grep -c "⏭️  SKIP" || true)
TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))

SUMMARY="${PASS_COUNT}/${TOTAL} passed"
if [[ $FAIL_COUNT -gt 0 ]]; then SUMMARY="${SUMMARY}, ${FAIL_COUNT} FAILED"; fi

log "RESULT: ${SUMMARY} (exit: ${EXIT_CODE})"

if [[ $FAIL_COUNT -gt 0 ]]; then
    # 실패 항목 추출
    FAILED_ITEMS=$(echo "$OUTPUT" | grep "❌ FAIL" | sed 's/❌ FAIL: //' | tr '\n' ', ' | sed 's/,$//')
    ALERT_MSG="E2E 자가진단 실패 (${FAIL_COUNT}건): ${FAILED_ITEMS}"

    log "ALERT: ${ALERT_MSG}"

    # ntfy 에스컬레이션
    NTFY_SERVER=$(jq -r '.ntfy.server' "$MONITORING" 2>/dev/null || echo "https://ntfy.sh")
    NTFY_TOPIC=$(jq -r '.ntfy.topic' "$MONITORING" 2>/dev/null || echo "")
    if [[ -n "$NTFY_TOPIC" ]]; then
        curl -sf -m 5 \
            -H "Title: ⚠️ E2E 실패" \
            -H "Priority: high" \
            -H "Tags: warning" \
            -d "$ALERT_MSG" \
            "${NTFY_SERVER}/${NTFY_TOPIC}" > /dev/null 2>&1 || true
    fi

    # 오래된 결과 정리 (30일 초과)
    find "$(dirname "$RESULT_FILE")" -name "*.txt" -mtime +30 -delete 2>/dev/null || true
    exit 1
fi

log "OK: ${SUMMARY}"

# 오래된 결과 정리 (30일 초과)
find "$(dirname "$RESULT_FILE")" -name "*.txt" -mtime +30 -delete 2>/dev/null || true
exit 0
