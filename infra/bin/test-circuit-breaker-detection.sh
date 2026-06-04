#!/usr/bin/env bash
# test-circuit-breaker-detection.sh — Circuit breaker detection 테스트 스크립트
#
# 목적: cron-safe-wrapper.sh의 exit code 99 circuit breaker 분류 개선 검증
#
# 실행: bash test-circuit-breaker-detection.sh
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_SCRIPT="${SCRIPT_DIR}/cron-safe-wrapper.sh"
WRAPPER_LOG="${HOME}/jarvis/runtime/logs/cron-safe-wrapper.log"
TEST_DIR="${SCRIPT_DIR}/../test-tmp-circuit"

TESTS_PASSED=0
TESTS_FAILED=0

_log() {
    printf '[%s] [test] %s\n' "$(date '+%F %T')" "$*"
}

_pass() {
    _log "✅ PASS: $*"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

_fail() {
    _log "❌ FAIL: $*"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

_cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}

_setup() {
    _cleanup
    mkdir -p "$TEST_DIR"
}

# Test 1: Exit code 99 with 'circuit' keyword
test_1() {
    _log "Testing: Exit code 99 with 'circuit' keyword → CIRCUIT_OPEN"
    cat > "$TEST_DIR/mock.sh" << 'EOF'
#!/bin/bash
echo "Circuit breaker activated: too many failures" >&2
exit 99
EOF
    chmod +x "$TEST_DIR/mock.sh"
    bash "$WRAPPER_SCRIPT" "test-1" 10 "$TEST_DIR/mock.sh" 2>/dev/null || true
    sleep 0.3
    if grep -q "test-1.*FAIL exit=99.*\[CIRCUIT_OPEN\]" "$WRAPPER_LOG"; then
        _pass "Exit code 99 with 'circuit' keyword"
    else
        _fail "Exit code 99 with 'circuit' keyword"
    fi
}

# Test 2: Exit code 99 with 'CIRCUIT' (uppercase)
test_2() {
    _log "Testing: Exit code 99 with 'CIRCUIT' (uppercase) → CIRCUIT_OPEN"
    cat > "$TEST_DIR/mock.sh" << 'EOF'
#!/bin/bash
echo "CIRCUIT_BREAKER activated immediately" >&2
exit 99
EOF
    chmod +x "$TEST_DIR/mock.sh"
    bash "$WRAPPER_SCRIPT" "test-2" 10 "$TEST_DIR/mock.sh" 2>/dev/null || true
    sleep 0.3
    if grep -q "test-2.*FAIL exit=99.*\[CIRCUIT_OPEN\]" "$WRAPPER_LOG"; then
        _pass "Exit code 99 with CIRCUIT uppercase"
    else
        _fail "Exit code 99 with CIRCUIT uppercase"
    fi
}

# Test 3: Exit code 99 with 'AUTH'
test_3() {
    _log "Testing: Exit code 99 with 'AUTH' keyword → AUTH_INTERNAL"
    cat > "$TEST_DIR/mock.sh" << 'EOF'
#!/bin/bash
echo "AUTH error from API" >&2
exit 99
EOF
    chmod +x "$TEST_DIR/mock.sh"
    bash "$WRAPPER_SCRIPT" "test-3" 10 "$TEST_DIR/mock.sh" 2>/dev/null || true
    sleep 0.3
    if grep -q "test-3.*FAIL exit=99.*\[AUTH_INTERNAL\]" "$WRAPPER_LOG"; then
        _pass "Exit code 99 with AUTH keyword"
    else
        _fail "Exit code 99 with AUTH keyword"
    fi
}

# Test 4: Exit code 99 with 'RATE'
test_4() {
    _log "Testing: Exit code 99 with 'RATE' keyword → RATE_LIMIT"
    cat > "$TEST_DIR/mock.sh" << 'EOF'
#!/bin/bash
echo "RATE limit exceeded" >&2
exit 99
EOF
    chmod +x "$TEST_DIR/mock.sh"
    bash "$WRAPPER_SCRIPT" "test-4" 10 "$TEST_DIR/mock.sh" 2>/dev/null || true
    sleep 0.3
    if grep -q "test-4.*FAIL exit=99.*\[RATE_LIMIT\]" "$WRAPPER_LOG"; then
        _pass "Exit code 99 with RATE keyword"
    else
        _fail "Exit code 99 with RATE keyword"
    fi
}

# Test 5: Exit code 99 without keywords
test_5() {
    _log "Testing: Exit code 99 without keywords → INTERNAL_ERROR"
    cat > "$TEST_DIR/mock.sh" << 'EOF'
#!/bin/bash
echo "Something went wrong" >&2
exit 99
EOF
    chmod +x "$TEST_DIR/mock.sh"
    bash "$WRAPPER_SCRIPT" "test-5" 10 "$TEST_DIR/mock.sh" 2>/dev/null || true
    sleep 0.3
    if grep -q "test-5.*FAIL exit=99.*\[INTERNAL_ERROR\]" "$WRAPPER_LOG"; then
        _pass "Exit code 99 without keywords"
    else
        _fail "Exit code 99 without keywords"
    fi
}

# Test 6: Exit code 1 should not be classified as CIRCUIT_OPEN
test_6() {
    _log "Testing: Exit code 1 with 'circuit' should not be CIRCUIT_OPEN"
    cat > "$TEST_DIR/mock.sh" << 'EOF'
#!/bin/bash
echo "circuit breaker text in regular error" >&2
exit 1
EOF
    chmod +x "$TEST_DIR/mock.sh"
    bash "$WRAPPER_SCRIPT" "test-6" 10 "$TEST_DIR/mock.sh" 2>/dev/null || true
    sleep 0.3
    if grep -q "test-6.*FAIL exit=1" "$WRAPPER_LOG" && ! grep -q "test-6.*CIRCUIT_OPEN" "$WRAPPER_LOG"; then
        _pass "Exit code 1 not classified as CIRCUIT_OPEN"
    else
        _fail "Exit code 1 not classified as CIRCUIT_OPEN"
    fi
}

# Test 7: Exit code 0 should show DONE
test_7() {
    _log "Testing: Exit code 0 should show DONE"
    cat > "$TEST_DIR/mock.sh" << 'EOF'
#!/bin/bash
echo "Success" >&2
exit 0
EOF
    chmod +x "$TEST_DIR/mock.sh"
    bash "$WRAPPER_SCRIPT" "test-7" 10 "$TEST_DIR/mock.sh" 2>/dev/null || true
    sleep 0.3
    if grep -q "test-7.*DONE exit=0" "$WRAPPER_LOG"; then
        _pass "Exit code 0 shows DONE"
    else
        _fail "Exit code 0 shows DONE"
    fi
}

main() {
    _log "Starting circuit breaker detection tests"
    _log "Wrapper script: $WRAPPER_SCRIPT"
    _log "Wrapper log: $WRAPPER_LOG"
    _setup

    test_1
    test_2
    test_3
    test_4
    test_5
    test_6
    test_7

    _cleanup

    _log ""
    _log "════════════════════════════════════════════════════════════════"
    _log "Test Results: ${TESTS_PASSED} PASSED, ${TESTS_FAILED} FAILED"
    _log "════════════════════════════════════════════════════════════════"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        _log "✅ All tests passed!"
        exit 0
    else
        _log "❌ Some tests failed"
        exit 1
    fi
}

main "$@"
