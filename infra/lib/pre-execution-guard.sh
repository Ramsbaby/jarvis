#!/usr/bin/env bash
# pre-execution-guard.sh
# 반복 실수 클러스터 cl-e30aee511af89e13 방어: 재실행 전 현재 상태 확인
#
# 원칙: 불필요한 재실행을 방지하기 위해 재실행 전에 현재 상태를 먼저 확인
# - 이미 완료된 작업인가?
# - 현재 진행 중인가?
# - 에러가 발생했는가? (재실행 필요)
#
# 사용법:
#   source ${BOT_HOME}/lib/pre-execution-guard.sh
#   check_task_status $task_id → 0 (OK, 진행 가능) or 1 (중단, 이미 완료/진행중)
#   is_task_already_complete $task_id → 0 (완료됨) or 1 (미완료)
#   is_task_in_progress $task_id → 0 (진행중) or 1 (진행중 아님)
#   get_task_status $task_id → "unknown", "running", "success", "failure", "timeout"

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
STATE_DIR="${BOT_HOME}/state"
TASK_STATUS_DIR="${STATE_DIR}/task-status"
TASK_LOCK_DIR="${STATE_DIR}/task-locks"

mkdir -p "$TASK_STATUS_DIR" "$TASK_LOCK_DIR" 2>/dev/null || true

# Status file: ${BOT_HOME}/state/task-status/{task_id}.json
# Content: {"task_id": "...", "status": "success|failure|running|timeout", "timestamp": "...", "exit_code": 0}

_guard_log() {
    local message="$1"
    local guard_log="${BOT_HOME}/logs/pre-execution-guard.log"
    mkdir -p "$(dirname "$guard_log")" 2>/dev/null || true
    printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$message" >> "$guard_log" 2>/dev/null || true
}

# 작업 상태 파일 경로
_get_status_file() {
    local task_id="${1:?task_id required}"
    echo "${TASK_STATUS_DIR}/${task_id}.json"
}

# 작업 락 파일 경로
_get_lock_file() {
    local task_id="${1:?task_id required}"
    echo "${TASK_LOCK_DIR}/${task_id}.lock"
}

# 작업 상태 파일에서 현재 상태 읽기
get_task_status() {
    local task_id="${1:?task_id required}"
    local status_file
    status_file=$(_get_status_file "$task_id")

    if [[ ! -f "$status_file" ]]; then
        echo "unknown"
        return 0
    fi

    # JSON 파일에서 status 필드 추출
    local status
    status=$(jq -r '.status // "unknown"' "$status_file" 2>/dev/null || echo "unknown")
    echo "$status"
}

# 작업이 이미 성공했는가?
is_task_already_complete() {
    local task_id="${1:?task_id required}"
    local status
    status=$(get_task_status "$task_id")

    # success이면 0 (이미 완료), 그 외는 1 (미완료)
    if [[ "$status" == "success" ]]; then
        _guard_log "ALREADY_COMPLETE task=$task_id status=$status"
        return 0
    fi
    return 1
}

# 작업이 현재 진행 중인가?
is_task_in_progress() {
    local task_id="${1:?task_id required}"
    local lock_file
    lock_file=$(_get_lock_file "$task_id")

    # 락 파일 존재 + 내용에 유효한 PID = 진행중
    if [[ -f "$lock_file" ]]; then
        local pid
        pid=$(cat "$lock_file" 2>/dev/null || echo "0")

        # PID가 현재 실행 중인지 확인 (ps 체크)
        if kill -0 "$pid" 2>/dev/null; then
            _guard_log "IN_PROGRESS task=$task_id pid=$pid"
            return 0  # 진행중
        else
            # PID가 죽었으면 락 파일 정리
            rm -f "$lock_file" 2>/dev/null || true
            return 1  # 진행중 아님
        fi
    fi
    return 1  # 락 파일 없음 = 진행중 아님
}

# 핵심: 재실행 전 현재 상태 확인
# 반환값: 0 (진행 가능) or 1 (진행 불가, 이미 완료되거나 진행중)
check_task_status() {
    local task_id="${1:?task_id required}"
    local allow_retry="${2:-false}"  # allow_retry=true이면 failure 상태도 진행 가능

    local status
    status=$(get_task_status "$task_id")

    case "$status" in
        success)
            # 이미 완료됨 → 재실행 금지
            _guard_log "CHECK_FAILED task=$task_id reason=already_complete"
            return 1
            ;;
        running)
            # 진행중 → 중복 실행 금지
            _guard_log "CHECK_FAILED task=$task_id reason=already_in_progress"
            return 1
            ;;
        failure|timeout)
            # 실패 상태
            if [[ "$allow_retry" == "true" ]]; then
                _guard_log "CHECK_PASSED task=$task_id status=$status allow_retry=true"
                return 0  # 재실행 허용
            else
                _guard_log "CHECK_FAILED task=$task_id status=$status allow_retry=false"
                return 1  # 재실행 금지
            fi
            ;;
        unknown)
            # 알 수 없음 → 진행 허용 (신규 작업)
            _guard_log "CHECK_PASSED task=$task_id reason=new_task"
            return 0
            ;;
        *)
            # 예상치 못한 상태 → 진행 허용 (보수적)
            _guard_log "CHECK_PASSED task=$task_id reason=unknown_status:$status"
            return 0
            ;;
    esac
}

# 작업 상태 기록 (성공)
mark_task_success() {
    local task_id="${1:?task_id required}"
    local exit_code="${2:-0}"
    local status_file
    status_file=$(_get_status_file "$task_id")

    # JSON 형식으로 상태 저장
    jq -n \
        --arg task_id "$task_id" \
        --arg status "success" \
        --arg timestamp "$(date -u +%FT%TZ)" \
        --argjson exit_code "$exit_code" \
        '{task_id: $task_id, status: $status, timestamp: $timestamp, exit_code: $exit_code}' \
        > "$status_file" 2>/dev/null || true

    # 락 파일 정리
    rm -f "$(_get_lock_file "$task_id")" 2>/dev/null || true

    _guard_log "MARK_SUCCESS task=$task_id"
}

# 작업 상태 기록 (실패)
mark_task_failure() {
    local task_id="${1:?task_id required}"
    local exit_code="${2:-1}"
    local status_file
    status_file=$(_get_status_file "$task_id")

    jq -n \
        --arg task_id "$task_id" \
        --arg status "failure" \
        --arg timestamp "$(date -u +%FT%TZ)" \
        --argjson exit_code "$exit_code" \
        '{task_id: $task_id, status: $status, timestamp: $timestamp, exit_code: $exit_code}' \
        > "$status_file" 2>/dev/null || true

    rm -f "$(_get_lock_file "$task_id")" 2>/dev/null || true

    _guard_log "MARK_FAILURE task=$task_id exit_code=$exit_code"
}

# 작업 상태 기록 (실행 중)
mark_task_running() {
    local task_id="${1:?task_id required}"
    local pid="${2:?pid required}"
    local lock_file
    lock_file=$(_get_lock_file "$task_id")

    # 락 파일에 PID 저장
    echo "$pid" > "$lock_file" 2>/dev/null || true

    # 상태 파일도 업데이트
    local status_file
    status_file=$(_get_status_file "$task_id")
    jq -n \
        --arg task_id "$task_id" \
        --arg status "running" \
        --arg timestamp "$(date -u +%FT%TZ)" \
        --argjson pid "$pid" \
        '{task_id: $task_id, status: $status, timestamp: $timestamp, pid: $pid}' \
        > "$status_file" 2>/dev/null || true

    _guard_log "MARK_RUNNING task=$task_id pid=$pid"
}

# 상태 파일 정리
clear_task_status() {
    local task_id="${1:?task_id required}"
    rm -f "$(_get_status_file "$task_id")" 2>/dev/null || true
    rm -f "$(_get_lock_file "$task_id")" 2>/dev/null || true
    _guard_log "CLEAR_STATUS task=$task_id"
}

# 디버그: 모든 작업 상태 조회
list_all_task_statuses() {
    echo "=== Task Status Overview ==="
    if [[ -d "$TASK_STATUS_DIR" ]]; then
        find "$TASK_STATUS_DIR" -name "*.json" -type f | while read -r status_file; do
            local task_id
            task_id=$(basename "$status_file" .json)
            local status
            status=$(jq -r '.status // "unknown"' "$status_file" 2>/dev/null || echo "unknown")
            local timestamp
            timestamp=$(jq -r '.timestamp // "N/A"' "$status_file" 2>/dev/null || echo "N/A")
            printf '  %-40s status=%-10s timestamp=%s\n' "$task_id" "$status" "$timestamp"
        done
    fi
}

export -f get_task_status
export -f is_task_already_complete
export -f is_task_in_progress
export -f check_task_status
export -f mark_task_success
export -f mark_task_failure
export -f mark_task_running
export -f clear_task_status
export -f list_all_task_statuses
