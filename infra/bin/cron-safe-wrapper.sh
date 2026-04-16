#!/usr/bin/env bash
set -euo pipefail

# cron-safe-wrapper.sh — 크론 스크립트 중앙 실행 래퍼
#
# 모든 크론 스크립트가 이 래퍼를 통해 실행되면:
#   1. mkdir atomic 싱글턴 락  → 중복 실행 원천 차단
#   2. timeout 강제             → 무한 실행 방지
#   3. nice +10                 → 시스템 부하 완충
#   4. 실행 결과 중앙 로그      → 추적 가능
#
# Usage: cron-safe-wrapper.sh <lock-name> <timeout-sec> <script-path> [args...]
#
# crontab 예시:
#   */5 * * * * /bin/bash /path/to/jarvis/infra/bin/cron-safe-wrapper.sh \
#     bot-watchdog 120 /path/to/jarvis/infra/bin/bot-watchdog.sh
#
# lock-name : /tmp/jarvis-cron-<lock-name>.lock 으로 사용됨
# timeout   : 초 단위. 초과 시 SIGTERM → 5초 후 SIGKILL
# script    : 실행할 스크립트 절대 경로

LOCK_NAME="${1:?Usage: cron-safe-wrapper.sh <lock-name> <timeout-sec> <cmd> [args...]}"
MAX_TIMEOUT="${2:?Usage: cron-safe-wrapper.sh <lock-name> <timeout-sec> <cmd> [args...]}"
shift 2
# 나머지 $@ = 실행할 커맨드 전체 (bash/node/python 구분 없이 수용)

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
LOCK_DIR="/tmp/jarvis-cron-${LOCK_NAME}.lock"
WRAPPER_LOG="${BOT_HOME}/logs/cron-safe-wrapper.log"

mkdir -p "$(dirname "$WRAPPER_LOG")"
_log() { printf '[%s] [wrapper:%s] %s\n' "$(date '+%F %T')" "$LOCK_NAME" "$*" >> "$WRAPPER_LOG"; }

# ── 로그 5MB 초과 시 트림 ─────────────────────────────────────────────────────
if [[ -f "$WRAPPER_LOG" ]] && (( $(wc -c < "$WRAPPER_LOG") > 5242880 )); then
    tail -n 500 "$WRAPPER_LOG" > "${WRAPPER_LOG}.tmp" && mv "${WRAPPER_LOG}.tmp" "$WRAPPER_LOG"
fi

# ── atomic 싱글턴 락 ─────────────────────────────────────────────────────────
# mkdir 는 POSIX 보장 atomic — echo > file 방식(TOCTOU 레이스)과 달리 커널이 보장
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    _pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo 0)
    _age=$(( $(date +%s) - $(stat -c '%Y' "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0) ))
    # 프로세스 살아있고 타임아웃 + 60초 버퍼 내라면 스킵
    if kill -0 "$_pid" 2>/dev/null && (( _age < MAX_TIMEOUT + 60 )); then
        _log "SKIP 이미 실행 중 (PID ${_pid}, ${_age}s 경과)"
        exit 0
    fi
    # 스테일 락 정리 후 재획득
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        _log "WARN 락 획득 실패 (race) — 이번 실행 스킵"
        exit 0
    fi
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null || true' EXIT

# ── 실행 ─────────────────────────────────────────────────────────────────────
_log "START $* (timeout=${MAX_TIMEOUT}s, nice=+10)"
_START=$(date +%s)

EXIT_CODE=0
TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

if [[ -n "$TIMEOUT_CMD" ]]; then
    # --kill-after: timeout 후 SIGTERM, 30초 뒤 SIGKILL
    # 5초는 CPU-bound 작업(ONNX 임베딩)에서 이벤트 루프가 SIGTERM 처리하기에 부족
    nice -n 10 "$TIMEOUT_CMD" --kill-after=30 "$MAX_TIMEOUT" "$@" || EXIT_CODE=$?
else
    nice -n 10 "$@" || EXIT_CODE=$?
fi

_ELAPSED=$(( $(date +%s) - _START ))

if [[ $EXIT_CODE -eq 124 ]]; then
    _log "TIMEOUT ${_ELAPSED}s (limit: ${MAX_TIMEOUT}s) exit=124"
elif [[ $EXIT_CODE -ne 0 ]]; then
    _log "FAIL exit=${EXIT_CODE} ${_ELAPSED}s"
else
    _log "DONE exit=0 ${_ELAPSED}s"
fi

exit $EXIT_CODE
