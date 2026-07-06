#!/usr/bin/env bash
# error-duplicate-tracker.sh — 세션 내 동일 오류 유형 재발 감지
#
# 클러스터 cl-733ea6d158b005b6 대응: 완료 선언 후 재검증 없어 동일 오류 재발
# 용도:
#   - 세션 내 오류 히스토리 기록
#   - 동일 오류 유형 재발 감지 (exit 1 반환)
#   - 이전 수정 이력과 대조
#
# 사용:
#   source ~/jarvis/infra/lib/error-duplicate-tracker.sh
#   track_error_duplicate "$TASK_ID" "$ERROR_TYPE" "$ERROR_MSG" "$SOLUTION"
#
#   반환값:
#     0 = 새로운 오류 (처음 발생)
#     1 = 재발 감지 (경고, 이전 해결책 제시)

set -euo pipefail

# 오류 중복 추적 디렉토리
_ERROR_TRACKER_DIR="${HOME}/jarvis/runtime/state/error-duplicate-tracker"
_ERROR_TRACKER_LEDGER="${_ERROR_TRACKER_DIR}/session-errors.jsonl"
_ERROR_HISTORY="${_ERROR_TRACKER_DIR}/error-history.json"

# 오류 유형 정규화 (중복 감지 향상)
_normalize_error_type() {
    local error_type="$1"
    # 공백 제거, 소문자 변환, 특수 문자 제거
    echo "$error_type" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g'
}

# 오류 시그니처 생성 (task + 정규화된 error_type)
_generate_error_signature() {
    local task_id="$1"
    local error_type="$2"
    local normalized_type=$(_normalize_error_type "$error_type")
    echo "${task_id}:${normalized_type}"
}

# 오류 중복 추적 초기화
_init_error_tracker() {
    mkdir -p "$_ERROR_TRACKER_DIR" 2>/dev/null || return 0
}

# 현재 세션의 오류 히스토리 로드
_load_session_errors() {
    local session_id="${1:-}"
    if [[ -f "$_ERROR_TRACKER_LEDGER" ]]; then
        # 현재 세션의 모든 오류 기록 출력
        grep "\"session_id\":\"${session_id}\"" "$_ERROR_TRACKER_LEDGER" 2>/dev/null || true
    fi
}

# 오류 이력에서 유사한 해결책 검색
_find_previous_solution() {
    local error_type="$1"
    if [[ -f "$_ERROR_HISTORY" ]]; then
        # 동일 오류 타입의 이전 해결책 조회
        jq --arg type "$error_type" '.[$type] | .solution // empty' "$_ERROR_HISTORY" 2>/dev/null || true
    fi
}

# 오류를 히스토리에 추가
_add_to_history() {
    local error_type="$1"
    local solution="$2"
    _init_error_tracker

    # 간단한 JSON 업데이트 (jq 필수)
    if command -v jq >/dev/null 2>&1; then
        local tmp_file
        tmp_file=$(mktemp)
        if [[ -f "$_ERROR_HISTORY" ]]; then
            jq --arg type "$error_type" --arg sol "$solution" \
                '.[$type] //= {} | .[$type].solution = $sol | .[$type].last_seen = now' \
                "$_ERROR_HISTORY" > "$tmp_file" 2>/dev/null || true
        else
            jq -cn --arg type "$error_type" --arg sol "$solution" \
                '{($type): {solution: $sol, last_seen: now}}' > "$tmp_file" 2>/dev/null || true
        fi
        [[ -s "$tmp_file" ]] && mv "$tmp_file" "$_ERROR_HISTORY"
        rm -f "$tmp_file"
    fi
}

# 메인: 오류 재발 감지 및 기록
track_error_duplicate() {
    local task_id="${1:?Task ID required}"
    local error_type="${2:?Error type required}"
    local error_msg="${3:?Error message required}"
    local solution="${4:-No solution provided}"

    _init_error_tracker

    local session_id="${SESSION_ID:-session-$$}"
    local error_sig=$(_generate_error_signature "$task_id" "$error_type")
    local timestamp
    timestamp=$(date -u +%FT%TZ)

    # 세션 오류 기록 조회
    local session_errors
    session_errors=$(_load_session_errors "$session_id")

    # 동일 오류 타입 재발 확인
    if echo "$session_errors" | grep -q "\"error_signature\":\"${error_sig}\"" 2>/dev/null; then
        # 재발 감지!
        local prev_solution
        prev_solution=$(_find_previous_solution "$error_type")

        printf '[%s] ERROR_DUPLICATE_DETECTED: %s (task=%s)\n' \
            "$timestamp" "$error_type" "$task_id" >&2
        printf '[%s] Previous solution: %s\n' "$timestamp" "${prev_solution:-unknown}" >&2

        # 오류 레져 기록 (재발)
        mkdir -p "$(dirname "$_ERROR_TRACKER_LEDGER")" 2>/dev/null || true
        jq -cn --arg sig "$error_sig" --arg task "$task_id" --arg type "$error_type" \
            --arg msg "$error_msg" --arg sol "$solution" --arg ts "$timestamp" \
            --arg session "$session_id" --arg status "duplicate" \
            '{error_signature:$sig, task:$task, error_type:$type, error_msg:$msg, solution:$sol, timestamp:$ts, session_id:$session, status:$status}' \
            >> "$_ERROR_TRACKER_LEDGER" 2>/dev/null || true

        return 1  # 재발 (경고)
    else
        # 새로운 오류
        printf '[%s] NEW_ERROR_TRACKED: %s (task=%s)\n' \
            "$timestamp" "$error_type" "$task_id" >&2

        # 오류 레져 기록 (새로운)
        mkdir -p "$(dirname "$_ERROR_TRACKER_LEDGER")" 2>/dev/null || true
        jq -cn --arg sig "$error_sig" --arg task "$task_id" --arg type "$error_type" \
            --arg msg "$error_msg" --arg sol "$solution" --arg ts "$timestamp" \
            --arg session "$session_id" --arg status "new" \
            '{error_signature:$sig, task:$task, error_type:$type, error_msg:$msg, solution:$sol, timestamp:$ts, session_id:$session, status:$status}' \
            >> "$_ERROR_TRACKER_LEDGER" 2>/dev/null || true

        # 히스토리 업데이트
        _add_to_history "$error_type" "$solution"

        return 0  # 새로운 오류 (OK)
    fi
}

# 세션 오류 통계
show_error_stats() {
    local session_id="${1:-}"
    if [[ -f "$_ERROR_TRACKER_LEDGER" ]]; then
        if [[ -n "$session_id" ]]; then
            echo "[Error Statistics for $session_id]"
            jq --arg session "$session_id" 'select(.session_id == $session) | {error_type, status}' \
                "$_ERROR_TRACKER_LEDGER" 2>/dev/null || true
        else
            echo "[All Error Statistics]"
            jq '{error_type, status}' "$_ERROR_TRACKER_LEDGER" 2>/dev/null | sort | uniq -c || true
        fi
    fi
}

# 오류 히스토리 초기화 (선택사항)
clear_error_history() {
    rm -f "$_ERROR_TRACKER_LEDGER" "$_ERROR_HISTORY" 2>/dev/null || true
    echo "[Error history cleared]"
}

export -f track_error_duplicate
export -f show_error_stats
export -f clear_error_history
