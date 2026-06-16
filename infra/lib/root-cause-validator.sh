#!/usr/bin/env bash
# root-cause-validator.sh — 근본원인 분석 검증 가드
#
# Purpose:
#   클러스터 cl-d8daa113f8bb5b30 반복 실수 대응
#   "초기 권고가 근본 해법이 아니었음" 패턴 방지
#   솔루션이 근본원인을 분석하고 제시하는지, 아니면 표면 증상만 조정하는지 판별
#
# Design:
#   - Pure bash/regex — LLM 호출 없음 (tokenless gate)
#   - 근본원인 분석 부재 감지 시 솔루션 제안 차단
#   - 3가지 판정: pass (근본해결) / warn (부분 분석) / block (근본미분석)
#   - ask-claude.sh의 evaluator.sh와 동일 계층에서 동작
#
# Usage: validate_root_cause "$TASK_ID" "$RESULT" "$PROMPT"
#   환경변수 (호출 후 설정):
#     ROOT_CAUSE_VERDICT  — "pass"|"warn"|"block"
#     ROOT_CAUSE_REASON   — 판정 사유
#     ROOT_CAUSE_BLOCKED  — true/false (차단 여부)
#
# Called from: ask-claude.sh (evaluator.sh 직후, 결과 저장 직전)
#   - block 판정 시: EVALUATOR_VERDICT를 fail로 override
#   - stdout에 "ROOT_CAUSE_ANALYSIS_REQUIRED" 메시지 출력 및 exit 1

# --- 근본원인 분석 키워드 (문제 해결에 필수) ---
# 이 키워드들이 전혀 없으면 "증상억제 의심" 판정
_ROOT_CAUSE_KEYWORDS=(
    "근본|원인|이유|왜"
    "cause|reason|why"
    "분석|analyze|investigation"
    "진단|diagnose|root"
    "발생|occur|happened"
)

# --- 표면 증상 억제 패턴 (근본 미분석 강한 신호) ---
# 이 패턴들이 많으면 "증상억제 의심"
_SYMPTOM_SUPPRESSION_PATTERNS=(
    "조정|adjust"
    "임시|temporary|temp"
    "우회|workaround|bypass"
    "억제|suppress|disable"
    "비활성화|turn off"
    "무시|ignore|skip"
    "마스킹|mask"
)

# --- 근본원인 분석 체크포인트 ---
# 문제 해결 솔루션이 충족해야 할 최소 요건
_check_root_cause_markers() {
    local result="$1"
    local markers_found=0

    # 최소 1개 이상의 근본원인 키워드 존재 확인
    for pattern in "${_ROOT_CAUSE_KEYWORDS[@]}"; do
        if printf '%s' "$result" | grep -qiE "$pattern"; then
            (( markers_found++ ))
        fi
    done

    echo "$markers_found"
}

# --- 증상억제 패턴 개수 세기 ---
_count_symptom_patterns() {
    local result="$1"
    local pattern_count=0

    for pattern in "${_SYMPTOM_SUPPRESSION_PATTERNS[@]}"; do
        local match_count
        match_count=$(printf '%s' "$result" | grep -io "$pattern" | wc -l | tr -d ' ')
        pattern_count=$(( pattern_count + match_count ))
    done

    echo "$pattern_count"
}

# --- 문제/증상 분석 검증 ---
# "문제가 무엇인가"를 명시적으로 분석했는지 확인
_has_problem_analysis() {
    local result="$1"

    # 문제를 정의하거나 상황을 분석하는 표현들
    local problem_markers="문제\|issue\|symptom\|문제점\|실제 문제\|근본적\|결국"

    if printf '%s' "$result" | grep -qiE "$problem_markers"; then
        return 0  # found
    else
        return 1  # not found
    fi
}

# --- 솔루션 정당성 검증 ---
# 솔루션이 "왜 이것이 근본해결인가"를 설명하는지 확인
_has_solution_justification() {
    local result="$1"

    # 솔루션이 근본원인과 연결되는 표현들
    local justification_patterns="따라서\|그래서\|이를 통해\|이렇게 함으로써\|이유는\|결과적으로\|이것이 근본적"

    if printf '%s' "$result" | grep -qiE "$justification_patterns"; then
        return 0  # found
    else
        return 1  # not found
    fi
}

# --- 5-why 분석 시뮬레이션 ---
# 최소 2단계 이상의 인과관계 분석 확인
_has_multi_level_analysis() {
    local result="$1"

    # 인과 연결고리를 나타내는 표현들 (최소 2개 이상 필요)
    local causation_patterns=(
        "때문\|because\|due to"
        "으로 인해\|caused by\|resulted from"
        "기인\|attributed\|stems from"
    )

    local causation_count=0
    for pattern in "${causation_patterns[@]}"; do
        if printf '%s' "$result" | grep -qiE "$pattern"; then
            (( causation_count++ ))
        fi
    done

    if (( causation_count >= 2 )); then
        return 0  # sufficient multi-level analysis
    else
        return 1  # insufficient
    fi
}

# --- 가드 진입 조건 (어떤 태스크에 적용할지) ---
_should_validate_root_cause() {
    local task_id="$1"

    # 문제 해결/진단 태스크들만 근본원인 검증 필수
    case "$task_id" in
        # 버그 수정/문제 진단
        *bug-fix*|*debug*|*diagnos*|*troubleshoot*|*error*|*fix-*|fix\-*)
            return 0
            ;;
        # 성능/안정성 개선 (근본 분석 필수)
        *performance*|*optimize*|*issue*|*problem*)
            return 0
            ;;
        # 일반 모니터링/리포팅 (검증 제외)
        *health*|*summary*|*briefing*|*monitor*|*report*)
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

validate_root_cause() {
    local task_id="$1"
    local result="$2"
    local prompt="$3"

    ROOT_CAUSE_VERDICT="pass"
    ROOT_CAUSE_REASON=""
    ROOT_CAUSE_BLOCKED=false

    # --- 가드 진입 조건 체크 ---
    if ! _should_validate_root_cause "$task_id"; then
        return 0  # 검증 대상 아님 (통과)
    fi

    # --- 근본원인 마커 개수 ---
    local markers
    markers=$(_check_root_cause_markers "$result")

    if (( markers < 1 )); then
        ROOT_CAUSE_VERDICT="block"
        ROOT_CAUSE_REASON="root_cause_analysis_missing (markers=0)"
        ROOT_CAUSE_BLOCKED=true
        return 0
    fi

    # --- 증상억제 패턴 개수 ---
    local symptom_patterns
    symptom_patterns=$(_count_symptom_patterns "$result")

    # 근본 분석이 충분하면 증상억제 패턴은 무시
    if (( markers >= 2 )); then
        if (( symptom_patterns > 5 )); then
            ROOT_CAUSE_VERDICT="warn"
            ROOT_CAUSE_REASON="partial_root_cause_analysis (symptom_patterns=$symptom_patterns)"
        fi
        return 0
    fi

    # 근본 분석이 부족하면 증상억제 패턴 다수 = 차단
    if (( symptom_patterns >= 3 )); then
        ROOT_CAUSE_VERDICT="block"
        ROOT_CAUSE_REASON="symptom_suppression_only (patterns=$symptom_patterns, markers=$markers)"
        ROOT_CAUSE_BLOCKED=true
        return 0
    fi

    # --- 문제 분석 검증 ---
    if ! _has_problem_analysis "$result"; then
        ROOT_CAUSE_VERDICT="warn"
        ROOT_CAUSE_REASON="no_explicit_problem_analysis"
        return 0
    fi

    # --- 솔루션 정당성 검증 ---
    if ! _has_solution_justification "$result"; then
        ROOT_CAUSE_VERDICT="warn"
        ROOT_CAUSE_REASON="solution_lacks_justification"
        return 0
    fi

    # --- 다단계 인과 분석 ---
    if ! _has_multi_level_analysis "$result"; then
        ROOT_CAUSE_VERDICT="warn"
        ROOT_CAUSE_REASON="insufficient_causal_depth"
        return 0
    fi

    # 모든 검증 통과
    ROOT_CAUSE_VERDICT="pass"
    ROOT_CAUSE_REASON="root_cause_analysis_sufficient"

    return 0
}

# --- 단독 실행 테스트 ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <task_id> <result> [prompt]" >&2
        exit 2
    fi

    task_id="$1"
    if [[ "$2" == "-" ]]; then
        result=$(cat)
    else
        result="$2"
    fi
    prompt="${3:-}"

    validate_root_cause "$task_id" "$result" "$prompt"
    printf 'verdict=%s reason=%s blocked=%s\n' \
        "$ROOT_CAUSE_VERDICT" "$ROOT_CAUSE_REASON" "$ROOT_CAUSE_BLOCKED"

    case "$ROOT_CAUSE_VERDICT" in
        pass)  exit 0 ;;
        warn)  exit 1 ;;
        block) exit 2 ;;
    esac
fi
