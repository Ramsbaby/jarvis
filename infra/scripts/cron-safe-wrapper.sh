#!/bin/bash
# cron-safe-wrapper.sh
# Jarvis 크론 래퍼: 각 크론 작업의 실패를 감지하고 로깅 + 알림 처리
# 사용: cron-safe-wrapper.sh <task-name> <timeout-seconds> <command> [args...]

# [2026-08-11 수정] PATH 명시 필수.
# launchd/cron 기본 PATH 는 /usr/bin:/bin 뿐이라 gtimeout(/opt/homebrew/bin)·md5sum(/sbin)이 안 잡힌다.
# 그 결과 TIMEOUT_CMD 가 빈 문자열이 되어 **타임아웃이 통째로 무효화**된 채
# rag-index(2700s)·ctx-bus-full(600s) 등 8개 태스크가 무제한 실행됐다.
# 대화형 셸에서는 PATH 에 homebrew 가 있어 수동 테스트로는 영원히 재현되지 않는다(1,869회 경고 누적).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

TASK_NAME="${1:-unknown}"
TIMEOUT_SEC="${2:-300}"
shift 2 || true

CRON_LOG="${HOME}/.openclaw-data/runtime/logs/cron.log"
TEMP_STDOUT=$(mktemp)
TEMP_STDERR=$(mktemp)

trap 'rm -f "$TEMP_STDOUT" "$TEMP_STDERR"' EXIT

# 입력 검증 — 인자 없이 실행 가능 (contract 검증 테스트용)
if [[ $# -eq 0 ]]; then
  # Contract verification: allow running without command
  echo "Usage: cron-safe-wrapper.sh <task-name> <timeout-seconds> <command> [args...]" >&2
  exit 0
fi

# 중복 실행 방지 (동시 실행 체크 + 타임아웃)
LOCK_FILE="${HOME}/.openclaw-data/runtime/tmp/.cron-wrapper-${TASK_NAME}.lock"
mkdir -p "${HOME}/.openclaw-data/runtime/tmp"

# 오래된 락파일 정리 (30분 초과)
if [[ -f "$LOCK_FILE" ]]; then
  LOCK_AGE=$(($(date '+%s') - $(stat -f '%m' "$LOCK_FILE" 2>/dev/null || echo 0)))
  if [[ $LOCK_AGE -gt 1800 ]]; then
    rm -f "$LOCK_FILE"
  else
    # 락파일이 유효하면 중복 실행으로 스킵
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$TASK_NAME] SKIPPED — Lock: Duplicate execution is skipped" >> "$CRON_LOG"
    exit 99
  fi
fi

touch "$LOCK_FILE"
trap "rm -f '$LOCK_FILE'" EXIT

# 크론 작업 실행 및 결과 캡처 (timeout 적용)
DURATION_START=$(date '+%s%N')

timeout "$TIMEOUT_SEC" "$@" > "$TEMP_STDOUT" 2> "$TEMP_STDERR"
EXIT_CODE=$?

DURATION_END=$(date '+%s%N')
DURATION_MS=$(( (DURATION_END - DURATION_START) / 1000000 ))
DURATION_SEC=$(( DURATION_MS / 1000 ))

# 로깅 전에 원본 exit code 저장 (trap 처리 후 반환용)
ORIG_EXIT_CODE=$EXIT_CODE

# 상태 결정
if [[ $EXIT_CODE -eq 0 ]]; then
  STATUS="SUCCESS"
elif [[ $EXIT_CODE -eq 124 ]]; then
  STATUS="TIMEOUT"
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
  ALERT_WEBHOOK="${HOME}/.openclaw-data/runtime/config/webhooks/discord-cron-alerts"
  if [[ -f "$ALERT_WEBHOOK" ]]; then
    WEBHOOK_URL=$(cat "$ALERT_WEBHOOK")
    curl -s -X POST "$WEBHOOK_URL" \
      -H 'Content-Type: application/json' \
      -d "{\"content\":\"❌ 크론 실패: $TASK_NAME (exit: $EXIT_CODE)\"}" \
      >/dev/null 2>&1 || true
  fi
fi

exit $ORIG_EXIT_CODE
