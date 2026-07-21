#!/usr/bin/env bash
# Duplicate Request Guard Functional Tests
# 클러스터 cl-3d5ba801bdad1df9: 중복 요청 가드 기능 검증

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
GUARD_SCRIPT="${BOT_HOME}/lib/duplicate-request-guard.mjs"
TEST_LOG="${BOT_HOME}/logs/test-duplicate-request-guard.log"

# Ensure directories exist
mkdir -p "$(dirname "$TEST_LOG")"

# Clean up old test entries to avoid interference
CACHE_FILE="${BOT_HOME}/state/duplicate-request-cache.jsonl"

# Remove entries from previous test runs (older than 10 seconds)
if [[ -f "$CACHE_FILE" ]]; then
    NOW_MS=$(date +%s)000
    CUTOFF_MS=$((NOW_MS - 10000))

    TEMP_CACHE=$(mktemp)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        CREATED_AT=$(echo "$line" | jq -r '.created_at // 0' 2>/dev/null || echo 0)
        if [[ $CREATED_AT -gt $CUTOFF_MS ]]; then
            echo "$line" >> "$TEMP_CACHE"
        fi
    done < "$CACHE_FILE"
    mv "$TEMP_CACHE" "$CACHE_FILE" || true
fi

echo "=== Duplicate Request Guard Functional Tests ===" | tee -a "$TEST_LOG"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$TEST_LOG"
echo "" | tee -a "$TEST_LOG"

PASS=0
FAIL=0

# Helper function to run test
run_test() {
    local name="$1" task_id="$2" prompt="$3" expect_dup="$4"

    echo -n "[TEST] $name ... "
    RESULT=$(timeout 5 node "$GUARD_SCRIPT" check "$task_id" "$prompt" 2>/dev/null || true)
    IS_DUP=$(echo "$RESULT" | jq -r '.is_duplicate' 2>/dev/null || echo "error")

    if [[ "$IS_DUP" == "$expect_dup" ]]; then
        echo "PASS"
        ((PASS++))
        printf '[%s] TEST_PASS: %s (is_duplicate=%s)\n' "$(date -u +%FT%TZ)" "$name" "$IS_DUP" >> "$TEST_LOG"
    else
        echo "FAIL (expected $expect_dup, got $IS_DUP)"
        ((FAIL++))
        printf '[%s] TEST_FAIL: %s (expected is_duplicate=%s, got %s)\n' "$(date -u +%FT%TZ)" "$name" "$expect_dup" "$IS_DUP" >> "$TEST_LOG"
    fi
}

# Test 1: New request
run_test "First request detection" "func-test-1" "Test prompt" "false"

# Test 2: Duplicate within 2min
run_test "Second identical request (duplicate)" "func-test-1" "Test prompt" "true"

# Test 3: Third duplicate
run_test "Third identical request (duplicate)" "func-test-1" "Test prompt" "true"

# Test 4: Different prompt = new
run_test "Different prompt (new)" "func-test-1" "Different prompt" "false"

# Test 5: Different task = new
run_test "Different task ID (new)" "func-test-2" "Test prompt" "false"

# Test 6: Second duplicate of new task
run_test "Second request for new task (duplicate)" "func-test-2" "Test prompt" "true"

echo "" | tee -a "$TEST_LOG"
echo "=== Test Summary ===" | tee -a "$TEST_LOG"
echo "Passed: $PASS" | tee -a "$TEST_LOG"
echo "Failed: $FAIL" | tee -a "$TEST_LOG"
echo "Total:  $((PASS + FAIL))" | tee -a "$TEST_LOG"

if [[ $FAIL -eq 0 ]]; then
    echo "Result: ALL PASS ✓" | tee -a "$TEST_LOG"
    exit 0
else
    echo "Result: SOME FAILED ✗" | tee -a "$TEST_LOG"
    exit 1
fi
