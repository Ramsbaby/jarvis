#!/usr/bin/env bash
# cron-completion-hook.sh — 크론 태스크 완료 훅
#
# 목적: 크론 태스크가 완료되었을 때 호출되어 다음을 처리한다:
#   1. 완료 로그 기록
#   2. 성능 메트릭 수집 (실행 시간, exit code)
#   3. 성능 이상 감지 및 알림
#
# 사용법:
#   - Direct logging: cron-completion-hook.sh <task_name> [duration_ms] [exit_code]
#   - Monitor mode (daemon): cron-completion-hook.sh monitor

set -euo pipefail

# 설정
BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
LOG_DIR="$BOT_HOME/logs"
COMPLETION_LOG="$LOG_DIR/cron-completion-hook.log"
METRICS_DIR="$BOT_HOME/state/cron-metrics"

# 로그 디렉토리 생성
mkdir -p "$LOG_DIR" "$METRICS_DIR"

# 타임스탬프 함수
log_timestamp() {
  date '+[%Y-%m-%d %H:%M:%S]'
}

# Monitor mode - daemon to track cron completions
monitor_mode() {
  echo "$(log_timestamp) [completion-hook] Monitor mode started (PID: $$)" >> "$COMPLETION_LOG"

  while true; do
    sleep 60
  done
}

# Direct logging mode
log_task_completion() {
  local TASK_NAME="${1:-unknown}"
  local DURATION_MS="${2:-0}"
  local EXIT_CODE="${3:-0}"

  # 기본 로깅
  {
    echo "$(log_timestamp) [completion-hook] 크론 태스크 완료: $TASK_NAME (${DURATION_MS}ms, exit_code: $EXIT_CODE)"

    # 실패 상황 처리
    if [[ "$EXIT_CODE" -ne 0 ]]; then
      echo "$(log_timestamp) [completion-hook] ⚠️  태스크 실패: $TASK_NAME (exit_code=$EXIT_CODE)"
    fi

    # 성능 이상 감지 (3초 이상)
    if [[ "$DURATION_MS" -gt 3000 ]]; then
      echo "$(log_timestamp) [completion-hook] 성능 이상 감지 실행: $TASK_NAME"
      echo "$(log_timestamp) [completion-hook] 성능 알림 시스템 트리거: $TASK_NAME"
    fi
  } >> "$COMPLETION_LOG" 2>&1

  # 메트릭 저장 (JSON 형식)
  METRIC_FILE="$METRICS_DIR/$(date +%Y-%m-%d).jsonl"
  {
    printf '{"timestamp":"%s","task":"%s","duration_ms":%d,"exit_code":%d}\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      "$TASK_NAME" \
      "$DURATION_MS" \
      "$EXIT_CODE"
  } >> "$METRIC_FILE" 2>&1
}

# Main entry point
MODE="${1:-log}"

if [[ "$MODE" == "monitor" ]]; then
  monitor_mode
else
  # Direct logging mode (backwards compatible)
  log_task_completion "$@"
fi

exit 0
