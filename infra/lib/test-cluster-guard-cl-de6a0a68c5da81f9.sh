#!/bin/bash
# test-cluster-guard-cl-de6a0a68c5da81f9.sh — 클러스터 가드 통합 테스트
#
# 역할:
#   1. 상태 폴링 스크립트 실행 가능성 검증
#   2. 상태 검증 함수가 exit code 반환 확인
#   3. 보고 템플릿 명시적 표현 검증
#   4. 기존 동작 파괴 없음 확인

set -o pipefail

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

log_pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((TESTS_PASSED++))
}

log_fail() {
    echo -e "${RED}✗${NC} $1"
    ((TESTS_FAILED++))
}

log_info() {
    echo -e "${YELLOW}ℹ${NC} $1"
}

# 테스트 1: 스크립트 소싱 가능성
test_sourcing() {
    log_info "Test 1: 스크립트 소싱 가능성"

    if source ~/.jarvis/lib/cluster-guard-cl-de6a0a68c5da81f9.sh 2>/dev/null; then
        log_pass "cluster-guard-cl-de6a0a68c5da81f9.sh 소싱 성공"
    else
        log_fail "cluster-guard-cl-de6a0a68c5da81f9.sh 소싱 실패"
        return 1
    fi

    if source ~/.jarvis/lib/report-template-certified-status.sh 2>/dev/null; then
        log_pass "report-template-certified-status.sh 소싱 성공"
    else
        log_fail "report-template-certified-status.sh 소싱 실패"
        return 1
    fi
}

# 테스트 2: 함수 정의 확인
test_functions() {
    log_info "Test 2: 함수 정의 확인"

    source ~/.jarvis/lib/cluster-guard-cl-de6a0a68c5da81f9.sh 2>/dev/null

    local funcs=(
        "guard_async_upload"
        "guard_async_deploy"
        "guard_async_task"
        "get_guard_status"
        "get_cluster_summary"
        "format_verification_report"
        "list_all_tasks"
        "cleanup_old_reports"
    )

    local all_defined=1
    for fn in "${funcs[@]}"; do
        if declare -f "$fn" >/dev/null 2>&1; then
            log_pass "함수 정의됨: $fn"
        else
            log_fail "함수 미정의: $fn"
            all_defined=0
        fi
    done

    return $((1 - all_defined))
}

# 테스트 3: 상태 폴링 스크립트 exit code 검증
test_exit_codes() {
    log_info "Test 3: Exit code 검증"

    source ~/.jarvis/lib/cluster-guard-cl-de6a0a68c5da81f9.sh 2>/dev/null

    # 잘못된 인자로 호출 시 0이 아닌 exit code 반환
    if get_guard_status 2>&1 | grep -q "ERROR"; then
        log_pass "오류 인자 처리: 오류 메시지 출력"
    else
        log_fail "오류 인자 처리: 오류 메시지 미출력"
    fi

    # 빈 상태 조회 시 exit code 1 반환 (새로운 task_id)
    if ! get_guard_status "nonexistent-task-id" >/dev/null 2>&1; then
        log_pass "미존재 작업 조회: exit code 1 반환"
    else
        log_fail "미존재 작업 조회: exit code 0 반환 (오류)"
    fi
}

# 테스트 4: 보고 템플릿 명시적 표현
test_report_template() {
    log_info "Test 4: 보고 템플릿 명시적 표현"

    source ~/.jarvis/lib/report-template-certified-status.sh 2>/dev/null

    # verified 보고서 작성
    if report_certified_verified "test-cluster" "test-001" "upload" "파일 업로드 완료"; then
        log_pass "Verified 보고서 작성 성공"
    else
        log_fail "Verified 보고서 작성 실패"
        return 1
    fi

    # unverified 보고서 작성
    if report_certified_unverified "test-cluster" "test-002" "deploy" "배포 명령 실행" "완료 미확인"; then
        log_pass "Unverified 보고서 작성 성공"
    else
        log_fail "Unverified 보고서 작성 실패"
        return 1
    fi

    # timeout 보고서 작성
    if report_certified_timeout "test-cluster" "test-003" "async-task" "30"; then
        log_pass "Timeout 보고서 작성 성공"
    else
        log_fail "Timeout 보고서 작성 실패"
        return 1
    fi
}

# 테스트 5: 보고서 내용 검증
test_report_content() {
    log_info "Test 5: 보고서 내용 검증"

    source ~/.jarvis/lib/report-template-certified-status.sh 2>/dev/null

    # verified 보고서 내용 확인
    report_certified_verified "test-cluster" "test-004" "upload" "테스트 메시지" "test"
    local report=$(get_certified_report "test-cluster" "test-004")

    if echo "$report" | jq -e '.certification_badge' | grep -q "검증됨"; then
        log_pass "Verified 보고서: '검증됨' 배지 포함"
    else
        log_fail "Verified 보고서: '검증됨' 배지 미포함"
    fi

    # unverified 보고서 내용 확인
    report_certified_unverified "test-cluster" "test-005" "deploy" "테스트" "미확인"
    report=$(get_certified_report "test-cluster" "test-005")

    if echo "$report" | jq -e '.certification_badge' | grep -q "검증 불가"; then
        log_pass "Unverified 보고서: '검증 불가' 배지 포함"
    else
        log_fail "Unverified 보고서: '검증 불가' 배지 미포함"
    fi

    # timeout 보고서 내용 확인
    report_certified_timeout "test-cluster" "test-006" "async-task" "30"
    report=$(get_certified_report "test-cluster" "test-006")

    if echo "$report" | jq -e '.certification_badge' | grep -q "확인 불가"; then
        log_pass "Timeout 보고서: '확인 불가' 배지 포함"
    else
        log_fail "Timeout 보고서: '확인 불가' 배지 미포함"
    fi
}

# 테스트 6: 기존 async-work-guard 호환성
test_existing_compatibility() {
    log_info "Test 6: 기존 async-work-guard 호환성"

    # async-work-guard.sh 소싱 가능성
    if source ~/.jarvis/lib/async-work-guard.sh 2>/dev/null; then
        log_pass "async-work-guard.sh 호환성 확인"
    else
        log_fail "async-work-guard.sh 호환성 실패"
    fi

    # async-task-poller.sh 소싱 가능성
    if source ~/.jarvis/lib/async-task-poller.sh 2>/dev/null; then
        log_pass "async-task-poller.sh 호환성 확인"
    else
        log_fail "async-task-poller.sh 호환성 실패"
    fi
}

# 테스트 7: 정리 함수 검증
test_cleanup() {
    log_info "Test 7: 정리 함수 검증"

    source ~/.jarvis/lib/cluster-guard-cl-de6a0a68c5da81f9.sh 2>/dev/null
    source ~/.jarvis/lib/report-template-certified-status.sh 2>/dev/null

    # 테스트 데이터 작성
    report_certified_verified "cleanup-test" "task-001" "test" "테스트"

    # 정리 함수 실행
    if cleanup_old_reports 0 >/dev/null 2>&1; then
        log_pass "정리 함수 실행 성공 (오래된 기록 삭제)"
    else
        log_fail "정리 함수 실행 실패"
    fi
}

# 메인
main() {
    echo "=========================================="
    echo "클러스터 가드 cl-de6a0a68c5da81f9 통합 테스트"
    echo "=========================================="
    echo ""

    test_sourcing
    echo ""

    test_functions
    echo ""

    test_exit_codes
    echo ""

    test_report_template
    echo ""

    test_report_content
    echo ""

    test_existing_compatibility
    echo ""

    test_cleanup
    echo ""

    echo "=========================================="
    echo "테스트 결과: ${GREEN}${TESTS_PASSED} 통과${NC} / ${RED}${TESTS_FAILED} 실패${NC}"
    echo "=========================================="

    if [ "$TESTS_FAILED" -eq 0 ]; then
        echo -e "${GREEN}✓ 모든 테스트 통과${NC}"
        return 0
    else
        echo -e "${RED}✗ 일부 테스트 실패${NC}"
        return 1
    fi
}

main "$@"
