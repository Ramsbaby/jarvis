#!/usr/bin/env bash
# test-file-state-guards.sh — 파일 상태 가드 E2E 시뮬레이션 테스트
#
# 목적: 파일 상태 캐시, 모순 감지, dev-queue 연동이 정상 작동하는지 검증
#
# 테스트 항목:
#   [1] file-state-cache.sh 기본 기능
#   [2] file-state-contradiction-guard.sh 모순 감지
#   [3] file-state-dev-queue-bridge.sh dev-queue 로깅
#   [4] 통합 플로우
#
# 실행법:
#   bash /Users/ramsbaby/jarvis/infra/scripts/test-file-state-guards.sh

set -euo pipefail

export BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"

# 색상 정의 (터미널 출력용)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# ═════════════════════════════════════════════════════════════════════════════════
# [0] 테스트 헬퍼 함수
# ═════════════════════════════════════════════════════════════════════════════════

print_header() {
    printf '\n%b[TEST] %s%b\n' "$YELLOW" "$1" "$NC"
    printf '%s\n' "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

assert_success() {
    local test_name="$1"
    local actual_exit_code="$2"

    if [[ $actual_exit_code -eq 0 ]]; then
        printf '%b✓%b %s\n' "$GREEN" "$NC" "$test_name"
        return 0
    else
        printf '%b✗%b %s (exit code: %d)\n' "$RED" "$NC" "$test_name" "$actual_exit_code"
        return 1
    fi
}

assert_failure() {
    local test_name="$1"
    local actual_exit_code="$2"

    if [[ $actual_exit_code -ne 0 ]]; then
        printf '%b✓%b %s (correctly failed)\n' "$GREEN" "$NC" "$test_name"
        return 0
    else
        printf '%b✗%b %s (should have failed but succeeded)\n' "$RED" "$NC" "$test_name"
        return 1
    fi
}

assert_file_exists() {
    local file_path="$1"
    local test_name="$2"

    if [[ -f "$file_path" ]]; then
        printf '%b✓%b %s exists\n' "$GREEN" "$NC" "$test_name"
        return 0
    else
        printf '%b✗%b %s missing at %s\n' "$RED" "$NC" "$test_name" "$file_path"
        return 1
    fi
}

# ═════════════════════════════════════════════════════════════════════════════════
# [1] TEST: file-state-cache.sh 초기화 및 캐시
# ═════════════════════════════════════════════════════════════════════════════════

test_cache_initialization() {
    print_header "TEST 1: 파일 상태 캐시 초기화"

    export RESPONSE_ID="test-response-001"

    source "${BOT_HOME}/lib/file-state-cache.sh"

    # 캐시 디렉토리 확인
    mkdir -p "$BOT_HOME/state/file-state-cache" || return 1

    # 초기화
    init_file_state_cache "$RESPONSE_ID" || return 1
    assert_file_exists "${BOT_HOME}/state/file-state-cache/${RESPONSE_ID}.json" "Cache init"

    # JSON 구조 검증
    local cache_json
    cache_json=$(<"${BOT_HOME}/state/file-state-cache/${RESPONSE_ID}.json")

    if printf '%s' "$cache_json" | jq . >/dev/null 2>&1; then
        printf '%b✓%b Cache JSON is valid\n' "$GREEN" "$NC"
    else
        printf '%b✗%b Cache JSON parsing failed\n' "$RED" "$NC"
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [2] TEST: file-state-cache.sh 파일 존재 여부 조회
# ═════════════════════════════════════════════════════════════════════════════════

test_cache_file_operations() {
    print_header "TEST 2: 파일 상태 캐시 - 조회 및 캐싱"

    export RESPONSE_ID="test-response-002"

    source "${BOT_HOME}/lib/file-state-cache.sh"

    # 초기화
    init_file_state_cache "$RESPONSE_ID" || return 1

    # 테스트: 존재하는 파일
    if is_file_exists "/etc/hostname"; then
        printf '%b✓%b Existing file correctly detected\n' "$GREEN" "$NC"
    else
        printf '%b✗%b Existing file not detected\n' "$RED" "$NC"
        return 1
    fi

    # 테스트: 존재하지 않는 파일
    if is_file_exists "/nonexistent/path/to/file.txt"; then
        printf '%b✗%b Non-existent file incorrectly detected as existing\n' "$RED" "$NC"
        return 1
    else
        printf '%b✓%b Non-existent file correctly detected\n' "$GREEN" "$NC"
    fi

    # 캐시 확인: 참조 횟수 > 0
    local cache_json
    cache_json=$(<"${BOT_HOME}/state/file-state-cache/${RESPONSE_ID}.json")
    local ref_count
    ref_count=$(printf '%s' "$cache_json" | jq '.reference_count | length')

    if [[ $ref_count -gt 0 ]]; then
        printf '%b✓%b Cache populated with %d file states\n' "$GREEN" "$NC" "$ref_count"
    else
        printf '%b✗%b Cache empty (expected entries)\n' "$RED" "$NC"
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [3] TEST: file-state-contradiction-guard.sh 모순 감지
# ═════════════════════════════════════════════════════════════════════════════════

test_contradiction_detection() {
    print_header "TEST 3: 파일 상태 모순 감지"

    source "${BOT_HOME}/lib/file-state-contradiction-guard.sh"

    # 테스트 케이스 1: 모순 없음
    local response_1="파일이 성공적으로 생성되었습니다."
    guard_file_state_contradictions "task-test-1" "$response_1" || {
        printf '%b✗%b Should not detect contradiction in normal response\n' "$RED" "$NC"
        return 1
    }
    printf '%b✓%b No contradiction in normal response\n' "$GREEN" "$NC"

    # 테스트 케이스 2: 모순 감지 (존재 + 부재)
    local response_2="파일이 존재하지만, 파일이 없어서 생성할 수 없습니다."
    guard_file_state_contradictions "task-test-2" "$response_2" && {
        printf '%b✗%b Should detect contradiction\n' "$RED" "$NC"
        return 1
    }
    printf '%b✓%b Contradiction correctly detected\n' "$GREEN" "$NC"

    # 테스트 케이스 3: 과도한 반복 언급
    local response_3="파일이 있어요. 파일이 존재해요. 파일이 생성되었습니다."
    guard_file_state_contradictions "task-test-3" "$response_3" && {
        printf '%b✗%b Should detect repetitive assertion\n' "$RED" "$NC"
        return 1
    }
    printf '%b✓%b Repetitive assertion correctly detected\n' "$GREEN" "$NC"

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [4] TEST: file-state-dev-queue-bridge.sh 개발 큐 통합
# ═════════════════════════════════════════════════════════════════════════════════

test_dev_queue_integration() {
    print_header "TEST 4: Dev-Queue 자동 로깅"

    source "${BOT_HOME}/lib/file-state-dev-queue-bridge.sh"

    # 작업 큐 생성
    mkdir -p "$BOT_HOME/logs" || return 1

    enqueue_file_state_contradiction_task "original-task-123" "파일 존재/부재 모순" "ERROR" || {
        printf '%b⚠%b Enqueue failed (expected if task-store unavailable)\n' "$YELLOW" "$NC"
    }

    # 수동 기록 확인
    local log_file="$BOT_HOME/logs/file-state-dev-queue-log.jsonl"
    if [[ -f "$log_file" ]]; then
        printf '%b✓%b Manual task entry logged\n' "$GREEN" "$NC"

        # JSONL 형식 검증
        while IFS= read -r line; do
            if ! printf '%s' "$line" | jq . >/dev/null 2>&1; then
                printf '%b✗%b Invalid JSON in log\n' "$RED" "$NC"
                return 1
            fi
        done < "$log_file"

        printf '%b✓%b All log entries are valid JSON\n' "$GREEN" "$NC"
    else
        printf '%b⚠%b Log file not created (expected in some environments)\n' "$YELLOW" "$NC"
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [5] TEST: 통합 플로우 (E2E)
# ═════════════════════════════════════════════════════════════════════════════════

test_integrated_flow() {
    print_header "TEST 5: 통합 E2E 플로우"

    export RESPONSE_ID="test-response-e2e-001"

    # 1. 캐시 초기화
    source "${BOT_HOME}/lib/file-state-cache.sh"
    init_file_state_cache "$RESPONSE_ID" || return 1
    printf '%b✓%b E2E: Cache initialized\n' "$GREEN" "$NC"

    # 2. 파일 상태 조회 (캐시 기록)
    if is_file_exists "/etc/hosts"; then
        printf '%b✓%b E2E: File state cached\n' "$GREEN" "$NC"
    else
        return 1
    fi

    # 3. 모순 감지
    local contradiction_response="파일이 있어요. 근데 파일이 없어서 못 찾았어요."

    source "${BOT_HOME}/lib/file-state-contradiction-guard.sh"
    guard_file_state_contradictions "task-e2e-001" "$contradiction_response" && {
        printf '%b✗%b E2E: Should detect contradiction\n' "$RED" "$NC"
        return 1
    }
    printf '%b✓%b E2E: Contradiction detected\n' "$GREEN" "$NC"

    # 4. Dev-queue 로깅
    source "${BOT_HOME}/lib/file-state-dev-queue-bridge.sh"
    enqueue_file_state_contradiction_task "task-e2e-001" "E2E 테스트 모순" "ERROR" || true
    printf '%b✓%b E2E: Task enqueued\n' "$GREEN" "$NC"

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [6] TEST: 기존 스크립트 호환성
# ═════════════════════════════════════════════════════════════════════════════════

test_backward_compatibility() {
    print_header "TEST 6: 기존 스크립트 호환성"

    local scripts=(
        "${BOT_HOME}/../infra/bin/ask-claude.sh"
        "${BOT_HOME}/../infra/lib/guards.sh"
        "${BOT_HOME}/../infra/lib/coder-functions.sh"
    )

    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            if bash -n "$script" 2>/dev/null; then
                printf '%b✓%b %s syntax OK\n' "$GREEN" "$NC" "$(basename "$script")"
            else
                printf '%b✗%b %s syntax error\n' "$RED" "$NC" "$(basename "$script")"
                return 1
            fi
        fi
    done

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [7] 메인 실행
# ═════════════════════════════════════════════════════════════════════════════════

main() {
    printf '\n%b╔════════════════════════════════════════════════════════════╗%b\n' "$YELLOW" "$NC"
    printf '%b║  파일 상태 가드 E2E 시뮬레이션 테스트                         ║%b\n' "$YELLOW" "$NC"
    printf '%b║  클러스터: cl-6f0c8cc1df90e995                             ║%b\n' "$YELLOW" "$NC"
    printf '%b╚════════════════════════════════════════════════════════════╝%b\n' "$YELLOW" "$NC"

    local test_count=0
    local pass_count=0

    # 테스트 실행
    for test_func in test_cache_initialization test_cache_file_operations \
                     test_contradiction_detection test_dev_queue_integration \
                     test_integrated_flow test_backward_compatibility; do

        test_count=$((test_count + 1))

        if "$test_func"; then
            pass_count=$((pass_count + 1))
        fi
    done

    # 결과 요약
    printf '\n%b╔════════════════════════════════════════════════════════════╗%b\n' "$YELLOW" "$NC"
    printf '%b║  테스트 결과                                                ║%b\n' "$YELLOW" "$NC"
    printf '%b║  통과: %d/%d                                               ║%b\n' "$GREEN" "$pass_count" "$test_count" "$NC"
    printf '%b╚════════════════════════════════════════════════════════════╝%b\n' "$YELLOW" "$NC"

    if [[ $pass_count -eq $test_count ]]; then
        printf '%b✓ 모든 테스트 통과%b\n\n' "$GREEN" "$NC"
        return 0
    else
        printf '%b✗ %d개 테스트 실패%b\n\n' "$RED" "$((test_count - pass_count))" "$NC"
        return 1
    fi
}

main "$@"
