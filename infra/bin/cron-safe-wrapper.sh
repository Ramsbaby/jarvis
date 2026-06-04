#!/usr/bin/env bash
set -euo pipefail

# cron-safe-wrapper.sh — 크론 스크립트 중앙 실행 래퍼
#
# 모든 크론 스크립트가 이 래퍼를 통해 실행되면:
#   1. mkdir atomic 싱글턴 락  → 중복 실행 원천 차단
#   2. timeout 강제             → 무한 실행 방지
#   3. nice +10                 → 시스템 부하 완충
#   4. 실행 결과 중앙 로그      → 추적 가능
#   5. 실패 진단                → 실패 원인 분류 (AUTH, RATE, CIRCUIT_OPEN, TIMEOUT 등)
#
# Usage: cron-safe-wrapper.sh <lock-name> <timeout-sec> <script-path> [args...]
#
# crontab 예시:
#   */5 * * * * /bin/bash /path/to/jarvis/infra/bin/cron-safe-wrapper.sh \
#     bot-watchdog 120 /path/to/jarvis/infra/bin/bot-watchdog.sh
#
# lock-name : /tmp/jarvis-cron-<lock-name>.lock 으로 사용됨
# timeout   : 초 단위. 초과 시 SIGTERM → 30초 후 SIGKILL
# script    : 실행할 스크립트 절대 경로
#
# Exit codes:
#   0   - Success
#   1   - Generic failure
#   99  - Circuit breaker open (graceful skip) or ask-claude.sh internal error
#        When exit 99 is returned with 'circuit' in stderr, it indicates the
#        circuit breaker gracefully skipped execution to protect the system.
#        This is NOT a failure—it's a controlled, protective mechanism.
#   124 - Timeout (exceeded limit)

LOCK_NAME="${1:?Usage: cron-safe-wrapper.sh <lock-name> <timeout-sec> <cmd> [args...]}"
MAX_TIMEOUT="${2:?Usage: cron-safe-wrapper.sh <lock-name> <timeout-sec> <cmd> [args...]}"
shift 2
# 나머지 $@ = 실행할 커맨드 전체 (bash/node/python 구분 없이 수용)

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
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

    # stat: Linux uses -c '%Y', macOS uses -f %m
    _lock_mtime=$(stat -c '%Y' "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)
    _age=$(( $(date +%s) - _lock_mtime ))

    # Check if process is still running
    _pid_running=0
    if [[ "$_pid" -gt 0 ]]; then
        kill -0 "$_pid" 2>/dev/null && _pid_running=1 || true
    fi

    # 프로세스 살아있고 타임아웃 + 60초 버퍼 내라면 스킵
    if (( _pid_running == 1 && _age < MAX_TIMEOUT + 60 )); then
        _log "SKIP 이미 실행 중 (PID ${_pid}, ${_age}s 경과)"
        exit 0
    fi

    # 스테일 락 정리 후 재획득 (최대 3회 재시도)
    _retry_count=0
    while (( _retry_count < 3 )); do
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            break
        fi
        _retry_count=$(( _retry_count + 1 ))
        sleep 0.1
    done

    if [[ ! -d "$LOCK_DIR" ]]; then
        _log "WARN 락 획득 실패 (race condition) — 이번 실행 스킵"
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

# Capture stderr for failure diagnosis
STDERR_FILE="${LOCK_DIR}/stderr.log"
mkdir -p "$(dirname "$STDERR_FILE")"

if [[ -n "$TIMEOUT_CMD" ]]; then
    # --kill-after: timeout 후 SIGTERM, 30초 뒤 SIGKILL
    # 5초는 CPU-bound 작업(ONNX 임베딩)에서 이벤트 루프가 SIGTERM 처리하기에 부족
    nice -n 10 "$TIMEOUT_CMD" --kill-after=30 "$MAX_TIMEOUT" "$@" 2>"$STDERR_FILE" || EXIT_CODE=$?
else
    nice -n 10 "$@" 2>"$STDERR_FILE" || EXIT_CODE=$?
fi

_ELAPSED=$(( $(date +%s) - _START ))

# ── 실패 진단 ─────────────────────────────────────────────────────────────────
if [[ $EXIT_CODE -eq 124 ]]; then
    _log "TIMEOUT ${_ELAPSED}s (limit: ${MAX_TIMEOUT}s) exit=124"
elif [[ $EXIT_CODE -eq 99 ]]; then
    # Exit code 99: ask-claude.sh graceful skip (circuit breaker open) or internal failure
    STDERR_CONTENT=$(cat "$STDERR_FILE" 2>/dev/null | head -c 2000 || echo "")
    FAILURE_TYPE="INTERNAL_ERROR"

    # Circuit breaker detection: case-insensitive 'circuit' keyword
    if [[ "$STDERR_CONTENT" =~ [Cc][Ii][Rr][Cc][Uu][Ii][Tt] ]]; then
        FAILURE_TYPE="CIRCUIT_OPEN"
    elif [[ "$STDERR_CONTENT" =~ AUTH ]]; then
        FAILURE_TYPE="AUTH_INTERNAL"
    elif [[ "$STDERR_CONTENT" =~ RATE ]]; then
        FAILURE_TYPE="RATE_LIMIT"
    elif [[ "$STDERR_CONTENT" =~ [Nn]ot.found ]]; then
        FAILURE_TYPE="NOT_FOUND"
    fi

    _log "FAIL exit=99 ${_ELAPSED}s [${FAILURE_TYPE}]"
    [[ -n "$STDERR_CONTENT" ]] && _log "  stderr: ${STDERR_CONTENT:0:150}"
elif [[ $EXIT_CODE -ne 0 ]]; then
    # Analyze stderr for failure pattern (generic failures)
    STDERR_CONTENT=$(cat "$STDERR_FILE" 2>/dev/null | head -c 2000 || echo "")
    FAILURE_TYPE="UNKNOWN"

    if [[ "$STDERR_CONTENT" =~ AUTH ]]; then
        FAILURE_TYPE="AUTH"
    elif [[ "$STDERR_CONTENT" =~ RATE ]]; then
        FAILURE_TYPE="RATE_LIMIT"
    elif [[ "$STDERR_CONTENT" =~ "not found" ]]; then
        FAILURE_TYPE="NOT_FOUND"
    elif [[ "$STDERR_CONTENT" =~ "Permission denied" ]]; then
        FAILURE_TYPE="PERMISSION"
    elif [[ "$STDERR_CONTENT" =~ Connection ]]; then
        FAILURE_TYPE="NETWORK"
    elif [[ "$STDERR_CONTENT" =~ timeout ]]; then
        FAILURE_TYPE="TIMEOUT_INTERNAL"
    fi

    _log "FAIL exit=${EXIT_CODE} ${_ELAPSED}s [${FAILURE_TYPE}]"
    [[ -n "$STDERR_CONTENT" ]] && _log "  stderr: ${STDERR_CONTENT:0:150}"
else
    _log "DONE exit=0 ${_ELAPSED}s"
fi

# Cleanup stderr file
rm -f "$STDERR_FILE" 2>/dev/null || true

# Report exit code to cron system
# Note: Cron jobs should return 0 on success and non-zero on failure
# This wrapper always exits with the original exit code to signal status
if [[ $EXIT_CODE -eq 0 ]]; then
    exit 0
else
    # Non-zero exit will trigger cron email alert (if configured)
    exit $EXIT_CODE
fi