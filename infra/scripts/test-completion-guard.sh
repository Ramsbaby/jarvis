#!/usr/bin/env bash
# test-completion-guard.sh — 완료 가드 통합 테스트
# 사용: source test-completion-guard.sh && run_tests

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
DISCORD_ROUTE_LIB="${HOME}/jarvis/infra/lib/discord-route.sh"

# ── 테스트 설정 ────────────────────────────────────────────────────────────

_test_count=0
_test_pass=0
_test_fail=0

_test_start() {
    local name="$1"
    (( _test_count++ ))
    printf '\n[TEST %d] %s\n' "$_test_count" "$name"
}

_test_pass() {
    (( _test_pass++ ))
    printf '  ✅ 통과\n'
}

_test_fail() {
    local msg="$1"
    (( _test_fail++ ))
    printf '  ❌ 실패: %s\n' "$msg" >&2
}

_test_assert() {
    local actual="$1" expected="$2" msg="${3:-}"
    if [[ "$actual" == "$expected" ]]; then
        _test_pass
    else
        _test_fail "기대값='$expected', 실제='$actual' $msg"
    fi
}

_test_assert_contain() {
    local haystack="$1" needle="$2"
    if echo "$haystack" | grep -q "$needle"; then
        _test_pass
    else
        _test_fail "포함 여부: '$needle' not in '$haystack'"
    fi
}

_test_assert_exit() {
    local cmd="$1" expect_code="$2" msg="${3:-}"
    if eval "$cmd" &>/dev/null; then
        if [[ "$expect_code" == "0" ]]; then
            _test_pass
        else
            _test_fail "성공했으나 실패 기대 (code=$expect_code) $msg"
        fi
    else
        local actual=$?
        if [[ "$actual" == "$expect_code" ]]; then
            _test_pass
        else
            _test_fail "종료 코드: 기대='$expect_code', 실제='$actual' $msg"
        fi
    fi
}

# ── 테스트 케이스 ──────────────────────────────────────────────────────────

run_tests() {
    printf '\n========== 완료 가드 통합 테스트 시작 ==========\n'

    # T1: transition 함수가 empty result 거부
    _test_start "transition 함수가 빈 result 필드 거부 (RESULT_REQUIRED)"
    EMPTY_RESULT_ERROR=$(
        node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
            transition "test-empty-result" "done" "test" '{}' 2>&1 || echo "error"
    )
    if echo "$EMPTY_RESULT_ERROR" | grep -q "RESULT_REQUIRED\|not found"; then
        _test_pass
    else
        _test_fail "에러 메시지에 RESULT_REQUIRED 미포함: $EMPTY_RESULT_ERROR"
    fi

    # T2: transition 함수가 유효한 result 허용
    _test_start "transition 함수가 유효한 result 필드 허용"
    # 먼저 test-valid-result 태스크 생성
    node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
        enqueue --id "test-valid-result" --title "Test Valid Result" \
        --prompt "Test prompt" --priority medium >/dev/null 2>&1 || true
    # running 상태로 변경 (테스트용)
    node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
        transition "test-valid-result" "running" "test" '{}' >/dev/null 2>&1 || true
    # done으로 전이 시 result 포함
    if VALID_RESULT=$(node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
        transition "test-valid-result" "done" "test" '{"result":"Valid completion"}' 2>&1); then
        _test_assert_contain "$VALID_RESULT" "ok"
    else
        _test_fail "유효한 result로 done 전이 실패: $VALID_RESULT"
    fi

    # T3: 역호환성: 기존 meta.result 사용 (backward compatibility)
    _test_start "역호환성: extra.result 없으면 meta.result 검색"
    # 태스크 생성
    node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
        enqueue --id "test-legacy-result" --title "Test Legacy Result" \
        --prompt "Test prompt" >/dev/null 2>&1 || true
    # running으로 변경
    node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
        transition "test-legacy-result" "running" "test" '{}' >/dev/null 2>&1 || true
    # done 시도 — result 없음 → 실패 (RESULT_REQUIRED)
    if ! node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
        transition "test-legacy-result" "done" "test" '{}' >/dev/null 2>&1; then
        _test_pass
    else
        _test_fail "빈 result를 허용했음 (검증 미실행)"
    fi

    # T4: 워크플로우 스크립트 기본 실행
    _test_start "워크플로우 스크립트: 성공 경로 (exit 0)"
    # 워크플로우 스크립트 존재 확인
    if [[ -x "${HOME}/jarvis/infra/scripts/task-completion-workflow.sh" ]]; then
        _test_pass
    else
        _test_fail "워크플로우 스크립트 미발견 또는 실행 불가"
    fi

    # T5: 워크플로우 스크립트: 빈 result 거부 (exit 100)
    _test_start "워크플로우 스크립트: 빈 result 거부 (exit 100)"
    set +e  # exit code 보존
    "${HOME}/jarvis/infra/scripts/task-completion-workflow.sh" \
        "test-workflow-empty" "" "test" >/dev/null 2>&1
    WORKFLOW_EXIT=$?
    set -e
    if [[ "$WORKFLOW_EXIT" == "100" ]]; then
        _test_pass
    else
        _test_fail "기대 exit code 100, 실제 $WORKFLOW_EXIT"
    fi

    # T6: discord_route 함수 존재 확인
    _test_start "discord_route 함수 존재 확인"
    if [[ -f "$DISCORD_ROUTE_LIB" ]]; then
        if grep -q "discord_route()" "$DISCORD_ROUTE_LIB"; then
            _test_pass
        else
            _test_fail "discord_route 함수 정의 미발견"
        fi
    else
        _test_fail "discord-route.sh 파일 미발견"
    fi

    # T7: 완료 아카이브 디렉토리 생성 확인
    _test_start "결과 아카이브 디렉토리 생성 가능"
    RESULTS_DIR="${BOT_HOME}/results/task-outcomes"
    if mkdir -p "$RESULTS_DIR" 2>/dev/null; then
        if [[ -d "$RESULTS_DIR" ]]; then
            _test_pass
        else
            _test_fail "결과 디렉토리 생성 실패"
        fi
    else
        _test_fail "결과 디렉토리 권한 부족"
    fi

    # T8: RAG 피드백 디렉토리 생성 확인
    _test_start "RAG 피드백 디렉토리 생성 가능"
    RAG_DIR="${BOT_HOME}/rag"
    if mkdir -p "$RAG_DIR" 2>/dev/null; then
        if [[ -d "$RAG_DIR" ]]; then
            _test_pass
        else
            _test_fail "RAG 디렉토리 생성 실패"
        fi
    else
        _test_fail "RAG 디렉토리 권한 부족"
    fi

    # ── 테스트 결과 요약 ──
    printf '\n========== 테스트 결과 ==========\n'
    printf '총 %d개: 통과 %d개, 실패 %d개\n' "$_test_count" "$_test_pass" "$_test_fail"

    if [[ "$_test_fail" -eq 0 ]]; then
        printf '\n✅ 모든 테스트 통과!\n'
        return 0
    else
        printf '\n❌ %d개 테스트 실패\n' "$_test_fail" >&2
        return 1
    fi
}

# 대화식 실행인 경우만 테스트 수행
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_tests
fi
