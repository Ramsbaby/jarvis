#!/usr/bin/env bash
# validate-root-cause-guard.sh — 근본원인 검증 가드 호환성 검증
#
# Purpose:
#   - 가드 스크립트 단독 테스트
#   - ask-claude.sh 통합 테스트
#   - 기존 정상 태스크 호환성 검증
#
# Usage: bash validate-root-cause-guard.sh [test-type]
#   test-type: unit / integration / compatibility / all (기본값: all)

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_CAUSE_VALIDATOR="${BOT_HOME}/lib/root-cause-validator.sh"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Test counters ---
PASS=0
FAIL=0

# --- Helper functions ---
test_unit() {
    local test_name="$1"
    local task_id="$2"
    local result="$3"
    local expected_verdict="$4"

    printf "\n${BLUE}[Unit Test]${NC} %s\n" "$test_name"

    # Run validator
    "$ROOT_CAUSE_VALIDATOR" "$task_id" "$result" >/tmp/test-output.txt 2>&1 || true
    output=$(cat /tmp/test-output.txt)

    # Extract verdict from output
    actual_verdict=$(echo "$output" | grep -o 'verdict=[^ ]*' | cut -d= -f2 || echo "unknown")

    if [[ "$actual_verdict" == "$expected_verdict" ]]; then
        printf "${GREEN}✓ PASS${NC} (verdict: %s)\n" "$actual_verdict"
        (( PASS++ )) || true
    else
        printf "${RED}✗ FAIL${NC} (expected: %s, got: %s)\n" "$expected_verdict" "$actual_verdict"
        printf "  Output: %s\n" "$output"
        (( FAIL++ )) || true
    fi
}

test_compatibility() {
    local test_name="$1"
    local task_id="$2"

    printf "\n${BLUE}[Compatibility Test]${NC} %s\n" "$test_name"

    # Test that monitoring tasks are excluded
    if [[ "$task_id" == *health* ]] || [[ "$task_id" == *summary* ]]; then
        "$ROOT_CAUSE_VALIDATOR" "$task_id" "모니터링 결과" >/tmp/test-output.txt 2>&1 || true
        output=$(cat /tmp/test-output.txt)
        actual_verdict=$(echo "$output" | grep -o 'verdict=[^ ]*' | cut -d= -f2 || echo "unknown")

        # Should pass (validation excluded for monitoring tasks)
        if [[ "$actual_verdict" == "pass" ]]; then
            printf "${GREEN}✓ PASS${NC} (monitoring task excluded, verdict: pass)\n"
            (( PASS++ )) || true
        else
            printf "${RED}✗ FAIL${NC} (expected pass for monitoring, got: %s)\n" "$actual_verdict"
            (( FAIL++ )) || true
        fi
    fi
}

# --- Unit Tests ---
run_unit_tests() {
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  UNIT TESTS: 근본원인 검증 로직"
    echo "════════════════════════════════════════════════════════"

    # Test 1: 근본분석 충분 (pass)
    test_unit \
        "근본분석 충분: 근본원인 + 분석 + 정당성" \
        "bug-fix-test" \
        "근본 원인은 메모리 누수입니다. 이를 분석한 결과 malloc 호출 후 free가 누락되었습니다. 따라서 이를 수정하면 문제가 해결됩니다." \
        "pass"

    # Test 2: 근본분석 없음 (block)
    test_unit \
        "근본분석 없음: 억제패턴만 있음" \
        "bug-fix-test" \
        "타임아웃 값을 60초에서 120초로 조정했습니다." \
        "block"

    # Test 3: 부분분석 (warn)
    test_unit \
        "부분분석: 원인 언급만 + 문제분석 부족" \
        "debug-test" \
        "네트워크 연결 문제가 원인인 것 같습니다. 임시로 타임아웃을 늘렸습니다." \
        "warn"  # 마커 1개 + 문제분석 부족 = warn

    # Test 4: 다단계 인과 분석
    test_unit \
        "다단계 인과분석: 명확한 5-why 구조" \
        "troubleshoot-test" \
        "메모리 누수 문제가 발생했습니다. 원인은 이벤트 리스너가 정리되지 않기 때문입니다. 이로 인해 메모리가 계속 증가합니다. 따라서 removeEventListener를 추가하면 근본적으로 해결됩니다." \
        "pass"

    # Test 5: 빈 결과
    test_unit \
        "빈 결과" \
        "bug-fix-test" \
        "" \
        "block"  # 검증 대상 태스크에서 빈 결과 = block

    # Test 6: 필터링 대상 (health)
    test_unit \
        "필터링 대상: system-health는 검증 제외" \
        "system-health" \
        "디스크 사용량 94%, 메모리 85%" \
        "pass"

    # Test 7: 필터링 대상 (summary)
    test_unit \
        "필터링 대상: daily-summary는 검증 제외" \
        "daily-summary" \
        "오늘 완료된 태스크들" \
        "pass"
}

# --- Compatibility Tests ---
run_compatibility_tests() {
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  COMPATIBILITY TESTS: 기존 태스크와의 호환성"
    echo "════════════════════════════════════════════════════════"

    test_compatibility "system-health 태스크" "system-health"
    test_compatibility "daily-summary 태스크" "daily-summary"
    test_compatibility "morning-standup 태스크" "morning-standup"
    test_compatibility "council-insight 태스크" "council-insight"

    # Additional compatibility check: problem-solving tasks should validate
    printf "\n${BLUE}[Compatibility Test]${NC} bug-fix 태스크는 검증 포함\n"
    "$ROOT_CAUSE_VALIDATOR" "bug-fix-test" "조정했습니다" >/tmp/test-output.txt 2>&1 || true
    output=$(cat /tmp/test-output.txt)
    actual_verdict=$(echo "$output" | grep -o 'verdict=[^ ]*' | cut -d= -f2 || echo "unknown")

    if [[ "$actual_verdict" == "block" ]]; then
        printf "${GREEN}✓ PASS${NC} (근본분석 없는 bug-fix는 block, verdict: block)\n"
        (( PASS++ )) || true
    else
        printf "${RED}✗ FAIL${NC} (expected block, got: %s)\n" "$actual_verdict"
        (( FAIL++ )) || true
    fi
}

# --- Integration Tests ---
run_integration_tests() {
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  INTEGRATION TESTS: ask-claude.sh와의 통합"
    echo "════════════════════════════════════════════════════════"

    printf "\n${BLUE}[Integration Test]${NC} root-cause-validator.sh 소싱 확인\n"

    # Create a test script that sources the validator
    cat > /tmp/test-integration.sh << 'EOF'
#!/bin/bash
set -euo pipefail
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
source "$BOT_HOME/lib/root-cause-validator.sh"
validate_root_cause "bug-fix-test" "원인을 분석한 결과 메모리 누수입니다." ""
echo "verdict=$ROOT_CAUSE_VERDICT blocked=$ROOT_CAUSE_BLOCKED"
EOF

    bash /tmp/test-integration.sh > /tmp/integration-output.txt 2>&1
    output=$(cat /tmp/integration-output.txt)

    if echo "$output" | grep -q "blocked="; then
        printf "${GREEN}✓ PASS${NC} (root-cause-validator.sh 소싱 성공)\n"
        printf "  Output: %s\n" "$output"
        (( PASS++ )) || true
    else
        printf "${RED}✗ FAIL${NC} (소싱 또는 실행 실패)\n"
        printf "  Output: %s\n" "$output"
        (( FAIL++ )) || true
    fi

    # Test that ask-claude.sh has the integration code
    printf "\n${BLUE}[Integration Test]${NC} ask-claude.sh에 root-cause-validator 코드 포함\n"

    ASK_CLAUDE="${BOT_HOME}/bin/ask-claude.sh"
    if grep -q "root-cause-validator.sh" "$ASK_CLAUDE"; then
        printf "${GREEN}✓ PASS${NC} (ask-claude.sh에 통합 코드 있음)\n"
        (( PASS++ )) || true
    else
        printf "${RED}✗ FAIL${NC} (ask-claude.sh에 통합 코드 없음)\n"
        (( FAIL++ )) || true
    fi

    if grep -q "ROOT_CAUSE_BLOCKED" "$ASK_CLAUDE"; then
        printf "${GREEN}✓ PASS${NC} (ask-claude.sh에서 ROOT_CAUSE_BLOCKED 사용 중)\n"
        (( PASS++ )) || true
    else
        printf "${RED}✗ FAIL${NC} (ask-claude.sh에서 ROOT_CAUSE_BLOCKED 미사용)\n"
        (( FAIL++ )) || true
    fi
}

# --- Summary ---
print_summary() {
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  TEST SUMMARY"
    echo "════════════════════════════════════════════════════════"
    printf "✓ PASS: ${GREEN}%d${NC}\n" "$PASS"
    printf "✗ FAIL: ${RED}%d${NC}\n" "$FAIL"
    echo "════════════════════════════════════════════════════════"

    if (( FAIL == 0 )); then
        printf "\n${GREEN}모든 테스트 통과!${NC}\n"
        return 0
    else
        printf "\n${RED}%d개 테스트 실패${NC}\n" "$FAIL"
        return 1
    fi
}

# --- Main ---
main() {
    local test_type="${1:-all}"

    printf "\n"
    printf "╔════════════════════════════════════════════════════════╗\n"
    printf "║  근본원인 검증 가드 - 호환성 검증 스크립트            ║\n"
    printf "║  Cluster: cl-d8daa113f8bb5b30                         ║\n"
    printf "╚════════════════════════════════════════════════════════╝\n"

    # Dependency check
    if [[ ! -f "$ROOT_CAUSE_VALIDATOR" ]]; then
        printf "${RED}✗ Error: %s not found${NC}\n" "$ROOT_CAUSE_VALIDATOR"
        exit 2
    fi

    case "$test_type" in
        unit)
            run_unit_tests
            ;;
        compatibility)
            run_compatibility_tests
            ;;
        integration)
            run_integration_tests
            ;;
        all)
            run_unit_tests
            run_compatibility_tests
            run_integration_tests
            ;;
        *)
            printf "Unknown test type: %s\n" "$test_type" >&2
            printf "Valid types: unit, compatibility, integration, all\n" >&2
            exit 2
            ;;
    esac

    print_summary
}

main "$@"
