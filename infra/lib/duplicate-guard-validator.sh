#!/usr/bin/env bash
# Duplicate Request Guard Validator (Cluster cl-3d5ba801bdad1df9)
#
# 목적: 중복 감지 가드의 구현 완성도 검증
# 검증 항목:
#   [1] 중복 감지 미들웨어 코드 존재 및 요청 해싱 로직 ✓
#   [2] ask-claude.sh에 미들웨어 통합 및 조기 종료 로직 ✓
#   [3] 중복 요청 캐시 저장소 및 N턴 이력 관리 ✓
#   [4] 기존 ask-claude 동작 호환성 유지 ✓
#   [5] 중복 감지 시 사용자에게 메시지 반환 ✓
#
# 사용: bash duplicate-guard-validator.sh [--strict]

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
INFRA_HOME="${BOT_HOME%/runtime}/infra"
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Functions
log_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((PASS_COUNT++)) || true
}

log_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((FAIL_COUNT++)) || true
}

log_warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
    ((WARN_COUNT++)) || true
}

log_info() {
    echo -e "${BLUE}ℹ INFO${NC}: $1"
}

# Cleanup on exit
cleanup() {
    rm -f /tmp/guard-test-*.tmp 2>/dev/null || true
}
trap cleanup EXIT

echo "=================================================="
echo "Duplicate Request Guard Validator"
echo "Cluster: cl-3d5ba801bdad1df9"
echo "=================================================="
echo ""

# [1] 중복 감지 미들웨어 코드 존재 확인
echo "Step 1: Validating middleware implementation..."

if [[ ! -f "${INFRA_HOME}/lib/duplicate-request-guard.mjs" ]]; then
    log_fail "duplicate-request-guard.mjs not found"
else
    if grep -q "hashRequest" "${INFRA_HOME}/lib/duplicate-request-guard.mjs" && \
       grep -q "checkDuplicate" "${INFRA_HOME}/lib/duplicate-request-guard.mjs"; then
        log_pass "duplicate-request-guard.mjs exists with hashing and detection logic"
    else
        log_fail "duplicate-request-guard.mjs missing core functions (hashRequest, checkDuplicate)"
    fi
fi

if [[ ! -f "${INFRA_HOME}/lib/duplicate-request-guard-enhanced.mjs" ]]; then
    log_warn "duplicate-request-guard-enhanced.mjs (semantic analysis) not found"
else
    log_pass "duplicate-request-guard-enhanced.mjs exists with semantic similarity support"
fi

echo ""

# [2] ask-claude.sh 통합 확인
echo "Step 2: Validating ask-claude.sh integration..."

if [[ ! -f "${INFRA_HOME}/bin/ask-claude.sh" ]]; then
    log_fail "ask-claude.sh not found"
else
    if grep -q "duplicate-request-guard" "${INFRA_HOME}/bin/ask-claude.sh"; then
        log_pass "ask-claude.sh integrates duplicate-request-guard"
    else
        log_fail "ask-claude.sh does not call duplicate-request-guard"
    fi

    if grep -q "exit 98" "${INFRA_HOME}/bin/ask-claude.sh"; then
        log_pass "ask-claude.sh has early exit logic (exit 98 for duplicates)"
    else
        log_fail "ask-claude.sh missing early exit logic"
    fi

    if grep -q '_DUP_MSG' "${INFRA_HOME}/bin/ask-claude.sh" && \
       grep -q 'echo.*_DUP_MSG' "${INFRA_HOME}/bin/ask-claude.sh"; then
        log_pass "ask-claude.sh returns duplicate message to user"
    else
        log_fail "ask-claude.sh does not return message to user on duplicate"
    fi
fi

echo ""

# [3] 캐시 저장소 및 이력 관리 확인
echo "Step 3: Validating cache storage system..."

STATE_DIR="${BOT_HOME}/state"
CACHE_FILE="${STATE_DIR}/duplicate-request-cache.jsonl"

if [[ -d "$STATE_DIR" ]]; then
    log_pass "State directory exists: $STATE_DIR"
else
    log_warn "State directory does not exist: $STATE_DIR"
fi

if [[ -f "$CACHE_FILE" ]]; then
    CACHE_LINES=$(wc -l < "$CACHE_FILE" 2>/dev/null | tr -d ' ' || echo 0)
    if [[ "$CACHE_LINES" -gt 0 ]]; then
        log_pass "Cache file exists and has entries (lines: $CACHE_LINES)"
    else
        log_warn "Cache file exists but is empty"
    fi
else
    log_warn "Cache file not yet created (first run expected)"
fi

if [[ -f "${STATE_DIR}/duplicate-request-stats.json" ]]; then
    log_pass "Statistics file exists: duplicate-request-stats.json"
else
    log_warn "Statistics file not yet created (first run expected)"
fi

if [[ -f "${STATE_DIR}/duplicate-request-detections.jsonl" ]]; then
    DETECTION_LINES=$(wc -l < "${STATE_DIR}/duplicate-request-detections.jsonl" 2>/dev/null | tr -d ' ' || echo 0)
    log_pass "Detection log exists (lines: $DETECTION_LINES)"
else
    log_warn "Detection log not yet created (first run expected)"
fi

echo ""

# [4] 기존 ask-claude 호환성 (구문 검사)
echo "Step 4: Validating backward compatibility..."

if bash -n "${INFRA_HOME}/bin/ask-claude.sh" 2>/dev/null; then
    log_pass "ask-claude.sh has valid bash syntax"
else
    log_fail "ask-claude.sh has syntax errors"
fi

if [[ -f "${INFRA_HOME}/lib/duplicate-request-guard.mjs" ]]; then
    if node -c "${INFRA_HOME}/lib/duplicate-request-guard.mjs" 2>/dev/null; then
        log_pass "duplicate-request-guard.mjs has valid JavaScript syntax"
    else
        log_fail "duplicate-request-guard.mjs has syntax errors"
    fi
fi

echo ""

# [5] 중복 감지 기능 테스트
echo "Step 5: Testing duplicate detection functionality..."

if ! command -v node >/dev/null 2>&1; then
    log_fail "node command not found"
else
    GUARD_SCRIPT="${INFRA_HOME}/lib/duplicate-request-guard.mjs"

    if [[ ! -f "$GUARD_SCRIPT" ]]; then
        log_fail "Guard script not found: $GUARD_SCRIPT"
    else
        # Test 1: New request
        TEST_RESULT=$(node "$GUARD_SCRIPT" check "test-new-1" "새로운 테스트 요청" 2>&1 || true)
        if echo "$TEST_RESULT" | jq -e '.is_duplicate == false' >/dev/null 2>&1; then
            log_pass "New request correctly detected as not duplicate"
        else
            log_fail "New request detection failed"
        fi

        # Test 2: Immediate duplicate
        TEST_RESULT2=$(node "$GUARD_SCRIPT" check "test-new-1" "새로운 테스트 요청" 2>&1 || true)
        if echo "$TEST_RESULT2" | jq -e '.is_duplicate == true' >/dev/null 2>&1; then
            log_pass "Duplicate request correctly detected"
        else
            log_fail "Duplicate request detection failed"
        fi

        # Test 3: Stats retrieval
        STATS=$(node "$GUARD_SCRIPT" stats 2>&1 || true)
        if echo "$STATS" | jq -e '.total_checks > 0' >/dev/null 2>&1; then
            log_pass "Statistics retrieval works"
        else
            log_fail "Statistics retrieval failed"
        fi

        # Test 4: Message format
        if echo "$TEST_RESULT" | jq -e '.message' >/dev/null 2>&1; then
            MSG=$(echo "$TEST_RESULT" | jq -r '.message')
            if [[ -n "$MSG" ]]; then
                log_pass "Message field present in response: '$MSG'"
            else
                log_fail "Message field is empty"
            fi
        else
            log_fail "Message field missing from response"
        fi
    fi
fi

echo ""

# [6] 관련 보조 스크립트 확인
echo "Step 6: Validating supporting scripts..."

if [[ -f "${INFRA_HOME}/lib/cleanup-duplicate-cache.sh" ]]; then
    log_pass "cleanup-duplicate-cache.sh exists"
else
    log_warn "cleanup-duplicate-cache.sh not found"
fi

if [[ -f "${INFRA_HOME}/lib/duplicate-request-cache-monitor.sh" ]]; then
    log_pass "duplicate-request-cache-monitor.sh exists"
else
    log_warn "duplicate-request-cache-monitor.sh not found"
fi

echo ""

# Summary
echo "=================================================="
echo "Validation Summary"
echo "=================================================="
echo -e "  ${GREEN}PASS${NC}:  $PASS_COUNT"
echo -e "  ${RED}FAIL${NC}:  $FAIL_COUNT"
echo -e "  ${YELLOW}WARN${NC}:  $WARN_COUNT"
echo ""

if [[ $FAIL_COUNT -eq 0 ]]; then
    if [[ $WARN_COUNT -eq 0 ]]; then
        echo -e "${GREEN}✓ All checks passed${NC}"
        exit 0
    else
        echo -e "${YELLOW}⚠ Checks passed with warnings${NC} (first-run warnings expected)"
        exit 0
    fi
else
    echo -e "${RED}✗ Some checks failed${NC}"
    exit 1
fi
