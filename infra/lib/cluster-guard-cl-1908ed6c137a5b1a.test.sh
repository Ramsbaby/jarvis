#!/bin/bash
# cluster-guard-cl-1908ed6c137a5b1a.test.sh — 오퍼 평가 시장 검증 가드 테스트

set -euo pipefail

# 테스트 환경 설정
export BOT_HOME="${HOME}/.openclaw-data/runtime"
GUARD_LIB="${HOME}/projects/jarvis/infra/lib/cluster-guard-cl-1908ed6c137a5b1a.sh"

# 색상
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 통계
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================================================
# 헬퍼
# ============================================================================

pass() {
  ((TESTS_PASSED++))
  printf "${GREEN}✓${NC} %s\n" "$1"
}

fail() {
  ((TESTS_FAILED++))
  printf "${RED}✗${NC} %s\n" "$1"
}

test_case() {
  ((TESTS_RUN++))
  printf "\n${YELLOW}Test $TESTS_RUN:${NC} %s\n" "$1"
}

# ============================================================================
# 테스트
# ============================================================================

test_case "Load guard library"
if source "$GUARD_LIB" 2>/dev/null; then
  pass "Guard library loaded successfully"
else
  fail "Failed to load guard library"
  exit 1
fi

test_case "Keyword detection: offer evaluation"
if test_keyword_detection "제 연봉은 뭐가 좋을까요?"; then
  pass "Detected offer evaluation keywords"
else
  fail "Failed to detect offer evaluation keywords"
fi

test_case "Keyword detection: salary question"
if test_keyword_detection "내 직급의 시장 기준 연봉이 뭔가요?"; then
  pass "Detected salary/job level keywords"
else
  fail "Failed to detect salary keywords"
fi

test_case "Keyword detection: CTC offer"
if test_keyword_detection "이 오퍼의 CTC가 합리적인가요?"; then
  pass "Detected CTC offer keywords"
else
  fail "Failed to detect CTC keywords"
fi

test_case "Keyword detection: compensation package"
if test_keyword_detection "What's a reasonable compensation package for a Senior Engineer?"; then
  pass "Detected English compensation keywords"
else
  fail "Failed to detect English keywords"
fi

test_case "Non-offer prompt should not trigger"
if ! test_keyword_detection "최근의 Python 트렌드는 뭔가요?"; then
  pass "Correctly ignored non-offer prompt"
else
  fail "Incorrectly triggered on non-offer prompt"
fi

test_case "Guard pre-check: offer evaluation detected"
TASK_ID="test-offer-1"
PROMPT="제가 받은 오퍼: 직급 Senior Engineer, 연봉 \$200k, stock options 포함. 시장 기준 대비 어떤가요?"
guard_offer_eval_pre_check "$TASK_ID" "$PROMPT" 2>/dev/null || true
_GUARD_RESULT=$(get_guard_status 2>/dev/null || echo "triggered=false")
if [[ "$_GUARD_RESULT" == *"triggered=true"* ]]; then
  pass "Guard successfully triggered on offer evaluation"
else
  fail "Guard triggered but status not set correctly: $_GUARD_RESULT"
fi

test_case "Market context section generation"
TASK_ID="test-offer-2"
PROMPT="오퍼 평가: Software Engineer 직급, 연봉 \$150k"
guard_offer_eval_pre_check "$TASK_ID" "$PROMPT" 2>/dev/null || true
CONTEXT=$(get_market_context_section 2>/dev/null) || CONTEXT=""
if [[ -n "$CONTEXT" ]]; then
  if echo "$CONTEXT" | grep -q "시장 데이터"; then
    pass "Market context section generated with expected content"
  else
    fail "Context section generated but missing expected content"
  fi
else
  fail "Failed to generate market context section"
fi

test_case "Guard statistics initialization"
if [[ -f "${BOT_HOME}/state/cluster-guards/cl-1908ed6c137a5b1a-state.json" ]]; then
  if grep -q "total_triggers" "${BOT_HOME}/state/cluster-guards/cl-1908ed6c137a5b1a-state.json"; then
    pass "Guard state initialized correctly"
  else
    fail "Guard state file exists but missing expected fields"
  fi
else
  fail "Guard state file not created"
fi

test_case "Cache directory creation"
if [[ -d "${BOT_HOME}/state/cluster-guards/cl-1908ed6c137a5b1a-cache" ]]; then
  pass "Cache directory created"
else
  fail "Cache directory not created"
fi

test_case "Market query logging"
TASK_ID="test-offer-3"
PROMPT="오퍼: Senior Developer, \$180k"
guard_offer_eval_pre_check "$TASK_ID" "$PROMPT" 2>/dev/null || true
if [[ -f "${BOT_HOME}/state/cluster-guards/cl-1908ed6c137a5b1a-market-queries.jsonl" ]]; then
  _LOG_LINES=$(wc -l < "${BOT_HOME}/state/cluster-guards/cl-1908ed6c137a5b1a-market-queries.jsonl" || echo 0)
  if [[ $_LOG_LINES -gt 0 ]]; then
    pass "Market queries logged to JSONL file"
  else
    fail "Log file exists but is empty"
  fi
else
  fail "Log file not created"
fi

# ============================================================================
# 최종 결과
# ============================================================================

printf "\n${YELLOW}=============================${NC}\n"
printf "Tests run:    $TESTS_RUN\n"
printf "${GREEN}Passed:       $TESTS_PASSED${NC}\n"
if [[ $TESTS_FAILED -gt 0 ]]; then
  printf "${RED}Failed:       $TESTS_FAILED${NC}\n"
else
  printf "Failed:       $TESTS_FAILED\n"
fi
printf "${YELLOW}=============================${NC}\n"

if [[ $TESTS_FAILED -eq 0 ]]; then
  printf "${GREEN}All tests passed!${NC}\n"
  exit 0
else
  printf "${RED}Some tests failed.${NC}\n"
  exit 1
fi
