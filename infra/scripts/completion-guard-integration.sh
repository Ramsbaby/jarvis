#!/usr/bin/env bash
# completion-guard-integration.sh
# skill-synthesis-verify와 completion-validator의 호환성 통합 레이어
#
# 목적:
# - skill-synthesis-verify 실행 시 completion-validator를 자동 호출
# - 성공/실패 여부에 관계없이 기존 skill-synthesis-verify 로직 보존
# - 완료 검증 결과를 별도 로그에 기록
#
# 사용:
#   source ~/jarvis/runtime/scripts/completion-guard-integration.sh
#   verify_completion_with_guard "task-id" "target_count" "completed_count"

set -euo pipefail

GUARD_LOG="${HOME}/jarvis/runtime/logs/completion-guard.log"
VALIDATOR_SCRIPT="${HOME}/jarvis/runtime/scripts/completion-validator.sh"

mkdir -p "$(dirname "$GUARD_LOG")" 2>/dev/null || true

# 완료 검증 + 가드 래퍼 함수
verify_completion_with_guard() {
    local task_id="${1:-}"
    local total="${2:-0}"
    local completed="${3:-0}"

    if [[ -z "$task_id" ]]; then
        echo "❌ Task ID required" >&2
        return 1
    fi

    local timestamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
    {
        echo "[${timestamp}] Task: ${task_id}"
        echo "[${timestamp}] Total: ${total} | Completed: ${completed}"
    } >> "$GUARD_LOG"

    # completion-validator 호출 (기존 스크립트에 영향 없음)
    if [[ -f "$VALIDATOR_SCRIPT" ]]; then
        # 검증 실행 (실패해도 진행)
        if bash "$VALIDATOR_SCRIPT" --verify --task "$task_id" --total "$total" --completed "$completed" 2>> "$GUARD_LOG"; then
            echo "[${timestamp}] Result: PASS (${completed}/${total})" >> "$GUARD_LOG"
        else
            echo "[${timestamp}] Result: FAIL (${completed}/${total}) - PARTIAL COMPLETION DETECTED" >> "$GUARD_LOG"
            # 부분 완료 경고는 로깅하되, 기존 프로세스는 계속 진행
            echo "⚠️  Completion validation: ${completed}/${total} (partial)" >&2
        fi
    fi
}

# 강제 증거 출력 함수 (skill-synthesis-verify에서 호출)
enforce_completion_evidence() {
    local task_id="${1:-}"
    local total="${2:-0}"
    local completed="${3:-0}"

    if [[ -z "$task_id" ]]; then
        echo "❌ Task ID required" >&2
        return 1
    fi

    if [[ -f "$VALIDATOR_SCRIPT" ]]; then
        bash "$VALIDATOR_SCRIPT" --verify --task "$task_id" --total "$total" --completed "$completed"
    else
        echo "⚠️  Validator script not found: $VALIDATOR_SCRIPT" >&2
        return 1
    fi
}

export -f verify_completion_with_guard
export -f enforce_completion_evidence
