#!/bin/bash
# test-cluster-guard-cl-3e0048f79eb206f9.sh — 클러스터 가드 테스트 스위트
#
# 사용:
#   bash ~/.jarvis/lib/test-cluster-guard-cl-3e0048f79eb206f9.sh

set -euo pipefail

# 컬러 출력
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 의존성
source ~/.jarvis/lib/cluster-guard-cl-3e0048f79eb206f9.sh 2>/dev/null || {
    echo -e "${RED}ERROR: cluster-guard script not found${NC}" >&2
    exit 1
}

# 테스트 추적
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# 헬퍼: 테스트 케이스 실행
run_test() {
    local test_name="$1"
    local test_fn="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "\n${BLUE}[Test $TESTS_RUN]${NC} $test_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if $test_fn; then
        echo -e "${GREEN}✓ PASSED${NC}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗ FAILED${NC}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# 헬퍼: 테스트 어설션
assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-Assertion failed}"

    if [[ "$expected" == "$actual" ]]; then
        echo "  ✓ $msg"
        return 0
    else
        echo -e "  ${RED}✗ $msg${NC}"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
        return 1
    fi
}

assert_exit_code() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-Exit code assertion failed}"

    if [[ "$expected" == "$actual" ]]; then
        echo "  ✓ $msg"
        return 0
    else
        echo -e "  ${RED}✗ $msg${NC}"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
        return 1
    fi
}

# ───────────────────────────────────────────────────
# 테스트 케이스
# ───────────────────────────────────────────────────

# Test 1: DB 초기화
test_db_initialization() {
    echo "  1. DB 파일 생성 확인"

    # 기존 DB 제거 (테스트용)
    rm -f ~/jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db

    # 초기화 함수 호출
    _init_sqlite_db

    # DB 파일 존재 여부 확인
    if [[ -f ~/jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db ]]; then
        echo "  ✓ DB 파일 생성됨"
    else
        echo -e "  ${RED}✗ DB 파일 생성 실패${NC}"
        return 1
    fi

    echo "  2. 테이블 스키마 확인"
    local schema
    schema=$(sqlite3 ~/jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db ".tables" 2>/dev/null || echo "")

    if [[ "$schema" == *"task_state"* ]]; then
        echo "  ✓ task_state 테이블 생성됨"
        return 0
    else
        echo -e "  ${RED}✗ task_state 테이블 미생성${NC}"
        return 1
    fi
}

# Test 2: 새로운 명령 감지
test_new_command_detection() {
    echo "  1. 새로운 명령 감지"

    local cmd_text="Test command for new detection"
    local result
    result=$(check_command_duplicate "$cmd_text" 2>/dev/null || echo "error")

    local status_code
    IFS=':' read -r status_code _ _ <<< "$result"

    assert_exit_code "0" "$status_code" "새로운 명령 상태코드 = 0" || return 1
    echo "  ✓ 새로운 명령 정상 감지"

    return 0
}

# Test 3: 명령 시작 기록
test_record_command_start() {
    echo "  1. 명령 시작 기록"

    local cmd_text="Test command for recording"
    local cmd_hash
    cmd_hash=$(_get_command_hash "$cmd_text")

    # 새 명령 먼저 확인
    check_command_duplicate "$cmd_text" > /dev/null 2>&1 || true

    # 시작 기록
    record_command_start "$cmd_hash" "$cmd_text"
    echo "  ✓ 명령 시작 기록됨"

    # 상태 조회
    echo "  2. 상태 조회"
    local status
    status=$(get_command_status "$cmd_hash" | awk -F'|' '{print $2}' | tr -d ' ' || echo "unknown")

    if [[ "$status" == "running" ]]; then
        echo "  ✓ 명령 상태 = running"
        return 0
    else
        echo -e "  ${RED}✗ 명령 상태 = $status (expected: running)${NC}"
        return 1
    fi
}

# Test 4: 중복 명령 감지 (실행 중)
test_duplicate_command_running() {
    echo "  1. 중복 명령 감지 (진행 중)"

    local cmd_text="Test command for duplicate detection"
    local cmd_hash
    cmd_hash=$(_get_command_hash "$cmd_text")

    # 첫 번째 호출 (새 명령)
    check_command_duplicate "$cmd_text" > /dev/null 2>&1 || true

    # 시작 기록
    record_command_start "$cmd_hash" "$cmd_text"
    echo "  ✓ 첫 번째 명령 시작됨"

    # 두 번째 호출 (중복)
    echo "  2. 동일 명령 재호출"
    local result
    result=$(check_command_duplicate "$cmd_text" 2>/dev/null || echo "error")

    local status_code
    IFS=':' read -r status_code _ _ <<< "$result"

    assert_exit_code "1" "$status_code" "중복 명령 상태코드 = 1 (진행중)" || return 1
    echo "  ✓ 중복 명령 정상 감지"

    return 0
}

# Test 5: 명령 완료 기록
test_record_command_result() {
    echo "  1. 명령 완료 기록"

    local cmd_text="Test command for result recording"
    local cmd_hash
    cmd_hash=$(_get_command_hash "$cmd_text")

    # 새 명령 확인
    check_command_duplicate "$cmd_text" > /dev/null 2>&1 || true

    # 시작 기록
    record_command_start "$cmd_hash" "$cmd_text"

    # 완료 기록
    record_command_result "$cmd_hash" '{"result":"success","time":"2026-07-16"}' "true"
    echo "  ✓ 명령 결과 기록됨"

    # 상태 조회
    echo "  2. 완료 상태 확인"
    local status
    status=$(get_command_status "$cmd_hash" | awk -F'|' '{print $2}' | tr -d ' ' || echo "unknown")

    if [[ "$status" == "completed" ]]; then
        echo "  ✓ 명령 상태 = completed"
        return 0
    else
        echo -e "  ${RED}✗ 명령 상태 = $status (expected: completed)${NC}"
        return 1
    fi
}

# Test 6: 완료된 명령 재호출
test_duplicate_command_completed() {
    echo "  1. 완료된 명령 재호출"

    local cmd_text="Test command for completed duplicate"
    local cmd_hash
    cmd_hash=$(_get_command_hash "$cmd_text")

    # 새 명령 확인
    check_command_duplicate "$cmd_text" > /dev/null 2>&1 || true

    # 시작 및 완료 기록
    record_command_start "$cmd_hash" "$cmd_text"
    record_command_result "$cmd_hash" '{"result":"done"}' "true"
    echo "  ✓ 명령 완료됨"

    # 재호출
    echo "  2. 동일 명령 재호출"
    local result
    result=$(check_command_duplicate "$cmd_text" 2>/dev/null || echo "error")

    local status_code
    IFS=':' read -r status_code _ _ <<< "$result"

    assert_exit_code "2" "$status_code" "완료된 명령 상태코드 = 2" || return 1
    echo "  ✓ 완료된 명령 정상 감지"

    return 0
}

# Test 7: 해시 생성 일관성
test_hash_consistency() {
    echo "  1. 해시 일관성 확인"

    local cmd_text="Test command for hash consistency"
    local hash1 hash2

    hash1=$(_get_command_hash "$cmd_text")
    hash2=$(_get_command_hash "$cmd_text")

    assert_eq "$hash1" "$hash2" "동일 명령의 해시가 일치" || return 1
    echo "  ✓ 해시 생성 일관성 확인됨"

    return 0
}

# Test 8: 진행 중인 명령 조회
test_list_pending_commands() {
    echo "  1. 진행 중인 명령 조회"

    local cmd_text="Test command for pending list"
    local cmd_hash
    cmd_hash=$(_get_command_hash "$cmd_text")

    # 새 명령 확인
    check_command_duplicate "$cmd_text" > /dev/null 2>&1 || true

    # 시작 기록
    record_command_start "$cmd_hash" "$cmd_text"

    # 진행 중인 명령 조회
    local pending_list
    pending_list=$(list_pending_commands 2>/dev/null || echo "")

    if [[ "$pending_list" == *"$cmd_hash"* ]]; then
        echo "  ✓ 진행 중인 명령 정상 조회됨"
        return 0
    else
        echo -e "  ${RED}✗ 진행 중인 명령 미조회${NC}"
        echo "  조회 결과: $pending_list"
        return 1
    fi
}

# ───────────────────────────────────────────────────
# 메인: 모든 테스트 실행
# ───────────────────────────────────────────────────

main() {
    echo -e "\n${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Cluster Guard Test Suite: cl-3e0048f79eb206f9${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}\n"

    # 정리: 기존 DB 제거
    echo -e "${YELLOW}[Setup]${NC} 테스트용 DB 초기화"
    rm -f ~/jarvis/runtime/state/command-state-cl-3e0048f79eb206f9.db
    mkdir -p ~/jarvis/runtime/state/cluster-guards

    # 테스트 실행
    run_test "DB 초기화" test_db_initialization
    run_test "새 명령 감지" test_new_command_detection
    run_test "명령 시작 기록" test_record_command_start
    run_test "중복 명령 감지 (진행중)" test_duplicate_command_running
    run_test "명령 완료 기록" test_record_command_result
    run_test "완료된 명령 재호출" test_duplicate_command_completed
    run_test "해시 일관성" test_hash_consistency
    run_test "진행 중인 명령 조회" test_list_pending_commands

    # 결과 요약
    echo -e "\n${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Test Summary${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}\n"

    echo "  Total:  $TESTS_RUN tests"
    echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
    fi

    # 최종 상태 덤프
    echo -e "\n${BLUE}[DB State]${NC}"
    dump_state_db

    # 종료 코드
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}✓ All tests passed!${NC}\n"
        return 0
    else
        echo -e "\n${RED}✗ Some tests failed!${NC}\n"
        return 1
    fi
}

main "$@"
