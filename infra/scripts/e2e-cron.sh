#!/usr/bin/env bash
# e2e-cron.sh - E2E 자가 진단 크론 래퍼 (L1: 자동 실행, 실패 시만 ntfy 에스컬레이션)
# Usage: e2e-cron.sh
# Schedule: 30 3 * * * (매일 03:30, rag-health 03:00 이후 실행)
set -uo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"

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

# gen-inventory.sh 완료 대기 (cron-catalog.md 최신화 필수)
# — e2e-test.sh가 cron-catalog.md 존재/일관성을 검사하므로 선행 필수
if [[ -f "${BOT_HOME}/scripts/gen-inventory.sh" ]]; then
  bash "${BOT_HOME}/scripts/gen-inventory.sh" >> "${BOT_HOME}/logs/gen-inventory.log" 2>&1 || true
  sleep 2  # file sync 대기
fi

# E2E 테스트 실행 (최대 2회 재시도)
# Discord bot이 일시적으로 응답하지 않을 수 있으므로 재시도 메커니즘 추가
MAX_RETRIES=2
RETRY_COUNT=0

while [[ $RETRY_COUNT -le $MAX_RETRIES ]]; do
  OUTPUT=$("${BOT_HOME}/scripts/e2e-test.sh" 2>&1 | sed 's/\x1b\[[0-9;]*m//g') || true
  E2E_EXIT_CODE=$?

  # 실패한 항목에서 "Discord bot running" 만 있으면 봇 재시작 후 재시도
  FAIL_COUNT=$(echo "$OUTPUT" | grep -c "❌ FAIL" || true)
  if [[ $FAIL_COUNT -eq 1 ]]; then
    FAILED_ITEM=$(echo "$OUTPUT" | grep "❌ FAIL" | sed 's/❌ FAIL: //')
    if [[ "$FAILED_ITEM" == "Discord bot running" ]] && [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
      log "Discord bot check failed, restarting bot and retrying... (attempt $((RETRY_COUNT+2))/$((MAX_RETRIES+1)))"

      # Discord bot 재시작 시도
      launchctl stop ai.jarvis.discord-bot 2>/dev/null || true
      sleep 2
      launchctl start ai.jarvis.discord-bot 2>/dev/null || true
      sleep 3  # 봇 시작 대기

      RETRY_COUNT=$((RETRY_COUNT+1))
      continue
    fi
  fi

  # 성공 또는 재시도 불가능한 실패이면 루프 탈출
  break
done

# 결과 파일 저장
echo "$OUTPUT" > "$RESULT_FILE"

# 통계 추출
PASS_COUNT=$(echo "$OUTPUT" | grep -c "✅ PASS" || true)
FAIL_COUNT=$(echo "$OUTPUT" | grep -c "❌ FAIL" || true)
WARN_COUNT=$(echo "$OUTPUT" | grep -c "⚠️  WARN" || true)
SKIP_COUNT=$(echo "$OUTPUT" | grep -c "⏭️  SKIP" || true)
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT + SKIP_COUNT))

SUMMARY="${PASS_COUNT}/${TOTAL} passed"
if [[ $FAIL_COUNT -gt 0 ]]; then SUMMARY="${SUMMARY}, ${FAIL_COUNT} FAILED"; fi

# Determine exit code (0 if no failures, 1 if there are failures)
FINAL_EXIT_CODE=0
if [[ $FAIL_COUNT -gt 0 ]]; then FINAL_EXIT_CODE=1; fi

log "RESULT: ${SUMMARY} (exit: ${FINAL_EXIT_CODE})"

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
else
    log "OK: ${SUMMARY}"
fi

# 오래된 결과 정리 (30일 초과)
find "$(dirname "$RESULT_FILE")" -name "*.txt" -mtime +30 -delete 2>/dev/null || true
exit "$FINAL_EXIT_CODE"