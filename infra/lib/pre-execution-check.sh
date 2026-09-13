#!/usr/bin/env bash
# pre-execution-check.sh — 계획 실행 직전 상태 검사 훅 (cl-a405499fa67279d6)
#
# 목적: 세션 시작이나 크론 실행 전에 정책-규칙 동기화 상태를 검사하고,
#       불일치 발견 시 세션 컨텍스트에 경고를 주입한다.
#
# 사용:
#   source ~/projects/jarvis/infra/lib/pre-execution-check.sh
#   run_pre_execution_check
#
# 기존 동작 보호:
#   - 실패해도 프로세스를 죽이지 않음 (exit code로만 표현)
#   - 경고 메시지는 stderr로 출력되어 CI/CD에 가시성 확보

set +e

# ── 상수 ────────────────────────────────────────────────────────────────────

readonly _PREEXEC_PREFIX="[pre-execution-check]"
readonly _PREEXEC_CHECK_RULE_DRIFT="${HOME}/projects/jarvis/infra/lib/check-rule-drift.sh"
readonly _PREEXEC_CONTEXT_FILE="${HOME}/.openclaw-data/runtime/state/pre-execution-context.md"

_PREEXEC_WARN='\033[0;33m'
_PREEXEC_RED='\033[0;31m'
_PREEXEC_GRN='\033[0;32m'
_PREEXEC_NC='\033[0m'

# ── 헬퍼 ────────────────────────────────────────────────────────────────────

_preexec_warn() {
    printf "${_PREEXEC_WARN}⚠️  %s [WARN]  %s${_PREEXEC_NC}\n" "$_PREEXEC_PREFIX" "$*" >&2
}

_preexec_fail() {
    printf "${_PREEXEC_RED}❌ %s [FAIL]  %s${_PREEXEC_NC}\n" "$_PREEXEC_PREFIX" "$*" >&2
}

_preexec_ok() {
    printf "${_PREEXEC_GRN}✅ %s [PASS]  %s${_PREEXEC_NC}\n" "$_PREEXEC_PREFIX" "$*" >&2
}

_preexec_ensure_state_dir() {
    mkdir -p "$(dirname "$_PREEXEC_CONTEXT_FILE")" 2>/dev/null || true
}

# ── 공개 API ──────────────────────────────────────────────────────────────────

run_pre_execution_check() {
    local check_passed=0
    local drift_detected=0

    _preexec_ensure_state_dir

    # 1. 정책-규칙 동기화 검사
    if [[ -f "$_PREEXEC_CHECK_RULE_DRIFT" ]]; then
        source "$_PREEXEC_CHECK_RULE_DRIFT" 2>/dev/null || {
            _preexec_warn "check-rule-drift.sh 로드 실패, 스킵"
            return 0
        }

        if check_rule_drift 180 2>/dev/null; then
            _preexec_ok "정책-규칙 동기화 검사 통과"
            ((check_passed++))
        else
            _preexec_fail "정책-규칙 드리프트 감지됨"
            ((drift_detected++))

            # 컨텍스트 파일에 보고서 저장
            {
                printf "# Pre-Execution Check Results\n\n"
                printf "_실행 시각: %s_\n\n" "$(date '+%Y-%m-%d %H:%M:%S')"
                generate_drift_report
            } > "$_PREEXEC_CONTEXT_FILE" 2>/dev/null || true

            _preexec_warn "드리프트 보고서 저장: $_PREEXEC_CONTEXT_FILE"
        fi
    else
        _preexec_warn "check-rule-drift.sh 없음: $_PREEXEC_CHECK_RULE_DRIFT"
    fi

    # 2. 결과 반환
    if (( drift_detected > 0 )); then
        _preexec_warn "1개 이상의 검사 실패. 진행 가능하지만 검증 권고"
        return 1
    fi

    return 0
}

# ── 자동 호출 여부 ──────────────────────────────────────────────────────────
# 이 파일을 직접 실행한 경우: ./pre-execution-check.sh
# 스크립트에서 source한 경우: run_pre_execution_check() 함수만 사용
# (자동 호출 없음 — 명시적 호출 필요)
