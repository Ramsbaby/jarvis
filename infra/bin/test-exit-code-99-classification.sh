#!/usr/bin/env bash
set -euo pipefail

# test-exit-code-99-classification.sh
# Comprehensive test suite for exit code 99 circuit breaker detection

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SCRIPT="${SCRIPT_DIR}/cron-safe-wrapper.sh"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

# Helper function to run a single test
run_test() {
    local test_name="$1"
    local exit_code="$2"
    local stderr_content="$3"
    local expected_failure_type="$4"

    # Create isolated temp directory for this test
    local test_dir="/tmp/exit-99-test-$$-${RANDOM}"
    mkdir -p "$test_dir"
    export BOT_HOME="$test_dir"

    local test_script="${test_dir}/test.sh"
    local wrapper_log="${test_dir}/logs/cron-safe-wrapper.log"

    # Create test script
    cat > "$test_script" << EOF
#!/usr/bin/env bash
[[ -n "$stderr_content" ]] && echo "$stderr_content" >&2
exit $exit_code
EOF
    chmod +x "$test_script"

    # Run wrapper with unique lock name
    local lock_name="test-$$-${RANDOM}"
    "$WRAPPER_SCRIPT" "$lock_name" 30 "$test_script" 2>/dev/null || true

    # Parse result from log
    local logged_failure_type="NOT_FOUND"
    if [[ -f "$wrapper_log" ]]; then
        logged_failure_type=$(grep "FAIL exit=$exit_code" "$wrapper_log" 2>/dev/null | sed 's/.*\[//' | sed 's/\].*//' | tail -1)
        if [[ -z "$logged_failure_type" ]]; then
            logged_failure_type="NOT_FOUND"
        fi
    fi

    # Check result
    if [[ "$logged_failure_type" == "$expected_failure_type" ]]; then
        printf "${GREEN}✅ PASS${NC}: %s\n" "$test_name"
        ((TESTS_PASSED++))
    else
        printf "${RED}❌ FAIL${NC}: %s\n" "$test_name"
        printf "  Expected: [%s]\n" "$expected_failure_type"
        printf "  Got:      [%s]\n" "$logged_failure_type"
        ((TESTS_FAILED++))
    fi

    # Cleanup
    rm -rf "$test_dir"
}

# ─────────────────────────────────────────────────────────────────
# Test Suite
# ─────────────────────────────────────────────────────────────────

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Exit Code 99 Classification Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Exit code 99 tests with circuit breaker patterns
run_test "Exit 99 with lowercase 'circuit'" 99 "error: circuit breaker open" "CIRCUIT_OPEN"
run_test "Exit 99 with uppercase 'CIRCUIT'" 99 "CIRCUIT BREAKER ACTIVATED" "CIRCUIT_OPEN"
run_test "Exit 99 with mixed case 'Circuit'" 99 "Warning: Circuit condition met" "CIRCUIT_OPEN"
run_test "Exit 99 with 'circuit' in message" 99 "ask-claude.sh: circuit breaker activated" "CIRCUIT_OPEN"

# Exit code 99 tests with other patterns
run_test "Exit 99 with AUTH pattern" 99 "Error: AUTH_ERROR token expired" "AUTH_INTERNAL"
run_test "Exit 99 with RATE pattern" 99 "API rate limit exceeded: RATE_LIMIT" "RATE_LIMIT"
run_test "Exit 99 with 'not found' pattern" 99 "Resource not found" "NOT_FOUND"

# Exit code 99 with no matching pattern
run_test "Exit 99 with empty stderr" 99 "" "INTERNAL_ERROR"
run_test "Exit 99 with unrelated error" 99 "Some random error message" "INTERNAL_ERROR"

# Exit code 99 with multiple keywords (circuit takes precedence)
run_test "Exit 99 with 'circuit' and 'AUTH'" 99 "AUTH failed, circuit breaker activated" "CIRCUIT_OPEN"

# Generic failures (exit 1) should NOT match circuit pattern
run_test "Exit 1 with 'circuit' keyword" 1 "circuit breaker mentioned" "UNKNOWN"
run_test "Exit 1 with AUTH pattern" 1 "Error: AUTH_FAILED" "AUTH"

# ─────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "Total Tests: %d\n" "$((TESTS_PASSED + TESTS_FAILED))"
printf "${GREEN}Passed: %d${NC}\n" "$TESTS_PASSED"
if [[ $TESTS_FAILED -gt 0 ]]; then
    printf "${RED}Failed: %d${NC}\n" "$TESTS_FAILED"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo
    printf "${GREEN}✅ All tests passed!${NC}\n"
    exit 0
else
    echo
    printf "${RED}❌ Some tests failed${NC}\n"
    exit 1
fi
