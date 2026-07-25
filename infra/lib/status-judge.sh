#!/bin/bash
# status-judge.sh — 표준 작업 판정 래퍼 (exit code 1순위, stderr 참고용)
#
# 역할:
#   작업 실행 후 exit code를 1순위로 성공/실패 판정
#   stderr는 로깅만 하고 판정에는 사용하지 않음
#   상태 파일 기반 추적으로 중복 실행 방지 검사
#
# 사용:
#   source ~/.jarvis/lib/status-judge.sh
#   judge_execution "my-task" "do_work" arg1 arg2
#
# 반환값:
#   0 - 작업 성공 (exit code == 0)
#   1 - 작업 실패 (exit code != 0)
#   2 - 이미 완료 (상태 파일 존재, 중복 실행 회피)
#   3 - 시스템 오류 (상태 디렉토리 생성 실패 등)

set -o pipefail

# 상수 정의
_JUDGE_STATE_DIR="${JUDGE_STATE_DIR:=${HOME}/jarvis/runtime/state/status-judge}"
_JUDGE_LOG_DIR="${JUDGE_LOG_DIR:=${HOME}/jarvis/runtime/logs}"
_JUDGE_DEDUP_TTL="${JUDGE_DEDUP_TTL:-0}"  # 0 = 무한, 초단위

# 내부: 상태 디렉토리 초기화
_judge_init_dirs() {
    mkdir -p "$_JUDGE_STATE_DIR" "$_JUDGE_LOG_DIR" 2>/dev/null || return 3
}

# 내부: 상태 파일 경로 반환
_judge_state_file() {
    local task_id="$1"
    echo "${_JUDGE_STATE_DIR}/${task_id}.state"
}

# 내부: 상태 파일이 유효한지 확인 (TTL 검사)
_judge_state_valid() {
    local state_file="$1"
    [ ! -f "$state_file" ] && return 1

    if [ "$_JUDGE_DEDUP_TTL" -le 0 ]; then
        return 0  # TTL 무한: 항상 유효
    fi

    local now mtime age
    now=$(date +%s)
    mtime=$(stat -f%m "$state_file" 2>/dev/null || echo 0)
    age=$((now - mtime))

    [ "$age" -lt "$_JUDGE_DEDUP_TTL" ]
}

# 내부: 상태 파일 생성 (성공 결과 기록)
_judge_record_success() {
    local task_id="$1" exit_code="$2" stderr_file="$3"
    local state_file
    state_file=$(_judge_state_file "$task_id")

    mkdir -p "$(dirname "$state_file")" 2>/dev/null || return 3

    cat > "$state_file" <<EOF
{
  "task_id": "$task_id",
  "status": "success",
  "exit_code": $exit_code,
  "timestamp": "$(date -u +%FT%TZ)",
  "stderr_log": "$stderr_file"
}
EOF
}

# 내부: 상태 파일 생성 (실패 결과 기록)
_judge_record_failure() {
    local task_id="$1" exit_code="$2" stderr_file="$3"
    local state_file
    state_file=$(_judge_state_file "$task_id")

    mkdir -p "$(dirname "$state_file")" 2>/dev/null || return 3

    cat > "$state_file" <<EOF
{
  "task_id": "$task_id",
  "status": "failure",
  "exit_code": $exit_code,
  "timestamp": "$(date -u +%FT%TZ)",
  "stderr_log": "$stderr_file"
}
EOF
}

# 내부: stderr 로그 저장
_judge_log_stderr() {
    local task_id="$1" stderr_text="$2"
    local stderr_file="${_JUDGE_LOG_DIR}/judge-stderr-${task_id}-$(date +%F_%H%M%S).log"

    mkdir -p "$_JUDGE_LOG_DIR" 2>/dev/null || return 3

    printf '%s\n' "$(date -u +%FT%TZ) [$task_id]" >> "$stderr_file"
    printf '%s\n' "$stderr_text" >> "$stderr_file"
    printf '%s\n' "$stderr_file"
}

# 외부 API: 이미 완료 상태 확인
check_already_done() {
    local task_id="$1"
    _judge_init_dirs || return 3

    local state_file
    state_file=$(_judge_state_file "$task_id")

    if _judge_state_valid "$state_file"; then
        local status
        status=$(grep '"status"' "$state_file" 2>/dev/null | grep -o '"success"' || echo '')
        if [ "$status" = '"success"' ]; then
            return 0  # 이미 성공 완료
        fi
    fi
    return 1  # 미완료 또는 실패
}

# 외부 API: 현재 상태 조회
get_task_status() {
    local task_id="$1"
    _judge_init_dirs || return 3

    local state_file
    state_file=$(_judge_state_file "$task_id")

    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        printf '{"status": "not_started"}\n'
    fi
}

# 외부 API: 상태 초기화 (수동 리셋)
clear_task_status() {
    local task_id="$1"
    _judge_init_dirs || return 3

    local state_file
    state_file=$(_judge_state_file "$task_id")
    rm -f "$state_file" 2>/dev/null || return 3
}

# 외부 API: 작업 실행 및 판정
# judge_execution TASK_ID FUNCTION [ARGS...]
judge_execution() {
    local task_id="$1"
    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 3; }
    shift

    local func_name="$1"
    [ -z "$func_name" ] && { echo "ERROR: function name required" >&2; return 3; }
    shift

    _judge_init_dirs || return 3

    # 중복 실행 검사
    if check_already_done "$task_id"; then
        echo "[status-judge] ✓ Already completed: $task_id (skipped)" >&2
        return 2
    fi

    # 함수 존재 확인
    if ! declare -F "$func_name" >/dev/null 2>&1; then
        echo "ERROR: function not defined: $func_name" >&2
        return 3
    fi

    # 작업 실행 (stderr 캡처)
    local exit_code stderr_text
    stderr_text=$(
        if ! "$func_name" "$@" 2>&1 >/dev/null; then
            cat
        fi
    ) 2>&1
    exit_code=$?

    # stderr 로그 저장 (항상)
    local stderr_file
    if [ -n "$stderr_text" ]; then
        stderr_file=$(_judge_log_stderr "$task_id" "$stderr_text") || stderr_file=""
    else
        stderr_file=""
    fi

    # Exit code 기반 판정 (stderr 무시)
    if [ "$exit_code" -eq 0 ]; then
        _judge_record_success "$task_id" "$exit_code" "$stderr_file" || return 3
        echo "[status-judge] ✓ Task succeeded: $task_id (exit=$exit_code)" >&2
        return 0
    else
        _judge_record_failure "$task_id" "$exit_code" "$stderr_file" || return 3
        echo "[status-judge] ✗ Task failed: $task_id (exit=$exit_code)" >&2
        if [ -n "$stderr_file" ]; then
            echo "[status-judge] stderr logged: $stderr_file" >&2
        fi
        return 1
    fi
}

# 외부 API: 작업 실행 (상태 추적 없음, 판정만)
judge_simple() {
    local task_id="$1"
    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 3; }
    shift

    local func_name="$1"
    [ -z "$func_name" ] && { echo "ERROR: function name required" >&2; return 3; }
    shift

    # 함수 존재 확인
    if ! declare -F "$func_name" >/dev/null 2>&1; then
        echo "ERROR: function not defined: $func_name" >&2
        return 3
    fi

    # 작업 실행 (exit code만 판정)
    if "$func_name" "$@"; then
        return 0
    else
        return $?
    fi
}

# Export 함수들 (다른 스크립트에서 source 후 사용 가능)
export -f check_already_done
export -f get_task_status
export -f clear_task_status
export -f judge_execution
export -f judge_simple
export -f _judge_init_dirs
export -f _judge_state_file
export -f _judge_state_valid
export -f _judge_record_success
export -f _judge_record_failure
export -f _judge_log_stderr
