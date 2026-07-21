#!/bin/bash
# cluster-guard-cl-de6a0a68c5da81f9.sh — 비동기 작업 상태 검증 클러스터 가드
#
# 역할:
#   클러스터 cl-de6a0a68c5da81f9: 비동기 작업 상태 불명확 - 검증 불가능 상태 보고
#
#   1. 비동기 작업(업로드/배포/에이전트) 완료 상태 폴링
#   2. 상태 검증 (명시적 success/unverified/timeout 구분)
#   3. 보고 템플릿에 검증 상태 명시적 표현
#   4. 기존 동작 파괴 없음
#
# 사용:
#   source ~/jarvis/runtime/infra/lib/cluster-guard-cl-de6a0a68c5da81f9.sh
#
#   # 업로드 작업 검증
#   guard_async_upload "upload-001" "/path/to/file" "https://server/upload"
#
#   # 배포 작업 검증
#   guard_async_deploy "deploy-001" "service-name" "v1.2.3"
#
#   # 일반 비동기 작업
#   guard_async_task "agent-001" "check_agent_status"

set -o pipefail

# 의존성
source "${HOME}/jarvis/runtime/infra/lib/async-work-guard.sh" 2>/dev/null || {
    echo "ERROR: async-work-guard.sh not found" >&2
    exit 1
}

# 상수
CLUSTER_ID="cl-de6a0a68c5da81f9"
STATE_DIR="${HOME}/jarvis/runtime/state/cluster-guards"
REPORT_DIR="${HOME}/jarvis/runtime/reports"

# 내부: 디렉토리 초기화
_guard_init() {
    mkdir -p "$STATE_DIR" "$REPORT_DIR" 2>/dev/null || return 1
}

# 내부: 검증 보고 기록
_guard_log_report() {
    local task_id="$1" status="$2" work_type="$3" detail="$4"
    local timestamp cert_status

    timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')
    cert_status="unverified"  # 기본값

    case "$status" in
        completed)
            cert_status="verified"
            ;;
        timeout|failed)
            cert_status="unverified"
            ;;
    esac

    local report_file="${REPORT_DIR}/${CLUSTER_ID}-${task_id}.json"

    cat > "$report_file" <<EOF
{
  "cluster_id": "${CLUSTER_ID}",
  "task_id": "${task_id}",
  "work_type": "${work_type}",
  "status": "${status}",
  "verification_status": "${cert_status}",
  "detail": "${detail}",
  "timestamp": "${timestamp}"
}
EOF

    return 0
}

# 외부 API: 업로드 작업 상태 폴링 및 보고
# guard_async_upload TASK_ID FILE_PATH SERVER_URL [MAX_POLLS] [POLL_INTERVAL]
guard_async_upload() {
    local task_id="$1" file_path="$2" server_url="$3"
    local max_polls="${4:-30}" poll_interval="${5:-2}"

    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 1; }
    [ -z "$file_path" ] && { echo "ERROR: file_path required" >&2; return 1; }
    [ -z "$server_url" ] && { echo "ERROR: server_url required" >&2; return 1; }

    _guard_init || return 1

    local exit_code

    # async-work-guard의 업로드 검증 함수 호출
    async_work_guard_upload "$task_id" "$file_path" "$server_url" "$CLUSTER_ID"
    exit_code=$?

    # 검증 상태별 로깅
    case "$exit_code" in
        0)
            _guard_log_report "$task_id" "completed" "upload" \
                "✓ 파일 업로드 완료 및 서버 도착 확인됨: $file_path → $server_url"
            return 0
            ;;
        1)
            _guard_log_report "$task_id" "failed" "upload" \
                "⚠ 파일 업로드 명령 실행됨, 단 서버 도착 미확인 (검증 불가): $file_path → $server_url"
            return 1
            ;;
        2)
            _guard_log_report "$task_id" "timeout" "upload" \
                "⏱ 파일 업로드 상태 폴링 타임아웃 (최대 $max_polls회, 각 ${poll_interval}s): $file_path"
            return 2
            ;;
        *)
            _guard_log_report "$task_id" "failed" "upload" \
                "? 알 수 없는 오류 발생"
            return 1
            ;;
    esac
}

# 외부 API: 배포 작업 상태 폴링 및 보고
# guard_async_deploy TASK_ID SERVICE_NAME VERSION [MAX_POLLS] [POLL_INTERVAL]
guard_async_deploy() {
    local task_id="$1" service_name="$2" version="$3"
    local max_polls="${4:-30}" poll_interval="${5:-2}"

    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 1; }
    [ -z "$service_name" ] && { echo "ERROR: service_name required" >&2; return 1; }
    [ -z "$version" ] && { echo "ERROR: version required" >&2; return 1; }

    _guard_init || return 1

    local exit_code

    async_work_guard_deploy "$task_id" "$service_name" "$version" "$CLUSTER_ID"
    exit_code=$?

    case "$exit_code" in
        0)
            _guard_log_report "$task_id" "completed" "deploy" \
                "✓ 배포 완료 및 버전 확인됨: $service_name:$version"
            return 0
            ;;
        1)
            _guard_log_report "$task_id" "failed" "deploy" \
                "⚠ 배포 명령 실행됨, 단 완료 미확인 (검증 불가): $service_name:$version"
            return 1
            ;;
        2)
            _guard_log_report "$task_id" "timeout" "deploy" \
                "⏱ 배포 상태 폴링 타임아웃 (최대 $max_polls회): $service_name:$version"
            return 2
            ;;
        *)
            _guard_log_report "$task_id" "failed" "deploy" \
                "? 알 수 없는 오류 발생"
            return 1
            ;;
    esac
}

# 외부 API: 일반 비동기 작업 상태 폴링 및 보고
# guard_async_task TASK_ID CHECK_FUNCTION [MAX_POLLS] [POLL_INTERVAL]
guard_async_task() {
    local task_id="$1" check_fn="$2"
    local max_polls="${3:-30}" poll_interval="${4:-2}"

    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 1; }
    [ -z "$check_fn" ] && { echo "ERROR: check_fn required" >&2; return 1; }

    _guard_init || return 1

    local exit_code

    async_work_guard_custom "$task_id" "$check_fn" "async-task" "$CLUSTER_ID"
    exit_code=$?

    case "$exit_code" in
        0)
            _guard_log_report "$task_id" "completed" "async-task" \
                "✓ 비동기 작업 완료 및 검증됨 (검증 함수: $check_fn)"
            return 0
            ;;
        1)
            _guard_log_report "$task_id" "failed" "async-task" \
                "⚠ 비동기 작업 실패 또는 상태 미확인 (검증 불가, 함수: $check_fn)"
            return 1
            ;;
        2)
            _guard_log_report "$task_id" "timeout" "async-task" \
                "⏱ 비동기 작업 폴링 타임아웃 (최대 $max_polls회, 함수: $check_fn)"
            return 2
            ;;
        *)
            _guard_log_report "$task_id" "failed" "async-task" \
                "? 알 수 없는 오류 발생"
            return 1
            ;;
    esac
}

# 외부 API: 상태 조회 (명시적 검증 상태 포함)
# get_guard_status TASK_ID
get_guard_status() {
    local task_id="$1"
    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 1; }

    _guard_init || return 1

    local report_file="${REPORT_DIR}/${CLUSTER_ID}-${task_id}.json"

    if [ -f "$report_file" ]; then
        cat "$report_file"
        return 0
    else
        printf '{"cluster_id":"%s","task_id":"%s","status":"unknown","verification_status":"unknown","detail":"No report found"}\n' \
            "$CLUSTER_ID" "$task_id"
        return 1
    fi
}

# 외부 API: 클러스터 상태 요약
# get_cluster_summary
get_cluster_summary() {
    _guard_init || return 1

    local total_tasks verified_tasks failed_tasks unknown_tasks

    total_tasks=$(find "$REPORT_DIR" -name "${CLUSTER_ID}-*.json" 2>/dev/null | wc -l)
    verified_tasks=$(grep -l '"verification_status":"verified"' "$REPORT_DIR/${CLUSTER_ID}-"*.json 2>/dev/null | wc -l)
    failed_tasks=$(grep -l '"verification_status":"unverified"' "$REPORT_DIR/${CLUSTER_ID}-"*.json 2>/dev/null | wc -l)
    unknown_tasks=$((total_tasks - verified_tasks - failed_tasks))

    cat <<EOF
{
  "cluster_id": "${CLUSTER_ID}",
  "summary": {
    "total_tasks": ${total_tasks},
    "verified": ${verified_tasks},
    "unverified": ${failed_tasks},
    "unknown": ${unknown_tasks}
  },
  "verification_rate": "$(awk "BEGIN {if (${total_tasks} > 0) printf \"%.1f%%\", (${verified_tasks}*100/${total_tasks}); else printf \"N/A\"}")",
  "timestamp": "$(date '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
}

# 외부 API: 보고 내용 명시화 (검증 불가, 추정 등)
# format_verification_report TASK_ID
format_verification_report() {
    local task_id="$1"
    [ -z "$task_id" ] && { echo "ERROR: task_id required" >&2; return 1; }

    _guard_init || return 1

    local report_file="${REPORT_DIR}/${CLUSTER_ID}-${task_id}.json"

    if [ ! -f "$report_file" ]; then
        echo "확인 불가: 해당 작업의 보고 기록이 없습니다 ($task_id)"
        return 1
    fi

    local status verification_status detail work_type

    status=$(jq -r '.status // empty' "$report_file" 2>/dev/null)
    verification_status=$(jq -r '.verification_status // empty' "$report_file" 2>/dev/null)
    detail=$(jq -r '.detail // empty' "$report_file" 2>/dev/null)
    work_type=$(jq -r '.work_type // empty' "$report_file" 2>/dev/null)

    local output_prefix
    case "$verification_status" in
        verified)
            output_prefix="✓ [검증됨]"
            ;;
        unverified)
            output_prefix="⚠ [검증 불가·추정]"
            ;;
        *)
            output_prefix="? [확인 불가]"
            ;;
    esac

    cat <<EOF
작업ID: $task_id
작업유형: $work_type
상태: $status
검증상태: $output_prefix
상세: $detail
EOF
}

# 외부 API: 모든 작업 상태 나열
# list_all_tasks
list_all_tasks() {
    _guard_init || return 1

    local report_dir="${REPORT_DIR}"

    if [ ! -d "$report_dir" ]; then
        echo "작업 기록이 없습니다"
        return 0
    fi

    find "$report_dir" -name "${CLUSTER_ID}-*.json" -type f 2>/dev/null | while read -r f; do
        jq -c '.' "$f" 2>/dev/null
    done
}

# 외부 API: 정리 (오래된 기록 삭제)
# cleanup_old_reports [DAYS]
cleanup_old_reports() {
    local days="${1:-7}"

    _guard_init || return 1

    find "$REPORT_DIR" -name "${CLUSTER_ID}-*.json" -type f -mtime +"$days" -delete 2>/dev/null

    return 0
}
