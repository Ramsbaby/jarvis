#!/usr/bin/env bash
################################################################################
# dev-queue-file-state-logger.sh — 파일 상태 모순 자동 dev-queue 로깅
#
# 클러스터 ID: cl-6f0c8cc1df90e995 (최근 7일 재발 40건)
#
# 목적:
#   file-state-contradiction-guard.sh에서 감지한 파일 상태 모순을
#   자동으로 dev-queue에 Tier 2 경고로 기록한다.
#
# 기능:
#   1. 파일 상태 위반 로그 감시
#   2. Tier 2 경고를 dev-queue.json에 추가
#   3. 중복 제거 (동일 위반은 한 번만 기록)
#
# 사용법:
#   source ~/jarvis/infra/lib/dev-queue-file-state-logger.sh
#   log_file_state_violation_to_queue "response-id" "위반 설명" "심각도"
#
################################################################################

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# 설정
# ──────────────────────────────────────────────────────────────────────────────

JARVIS_HOME="${HOME}/.jarvis"
JARVIS_RUNTIME="${JARVIS_HOME}/runtime"
DEV_QUEUE_FILE="${JARVIS_RUNTIME}/state/dev-queue.json"
FSC_GUARD_CLUSTER="cl-6f0c8cc1df90e995"
DQL_LOG="${JARVIS_RUNTIME}/logs/dev-queue-file-state-logger.jsonl"

# ──────────────────────────────────────────────────────────────────────────────
# 초기화
# ──────────────────────────────────────────────────────────────────────────────

_dql_init() {
    mkdir -p "${JARVIS_RUNTIME}/logs" 2>/dev/null || true
    mkdir -p "$(dirname "$DEV_QUEUE_FILE")" 2>/dev/null || true
}
_dql_init

# ──────────────────────────────────────────────────────────────────────────────
# 로깅
# ──────────────────────────────────────────────────────────────────────────────

_dql_log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "${DQL_LOG}" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# JSON 유틸리티
# ──────────────────────────────────────────────────────────────────────────────

_dql_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# ──────────────────────────────────────────────────────────────────────────────
# [내부] 중복 검사 (24시간 내 동일 위반이 있는지 확인)
# ──────────────────────────────────────────────────────────────────────────────

_dql_check_duplicate() {
    local violation_type="$1"
    local current_ts
    current_ts=$(date -u '+%s')
    local cutoff_ts=$((current_ts - 86400))  # 24시간 전

    if [[ ! -f "$DEV_QUEUE_FILE" ]]; then
        return 1  # 파일 없음 = 중복 없음
    fi

    if command -v jq &>/dev/null; then
        # jq로 24시간 이내 file_state 관련 항목 검색
        local count
        count=$(jq --arg vid "$violation_type" \
                   --arg cluster "$FSC_GUARD_CLUSTER" \
                   '[.[] | select(.cluster_id == $cluster and .type == "file_state_violation" and .metadata.violation_type == $vid)] | length' \
                   "$DEV_QUEUE_FILE" 2>/dev/null || echo "0")

        if [[ $count -gt 0 ]]; then
            return 0  # 중복 있음
        fi
    fi

    return 1  # 중복 없음
}

# ──────────────────────────────────────────────────────────────────────────────
# [내부] 새 dev-queue 항목 생성
# ──────────────────────────────────────────────────────────────────────────────

_dql_create_queue_entry() {
    local response_id="$1"
    local violation_desc="$2"
    local severity="${3:-WARN}"

    local ts
    ts=$(date -u '+%Y-%m-%d %H:%M:%S')

    # severity를 dev-queue 레벨로 매핑
    local queue_severity="tier_2"
    case "$severity" in
        ERROR) queue_severity="tier_1" ;;
        WARN) queue_severity="tier_2" ;;
        INFO) queue_severity="tier_3" ;;
    esac

    cat <<EOF
{
  "id": "file-state-violation-$(date -u +%s)-$RANDOM",
  "type": "file_state_violation",
  "cluster_id": "$FSC_GUARD_CLUSTER",
  "title": "파일 상태 모순 감지: $response_id",
  "description": "$(_dql_json_escape "$violation_desc")",
  "severity": "$queue_severity",
  "created_at": "$ts",
  "status": "pending",
  "metadata": {
    "response_id": "$response_id",
    "violation_type": "file_state_contradiction",
    "guard": "file-state-contradiction-guard.sh",
    "requires_investigation": true
  }
}
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# [공개] log_file_state_violation_to_queue — 위반을 dev-queue에 기록
# 인자: 응답 ID, 위반 설명, 심각도
# 반환: 0 = 기록 성공, 1 = 기록 실패 또는 중복
# ──────────────────────────────────────────────────────────────────────────────

log_file_state_violation_to_queue() {
    local response_id="$1"
    local violation_desc="${2:-unknown violation}"
    local severity="${3:-WARN}"

    [[ -z "$response_id" ]] && {
        _dql_log "ERROR" "log_file_state_violation_to_queue: empty response_id"
        return 1
    }

    # 중복 검사
    if _dql_check_duplicate "file_state_contradiction"; then
        _dql_log "WARN" "중복 위반 스킵: $response_id"
        return 1
    fi

    # 새 항목 생성
    local new_entry
    new_entry=$(_dql_create_queue_entry "$response_id" "$violation_desc" "$severity")

    # dev-queue.json이 없으면 배열로 초기화
    if [[ ! -f "$DEV_QUEUE_FILE" ]]; then
        echo "[]" > "$DEV_QUEUE_FILE"
        _dql_log "INFO" "dev-queue.json 초기화"
    fi

    # 배열에 항목 추가 (jq)
    if command -v jq &>/dev/null; then
        local temp_queue
        temp_queue=$(mktemp)

        if jq ". += [$(cat <<< "$new_entry")]" "$DEV_QUEUE_FILE" > "$temp_queue" 2>/dev/null; then
            mv "$temp_queue" "$DEV_QUEUE_FILE"
            _dql_log "INFO" "dev-queue 항목 추가: $response_id"
            return 0
        else
            rm -f "$temp_queue"
            _dql_log "ERROR" "dev-queue 업데이트 실패: $response_id"
            return 1
        fi
    else
        _dql_log "WARN" "jq 없음 — dev-queue 업데이트 불가"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# [공개] get_pending_file_state_violations — 대기 중인 위반 항목 조회
# 반환: dev-queue의 file_state 관련 pending 항목 개수
# ──────────────────────────────────────────────────────────────────────────────

get_pending_file_state_violations() {
    if [[ ! -f "$DEV_QUEUE_FILE" ]]; then
        echo "0"
        return 0
    fi

    if command -v jq &>/dev/null; then
        local count
        count=$(jq '[.[] | select(.type == "file_state_violation" and .status == "pending")] | length' \
                   "$DEV_QUEUE_FILE" 2>/dev/null || echo "0")
        echo "$count"
    else
        echo "0"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# [공개] clear_file_state_violations — 완료된 위반 항목 정리
# 인자: 응답 ID (선택사항)
# 반환: 0 = 성공
# ──────────────────────────────────────────────────────────────────────────────

clear_file_state_violations() {
    local response_id="${1:-}"

    if [[ ! -f "$DEV_QUEUE_FILE" ]]; then
        return 0
    fi

    if command -v jq &>/dev/null; then
        local temp_queue
        temp_queue=$(mktemp)

        if [[ -n "$response_id" ]]; then
            # 특정 응답 ID의 항목만 제거
            jq "[.[] | select(.type != \"file_state_violation\" or .metadata.response_id != \"$response_id\")]" \
               "$DEV_QUEUE_FILE" > "$temp_queue"
        else
            # 모든 완료된 file_state 항목 제거
            jq "[.[] | select(.type != \"file_state_violation\" or .status != \"resolved\")]" \
               "$DEV_QUEUE_FILE" > "$temp_queue"
        fi

        if [[ -f "$temp_queue" ]]; then
            mv "$temp_queue" "$DEV_QUEUE_FILE"
            _dql_log "INFO" "dev-queue 항목 정리 완료"
            return 0
        fi
    fi

    return 1
}

_dql_log "INFO" "dev-queue-file-state-logger.sh 로드 완료"
