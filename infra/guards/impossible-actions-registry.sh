#!/usr/bin/env bash
# impossible-actions-registry.sh — 실행 불가능한 작업 유형 등록 및 검증
#
# 역할:
#   - AI 에이전트가 실제로 수행할 수 없는 작업 유형을 명시적으로 등록
#   - 해당 작업 완료 주장 시 자동 차단
#   - 기존 동작 파괴 금지
#
# 사용:
#   source ~/projects/jarvis/infra/guards/impossible-actions-registry.sh
#   is_impossible_action "web-form-manipulation"
#   get_impossible_reason "web-form-manipulation"
#   list_impossible_actions

set -o pipefail

# 불가능한 작업 레지스트리
# 형식: action_type|reason|fallback_guidance
_IMPOSSIBLE_ACTIONS=(
    # cl-41697ce934383874: 웹 폼 직접 조작 (browser 없음, JavaScript 실행 불가)
    "web-form-manipulation|AI는 브라우저 없이 웹 폼을 직접 조작할 수 없습니다|폼 처리 스크립트 작성 또는 자동화 플랫폼(Selenium, Playwright) 사용을 제안하세요"

    # 외부 시스템 접근 (권한 없음)
    "external-system-access|AI는 외부 시스템에 대한 권한이 없습니다|API 호출 또는 시스템 관리자를 통한 요청을 제안하세요"

    # 실시간 이벤트 감시 (한 번의 요청만 처리, 지속 감시 불가)
    "realtime-event-monitoring|AI는 실시간으로 이벤트를 감시할 수 없습니다|로깅·모니터링 시스템 구성을 제안하세요"

    # 브라우저 자동화 없는 GUI 조작
    "gui-automation-without-tools|AI는 GUI를 직접 조작할 수 없습니다|자동화 도구(RPA) 또는 API를 사용하세요"

    # 실시간 비디오/음성 스트림 분석
    "live-stream-processing|AI는 실시간 스트림을 처리할 수 없습니다|녹화본 또는 스냅샷 분석을 제안하세요"
)

# 함수: 작업이 불가능한지 확인
is_impossible_action() {
    local action_type="$1"

    [[ -z "$action_type" ]] && return 2

    for entry in "${_IMPOSSIBLE_ACTIONS[@]}"; do
        local type="${entry%%|*}"
        if [[ "$type" == "$action_type" ]]; then
            return 0  # 불가능 (true)
        fi
    done

    return 1  # 가능
}

# 함수: 불가능 이유 조회
get_impossible_reason() {
    local action_type="$1"

    [[ -z "$action_type" ]] && return 2

    for entry in "${_IMPOSSIBLE_ACTIONS[@]}"; do
        local type="${entry%%|*}"
        if [[ "$type" == "$action_type" ]]; then
            local reason="${entry#*|}"
            reason="${reason%%|*}"
            echo "$reason"
            return 0
        fi
    done

    return 1
}

# 함수: 대체 제안 조회
get_impossible_fallback() {
    local action_type="$1"

    [[ -z "$action_type" ]] && return 2

    for entry in "${_IMPOSSIBLE_ACTIONS[@]}"; do
        local type="${entry%%|*}"
        if [[ "$type" == "$action_type" ]]; then
            local fallback="${entry##*|}"
            echo "$fallback"
            return 0
        fi
    done

    return 1
}

# 함수: 전체 불가능 작업 목록
list_impossible_actions() {
    echo "=== 실행 불가능한 작업 유형 (Impossible Actions Registry) ===" >&2
    echo "" >&2

    local idx=1
    for entry in "${_IMPOSSIBLE_ACTIONS[@]}"; do
        local type="${entry%%|*}"
        local reason="${entry#*|}"
        reason="${reason%%|*}"
        local fallback="${entry##*|}"

        echo "[$idx] 작업: $type" >&2
        echo "    이유: $reason" >&2
        echo "    대체: $fallback" >&2
        echo "" >&2

        ((idx++))
    done
}

# 함수: 완료 주장 검증 (impossible action 차단)
validate_completion_against_impossible_registry() {
    local action_type="$1"
    local verbose="${2:-0}"

    [[ -z "$action_type" ]] && { echo "ERROR: action_type required" >&2; return 2; }

    if is_impossible_action "$action_type"; then
        local reason
        local fallback
        reason=$(get_impossible_reason "$action_type")
        fallback=$(get_impossible_fallback "$action_type")

        echo "BLOCKED: 작업 '$action_type' 완료 불가능" >&2
        echo "  이유: $reason" >&2
        echo "  제안: $fallback" >&2

        [[ "$verbose" == "1" ]] && list_impossible_actions

        return 1
    fi

    echo "OK: 작업 '$action_type' 실행 가능" >&2
    return 0
}

# 함수: 신규 불가능 작업 등록 (런타임, 배열 한계)
# 실제 등록은 이 파일을 직접 편집하고 git commit (체계적 추적)
register_impossible_action_static() {
    # 이 함수는 placeholder — 동적 등록은 위험하므로
    # 모든 신규 등록은 _IMPOSSIBLE_ACTIONS 배열을 직접 수정하고
    # git으로 추적해야 함 (audit trail 확보)
    echo "ERROR: 신규 등록은 이 파일을 직접 편집하고 git commit하세요" >&2
    return 1
}

# 함수: JSON 형식 리포트 (모니터링/로깅용)
report_impossible_action_json() {
    local action_type="$1"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    [[ -z "$action_type" ]] && return 2

    if is_impossible_action "$action_type"; then
        local reason
        reason=$(get_impossible_reason "$action_type")

        cat <<EOF
{
  "timestamp": "$timestamp",
  "cluster": "cl-41697ce934383874",
  "guard": "impossible-actions-registry",
  "action_type": "$action_type",
  "blocked": true,
  "reason": "$reason"
}
EOF
        return 0
    fi

    return 1
}

# Test mode (직접 실행 시)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Testing impossible-actions-registry.sh..."

    # 테스트 1: 불가능 작업 확인
    echo ""
    echo "Test 1: is_impossible_action 'web-form-manipulation'"
    is_impossible_action "web-form-manipulation" && echo "  PASS: 불가능" || echo "  FAIL"

    # 테스트 2: 가능 작업 확인
    echo ""
    echo "Test 2: is_impossible_action 'valid-action'"
    is_impossible_action "valid-action" && echo "  FAIL" || echo "  PASS: 가능"

    # 테스트 3: 이유 조회
    echo ""
    echo "Test 3: get_impossible_reason 'web-form-manipulation'"
    get_impossible_reason "web-form-manipulation"

    # 테스트 4: 완료 주장 검증
    echo ""
    echo "Test 4: validate_completion_against_impossible_registry 'web-form-manipulation'"
    validate_completion_against_impossible_registry "web-form-manipulation" 0

    # 테스트 5: JSON 리포트
    echo ""
    echo "Test 5: report_impossible_action_json 'web-form-manipulation'"
    report_impossible_action_json "web-form-manipulation"

    # 전체 목록
    echo ""
    list_impossible_actions
fi
