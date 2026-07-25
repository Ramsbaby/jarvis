#!/bin/bash
# guard-status-check.sh — 재실행 방지 가드 함수
#
# 역할:
#   스크립트/함수 실행 전에 현재 상태를 먼저 확인
#   이미 진행 중 또는 완료된 작업의 중복 실행 방지
#
# 사용:
#   source ~/.jarvis/lib/guard-status-check.sh
#
#   if status_guard "task-name"; then
#       # 작업 실행
#       do_work
#       mark_complete "task-name"  # or mark_failed
#   fi
#
# 반환값:
#   0 - 계속 진행 가능 (상태 없음 또는 TTL 만료)
#   1 - 실행 중단 (이미 완료, 진행 중, 또는 최근 실패)

set -o pipefail

# 상수 정의
_GUARD_STATE_DIR="${GUARD_STATE_DIR:=${HOME}/jarvis/runtime/state/guard-status}"
_GUARD_LOCK_DIR="${GUARD_LOCK_DIR:=${HOME}/jarvis/runtime/state/guard-locks}"
_GUARD_LOG_DIR="${GUARD_LOG_DIR:=${HOME}/jarvis/runtime/logs}"

# 내부: 상태 디렉토리 초기화
_guard_init() {
    mkdir -p "$_GUARD_STATE_DIR" "$_GUARD_LOCK_DIR" "$_GUARD_LOG_DIR" 2>/dev/null || return 1
}

# 내부: 상태 파일 경로
_guard_state_file() {
    local task_id="$1"
    printf '%s/%s.state' "$_GUARD_STATE_DIR" "$task_id"
}

# 내부: 락 파일 경로 (진행 중 표식)
_guard_lock_file() {
    local task_id="$1"
    printf '%s/%s.lock' "$_GUARD_LOCK_DIR" "$task_id"
}

# 내부: 상태 파일이 유효한지 확인 (TTL)
_guard_is_stale() {
    local state_file="$1" ttl_seconds="${2:-86400}"
    [ ! -f "$state_file" ] && return 0  # 파일 없으면 fresh

    local now mtime age
    now=$(date +%s 2>/dev/null || echo 0)
    mtime=$(stat -f%m "$state_file" 2>/dev/null || echo 0)

    if [ "$mtime" = "0" ]; then
        return 0  # stat 실패 → fresh로 간주
    fi

    age=$((now - mtime))
    [ "$age" -ge "$ttl_seconds" ]  # age >= TTL → stale
}

# 외부 API: 상태 확인 (가드)
# status_guard TASK_ID [TTL_SECONDS]
# 반환값: 0 = 진행 가능, 1 = 스킵 (이미 완료/진행 중)
status_guard() {
    local task_id="$1" ttl_seconds="${2:-86400}"
    _guard_init || return 1

    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 1; }

    local state_file lock_file
    state_file=$(_guard_state_file "$task_id")
    lock_file=$(_guard_lock_file "$task_id")

    # 진행 중 확인
    if [ -f "$lock_file" ]; then
        local lock_age
        lock_age=$(( $(date +%s 2>/dev/null || echo 0) - $(stat -f%m "$lock_file" 2>/dev/null || echo 0) ))

        if [ "$lock_age" -lt 3600 ]; then  # 1시간 이내 락
            echo "[guard] ℹ Task in progress (lock exists): $task_id" >&2
            return 1
        else
            echo "[guard] ⚠ Stale lock removed: $task_id" >&2
            rm -f "$lock_file"
        fi
    fi

    # 상태 파일 확인
    if [ -f "$state_file" ]; then
        if _guard_is_stale "$state_file" "$ttl_seconds"; then
            echo "[guard] ℹ Status expired (TTL): $task_id" >&2
            rm -f "$state_file"
            return 0  # 진행 가능
        fi

        local status
        status=$(grep -o '"status":"[^"]*"' "$state_file" 2>/dev/null | cut -d'"' -f4)

        case "$status" in
            complete|success)
                echo "[guard] ✓ Already completed: $task_id" >&2
                return 1
                ;;
            failed)
                echo "[guard] ✗ Last run failed (retry prevented): $task_id" >&2
                return 1
                ;;
            in_progress)
                echo "[guard] ⚠ Already in progress: $task_id" >&2
                return 1
                ;;
            *)
                return 0
                ;;
        esac
    fi

    return 0  # 상태 없음 → 진행 가능
}

# 외부 API: 작업 시작 (락 + 상태 파일 생성)
start_guard() {
    local task_id="$1"
    _guard_init || return 1

    local lock_file state_file
    lock_file=$(_guard_lock_file "$task_id")
    state_file=$(_guard_state_file "$task_id")

    mkdir -p "$(dirname "$lock_file")" "$(dirname "$state_file")" 2>/dev/null || return 1

    # 상태 파일에 in_progress 기록 (한 줄 JSON)
    printf '{"task_id":"%s","status":"in_progress","started_at":"%s","pid":%d}\n' \
        "$task_id" "$(date -u +%FT%TZ)" $$ > "$state_file"

    # 락 파일도 생성 (스테일 락 탐지용)
    printf '{"task_id":"%s","status":"in_progress","started_at":"%s","pid":%d}\n' \
        "$task_id" "$(date -u +%FT%TZ)" $$ > "$lock_file"
}

# 외부 API: 작업 완료 (락 제거, 상태 기록)
mark_complete() {
    local task_id="$1"
    _guard_init || return 1

    local state_file lock_file
    state_file=$(_guard_state_file "$task_id")
    lock_file=$(_guard_lock_file "$task_id")

    # 상태 저장 (한 줄 JSON)
    printf '{"task_id":"%s","status":"success","completed_at":"%s"}\n' \
        "$task_id" "$(date -u +%FT%TZ)" > "$state_file"

    # 락 제거
    rm -f "$lock_file" 2>/dev/null || true
}

# 외부 API: 작업 실패 (락 제거, 실패 기록)
mark_failed() {
    local task_id="$1" reason="${2:-unknown}"
    _guard_init || return 1

    local state_file lock_file
    state_file=$(_guard_state_file "$task_id")
    lock_file=$(_guard_lock_file "$task_id")

    # 상태 저장 (한 줄 JSON, reason 이스케이프)
    local escaped_reason="${reason//\"/\\\"}"
    printf '{"task_id":"%s","status":"failed","failed_at":"%s","reason":"%s"}\n' \
        "$task_id" "$(date -u +%FT%TZ)" "$escaped_reason" > "$state_file"

    # 락 제거
    rm -f "$lock_file" 2>/dev/null || true
}

# 외부 API: 상태 조회
get_guard_status() {
    local task_id="$1"
    _guard_init || return 1

    local state_file
    state_file=$(_guard_state_file "$task_id")

    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        printf '{"task_id":"%s","status":"none"}\n' "$task_id"
    fi
}

# 외부 API: 상태 초기화 (강제 리셋)
reset_guard_status() {
    local task_id="$1"
    _guard_init || return 1

    local state_file lock_file
    state_file=$(_guard_state_file "$task_id")
    lock_file=$(_guard_lock_file "$task_id")

    rm -f "$state_file" "$lock_file" 2>/dev/null || true
}

# Export 함수들
export -f status_guard
export -f start_guard
export -f mark_complete
export -f mark_failed
export -f get_guard_status
export -f reset_guard_status
export -f _guard_init
export -f _guard_state_file
export -f _guard_lock_file
export -f _guard_is_stale
