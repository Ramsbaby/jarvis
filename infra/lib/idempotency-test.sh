#!/usr/bin/env bash
# idempotency-test.sh
# Idempotency guard 시스템 검증 및 테스트

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
TEST_TASK_ID="test-idempotency-$$"
TEST_PROMPT="Test prompt for idempotency check"
TEST_TOOLS="Read,Edit"

# Source guard library
source "${BOT_HOME}/lib/idempotency-guard.sh"

echo "[TEST] Starting idempotency guard tests..."

# Test 1: Check initial state (should be NOT_FOUND)
echo "[TEST 1] Initial state check..."
RESULT=$(check_command_status "$TEST_TASK_ID" "$TEST_PROMPT" "$TEST_TOOLS")
if [[ "$RESULT" == "NOT_FOUND" ]]; then
    echo "✓ Initial state correctly reported as NOT_FOUND"
else
    echo "✗ Expected NOT_FOUND but got: $RESULT"
    exit 1
fi

# Test 2: Record command start
echo "[TEST 2] Recording command start..."
HASH=$(record_command_start "$TEST_TASK_ID" "$TEST_PROMPT" "$TEST_TOOLS")
echo "✓ Command hash recorded: $HASH"

# Test 3: Check status after start (should be DUPLICATE_IN_PROGRESS)
echo "[TEST 3] Status after start..."
RESULT=$(check_command_status "$TEST_TASK_ID" "$TEST_PROMPT" "$TEST_TOOLS")
if [[ "$RESULT" == DUPLICATE_IN_PROGRESS* ]]; then
    echo "✓ Status correctly reported as DUPLICATE_IN_PROGRESS"
else
    echo "✗ Expected DUPLICATE_IN_PROGRESS but got: $RESULT"
    exit 1
fi

# Test 4: Record command completion
echo "[TEST 4] Recording command completion..."
RESULT_FILE="/tmp/test-result-$$.md"
echo "Test result content" > "$RESULT_FILE"
record_command_end "$TEST_TASK_ID" "$HASH" "completed" "$RESULT_FILE" "Test completion"
echo "✓ Command completion recorded"

# Test 5: Check status after completion (should be DUPLICATE_COMPLETED)
echo "[TEST 5] Status after completion..."
RESULT=$(check_command_status "$TEST_TASK_ID" "$TEST_PROMPT" "$TEST_TOOLS")
if [[ "$RESULT" == DUPLICATE_COMPLETED* ]]; then
    echo "✓ Status correctly reported as DUPLICATE_COMPLETED"
else
    echo "✗ Expected DUPLICATE_COMPLETED but got: $RESULT"
    exit 1
fi

# Test 6: Get command state (debug function)
echo "[TEST 6] Querying command state..."
STATE=$(get_command_state "$HASH")
if [[ -n "$STATE" ]]; then
    echo "✓ Command state retrieved:"
    echo "  $STATE"
else
    echo "✗ Failed to retrieve command state"
    exit 1
fi

# Test 7: Test failed command
echo "[TEST 7] Testing failed command recording..."
TEST_TASK_ID_2="test-failed-$$"
HASH_2=$(record_command_start "$TEST_TASK_ID_2" "Failed test" "Read")
record_command_end "$TEST_TASK_ID_2" "$HASH_2" "failed" "" "Simulated failure"
RESULT=$(check_command_status "$TEST_TASK_ID_2" "Failed test" "Read")
if [[ "$RESULT" == DUPLICATE_FAILED* ]]; then
    echo "✓ Failed command status correctly reported"
else
    echo "✗ Expected DUPLICATE_FAILED but got: $RESULT"
    exit 1
fi

# Cleanup
rm -f "$RESULT_FILE"

echo ""
echo "=========================================="
echo "All tests passed! ✓"
echo "=========================================="
echo ""
echo "Database location: ${IDEMPOTENCY_DB:-${BOT_HOME}/data/command-state.db}"
echo ""
echo "To view database contents:"
echo "  sqlite3 ${IDEMPOTENCY_DB:-${BOT_HOME}/data/command-state.db} 'SELECT * FROM task_state;'"
