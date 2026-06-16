#!/usr/bin/env bash
# rca-gate.sh
# 근본원인 분석 검증 게이트 (ask-claude.sh 호출 전)
# 클러스터 cl-d8daa113f8bb5b30 문제 해결 자동 차단 가드
#
# 통합 패턴:
#   source rca-gate.sh
#   rca_gate_check "$TASK_ID" "$PROMPT"
#   if [ $? -ne 0 ]; then exit 1; fi

set -euo pipefail

# RCA 게이트 설정
RCA_GATE_LOG="${RCA_GATE_LOG:-${HOME}/jarvis/runtime/logs/rca-gate.log}"
RCA_GATE_ENABLED="${RCA_GATE_ENABLED:-1}"
RCA_GATE_STRICT="${RCA_GATE_STRICT:-1}"  # 1: 차단, 0: 경고만

# 문제 관련 TASK_ID 패턴 (클러스터 cl-d8daa113f8bb5b30 관련)
PROBLEM_TASK_PATTERNS=(
    "problem-solving"
    "diagnosis"
    "debug"
    "fix"
    "issue"
    "error"
    "bug"
    "troubleshoot"
)

# 초기 권고 관련 의심 표현 (이 표현이 많으면 증상억제 가능성 높음)
SUSPECT_PHRASES=(
    "initial.*recommendation"
    "initial.*advice"
    "first.*approach"
    "quick.*fix"
    "temporary.*solution"
    "workaround"
    "bandaid"
    "bypass"
    "ignore the error"
    "suppress the error"
    "catch and move on"
)

# 근본 분석 증거 표현
ROOT_CAUSE_EVIDENCE=(
    "root.*cause"
    "why.*analysis"
    "deep.*analysis"
    "underlying.*cause"
    "architecture.*review"
    "design.*issue"
    "structural.*problem"
    "refactor"
    "redesign"
)

log_gate() {
    local level="$1" message="$2" task_id="${3:-unknown}"
    local ts
    ts=$(date -u +"%FT%TZ")
    printf '[%s] %s task=%s %s\n' "$ts" "$level" "$task_id" "$message" >> "$RCA_GATE_LOG" 2>/dev/null || true
}

is_problem_task() {
    local prompt="$1"
    
    for pattern in "${PROBLEM_TASK_PATTERNS[@]}"; do
        if grep -iq "$pattern" <<<"$prompt"; then
            return 0  # true - 문제 해결 관련 태스크
        fi
    done
    return 1  # false
}

check_for_repeated_mistake() {
    local prompt="$1"
    local violation_count=0
    local evidence_count=0

    # 의심 표현 카운트
    for phrase in "${SUSPECT_PHRASES[@]}"; do
        if grep -iq "$phrase" <<<"$prompt"; then
            (( violation_count++ ))
        fi
    done

    # 근본 분석 증거 카운트
    for evidence in "${ROOT_CAUSE_EVIDENCE[@]}"; do
        if grep -iq "$evidence" <<<"$prompt"; then
            (( evidence_count++ ))
        fi
    done

    # 반환값: 의심 표현이 있으면 1, 없으면 0
    # 메시지로 세부 정보 전달
    if (( violation_count >= 1 && evidence_count == 0 )); then
        echo "REPEATED_MISTAKE_PATTERN suspected=$violation_count evidence=$evidence_count"
        return 1  # violation detected
    fi

    echo "CLEAN suspected=$violation_count evidence=$evidence_count"
    return 0  # no violation
}

rca_gate_check() {
    local task_id="${1:?RCA 게이트: TASK_ID 필수}"
    local prompt="${2:?RCA 게이트: PROMPT 필수}"

    if [[ "$RCA_GATE_ENABLED" != "1" ]]; then
        return 0
    fi

    # 문제 해결 관련 태스크인지 확인
    if ! is_problem_task "$prompt"; then
        log_gate "SKIP" "not a problem-solving task, gates not applied" "$task_id"
        return 0
    fi

    log_gate "CHECK" "problem-solving task detected, running RCA gates" "$task_id"

    # 반복 실수 패턴 검사
    local check_result
    check_result=$(check_for_repeated_mistake "$prompt" || echo "REPEATED_MISTAKE_PATTERN")
    
    if [[ "$check_result" == REPEATED_MISTAKE_PATTERN* ]]; then
        local verdict="GATE_FAIL"
        
        if [[ "$RCA_GATE_STRICT" == "1" ]]; then
            log_gate "BLOCK" "$check_result" "$task_id"
            cat >&2 <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⛔ 반복 실수 패턴 감지 — 솔루션 제안 차단됨 (클러스터: cl-d8daa113f8bb5b30)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

감지 사항: $check_result
Task ID: $task_id

이 패턴은 초기 권고가 근본 해법이 아닐 수 있음을 나타냅니다.

✓ 근본 분석이 필요한 경우:
  1. 문제의 정확한 증상 설명 (What, When, Where)
  2. 재현 방법 명확히
  3. 원인 분석 (Why를 반복)
  4. 구조적/아키텍처 관점의 검토
  5. 다른 영역에 미치는 영향 확인
  6. 검증 계획 수립

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
            return 1
        else
            log_gate "WARN" "$check_result" "$task_id"
        fi
    fi

    log_gate "PASS" "RCA gates passed, proceeding with claude call" "$task_id"
    return 0
}

mkdir -p "$(dirname "$RCA_GATE_LOG")"
