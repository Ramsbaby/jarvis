#!/bin/bash
# cron-safe-wrapper.sh
# Jarvis 크론 래퍼: 각 크론 작업의 실패를 감지하고 로깅 + 알림 처리
# 사용: cron-safe-wrapper.sh <task-name> <command> [args...]

TASK_NAME="${1:-unknown}"
shift || true

CRON_LOG="${HOME}/.jarvis/logs/cron.log"
TEMP_STDOUT=$(mktemp)
TEMP_STDERR=$(mktemp)

trap 'rm -f "$TEMP_STDOUT" "$TEMP_STDERR"' EXIT

# 입력 검증
if [[ $# -eq 0 ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cron-safe-wrapper] ERROR: No command provided" >> "$CRON_LOG"
  exit 1
fi

# 중복 실행 방지 (동시 실행 체크 + 타임아웃)
LOCK_FILE="${HOME}/.jarvis/tmp/.cron-wrapper-${TASK_NAME}.lock"
mkdir -p "${HOME}/.jarvis/tmp"

# 오래된 락파일 정리 (30분 초과)
if [[ -f "$LOCK_FILE" ]]; then
  LOCK_AGE=$(($(date '+%s') - $(stat -f '%m' "$LOCK_FILE" 2>/dev/null || echo 0)))
  if [[ $LOCK_AGE -gt 1800 ]]; then
    rm -f "$LOCK_FILE"
  fi
fi

touch "$LOCK_FILE"
trap "rm -f '$LOCK_FILE'" EXIT

# 크론 작업 실행 및 결과 캡처
DURATION_START=$(date '+%s%N')

"$@" > "$TEMP_STDOUT" 2> "$TEMP_STDERR"
EXIT_CODE=$?

DURATION_END=$(date '+%s%N')
DURATION_MS=$(( (DURATION_END - DURATION_START) / 1000000 ))
DURATION_SEC=$(( DURATION_MS / 1000 ))

# 상태 결정
if [[ $EXIT_CODE -eq 0 ]]; then
  STATUS="SUCCESS"
else
  STATUS="FAILED"
fi

# 로그 기록
{
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$TASK_NAME] $STATUS (exit: $EXIT_CODE, duration: ${DURATION_SEC}s)"

  if [[ $EXIT_CODE -ne 0 ]]; then
    STDOUT_CONTENT=$(cat "$TEMP_STDOUT" 2>/dev/null || echo "(empty)")
    STDERR_CONTENT=$(cat "$TEMP_STDERR" 2>/dev/null || echo "(empty)")

    if [[ -n "$STDOUT_CONTENT" && "$STDOUT_CONTENT" != "(empty)" ]]; then
      echo "  STDOUT: $STDOUT_CONTENT"
    fi

    if [[ -n "$STDERR_CONTENT" && "$STDERR_CONTENT" != "(empty)" ]]; then
      echo "  STDERR: $STDERR_CONTENT"
    fi
  fi
} >> "$CRON_LOG"

# 실패 시 알림 (옵션)
if [[ $EXIT_CODE -ne 0 ]]; then
  ALERT_WEBHOOK="${HOME}/.jarvis/config/webhooks/discord-cron-alerts"
  if [[ -f "$ALERT_WEBHOOK" ]]; then
    WEBHOOK_URL=$(cat "$ALERT_WEBHOOK")
    curl -s -X POST "$WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d "{\"content\":\"❌ 크론 실패: $TASK_NAME (exit: $EXIT_CODE)\"}" \
      >/dev/null 2>&1 || true
  fi
fi

exit $EXIT_CODE
