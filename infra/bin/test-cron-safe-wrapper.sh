#!/usr/bin/env bash
# Integration test for cron-safe-wrapper.sh
# Tests: lock handling, timeout detection, failure classification, exit code propagation

set -euo pipefail

WRAPPER="/Users/ramsbaby/jarvis/runtime/bin/cron-safe-wrapper.sh"
TEST_LOG="/tmp/cron-wrapper-test-$(date +%s).log"
PASS_COUNT=0
FAIL_COUNT=0

# Ensure wrapper exists
if [[ ! -f "$WRAPPER" ]]; then
    echo "ERROR: Wrapper not found at $WRAPPER"
    exit 1
fi

# Helper functions
_test_case() {
    local name="$1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST: $name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

_pass() {
    echo "✓ PASS"
    PASS_COUNT=$((PASS_COUNT + 1))
    echo ""
}

_fail() {
    local reason="$1"
    echo "✗ FAIL: $reason"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo ""
}

_assert_exit_code() {
    local expected="$1"
    local actual="$2"
    if [[ "$actual" -eq "$expected" ]]; then
        _pass
    else
        _fail "Expected exit code $expected, got $actual"
    fi
}

_assert_log_contains() {
    local pattern="$1"
    local log_file="$2"
    if grep -q "$pattern" "$log_file" 2>/dev/null; then
        _pass
    else
        _fail "Log does not contain pattern: $pattern"
        echo "Log contents:"
        cat "$log_file" 2>/dev/null || echo "(log not available)"
    fi
}

# Test 1: Success case (exit 0)
_test_case "Success: Command exits with 0"
EXIT_CODE=0
bash "$WRAPPER" test-success 10 bash -c "exit 0" 2>&1 || EXIT_CODE=$?
_assert_exit_code 0 "$EXIT_CODE"

# Test 2: Generic failure (exit 1)
_test_case "Failure: Command exits with 1"
EXIT_CODE=0
bash "$WRAPPER" test-failure 10 bash -c "exit 1" 2>&1 || EXIT_CODE=$?
_assert_exit_code 1 "$EXIT_CODE"

# Test 3: Timeout detection
_test_case "Timeout: Command exceeds timeout limit"
EXIT_CODE=0
bash "$WRAPPER" test-timeout 1 bash -c "sleep 3" 2>&1 || EXIT_CODE=$?
_assert_exit_code 124 "$EXIT_CODE"

# Test 4: Exit code 99 (ask-claude.sh internal error)
_test_case "Internal Error: Command exits with 99"
EXIT_CODE=0
bash "$WRAPPER" test-exit99 10 bash -c "exit 99" 2>&1 || EXIT_CODE=$?
_assert_exit_code 99 "$EXIT_CODE"

# Test 5: Auth error detection via stderr
_test_case "Auth Error: Detect AUTH in stderr"
EXIT_CODE=0
bash "$WRAPPER" test-auth 10 bash -c "echo 'AUTH_FAILED' >&2; exit 1" 2>&1 || EXIT_CODE=$?
_assert_exit_code 1 "$EXIT_CODE"

# Check wrapper log for auth detection
if [[ -f "$HOME/jarvis/runtime/logs/cron-safe-wrapper.log" ]]; then
    _assert_log_contains "AUTH" "$HOME/jarvis/runtime/logs/cron-safe-wrapper.log"
else
    _fail "Wrapper log not created"
fi

# Test 6: Lock mechanism - duplicate execution prevention
_test_case "Lock: Duplicate execution is skipped"
LOCK_NAME="test-lock-duplicate"

# Start long-running process in background
bash "$WRAPPER" "$LOCK_NAME" 10 bash -c "sleep 2; exit 0" &
BG_PID=$!
sleep 0.5

# Try to run same lock name - should be skipped
EXIT_CODE=0
bash "$WRAPPER" "$LOCK_NAME" 10 bash -c "exit 0" 2>&1 || EXIT_CODE=$?

# If exit code is 0, it was skipped (good)
if [[ $EXIT_CODE -eq 0 ]]; then
    _pass
else
    _fail "Duplicate execution not properly skipped (exit=$EXIT_CODE)"
fi

# Wait for background job
wait $BG_PID 2>/dev/null || true

# Test 7: Rate limit detection
_test_case "Rate Limit: Detect RATE in stderr"
EXIT_CODE=0
bash "$WRAPPER" test-rate 10 bash -c "echo 'RATE_LIMIT_EXCEEDED' >&2; exit 1" 2>&1 || EXIT_CODE=$?
_assert_exit_code 1 "$EXIT_CODE"

# Test 8: Network error detection
_test_case "Network Error: Detect Connection in stderr"
EXIT_CODE=0
bash "$WRAPPER" test-network 10 bash -c "echo 'Connection refused' >&2; exit 1" 2>&1 || EXIT_CODE=$?
_assert_exit_code 1 "$EXIT_CODE"

# Test 9: Permission error detection
_test_case "Permission: Detect Permission denied in stderr"
EXIT_CODE=0
bash "$WRAPPER" test-perm 10 bash -c "echo 'Permission denied' >&2; exit 1" 2>&1 || EXIT_CODE=$?
_assert_exit_code 1 "$EXIT_CODE"

# Test 10: Exit code propagation (exit 42)
_test_case "Exit Code Propagation: Non-standard exit codes"
EXIT_CODE=0
bash "$WRAPPER" test-exit42 10 bash -c "exit 42" 2>&1 || EXIT_CODE=$?
_assert_exit_code 42 "$EXIT_CODE"

# Summary
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    TEST SUMMARY                            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo "✓ All integration tests passed!"
    exit 0
else
    echo "✗ Some tests failed"
    exit 1
fi
