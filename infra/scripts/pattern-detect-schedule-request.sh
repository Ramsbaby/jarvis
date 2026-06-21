#!/usr/bin/env bash
# pattern-detect-schedule-request.sh — 일정/여행/운동 계획 요청 패턴 감지 모듈
#
# 목적:
#   - 신체 제약 정보 미확인 상태에서 일정을 제시하는 오류를 방지
#   - 요청 텍스트 분석으로 일정/여행/운동 계획 감지
#   - 필수 건강 정보 체크리스트 자동 질의
#   - 미답변 시 응답 블로킹
#
# 사용 예:
#   pattern-detect-schedule-request.sh --text "내일 산책 코스 추천해줄래?"
#   pattern-detect-schedule-request.sh --check-health --blocking

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
SCRIPT_NAME="pattern-detect-schedule-request"
LOG_FILE="$JARVIS_HOME/runtime/logs/${SCRIPT_NAME}.log"
STATE_FILE="$JARVIS_HOME/runtime/state/${SCRIPT_NAME}-state.json"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"

_log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ============================================================================
# [1] 일정/여행/운동 계획 요청 패턴 감지 정규식 & 키워드
# ============================================================================

# 정규식: 일정/여행/운동 계획 요청 감지
SCHEDULE_KEYWORDS=(
    # 일정 관련
    "일정"
    "계획"
    "스케줄"
    "예약"
    "약속"
    # 여행 관련
    "여행"
    "여행지"
    "여행 계획"
    "여름 여행"
    "겨울 여행"
    "국내여행"
    "해외여행"
    "여행 추천"
    "여행지 추천"
    # 운동 관련
    "운동"
    "헬스"
    "피트니스"
    "요가"
    "필라테스"
    "조깅"
    "산책"
    "등산"
    "웨이트"
    "러닝"
    "운동 루틴"
    "운동 계획"
    "운동 추천"
    # 이동 관련
    "산책 코스"
    "등산 코스"
    "러닝 코스"
    "자전거"
    "하이킹"
    "트레킹"
    # 활동 관련
    "활동"
    "액티비티"
    "스포츠"
    "레포츠"
)

# 건강 상태 확인 항목
HEALTH_CHECK_ITEMS=(
    "current_pain|현재 통증 여부"
    "chronic_disease|만성질환 보유"
    "medications|현재 복용 약물"
    "physical_limitation|신체 제약 사항"
    "last_medical_check|최근 건강검진 시기"
    "mobility_level|현재 활동 능력 수준"
)

# ============================================================================
# [2] 텍스트에서 패턴 감지
# ============================================================================

detect_schedule_pattern() {
    local text="$1"
    local has_schedule_keyword=0

    # 핵심 키워드 매칭 (한글 포함)
    for keyword in "${SCHEDULE_KEYWORDS[@]}"; do
        # grep을 사용한 간단한 문자열 포함 검사 (대소문자 무시)
        if echo "$text" | grep -qi "$keyword"; then
            has_schedule_keyword=1
            break
        fi
    done

    # 핵심 일정 키워드가 있을 때만 의도 감지 허용
    if [ "$has_schedule_keyword" -eq 1 ]; then
        # 의도 감지: 추천/조언 요청 (일정 키워드와 함께 있어야 함)
        if echo "$text" | grep -qE "(추천|제시|제안|조언|추천해|해줄|어떻게|어디|어느|좋은|최고의)"; then
            return 0  # 패턴 감지됨
        fi
        # 일정 키워드만 있어도 패턴 감지
        return 0
    fi

    return 1  # 패턴 미감지
}

# ============================================================================
# [3] 건강 정보 체크리스트 생성 & 질의
# ============================================================================

generate_health_checklist() {
    cat <<'EOF'
다음 정보가 필요합니다 (필수 항목):

1. 현재 통증이 있으신가요? (예: 허리, 무릎, 어깨 등)
   - 답변: [ ]

2. 만성질환이 있으신가요? (예: 당뇨, 고혈압, 천식 등)
   - 답변: [ ]

3. 현재 복용 중인 약물이 있으신가요?
   - 답변: [ ]

4. 신체 제약 사항이 있으신가요? (예: 수술 후 회복 중, 부상 등)
   - 답변: [ ]

5. 최근 건강검진을 받으신 적이 있으신가요? (언제?)
   - 답변: [ ]

6. 현재 활동 능력 수준은 어떻게 되나요? (예: 저강도, 중강도, 고강도 가능)
   - 답변: [ ]

⚠️  모든 항목에 답변하신 후 일정 추천을 진행하겠습니다.
EOF
}

# ============================================================================
# [4] 건강 정보 검증 (필수 항목 답변 확인)
# ============================================================================

validate_health_responses() {
    local state_file="$1"

    if [ ! -f "$state_file" ]; then
        return 1  # 파일 없음 = 미답변
    fi

    # JSON에서 필수 항목 확인
    local required_count=0
    for item in "${HEALTH_CHECK_ITEMS[@]}"; do
        local key="${item%%|*}"
        if grep -q "\"$key\"" "$state_file" 2>/dev/null; then
            ((required_count++))
        fi
    done

    # 전체 항목 개수와 비교
    if [ "$required_count" -ge ${#HEALTH_CHECK_ITEMS[@]} ]; then
        return 0  # 모든 항목 답변됨
    else
        return 1  # 미답변 항목 존재
    fi
}

# ============================================================================
# [5] 응답 블로킹 로직
# ============================================================================

block_recommendation_if_needed() {
    local text="$1"
    local user_id="$2"
    local state_file="$JARVIS_HOME/runtime/state/${SCRIPT_NAME}-${user_id}.json"

    if detect_schedule_pattern "$text"; then
        _log "일정/여행/운동 요청 감지: $text"

        if ! validate_health_responses "$state_file"; then
            _log "경고: 필수 건강 정보 미답변 — 응답 블로킹"
            cat <<'EOF'

⛔ 일정 추천 불가 — 필수 건강 정보 필요

신체 제약 정보를 먼저 확인하겠습니다.

EOF
            generate_health_checklist
            echo ""
            echo "✋ 위 체크리스트를 먼저 작성해주세요."
            return 1  # 블로킹됨
        else
            _log "OK: 필수 건강 정보 확인됨 — 추천 응답 진행"
            return 0  # 블로킹 해제
        fi
    else
        # 패턴 미감지 — 일반 요청
        return 0
    fi
}

# ============================================================================
# [6] 상태 저장 (JSON)
# ============================================================================

save_health_state() {
    local user_id="$1"
    local state_file="$JARVIS_HOME/runtime/state/${SCRIPT_NAME}-${user_id}.json"
    local health_data="$2"

    mkdir -p "$(dirname "$state_file")"
    echo "$health_data" > "$state_file"
    _log "상태 저장: $state_file"
}

# ============================================================================
# [7] 메인 처리
# ============================================================================

main() {
    local action="${1:-detect}"

    case "$action" in
        detect)
            # 텍스트에서 패턴 감지
            shift  # 'detect' 제거
            local text="$*"  # 나머지 인자 모두를 텍스트로 취급
            if [ -z "$text" ]; then
                _log "오류: 텍스트가 필요합니다"
                exit 1
            fi

            if detect_schedule_pattern "$text"; then
                _log "패턴 감지됨: $text"
                echo "DETECTED"
                exit 0
            else
                echo "NOT_DETECTED"
                exit 1
            fi
            ;;

        check-health)
            # 건강 정보 체크리스트 출력
            local user_id="${2:-default}"
            local state_file="$JARVIS_HOME/runtime/state/${SCRIPT_NAME}-${user_id}.json"

            if validate_health_responses "$state_file"; then
                _log "OK: 건강 정보 확인됨"
                echo "VALIDATED"
                exit 0
            else
                _log "경고: 필수 건강 정보 미답변"
                generate_health_checklist
                echo ""
                echo "상태: 미답변"
                exit 1
            fi
            ;;

        block)
            # 블로킹 로직 실행
            shift  # 'block' 제거
            local text="$1"
            local user_id="${2:-default}"

            if [ -z "$text" ]; then
                _log "오류: 텍스트가 필요합니다"
                exit 1
            fi

            if block_recommendation_if_needed "$text" "$user_id"; then
                _log "OK: 응답 진행 가능"
                echo "ALLOWED"
                exit 0
            else
                _log "경고: 응답 블로킹됨"
                echo "BLOCKED"
                exit 1
            fi
            ;;

        save)
            # 건강 정보 저장
            shift  # 'save' 제거
            local user_id="$1"
            local health_json="$2"

            if [ -z "$user_id" ] || [ -z "$health_json" ]; then
                _log "오류: user_id와 health_json이 필요합니다"
                exit 1
            fi

            save_health_state "$user_id" "$health_json"
            _log "건강 정보 저장 완료"
            exit 0
            ;;

        *)
            _log "오류: 알 수 없는 액션 '$action'"
            echo "사용법:"
            echo "  $0 detect --text '텍스트'"
            echo "  $0 check-health [user_id]"
            echo "  $0 block --text '텍스트' [user_id]"
            echo "  $0 save --user-id 'user' --data '{json}'"
            exit 1
            ;;
    esac
}

# CLI 모드 vs 소싱 모드 판별
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
