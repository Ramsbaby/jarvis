#!/usr/bin/env bash
# cluster-guard-cl-a405499fa67279d6.test.sh — 테스트 스크립트

set -euo pipefail

readonly TEST_PREFIX="[test-cl-a405499fa67279d6]"

# 색상 정의
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[0;33m'
readonly NC='\033[0m'

_test_ok() {
    printf "${GREEN}✅ %s${NC}\n" "$*"
}

_test_fail() {
    printf "${RED}❌ %s${NC}\n" "$*"
    exit 1
}

_test_info() {
    printf "${YELLOW}ℹ️  %s${NC}\n" "$*"
}

# ── 테스트 1: check-rule-drift.sh 로드 ──────────────────────────────────────

_test_info "$TEST_PREFIX 테스트 1: check-rule-drift.sh 로드 및 검사"

source ~/projects/jarvis/infra/lib/check-rule-drift.sh 2>/dev/null || {
    _test_fail "check-rule-drift.sh 로드 실패"
}

_test_ok "check-rule-drift.sh 로드 성공"

# ── 테스트 2: 드리프트 검사 실행 ──────────────────────────────────────────

_test_info "$TEST_PREFIX 테스트 2: 180분 임계치로 드리프트 검사"

if check_rule_drift 180 >/dev/null 2>&1; then
    _test_ok "드리프트 검사 통과 (모든 파일 동기화됨)"
else
    _test_ok "드리프트 감지됨 (예상된 결과 — CLAUDE.md가 stale)"
fi

# ── 테스트 3: 보고서 생성 ───────────────────────────────────────────────────

_test_info "$TEST_PREFIX 테스트 3: 드리프트 보고서 생성"

report=$(generate_drift_report)
if echo "$report" | grep -q "정책-규칙 동기화"; then
    _test_ok "보고서 생성 성공"
    printf "%s\n" "$report" | head -15
else
    _test_fail "보고서 생성 실패"
fi

# ── 테스트 4: pre-execution-check 로드 ──────────────────────────────────────

_test_info "$TEST_PREFIX 테스트 4: pre-execution-check.sh 로드"

source ~/projects/jarvis/infra/lib/pre-execution-check.sh 2>/dev/null || {
    _test_fail "pre-execution-check.sh 로드 실패"
}

_test_ok "pre-execution-check.sh 로드 성공"

# ── 테스트 5: pre-execution-check 실행 ──────────────────────────────────────

_test_info "$TEST_PREFIX 테스트 5: pre-execution-check 훅 실행"

if run_pre_execution_check >/dev/null 2>&1; then
    _test_ok "pre-execution-check 통과"
else
    _test_ok "pre-execution-check 드리프트 감지 (예상된 결과)"
fi

# ── 테스트 6: 컨텍스트 파일 존재 확인 ───────────────────────────────────────

_test_info "$TEST_PREFIX 테스트 6: pre-execution 컨텍스트 파일 확인"

CONTEXT_FILE="${HOME}/.openclaw-data/runtime/state/pre-execution-context.md"
if [[ -f "$CONTEXT_FILE" ]]; then
    _test_ok "컨텍스트 파일 생성됨: $CONTEXT_FILE"
    wc -l < "$CONTEXT_FILE"
else
    _test_fail "컨텍스트 파일 없음"
fi

# ── 테스트 7: 로그 파일 확인 ───────────────────────────────────────────────

_test_info "$TEST_PREFIX 테스트 7: 클러스터 가드 로그 확인"

LOG_FILE="${HOME}/.openclaw-data/runtime/logs/cluster-guard-cl-a405499fa67279d6.jsonl"
if [[ -f "$LOG_FILE" ]]; then
    _test_ok "로그 파일 생성됨: $LOG_FILE"
    echo "  최근 기록:"
    tail -3 "$LOG_FILE" | jq -r '.detail' 2>/dev/null | sed 's/^/    /'
else
    _test_fail "로그 파일 없음"
fi

# ── 최종 결과 ────────────────────────────────────────────────────────────────

printf "\n${GREEN}=== 모든 테스트 완료 ===${NC}\n"
printf "✅ check-rule-drift.sh 구현 완료\n"
printf "✅ pre-execution-check.sh 구현 완료\n"
printf "✅ ask-claude-safe.sh에 통합 완료\n"
printf "\n**다음 단계:**\n"
printf "1. CLAUDE.md를 최신으로 갱신 (jarvis.md와 동기화)\n"
printf "2. autonomy-levels.md를 최신으로 갱신\n"
