#!/bin/bash
# async-task-poller.sh — 비동기 작업 상태 폴링 가드
#
# 역할:
#   업로드, 배포, 에이전트 작업 등 비동기 작업의 실제 완료를 확인
#   폴링으로 상태를 검증하고, timeout/불명확 상태를 명시적으로 보고
#
# 사용:
#   source ~/.jarvis/infra/lib/async-task-poller.sh
#
#   # 업로드 작업 폴링 (서버 도착 확인)
#   poll_upload_completion "upload-20260714-001" "file.txt" "https://server/file"
#
#   # 배포 작업 폴링 (배포 완료 확인)
#   poll_deploy_completion "deploy-20260714-001" "service-name" "version"
#
#   # 일반 비동기 작업 폴링 (custom check function)
#   poll_async_task "task-20260714-001" "check_my_status" 30 60
#
# 반환값:
#   0 - 작업 완료 확인됨
#   1 - 작업 실패 또는 타임아웃
#   2 - 상태 불명확 (검증 불가)

set -o pipefail

# 상수 정의
_ASYNC_STATE_DIR="${ASYNC_STATE_DIR:=${HOME}/jarvis/runtime/state/async-tasks}"
_ASYNC_LOG_DIR="${ASYNC_LOG_DIR:=${HOME}/jarvis/runtime/logs/async}"

# 내부: 디렉토리 초기화
_async_init() {
    mkdir -p "$_ASYNC_STATE_DIR" "$_ASYNC_LOG_DIR" 2>/dev/null || return 1
}

# 내부: 상태 파일 경로
_async_state_file() {
    local task_id="$1"
    printf '%s/%s.state' "$_ASYNC_STATE_DIR" "$task_id"
}

# 내부: 로그 파일 경로
_async_log_file() {
    local task_id="$1"
    printf '%s/%s.log' "$_ASYNC_LOG_DIR" "$task_id"
}

# 내부: 상태 기록
_async_write_state() {
    local task_id="$1" status="$2" detail="$3"
    local state_file log_file timestamp

    state_file=$(_async_state_file "$task_id")
    log_file=$(_async_log_file "$task_id")
    timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')

    # JSON 상태 파일 작성
    cat > "$state_file" <<EOF
{
  "task_id": "$task_id",
  "status": "$status",
  "timestamp": "$timestamp",
  "detail": "$detail"
}
EOF

    # 로그에 append
    printf '[%s] [%s] %s: %s\n' "$timestamp" "$status" "$task_id" "$detail" >> "$log_file"
}

# 내부: 상태 읽기
_async_read_status() {
    local task_id="$1"
    local state_file
    state_file=$(_async_state_file "$task_id")

    if [ -f "$state_file" ]; then
        grep -o '"status":"[^"]*"' "$state_file" 2>/dev/null | cut -d'"' -f4
    else
        echo "unknown"
    fi
}

# 외부 API: 업로드 완료 폴링
# poll_upload_completion TASK_ID FILE_PATH SERVER_URL [MAX_POLLS] [POLL_INTERVAL]
poll_upload_completion() {
    local task_id="$1" file_path="$2" server_url="$3"
    local max_polls="${4:-30}" poll_interval="${5:-2}"  # 최대 60초
    local poll_count=0

    _async_init || return 1

    _async_write_state "$task_id" "in_progress" "Polling upload completion for: $file_path"

    while [ "$poll_count" -lt "$max_polls" ]; do
        # 서버에서 파일 존재 여부 확인 (HEAD 요청)
        if curl -sf -I "$server_url" >/dev/null 2>&1; then
            _async_write_state "$task_id" "completed" "File verified on server: $server_url"
            return 0
        fi

        poll_count=$((poll_count + 1))
        if [ "$poll_count" -lt "$max_polls" ]; then
            sleep "$poll_interval"
        fi
    done

    # 타임아웃
    _async_write_state "$task_id" "timeout" "Upload verification timeout after ${max_polls} polls (${poll_interval}s each)"
    return 2
}

# 외부 API: 배포 완료 폴링
# poll_deploy_completion TASK_ID SERVICE_NAME VERSION [MAX_POLLS] [POLL_INTERVAL]
poll_deploy_completion() {
    local task_id="$1" service_name="$2" version="$3"
    local max_polls="${4:-30}" poll_interval="${5:-2}"
    local poll_count=0

    _async_init || return 1

    _async_write_state "$task_id" "in_progress" "Polling deploy for: $service_name:$version"

    while [ "$poll_count" -lt "$max_polls" ]; do
        # 배포 상태 확인 (실제 구현은 서비스별 API 호출)
        # 예시: kubectl, gcloud, aws, 또는 내부 상태 API
        if _check_deploy_status "$service_name" "$version"; then
            _async_write_state "$task_id" "completed" "Deployment verified: $service_name:$version"
            return 0
        fi

        poll_count=$((poll_count + 1))
        if [ "$poll_count" -lt "$max_polls" ]; then
            sleep "$poll_interval"
        fi
    done

    # 타임아웃
    _async_write_state "$task_id" "timeout" "Deploy verification timeout after ${max_polls} polls"
    return 2
}

# 내부: 배포 상태 확인 (구현 필요)
_check_deploy_status() {
    local service_name="$1" version="$2"

    # 플레이스홀더 - 실제 구현은 서비스별 API 호출
    # 예: kubectl get deployment $service_name -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'
    # 또는: curl -s https://api.internal/deployments/$service_name | jq ".version == \"$version\""

    return 1  # 기본값은 미완료 (실제 구현 필요)
}

# 외부 API: 일반 비동기 작업 폴링
# poll_async_task TASK_ID CHECK_FUNCTION_NAME [MAX_POLLS] [POLL_INTERVAL]
poll_async_task() {
    local task_id="$1" check_fn="$2"
    local max_polls="${3:-30}" poll_interval="${4:-2}"
    local poll_count=0

    _async_init || return 1

    if [ -z "$check_fn" ] || ! declare -f "$check_fn" >/dev/null 2>&1; then
        _async_write_state "$task_id" "failed" "Check function not defined: $check_fn"
        return 1
    fi

    _async_write_state "$task_id" "in_progress" "Polling with function: $check_fn"

    while [ "$poll_count" -lt "$max_polls" ]; do
        if $check_fn "$task_id"; then
            _async_write_state "$task_id" "completed" "Verification passed by: $check_fn"
            return 0
        fi

        poll_count=$((poll_count + 1))
        if [ "$poll_count" -lt "$max_polls" ]; then
            sleep "$poll_interval"
        fi
    done

    # 타임아웃
    _async_write_state "$task_id" "timeout" "Polling timeout after ${max_polls} polls (function: $check_fn)"
    return 2
}

# 외부 API: 상태 조회
# get_async_task_status TASK_ID
get_async_task_status() {
    local task_id="$1"
    local state_file

    state_file=$(_async_state_file "$task_id")

    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        printf '{"task_id": "%s", "status": "unknown", "detail": "No state file found"}\n' "$task_id"
    fi
}

# 외부 API: 폴링 로그 출력
# get_async_task_log TASK_ID
get_async_task_log() {
    local task_id="$1"
    local log_file

    log_file=$(_async_log_file "$task_id")

    if [ -f "$log_file" ]; then
        cat "$log_file"
    else
        printf "No log found for task: %s\n" "$task_id"
    fi
}

# 외부 API: 폴링 정리 (상태 파일 삭제)
# clear_async_task TASK_ID
clear_async_task() {
    local task_id="$1"
    local state_file

    state_file=$(_async_state_file "$task_id")
    [ -f "$state_file" ] && rm -f "$state_file"
    return 0
}
