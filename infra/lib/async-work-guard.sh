#!/bin/bash
# async-work-guard.sh — 비동기 작업 상태 검증 통합 가드
#
# 역할:
#   비동기 작업(업로드/배포/에이전트)의 상태를 검증하고,
#   검증 상태를 명시적으로 보고하는 통합 가드
#
# 사용:
#   source ~/.jarvis/infra/lib/async-work-guard.sh
#
#   # 업로드 작업 검증 후 보고
#   async_work_guard_upload "task-001" "/path/to/file" "https://server/file" "data-upload"
#
#   # 배포 작업 검증 후 보고
#   async_work_guard_deploy "task-002" "api-service" "v1.2.3"
#
#   # 일반 비동기 작업 (커스텀 검증 함수)
#   async_work_guard_custom "task-003" "check_my_task" "my_task"
#
# 반환값:
#   0 - 검증 성공, 보고 완료
#   1 - 검증 실패
#   2 - 상태 불명확

set -o pipefail

# 의존성
source "${HOME}/.jarvis/infra/lib/async-task-poller.sh" || { echo "ERROR: async-task-poller.sh not found" >&2; exit 1; }
source "${HOME}/.jarvis/infra/lib/report-template-verified.sh" || { echo "ERROR: report-template-verified.sh not found" >&2; exit 1; }

# 상수
_GUARD_CLUSTER_ID="${GUARD_CLUSTER_ID:-cl-de6a0a68c5da81f9}"
_GUARD_TIMEOUT_POLLS="${GUARD_TIMEOUT_POLLS:-30}"
_GUARD_POLL_INTERVAL="${GUARD_POLL_INTERVAL:-2}"

# 외부 API: 업로드 작업 검증 및 보고
# async_work_guard_upload TASK_ID FILE_PATH SERVER_URL [CLUSTER_ID]
async_work_guard_upload() {
    local task_id="$1" file_path="$2" server_url="$3"
    local cluster_id="${4:-$_GUARD_CLUSTER_ID}"

    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 1; }
    [ -z "$file_path" ] && { echo "ERROR: file_path required" >&2; return 1; }
    [ -z "$server_url" ] && { echo "ERROR: server_url required" >&2; return 1; }

    local exit_code

    # 1. 폴링 실행
    poll_upload_completion "$task_id" "$file_path" "$server_url" "$_GUARD_TIMEOUT_POLLS" "$_GUARD_POLL_INTERVAL"
    exit_code=$?

    # 2. 검증 상태별 보고
    case "$exit_code" in
        0)
            report_task_completed "$cluster_id" "$task_id" "upload" \
                "파일 업로드 완료 및 서버 도착 확인" "async-poller"
            return 0
            ;;
        1)
            report_task_unverified "$cluster_id" "$task_id" "upload" \
                "파일 업로드 완료했으나 서버 도착 미확인 ($file_path → $server_url)"
            return 1
            ;;
        2)
            report_task_timeout "$cluster_id" "$task_id" "upload" "$_GUARD_TIMEOUT_POLLS"
            return 2
            ;;
        *)
            report_task_unverified "$cluster_id" "$task_id" "upload" "알 수 없는 오류"
            return 1
            ;;
    esac
}

# 외부 API: 배포 작업 검증 및 보고
# async_work_guard_deploy TASK_ID SERVICE_NAME VERSION [CLUSTER_ID]
async_work_guard_deploy() {
    local task_id="$1" service_name="$2" version="$3"
    local cluster_id="${4:-$_GUARD_CLUSTER_ID}"

    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 1; }
    [ -z "$service_name" ] && { echo "ERROR: service_name required" >&2; return 1; }
    [ -z "$version" ] && { echo "ERROR: version required" >&2; return 1; }

    local exit_code

    # 1. 폴링 실행
    poll_deploy_completion "$task_id" "$service_name" "$version" "$_GUARD_TIMEOUT_POLLS" "$_GUARD_POLL_INTERVAL"
    exit_code=$?

    # 2. 검증 상태별 보고
    case "$exit_code" in
        0)
            report_task_completed "$cluster_id" "$task_id" "deploy" \
                "배포 완료 및 버전 확인: $service_name:$version" "async-poller"
            return 0
            ;;
        1)
            report_task_unverified "$cluster_id" "$task_id" "deploy" \
                "배포 명령 실행했으나 완료 미확인 ($service_name:$version)"
            return 1
            ;;
        2)
            report_task_timeout "$cluster_id" "$task_id" "deploy" "$_GUARD_TIMEOUT_POLLS"
            return 2
            ;;
        *)
            report_task_unverified "$cluster_id" "$task_id" "deploy" "알 수 없는 오류"
            return 1
            ;;
    esac
}

# 외부 API: 커스텀 비동기 작업 검증 및 보고
# async_work_guard_custom TASK_ID CHECK_FUNCTION TASK_TYPE [CLUSTER_ID]
async_work_guard_custom() {
    local task_id="$1" check_fn="$2" task_type="$3"
    local cluster_id="${4:-$_GUARD_CLUSTER_ID}"

    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 1; }
    [ -z "$check_fn" ] && { echo "ERROR: check_fn required" >&2; return 1; }
    [ -z "$task_type" ] && task_type="async-task"

    local exit_code

    # 1. 폴링 실행
    poll_async_task "$task_id" "$check_fn" "$_GUARD_TIMEOUT_POLLS" "$_GUARD_POLL_INTERVAL"
    exit_code=$?

    # 2. 검증 상태별 보고
    case "$exit_code" in
        0)
            report_task_completed "$cluster_id" "$task_id" "$task_type" \
                "비동기 작업 완료 (검증 함수: $check_fn)" "async-poller"
            return 0
            ;;
        1)
            report_task_unverified "$cluster_id" "$task_id" "$task_type" \
                "비동기 작업 실패 또는 상태 미확인 (검증 함수: $check_fn)"
            return 1
            ;;
        2)
            report_task_timeout "$cluster_id" "$task_id" "$task_type" "$_GUARD_TIMEOUT_POLLS"
            return 2
            ;;
        *)
            report_task_unverified "$cluster_id" "$task_id" "$task_type" "알 수 없는 오류"
            return 1
            ;;
    esac
}

# 외부 API: 상태 폴링 후 명시적 검증 상태 반환
# check_async_work_status TASK_ID
check_async_work_status() {
    local task_id="$1"
    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 1; }

    local status_json
    status_json=$(get_async_task_status "$task_id")
    echo "$status_json"
}

# 외부 API: 폴링 로그 조회
# get_async_work_log TASK_ID
get_async_work_log() {
    local task_id="$1"
    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 1; }

    get_async_task_log "$task_id"
}

# 외부 API: 모든 비동기 작업 상태 조회
# list_async_work_status [CLUSTER_ID]
list_async_work_status() {
    local cluster_id="${1:-$_GUARD_CLUSTER_ID}"

    list_verification_reports "$cluster_id"
}

# 외부 API: 비동기 작업 정리
# clear_async_work TASK_ID
clear_async_work() {
    local task_id="$1"
    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 1; }

    clear_async_task "$task_id"
    clear_verification_reports "$_GUARD_CLUSTER_ID" "$task_id"
    return 0
}
