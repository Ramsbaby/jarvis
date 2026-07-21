#!/usr/bin/env bash
# status-guard.sh — 재실행 전 현재 상태 확인 가드
#
# 문제:
#   반복 실수 클러스터 cl-e30aee511af89e13에서 현재 상태를 확인하지 않고
#   작업 실패를 판단 후 즉시 재시도 → 무한 루프 또는 중복 실행
#
# 해결책:
#   - 작업 재실행 전 현재 상태 파일(state file)을 먼저 조회
#   - 상태 파일이 최근(기본 1시간 내)이면 작업이 이미 진행 중 또는 최근 완료 상태로 판단
#   - 재실행을 스킵하거나 경고 발생

set -euo pipefail

check_task_status() {
    local task_id="${1:?check_task_status: task_id required}"
    local state_dir="${2:-${BOT_HOME:-${HOME}/jarvis/runtime}/state}"
    local ttl_seconds="${3:-3600}"

    mkdir -p "$state_dir" 2>/dev/null || {
        printf '[%s] ERROR check_task_status: failed to create state_dir: %s\n' "$(date -u +%s)" "$state_dir" >&2
        return 2
    }

    local state_file="$state_dir/${task_id}.state.json"

    if [[ ! -f "$state_file" ]]; then
        return 1
    fi

    local recorded_time
    recorded_time=$(jq -r '.timestamp // 0' "$state_file" 2>/dev/null || echo "0")

    if [[ "$recorded_time" == "0" ]] || [[ ! "$recorded_time" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    local current_time
    current_time=$(date +%s)

    local elapsed=$((current_time - recorded_time))

    if [[ $elapsed -lt $ttl_seconds ]]; then
        return 0
    else
        return 1
    fi
}

record_task_status() {
    local task_id="${1:?record_task_status: task_id required}"
    local status="${2:?record_task_status: status required}"
    local state_dir="${3:-${BOT_HOME:-${HOME}/jarvis/runtime}/state}"
    local result_details="${4:-}"

    mkdir -p "$state_dir" 2>/dev/null || {
        printf '[%s] ERROR record_task_status: failed to create state_dir: %s\n' "$(date -u +%s)" "$state_dir" >&2
        return 2
    }

    local state_file="$state_dir/${task_id}.state.json"
    local timestamp
    timestamp=$(date +%s)

    local state_json="{\"task_id\":\"$task_id\",\"status\":\"$status\",\"timestamp\":$timestamp"
    [[ -n "$result_details" ]] && state_json="$state_json,\"result\":$result_details"
    state_json="$state_json}"

    local tmp_file="$state_file.tmp.$$"
    echo "$state_json" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 2
    }
    mv -f "$tmp_file" "$state_file" || return 2
}

get_task_status() {
    local task_id="${1:?get_task_status: task_id required}"
    local state_dir="${2:-${BOT_HOME:-${HOME}/jarvis/runtime}/state}"
    local field="${3:-status}"

    local state_file="$state_dir/${task_id}.state.json"

    if [[ ! -f "$state_file" ]]; then
        return 1
    fi

    jq -r ".$field // empty" "$state_file" 2>/dev/null || return 1
}

clear_task_status() {
    local task_id="${1:?clear_task_status: task_id required}"
    local state_dir="${2:-${BOT_HOME:-${HOME}/jarvis/runtime}/state}"

    local state_file="$state_dir/${task_id}.state.json"
    rm -f "$state_file" 2>/dev/null || true
}

should_skip_task() {
    local task_id="${1:?should_skip_task: task_id required}"
    local state_dir="${2:-${BOT_HOME:-${HOME}/jarvis/runtime}/state}"
    local ttl_seconds="${3:-3600}"
    local skip_on_recent="${4:-true}"

    if [[ "$skip_on_recent" != "true" ]]; then
        return 1
    fi

    check_task_status "$task_id" "$state_dir" "$ttl_seconds"
}

export -f check_task_status
export -f record_task_status
export -f get_task_status
export -f clear_task_status
export -f should_skip_task
