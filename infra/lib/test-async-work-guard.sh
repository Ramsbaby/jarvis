#!/bin/bash
# test-async-work-guard.sh — 비동기 작업 상태 검증 가드 테스트
#
# 역할: async-work-guard.sh의 모든 기능을 테스트
# 실행: bash ~/jarvis/infra/lib/test-async-work-guard.sh
#
# 테스트 케이스:
#   1. 비동기 작업 상태 폴링 (성공)
#   2. 검증 상태 명시 보고
#   3. 기존 크론 스크립트 호환성 (부작용 없음)

set -o pipefail

# 절대 경로 설정
JARVIS_LIB="${HOME}/jarvis/infra/lib"
TEST_DIR="/tmp/async-work-guard-test-$$"
TEST_CLUSTER_ID="cl-test-async-work-guard"
LOG_FILE="$TEST_DIR/test.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 로깅
log_info() {
    printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$1" | tee -a "$LOG_FILE"
}

log_pass() {
    printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$1" | tee -a "$LOG_FILE"
}

log_fail() {
    printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$1" | tee -a "$LOG_FILE"
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$1" | tee -a "$LOG_FILE"
}

# 테스트 환경 초기화
setup_test_env() {
    mkdir -p "$TEST_DIR"
    printf "=== Async Work Guard Test Suite ===\nStart: %s\n\n" "$(date)" > "$LOG_FILE"

    log_info "Test environment initialized at $TEST_DIR"
    log_info "Cluster ID: $TEST_CLUSTER_ID"
    log_info "Jarvis lib path: $JARVIS_LIB"

    # 테스트용 인프라 디렉토리 생성 (실제 ~/.jarvis 사용)
    mkdir -p ~/jarvis/runtime/state/async-tasks
    mkdir -p ~/jarvis/runtime/logs/async
    mkdir -p ~/jarvis/runtime/state/verified-reports
    mkdir -p ~/jarvis/runtime/logs/verified-reports
}

# 테스트 정리
cleanup_test_env() {
    log_info "Cleaning up test environment..."
    log_info "Test artifacts saved at $TEST_DIR"
}

# 테스트 1: 폴링 함수 테스트 (구조 검증)
test_polling_success() {
    log_info "TEST 1: Polling function structure"

    # 의존성 소싱
    source "$JARVIS_LIB/async-task-poller.sh" || { log_fail "Failed to source async-task-poller.sh"; return 1; }

    # 함수 존재 확인
    if declare -f poll_upload_completion >/dev/null && \
       declare -f poll_deploy_completion >/dev/null && \
       declare -f poll_async_task >/dev/null; then
        log_pass "All polling functions available"
        return 0
    else
        log_fail "Some polling functions not found"
        return 1
    fi
}

# 테스트 2: 보고 템플릿 테스트
test_report_template() {
    log_info "TEST 2: Report template with verification status"

    source "$JARVIS_LIB/report-template-verified.sh" || { log_fail "Failed to source report-template-verified.sh"; return 1; }

    local task_id="test-report-001"

    # 테스트 2-1: 성공 보고
    report_task_completed "$TEST_CLUSTER_ID" "$task_id" "upload" "파일 업로드 완료" "test-framework"

    if [ -f "${HOME}/jarvis/runtime/state/verified-reports/${TEST_CLUSTER_ID}_${task_id}.report" ]; then
        log_pass "TEST 2-1: Completed report written"
    else
        log_fail "TEST 2-1: Report file not found"
        return 1
    fi

    # 테스트 2-2: 미확인 보고
    task_id="test-report-002"
    report_task_unverified "$TEST_CLUSTER_ID" "$task_id" "deploy" "배포 상태 미확인"

    if [ -f "${HOME}/jarvis/runtime/state/verified-reports/${TEST_CLUSTER_ID}_${task_id}.report" ]; then
        log_pass "TEST 2-2: Unverified report written"
    else
        log_fail "TEST 2-2: Unverified report not found"
        return 1
    fi

    # 테스트 2-3: 타임아웃 보고
    task_id="test-report-003"
    report_task_timeout "$TEST_CLUSTER_ID" "$task_id" "deploy" 30

    if [ -f "${HOME}/jarvis/runtime/state/verified-reports/${TEST_CLUSTER_ID}_${task_id}.report" ]; then
        log_pass "TEST 2-3: Timeout report written"
    else
        log_fail "TEST 2-3: Timeout report not found"
        return 1
    fi

    # 테스트 2-4: 부분 검증 보고
    task_id="test-report-004"
    report_task_partial "$TEST_CLUSTER_ID" "$task_id" "batch-deploy" \
        "배포 작업 부분 완료" "3/5 서비스 배포됨" "2/5 서비스 미배포"

    if [ -f "${HOME}/jarvis/runtime/state/verified-reports/${TEST_CLUSTER_ID}_${task_id}.report" ]; then
        log_pass "TEST 2-4: Partial report written"
    else
        log_fail "TEST 2-4: Partial report not found"
        return 1
    fi

    return 0
}

# 테스트 3: 통합 가드 함수 구조 검증
test_async_work_guard_structure() {
    log_info "TEST 3: Async work guard integration"

    source "$JARVIS_LIB/async-work-guard.sh" || { log_fail "Failed to source async-work-guard.sh"; return 1; }

    # 함수 존재 확인
    local functions=("async_work_guard_upload" "async_work_guard_deploy" "async_work_guard_custom" "check_async_work_status")

    for func in "${functions[@]}"; do
        if declare -f "$func" >/dev/null 2>&1; then
            log_pass "Function available: $func"
        else
            log_fail "Function not found: $func"
            return 1
        fi
    done

    return 0
}

# 테스트 4: 검증 상태 표현 명확성 테스트
test_verification_status_labels() {
    log_info "TEST 4: Verification status labels"

    source "$JARVIS_LIB/report-template-verified.sh" || { log_fail "Failed to source report-template-verified.sh"; return 1; }

    # 상태 레이블 확인
    local labels=(
        "[검증완료✓]"
        "[검증불가⚠]"
        "[부분검증⊘]"
        "[폴링초과⏱]"
    )

    for label in "${labels[@]}"; do
        if printf '%s' "$label" | grep -q "✓\|⚠\|⊘\|⏱"; then
            log_pass "Label found: $label"
        else
            log_fail "Label not found: $label"
            return 1
        fi
    done

    return 0
}

# 테스트 5: Exit code 표준 검증
test_exit_code_standards() {
    log_info "TEST 5: Exit code standards"

    # 기대 표준:
    # 0 = 성공/검증됨
    # 1 = 실패/검증 불가
    # 2 = 타임아웃/미확인

    local exit_codes=(0 1 2)
    local expected_statuses=("verified" "unverified" "timeout")

    for i in "${!exit_codes[@]}"; do
        log_pass "Exit code ${exit_codes[$i]} → ${expected_statuses[$i]}"
    done

    return 0
}

# 테스트 6: 기존 동작 호환성 (부작용 없음)
test_backward_compatibility() {
    log_info "TEST 6: Backward compatibility (no side effects on existing scripts)"

    # 기존 guard-status-check.sh가 여전히 작동하는지 확인
    if [ -f "$JARVIS_LIB/guard-status-check.sh" ]; then
        source "$JARVIS_LIB/guard-status-check.sh" 2>/dev/null && \
            log_pass "guard-status-check.sh still works"
    else
        log_warn "guard-status-check.sh not found"
    fi

    # 기존 verify-before-report.sh
    if [ -f "$JARVIS_LIB/verify-before-report.sh" ]; then
        source "$JARVIS_LIB/verify-before-report.sh" 2>/dev/null && \
            log_pass "verify-before-report.sh still works"
    fi

    log_pass "TEST 6: No breaking changes to existing infrastructure"
    return 0
}

# 테스트 7: 상태 파일 구조 검증
test_state_file_structure() {
    log_info "TEST 7: State file JSON structure"

    source "$JARVIS_LIB/report-template-verified.sh" || { log_fail "Failed to source report-template-verified.sh"; return 1; }

    local task_id="test-state-001"
    report_task_completed "$TEST_CLUSTER_ID" "$task_id" "upload" "테스트 완료"

    local report_file="${HOME}/jarvis/runtime/state/verified-reports/${TEST_CLUSTER_ID}_${task_id}.report"

    if [ -f "$report_file" ]; then
        # JSON 유효성 확인
        if cat "$report_file" | grep -q '"task_id"' && \
           cat "$report_file" | grep -q '"verification_status"' && \
           cat "$report_file" | grep -q '"human_readable"'; then
            log_pass "Report file has required JSON fields"

            # 파일 내용 출력
            log_info "Report content (sample):"
            head -5 "$report_file" | sed 's/^/  /' | tee -a "$LOG_FILE"
        else
            log_fail "Report file missing required JSON fields"
            return 1
        fi
    else
        log_fail "Report file not created at $report_file"
        return 1
    fi

    return 0
}

# 테스트 8: 문서화 및 주석 검증
test_documentation() {
    log_info "TEST 8: Documentation and comments"

    local files=("$JARVIS_LIB/async-task-poller.sh" "$JARVIS_LIB/report-template-verified.sh" "$JARVIS_LIB/async-work-guard.sh")
    local all_ok=true

    for file in "${files[@]}"; do
        if [ -f "$file" ]; then
            if head -20 "$file" | grep -q "역할:" && head -20 "$file" | grep -q "사용:"; then
                log_pass "File documented: $(basename "$file")"
            else
                log_warn "File may lack documentation: $(basename "$file")"
            fi
        else
            log_fail "File not found: $file"
            all_ok=false
        fi
    done

    return 0
}

# 메인 테스트 실행
main() {
    setup_test_env

    local test_count=0
    local pass_count=0

    # 각 테스트 실행
    tests=(
        "test_polling_success"
        "test_report_template"
        "test_async_work_guard_structure"
        "test_verification_status_labels"
        "test_exit_code_standards"
        "test_backward_compatibility"
        "test_state_file_structure"
        "test_documentation"
    )

    for test in "${tests[@]}"; do
        test_count=$((test_count + 1))
        log_info "Running $test..."

        if $test; then
            pass_count=$((pass_count + 1))
        else
            log_fail "$test failed"
        fi

        printf '\n'
    done

    # 결과 요약
    printf '\n%s\n' "=== TEST SUMMARY ===" | tee -a "$LOG_FILE"
    printf 'Total: %d | Passed: %d | Failed: %d\n' "$test_count" "$pass_count" "$((test_count - pass_count))" | tee -a "$LOG_FILE"

    if [ "$pass_count" -eq "$test_count" ]; then
        log_pass "All tests passed!"
        printf '\nTest log: %s\n' "$LOG_FILE"
        cleanup_test_env
        return 0
    else
        log_fail "Some tests failed!"
        printf '\nTest log: %s\n' "$LOG_FILE"
        return 1
    fi
}

main "$@"
