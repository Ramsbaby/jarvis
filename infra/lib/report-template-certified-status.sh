#!/bin/bash
# report-template-certified-status.sh — 보고 템플릿 표준화 (명시적 검증 상태)
#
# 역할:
#   비동기 작업 보고 시 "확인 불가", "추정", "검증 불가" 등 명시적 표현 포함
#   기존 report-template-verified.sh를 보완
#
# 사용:
#   source ~/jarvis/runtime/infra/lib/report-template-certified-status.sh
#   report_certified_status CLUSTER_ID TASK_ID WORK_TYPE CERT_LEVEL MESSAGE

set -o pipefail

# 상수
_REPORT_TEMPLATE_DIR="${HOME}/jarvis/runtime/reports"

# 내부: 디렉토리 초기화
_report_template_init() {
    mkdir -p "$_REPORT_TEMPLATE_DIR" 2>/dev/null || return 1
}

# 외부 API: 검증된 상태 보고 (확인됨)
# report_certified_verified CLUSTER_ID TASK_ID WORK_TYPE MESSAGE [SOURCE]
report_certified_verified() {
    local cluster_id="$1" task_id="$2" work_type="$3" message="$4" source="${5:-manual}"

    [ -z "$cluster_id" ] || [ -z "$task_id" ] && return 1

    _report_template_init || return 1

    local timestamp report_file cert_level

    timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')
    cert_level="verified"
    report_file="${_REPORT_TEMPLATE_DIR}/${cluster_id}-${task_id}-certified.json"

    cat > "$report_file" <<EOF
{
  "report_type": "certification",
  "cluster_id": "${cluster_id}",
  "task_id": "${task_id}",
  "work_type": "${work_type}",
  "certification_level": "${cert_level}",
  "certification_badge": "✓ [검증됨]",
  "message": "${message}",
  "source": "${source}",
  "timestamp": "${timestamp}",
  "can_be_reported_as": "완료·검증됨"
}
EOF

    return 0
}

# 외부 API: 검증 불가능한 상태 보고 (추정)
# report_certified_unverified CLUSTER_ID TASK_ID WORK_TYPE MESSAGE [REASON] [SOURCE]
report_certified_unverified() {
    local cluster_id="$1" task_id="$2" work_type="$3" message="$4" reason="${5:-unknown}" source="${6:-manual}"

    [ -z "$cluster_id" ] || [ -z "$task_id" ] && return 1

    _report_template_init || return 1

    local timestamp report_file cert_level

    timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')
    cert_level="unverified"
    report_file="${_REPORT_TEMPLATE_DIR}/${cluster_id}-${task_id}-certified.json"

    cat > "$report_file" <<EOF
{
  "report_type": "certification",
  "cluster_id": "${cluster_id}",
  "task_id": "${task_id}",
  "work_type": "${work_type}",
  "certification_level": "${cert_level}",
  "certification_badge": "⚠ [검증 불가·추정]",
  "message": "${message}",
  "reason_not_verified": "${reason}",
  "source": "${source}",
  "timestamp": "${timestamp}",
  "can_be_reported_as": "완료했으나 검증 불가·추정 상태"
}
EOF

    return 0
}

# 외부 API: 확인 불가능한 상태 보고 (타임아웃)
# report_certified_timeout CLUSTER_ID TASK_ID WORK_TYPE TIMEOUT_SECONDS [SOURCE]
report_certified_timeout() {
    local cluster_id="$1" task_id="$2" work_type="$3" timeout_seconds="$4" source="${5:-manual}"

    [ -z "$cluster_id" ] || [ -z "$task_id" ] && return 1

    _report_template_init || return 1

    local timestamp report_file cert_level

    timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')
    cert_level="timeout"
    report_file="${_REPORT_TEMPLATE_DIR}/${cluster_id}-${task_id}-certified.json"

    cat > "$report_file" <<EOF
{
  "report_type": "certification",
  "cluster_id": "${cluster_id}",
  "task_id": "${task_id}",
  "work_type": "${work_type}",
  "certification_level": "${cert_level}",
  "certification_badge": "⏱ [확인 불가·타임아웃]",
  "message": "작업 완료 여부 확인 타임아웃 (최대 ${timeout_seconds}초 폴링)",
  "reason_not_verified": "폴링 타임아웃으로 완료 확인 불가",
  "source": "${source}",
  "timestamp": "${timestamp}",
  "can_be_reported_as": "완료 여부 확인 불가 (타임아웃)"
}
EOF

    return 0
}

# 외부 API: 검증 불가능한 상태 조회
# get_certified_report CLUSTER_ID TASK_ID
get_certified_report() {
    local cluster_id="$1" task_id="$2"

    [ -z "$cluster_id" ] || [ -z "$task_id" ] && return 1

    _report_template_init || return 1

    local report_file="${_REPORT_TEMPLATE_DIR}/${cluster_id}-${task_id}-certified.json"

    if [ -f "$report_file" ]; then
        cat "$report_file"
        return 0
    else
        printf '{"cluster_id":"%s","task_id":"%s","certification_level":"unknown","message":"No certification report found"}\n' \
            "$cluster_id" "$task_id"
        return 1
    fi
}

# 외부 API: 인간 가독형 보고서 생성
# format_certified_report_human CLUSTER_ID TASK_ID
format_certified_report_human() {
    local cluster_id="$1" task_id="$2"

    [ -z "$cluster_id" ] || [ -z "$task_id" ] && return 1

    _report_template_init || return 1

    local report_file="${_REPORT_TEMPLATE_DIR}/${cluster_id}-${task_id}-certified.json"

    if [ ! -f "$report_file" ]; then
        echo "[확인 불가] 해당 작업의 보고 기록이 없습니다 ($task_id)"
        return 1
    fi

    local badge message reason timestamp

    badge=$(jq -r '.certification_badge // "?"' "$report_file" 2>/dev/null)
    message=$(jq -r '.message // ""' "$report_file" 2>/dev/null)
    reason=$(jq -r '.reason_not_verified // ""' "$report_file" 2>/dev/null)
    timestamp=$(jq -r '.timestamp // ""' "$report_file" 2>/dev/null)

    cat <<EOF
${badge}
메시지: $message
${reason:+이유: $reason}
보고시간: $timestamp
EOF
}

# 외부 API: 클러스터 인증 통계
# get_certification_stats CLUSTER_ID
get_certification_stats() {
    local cluster_id="$1"

    [ -z "$cluster_id" ] && return 1

    _report_template_init || return 1

    local verified unverified timeout unknown total

    verified=$(find "$_REPORT_TEMPLATE_DIR" -name "${cluster_id}-*-certified.json" -type f 2>/dev/null | \
        xargs grep -l '"certification_level":"verified"' 2>/dev/null | wc -l)

    unverified=$(find "$_REPORT_TEMPLATE_DIR" -name "${cluster_id}-*-certified.json" -type f 2>/dev/null | \
        xargs grep -l '"certification_level":"unverified"' 2>/dev/null | wc -l)

    timeout=$(find "$_REPORT_TEMPLATE_DIR" -name "${cluster_id}-*-certified.json" -type f 2>/dev/null | \
        xargs grep -l '"certification_level":"timeout"' 2>/dev/null | wc -l)

    total=$((verified + unverified + timeout))

    cat <<EOF
{
  "cluster_id": "${cluster_id}",
  "certification_stats": {
    "verified": ${verified},
    "unverified": ${unverified},
    "timeout": ${timeout},
    "total": ${total}
  },
  "verification_rate": "$(awk "BEGIN {if (${total} > 0) printf \"%.1f%%\", (${verified}*100/${total}); else printf \"N/A\"}")",
  "timestamp": "$(date '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
}
