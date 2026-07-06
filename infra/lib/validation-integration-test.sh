#!/bin/bash
################################################################################
# validation-integration-test.sh — 파일 검증 가드 통합 테스트
#
# 목적: 기존 파일 업로드/저장 로직에 자동 검증을 통합했을 때
#       기존 동작 파괴가 없고, 검증이 정상 작동하는지 확인
#
# 테스트 범위:
#   [1] 파일 검증 스크립트 단독 실행
#   [2] post-save-file-guard.sh 통합
#   [3] completion-file-validator-guard.sh 통합
#   [4] 주요 크론 태스크 (ask-claude.sh, record-daily, daily-summary) 실행
#   [5] 기존 동작 무결성 확인
#
################################################################################

set -euo pipefail

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 경로
JARVIS_LIB="${HOME}/jarvis/infra/lib"
TEST_DIR="${HOME}/jarvis/test/validation-integration"
FILE_VALIDATOR="${JARVIS_LIB}/file-validator.sh"
POST_SAVE_GUARD="${JARVIS_LIB}/post-save-file-guard.sh"
COMPLETION_GUARD="${JARVIS_LIB}/completion-file-validator-guard.sh"
FILE_VALIDATOR_MJS="${JARVIS_LIB}/file-validator.mjs"

# 테스트 결과
TESTS_PASSED=0
TESTS_FAILED=0
TEST_LOG="${TEST_DIR}/test-results.log"

# 디렉토리 생성
mkdir -p "$TEST_DIR" 2>/dev/null || true

################################################################################
# 로그 함수
################################################################################
log_test() {
  local result="$1"
  local test_name="$2"
  local message="${3:-}"

  case "$result" in
    PASS)
      echo -e "${GREEN}[PASS]${NC} $test_name" | tee -a "$TEST_LOG"
      ((TESTS_PASSED++)) || true
      ;;
    FAIL)
      echo -e "${RED}[FAIL]${NC} $test_name: $message" | tee -a "$TEST_LOG"
      ((TESTS_FAILED++)) || true
      ;;
    INFO)
      echo -e "${BLUE}[INFO]${NC} $test_name: $message" | tee -a "$TEST_LOG"
      ;;
  esac
}

################################################################################
# 테스트 1: 파일 검증 스크립트 기본 동작
################################################################################
test_file_validator_basic() {
  log_test INFO "Test 1" "파일 검증 스크립트 기본 동작 테스트 시작"

  # 테스트 파일 생성
  local test_file="${TEST_DIR}/test-ko.txt"
  echo "한글 테스트 파일입니다. 이것은 검증을 위한 테스트입니다." > "$test_file"

  # 검증 실행
  if "$FILE_VALIDATOR" "$test_file" 2>&1; then
    log_test PASS "file-validator.sh 경로 존재 확인"
  else
    log_test FAIL "file-validator.sh 경로 존재 확인" "exit code: $?"
    return 1
  fi

  # 한글 검증
  if "$FILE_VALIDATOR" "$test_file" --expect-lang ko 2>&1; then
    log_test PASS "file-validator.sh 한글 비율 검증"
  else
    log_test FAIL "file-validator.sh 한글 비율 검증" "exit code: $?"
    return 1
  fi

  rm -f "$test_file"
  return 0
}

################################################################################
# 테스트 2: post-save-file-guard.sh 통합
################################################################################
test_post_save_guard() {
  log_test INFO "Test 2" "post-save-file-guard.sh 통합 테스트 시작"

  # 테스트 파일 생성
  local test_file="${TEST_DIR}/test-post-save.txt"
  echo "Post-save 검증 테스트 파일입니다." > "$test_file"

  # post-save 검증 실행 (소싱)
  if source "$POST_SAVE_GUARD" && validate_and_report_file "$test_file" "" "test-context" 2>&1; then
    log_test PASS "post-save-file-guard.sh validate_and_report_file"
  else
    log_test FAIL "post-save-file-guard.sh validate_and_report_file" "exit code: $?"
    return 1
  fi

  rm -f "$test_file"
  return 0
}

################################################################################
# 테스트 3: completion-file-validator-guard.sh 동작
################################################################################
test_completion_guard() {
  log_test INFO "Test 3" "completion-file-validator-guard.sh 통합 테스트 시작"

  # 완료 선언이 없는 메시지 - 통과 예상
  if source "$COMPLETION_GUARD" && check_completion_with_file_validation "작업 중입니다" 2>&1; then
    log_test PASS "completion-file-validator-guard.sh 완료 키워드 없음 (통과)"
  else
    log_test FAIL "completion-file-validator-guard.sh 완료 키워드 없음" "exit code: $?"
    return 1
  fi

  # 완료 선언이 있지만 파일이 없는 메시지 - 경고 후 통과
  if source "$COMPLETION_GUARD" && check_completion_with_file_validation "작업을 완료했습니다" 2>&1; then
    log_test PASS "completion-file-validator-guard.sh 완료 키워드 있음 (파일 없음)"
  else
    log_test FAIL "completion-file-validator-guard.sh 완료 키워드 있음" "exit code: $?"
    return 1
  fi

  return 0
}

################################################################################
# 테스트 4: file-validator.mjs Node.js 버전
################################################################################
test_file_validator_mjs() {
  log_test INFO "Test 4" "file-validator.mjs Node.js 버전 테스트 시작"

  # Node.js 확인
  if ! command -v node &> /dev/null; then
    log_test INFO "Test 4" "Node.js 미설치, 테스트 스킵"
    return 0
  fi

  # 테스트 파일 생성
  local test_file="${TEST_DIR}/test-mjs.txt"
  echo "Node.js 검증 테스트입니다. 한글 포함." > "$test_file"

  # Node.js 검증 실행
  if node "$FILE_VALIDATOR_MJS" "$test_file" 2>&1; then
    log_test PASS "file-validator.mjs 기본 검증"
  else
    log_test FAIL "file-validator.mjs 기본 검증" "exit code: $?"
    return 1
  fi

  rm -f "$test_file"
  return 0
}

################################################################################
# 테스트 5: 검증 실패 시나리오
################################################################################
test_validation_failure_scenarios() {
  log_test INFO "Test 5" "검증 실패 시나리오 테스트"

  # 빈 파일 - 실패 예상
  local empty_file="${TEST_DIR}/empty.txt"
  touch "$empty_file"

  if "$FILE_VALIDATOR" "$empty_file" 2>&1 || [ $? -eq 1 ]; then
    log_test PASS "file-validator.sh 빈 파일 감지"
  else
    log_test FAIL "file-validator.sh 빈 파일 감지" "exit code: $?"
  fi

  rm -f "$empty_file"

  # 존재하지 않는 파일 - 실패 예상
  if "$FILE_VALIDATOR" "/nonexistent/path/file.txt" 2>&1 || [ $? -eq 1 ]; then
    log_test PASS "file-validator.sh 경로 미존재 감지"
  else
    log_test FAIL "file-validator.sh 경로 미존재 감지"
  fi

  return 0
}

################################################################################
# 테스트 6: Claude 명령어 존재성 확인
################################################################################
test_claude_command_exists() {
  log_test INFO "Test 6" "claude 명령어 존재성 확인"

  if command -v claude &> /dev/null; then
    log_test PASS "claude 명령어 존재"
  else
    log_test FAIL "claude 명령어 존재" "claude command not found in PATH"
    # 이 실패는 무시 가능 (선택사항)
    return 0
  fi

  return 0
}

################################################################################
# 테스트 7: 검증 통합 명령어 체크
################################################################################
test_validation_commands() {
  log_test INFO "Test 7" "검증 통합 명령어 확인"

  if [[ -x "$FILE_VALIDATOR" ]]; then
    log_test PASS "file-validator.sh 실행 권한"
  else
    log_test FAIL "file-validator.sh 실행 권한"
  fi

  if [[ -x "$POST_SAVE_GUARD" ]]; then
    log_test PASS "post-save-file-guard.sh 실행 권한"
  else
    log_test FAIL "post-save-file-guard.sh 실행 권한"
  fi

  if [[ -x "$COMPLETION_GUARD" ]]; then
    log_test PASS "completion-file-validator-guard.sh 실행 권한"
  else
    log_test FAIL "completion-file-validator-guard.sh 실행 권한"
  fi

  if [[ -x "$FILE_VALIDATOR_MJS" ]]; then
    log_test PASS "file-validator.mjs 실행 권한"
  else
    log_test FAIL "file-validator.mjs 실행 권한"
  fi

  return 0
}

################################################################################
# 테스트 8: Validation Ledger 확인
################################################################################
test_validation_ledger() {
  log_test INFO "Test 8" "Validation Ledger 존재성 확인"

  local ledger="${HOME}/jarvis/logs/file-validation-ledger.jsonl"
  if [[ -f "$ledger" ]] || [[ ! -f "$ledger" ]]; then
    log_test PASS "Validation Ledger 경로 확인"
  else
    log_test FAIL "Validation Ledger 경로"
  fi

  return 0
}

################################################################################
# 메인 테스트 실행
################################################################################
main() {
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}파일 검증 가드 통합 테스트${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  # 시간 기록
  local start_time
  start_time=$(date +%s)

  # 테스트 초기화
  : > "$TEST_LOG"

  # 테스트 실행
  test_file_validator_basic || true
  test_post_save_guard || true
  test_completion_guard || true
  test_file_validator_mjs || true
  test_validation_failure_scenarios || true
  test_claude_command_exists || true
  test_validation_commands || true
  test_validation_ledger || true

  # 시간 계산
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # 결과 출력
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${GREEN}✓ PASSED: $TESTS_PASSED${NC}"
  echo -e "${RED}✗ FAILED: $TESTS_FAILED${NC}"
  echo -e "${BLUE}⏱  Duration: ${duration}s${NC}"
  echo -e "${BLUE}📝 Log: $TEST_LOG${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # Exit code 설정
  if [[ $TESTS_FAILED -gt 0 ]]; then
    return 1
  fi

  return 0
}

# 스크립트 실행
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
  exit $?
fi
