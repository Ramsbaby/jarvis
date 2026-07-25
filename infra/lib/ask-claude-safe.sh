#!/bin/bash
# ask-claude-safe.sh — ask-claude.sh의 안전한 래퍼
#
# ask-claude.sh 호출 시 자동으로 idempotency 체크를 수행하고,
# 중복 명령을 감지하여 상태 혼란을 방지합니다.
#
# 사용:
#   source ~/.jarvis/lib/ask-claude-safe.sh
#   ask_claude_safe TASK_ID PROMPT [ALLOWED_TOOLS] [TIMEOUT] [MAX_BUDGET]
#

set -euo pipefail

# 의존성
readonly ASK_CLAUDE_BIN="${ASK_CLAUDE_BIN:-${HOME}/claude-discord-bridge-refactor/bin/ask-claude.sh}"
source "${HOME}/.jarvis/lib/idempotency-middleware.sh" 2>/dev/null || {
    echo "ERROR: idempotency-middleware.sh not found" >&2
    exit 1
}

# cl-faf6f4c1f94bd512: 백그라운드 작업 exit code 자동 기록 (bg_task_record_exit 활성화)
_CL_FAF6_GUARD="${HOME}/jarvis/infra/lib/cluster-guard-cl-faf6f4c1f94bd512.sh"
if [[ -f "$_CL_FAF6_GUARD" ]]; then
    # shellcheck disable=SC1090
    source "$_CL_FAF6_GUARD" 2>/dev/null || true
fi
unset _CL_FAF6_GUARD

# cl-53499c7975efb1b0: 문서 내부 불일치 검증 가드 (숫자 교차검증)
_CL_5349_GUARD="${HOME}/jarvis/infra/lib/cluster-guard-cl-53499c7975efb1b0.sh"
if [[ -f "$_CL_5349_GUARD" ]]; then
    # shellcheck disable=SC1090
    source "$_CL_5349_GUARD" 2>/dev/null || true
fi
unset _CL_5349_GUARD

# 메인 함수: 멱등성 체크를 포함한 ask-claude 호출
ask_claude_safe() {
    local task_id="$1"
    local prompt="$2"
    local allowed_tools="${3:-Read}"
    local timeout="${4:-180}"
    local max_budget="${5:-}"
    local result_retention="${6:-7}"
    local model="${7:-}"

    if [[ ! -f "$ASK_CLAUDE_BIN" ]]; then
        echo "ERROR: ask-claude.sh not found at $ASK_CLAUDE_BIN" >&2
        return 1
    fi

    # Step 1: 중복 체크
    local dup_result
    dup_result=$(check_and_protect_duplicate "$task_id" "$prompt" 2>&1 || echo "check_failed")

    case "$?" in
        0)
            # 새로운 명령: 정상 진행
            ;;
        1)
            # 진행중인 명령: 경고 + 선택지
            echo "ERROR: Duplicate command in progress. Please wait or retry later." >&2
            return 1
            ;;
        2)
            # 완료된 명령: 경고만 하고 진행 (재실행 가능)
            echo "WARNING: This command was already completed. Rerunning may create duplicate results." >&2
            ;;
        3)
            # 이전 실패: 경고만 하고 재시도
            echo "WARNING: Previous execution of this command failed. Retrying..." >&2
            ;;
    esac

    # Step 2: ask-claude.sh 실행
    local exit_code=0
    if [[ -n "$model" ]]; then
        "$ASK_CLAUDE_BIN" "$task_id" "$prompt" "$allowed_tools" "$timeout" "$max_budget" "$result_retention" "$model" || exit_code=$?
    elif [[ -n "$result_retention" ]]; then
        "$ASK_CLAUDE_BIN" "$task_id" "$prompt" "$allowed_tools" "$timeout" "$max_budget" "$result_retention" || exit_code=$?
    elif [[ -n "$max_budget" ]]; then
        "$ASK_CLAUDE_BIN" "$task_id" "$prompt" "$allowed_tools" "$timeout" "$max_budget" || exit_code=$?
    elif [[ -n "$timeout" ]]; then
        "$ASK_CLAUDE_BIN" "$task_id" "$prompt" "$allowed_tools" "$timeout" || exit_code=$?
    else
        "$ASK_CLAUDE_BIN" "$task_id" "$prompt" "$allowed_tools" || exit_code=$?
    fi

    # Step 3: 결과 기록
    if [[ $exit_code -eq 0 ]]; then
        mark_command_completed "$task_id" "$prompt" "Success"
    else
        mark_command_failed "$task_id" "$prompt" "Failed with exit code $exit_code"
    fi

    # Step 3-G: cl-faf6f4c1f94bd512 — exit code 기록 (bg_task_verify가 나중에 읽음)
    if command -v bg_task_record_exit >/dev/null 2>&1; then
        bg_task_record_exit "$task_id" "$exit_code" 2>/dev/null || true
    fi

    return $exit_code
}

# 선택사항: 상태 조회 함수
ask_claude_status() {
    local task_id="$1"
    local prompt="$2"

    get_command_state "$task_id" "$prompt"
}

# 메인
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # 직접 실행된 경우
    ask_claude_safe "$@"
fi
