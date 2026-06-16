#!/usr/bin/env bash
# root-cause-validator.sh
# 근본원인 분석 검증 가드 스크립트
# 클러스터 cl-d8daa113f8bb5b30: 증상억제 vs 근본해결 자동 판별
#
# 사용 방식:
#   source /path/to/root-cause-validator.sh
#   validate_root_cause_analysis "$PROBLEM_DESCRIPTION" "$PROPOSED_SOLUTION"
#   if [ $? -ne 0 ]; then
#       echo "근본원인 분석 미실시. 솔루션 차단됨."
#       exit 1
#   fi

set -euo pipefail

# --- 전역 설정 ---
RCA_ENABLED="${RCA_ENABLED:-1}"
RCA_STRICT_MODE="${RCA_STRICT_MODE:-1}"  # 1: 차단, 0: 경고만
RCA_LOG_FILE="${RCA_LOG_FILE:-${HOME}/jarvis/runtime/logs/rca-validation.log}"

# --- RCA 판별 기준 정의 ---
# 증상억제(Symptom Suppression) 패턴
SYMPTOM_KEYWORDS=(
    "ignore"
    "suppress"
    "disable"
    "timeout"
    "retry"
    "skip"
    "workaround"
    "temporary"
    "bandaid"
    "quick fix"
    "patch"
    "cache"
    "fallback"
    "default"
    "catch and ignore"
)

# 근본원인 해결(Root Cause Resolution) 패턴
ROOT_CAUSE_KEYWORDS=(
    "refactor"
    "redesign"
    "fix the issue"
    "eliminate"
    "solve"
    "correct"
    "architecture"
    "dependency"
    "logic"
    "algorithm"
    "implementation"
    "validate"
    "sanitize"
    "normalize"
)

# 분석 단계 체크리스트
RCA_CHECKLIST=(
    "repro\|reproduction\|reproduce"
    "why.*why\|5.*why\|root.*cause"
    "architecture\|design\|pattern"
    "test\|verify\|validate"
    "monitor\|metric\|observe"
)

# --- 유틸리티 함수 ---

log_rca() {
    local level="$1" message="$2"
    local timestamp
    timestamp=$(date -u +"%FT%TZ")
    printf '[%s] %s: %s\n' "$timestamp" "$level" "$message" >> "$RCA_LOG_FILE" 2>/dev/null || true
}

count_keyword_matches() {
    local text="$1"
    local -n keywords=$2
    local count=0

    for keyword in "${keywords[@]}"; do
        if grep -iq "$keyword" <<<"$text" 2>/dev/null; then
            (( count++ ))
        fi
    done
    echo "$count"
}

contains_investigation_phrase() {
    local text="$1"
    if grep -iq "investig\|analyz\|diagnos\|debug\|trace\|profile\|reason\|cause\|factor" <<<"$text"; then
        return 0
    fi
    return 1
}

contains_mitigation_only() {
    local text="$1"
    if grep -iq "avoid\|prevent\|detect\|alert\|notify" <<<"$text" && \
       ! grep -iq "refactor\|redesign\|rewrite\|fix\|eliminate" <<<"$text"; then
        return 0
    fi
    return 1
}

# --- 핵심 검증 함수 ---

validate_root_cause_analysis() {
    local problem_description="${1:?근본원인 분석 검증 필요: PROBLEM_DESCRIPTION 인자 필수}"
    local proposed_solution="${2:?근본원인 분석 검증 필요: PROPOSED_SOLUTION 인자 필수}"
    local cluster_id="${3:-cl-d8daa113f8bb5b30}"

    if [[ "$RCA_ENABLED" != "1" ]]; then
        return 0
    fi

    local combined_text="${problem_description}\n${proposed_solution}"
    local verdict=0
    local violations=()
    local analysis_score=0

    # --- 검증 1: 재현 가능성 확인 ---
    if ! grep -iq "repro\|reproduce\|occur\|happen\|when\|condition" <<<"$problem_description"; then
        violations+=("MISSING_REPRODUCTION_PATH: 재현 조건 설명 부재")
    fi

    # --- 검증 2: 분석 단계 확인 ---
    local checklist_passed=0
    for check in "${RCA_CHECKLIST[@]}"; do
        if grep -iq "$check" <<<"$combined_text"; then
            (( checklist_passed++ ))
        fi
    done
    analysis_score=$((checklist_passed * 20))

    if (( analysis_score < 40 )); then
        violations+=("INSUFFICIENT_ANALYSIS: 분석 체크포인트 부족 (점수: $analysis_score/100)")
    fi

    # --- 검증 3: 증상억제 vs 근본해결 판별 ---
    local symptom_count
    local root_cause_count
    symptom_count=$(count_keyword_matches "$proposed_solution" SYMPTOM_KEYWORDS)
    root_cause_count=$(count_keyword_matches "$proposed_solution" ROOT_CAUSE_KEYWORDS)

    if (( symptom_count > root_cause_count + 2 )); then
        violations+=("SYMPTOM_SUPPRESSION_DETECTED: 증상억제 패턴이 근본해결보다 많음 (억제=$symptom_count, 해결=$root_cause_count)")
    fi

    # --- 검증 4: 순수 완화 전략만 있는 경우 ---
    if contains_mitigation_only "$proposed_solution"; then
        violations+=("MITIGATION_ONLY_APPROACH: 탐지/알림만 있고 근본 해결 없음")
    fi

    # --- 검증 5: 조사/분석 증거 ---
    if ! contains_investigation_phrase "$combined_text"; then
        violations+=("NO_INVESTIGATION_EVIDENCE: 원인 분석 증거 부재")
    fi

    # --- 검증 6: 구조적 이해도 확인 ---
    if ! grep -iq "architecture\|design\|module\|component\|interface\|contract\|invariant" <<<"$combined_text"; then
        violations+=("LACK_OF_STRUCTURAL_ANALYSIS: 구조적 분석 부족")
    fi

    # --- 결과 기록 및 반환 ---
    local status="PASS"
    if [[ ${#violations[@]} -gt 0 ]]; then
        status="FAIL"
        verdict=1
    fi

    local log_msg="RCA_VALIDATION cluster=$cluster_id status=$status score=$analysis_score symptom=$symptom_count root_cause=$root_cause_count violations=${#violations[@]}"
    log_rca "$status" "$log_msg"

    for violation in "${violations[@]}"; do
        log_rca "VIOLATION" "$violation"
    done

    if [[ "$RCA_STRICT_MODE" == "1" && $verdict -ne 0 ]]; then
        cat >&2 <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
❌ 근본원인 분석 미실시 — 솔루션 제안 차단됨 (클러스터: $cluster_id)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

분석 점수: $analysis_score/100
증상억제 키워드: $symptom_count
근본해결 키워드: $root_cause_count

위반 항목 (${#violations[@]}개):
EOF
        for violation in "${violations[@]}"; do
            echo "  • $violation" >&2
        done
        cat >&2 <<'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
필수 체크포인트:
  [✓] 재현 조건을 명확히 했는가?
  [✓] "왜"를 5번 이상 물었는가?
  [✓] 구조적/아키텍처 관점에서 분석했는가?
  [✓] 다른 영역에 영향이 있는지 확인했는가?
  [✓] 검증(테스트)은 가능한가?

권장 프로세스:
  1. 문제를 명확히 정의 (What, When, Where)
  2. 재현 스텝 기록
  3. 원인 분석 (Why 5번법)
  4. 구조적 이해 문서화
  5. 검증 계획 수립
  6. 다시 분석 검증 요청

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
        return 1
    fi

    return 0
}

validate_multiple_solutions() {
    local problem_description="$1"
    local -n solutions=$2
    local cluster_id="${3:-cl-d8daa113f8bb5b30}"

    local passed=0
    local failed=0

    for i in "${!solutions[@]}"; do
        if validate_root_cause_analysis "$problem_description" "${solutions[$i]}" "$cluster_id"; then
            (( passed++ ))
        else
            (( failed++ ))
        fi
    done

    echo "RCA_BATCH_RESULT: passed=$passed failed=$failed"
    return $((failed > 0 ? 1 : 0))
}

rca_set_strict_mode() {
    RCA_STRICT_MODE="${1:-1}"
    log_rca "INFO" "RCA_STRICT_MODE=$RCA_STRICT_MODE"
}

rca_disable() {
    RCA_ENABLED="0"
    log_rca "INFO" "RCA validation disabled"
}

rca_enable() {
    RCA_ENABLED="1"
    log_rca "INFO" "RCA validation enabled"
}

rca_get_last_violation() {
    if [[ -f "$RCA_LOG_FILE" ]]; then
        tail -n 20 "$RCA_LOG_FILE" | grep "VIOLATION" | tail -n 1
    fi
}

mkdir -p "$(dirname "$RCA_LOG_FILE")"
