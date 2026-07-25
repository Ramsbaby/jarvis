#!/bin/bash
# report-template-verified.sh — 검증 상태 명시 보고 템플릿
#
# 역할:
#   비동기 작업의 검증 상태를 명시적으로 표기하는 표준 보고 템플릿
#   "확인 불가", "추정", "검증 완료" 등 상태를 명확히 구분
#
# 특징:
#   1. 검증 상태를 필수 필드로 명시 (verified/unverified/partial)
#   2. 타임스탐프와 폴링 기록 포함
#   3. 상태별 다른 메시지 포맷 적용
#   4. 명시적 표현으로 거짓 완료 선언 방지
#
# 사용:
#   source ~/.jarvis/infra/lib/report-template-verified.sh
#
#   report_with_verification \
#     "cl-de6a0a68c5da81f9" \
#     "task-20260714-001" \
#     "upload" \
#     "completed" \
#     "File uploaded to S3"
#
# 반환값: 0 = 보고 완료, 1 = 보고 실패

set -o pipefail

# 상수
_VERIFY_STATE_DIR="${HOME}/jarvis/runtime/state/verified-reports"
_VERIFY_LOG_DIR="${HOME}/jarvis/runtime/logs/verified-reports"

# 내부: 디렉토리 초기화
_verify_init() {
    mkdir -p "$_VERIFY_STATE_DIR" "$_VERIFY_LOG_DIR" 2>/dev/null || return 1
}

# 내부: 보고서 파일 경로
_verify_report_file() {
    local cluster_id="$1" task_id="$2"
    printf '%s/%s_%s.report' "$_VERIFY_STATE_DIR" "$cluster_id" "$task_id"
}

# 내부: 검증 상태 결정
# 반환값: verified / unverified / partial / timeout
_determine_verification_status() {
    local exit_code="$1"

    case "$exit_code" in
        0) echo "verified" ;;      # 완료 확인됨
        1) echo "unverified" ;;    # 검증 실패 (상태 불명확)
        2) echo "timeout" ;;       # 폴링 타임아웃
        *) echo "unknown" ;;
    esac
}

# 내부: 검증 상태별 한글 표현
_verify_status_label() {
    local status="$1"

    case "$status" in
        verified)   echo "[검증완료✓]" ;;
        unverified) echo "[검증불가⚠]" ;;
        partial)    echo "[부분검증⊘]" ;;
        timeout)    echo "[폴링초과⏱]" ;;
        *)          echo "[미확인?]" ;;
    esac
}

# 외부 API: 검증 상태 명시 보고
# report_with_verification CLUSTER_ID TASK_ID TASK_TYPE EXIT_CODE DETAIL [EXTRA_INFO]
report_with_verification() {
    local cluster_id="$1" task_id="$2" task_type="$3" exit_code="$4" detail="$5"
    local extra_info="${6:-}"

    _verify_init || return 1

    local verify_status verify_label report_file timestamp

    timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')
    verify_status=$(_determine_verification_status "$exit_code")
    verify_label=$(_verify_status_label "$verify_status")
    report_file=$(_verify_report_file "$cluster_id" "$task_id")

    # 보고서 작성
    cat > "$report_file" <<EOF
{
  "cluster_id": "$cluster_id",
  "task_id": "$task_id",
  "task_type": "$task_type",
  "timestamp": "$timestamp",
  "verification_status": "$verify_status",
  "exit_code": "$exit_code",
  "detail": "$detail",
  "extra_info": "$extra_info",
  "human_readable": "$verify_label $detail"
}
EOF

    # 콘솔 출력
    printf '%s [%s] %s: %s\n' "$verify_label" "$task_type" "$task_id" "$detail"

    return 0
}

# 외부 API: 표준화된 완료 보고 (성공)
# report_task_completed CLUSTER_ID TASK_ID TASK_TYPE DETAIL [VERIFICATION_SOURCE]
report_task_completed() {
    local cluster_id="$1" task_id="$2" task_type="$3" detail="$4"
    local verification_source="${5:-automatic_verification}"

    report_with_verification "$cluster_id" "$task_id" "$task_type" 0 \
        "✓ 완료 (검증됨): $detail [출처: $verification_source]"
}

# 외부 API: 표준화된 미확인 보고 (검증 불가)
# report_task_unverified CLUSTER_ID TASK_ID TASK_TYPE DETAIL
report_task_unverified() {
    local cluster_id="$1" task_id="$2" task_type="$3" detail="$4"

    report_with_verification "$cluster_id" "$task_id" "$task_type" 1 \
        "⚠ 검증 불가 (미확인 상태): $detail — 수동 확인 필요"
}

# 외부 API: 표준화된 타임아웃 보고
# report_task_timeout CLUSTER_ID TASK_ID TASK_TYPE POLLS_COUNT
report_task_timeout() {
    local cluster_id="$1" task_id="$2" task_type="$3" polls_count="${4:-30}"

    report_with_verification "$cluster_id" "$task_id" "$task_type" 2 \
        "⏱ 폴링 타임아웃: $polls_count회 시도 후에도 상태 미확인 — 수동 점검 필요"
}

# 외부 API: 부분 검증 보고
# report_task_partial CLUSTER_ID TASK_ID TASK_TYPE DETAIL VERIFIED_PART UNVERIFIED_PART
report_task_partial() {
    local cluster_id="$1" task_id="$2" task_type="$3" detail="$4"
    local verified_part="$5" unverified_part="$6"

    local extra="검증됨: $verified_part | 미확인: $unverified_part"

    _verify_init || return 1
    local report_file timestamp
    report_file=$(_verify_report_file "$cluster_id" "$task_id")
    timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')

    cat > "$report_file" <<EOF
{
  "cluster_id": "$cluster_id",
  "task_id": "$task_id",
  "task_type": "$task_type",
  "timestamp": "$timestamp",
  "verification_status": "partial",
  "exit_code": 3,
  "detail": "$detail",
  "verified_part": "$verified_part",
  "unverified_part": "$unverified_part",
  "human_readable": "[부분검증⊘] $detail"
}
EOF

    printf '[부분검증⊘] [%s] %s: %s (검증: %s | 미확인: %s)\n' \
        "$task_type" "$task_id" "$detail" "$verified_part" "$unverified_part"

    return 0
}

# 외부 API: 보고서 읽기
# get_verification_report CLUSTER_ID TASK_ID
get_verification_report() {
    local cluster_id="$1" task_id="$2"
    local report_file

    report_file=$(_verify_report_file "$cluster_id" "$task_id")

    if [ -f "$report_file" ]; then
        cat "$report_file"
    else
        printf '{"error": "No report found", "cluster_id": "%s", "task_id": "%s"}\n' "$cluster_id" "$task_id"
    fi
}

# 외부 API: 클러스터별 모든 보고서 나열
# list_verification_reports CLUSTER_ID
list_verification_reports() {
    local cluster_id="$1"

    _verify_init || return 1

    local pattern report_file

    pattern="${_VERIFY_STATE_DIR}/${cluster_id}_*.report"

    if ls "$pattern" 2>/dev/null | head -1 >/dev/null; then
        for report_file in "$pattern"; do
            [ -f "$report_file" ] && cat "$report_file"
        done
    else
        printf "No reports found for cluster: %s\n" "$cluster_id"
    fi
}

# 내부: 보고서 정리
# clear_verification_reports CLUSTER_ID [TASK_ID]
clear_verification_reports() {
    local cluster_id="$1" task_id="${2:-}"

    _verify_init || return 1

    if [ -n "$task_id" ]; then
        local report_file
        report_file=$(_verify_report_file "$cluster_id" "$task_id")
        [ -f "$report_file" ] && rm -f "$report_file"
    else
        rm -f "${_VERIFY_STATE_DIR}/${cluster_id}_"*.report
    fi

    return 0
}
