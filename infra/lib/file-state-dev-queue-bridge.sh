#!/usr/bin/env bash
# file-state-dev-queue-bridge.sh — 파일 상태 모순 감지 → dev-queue 자동 로깅
#
# 클러스터 ID  : cl-6f0c8cc1df90e995 (최근 7일 재발 40건)
# 용도         : 파일 상태 모순 감지 시 dev-queue에 Tier 2 경고 자동 생성
# 목적         : 반복되는 파일 상태 모순을 추적하고 자동 학습 규칙 생성 준비
#
# 사용법:
#   source "${BOT_HOME}/lib/file-state-dev-queue-bridge.sh"
#
#   # 파일 상태 모순 감지 후:
#   enqueue_file_state_contradiction_task "task-123" "파일 존재/부재 모순" "ERROR"
#
# 반환값:
#   0 = 성공
#   1 = 실패 (자동 계속 진행, 경고만 기록)

set -euo pipefail

export BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"

# ═════════════════════════════════════════════════════════════════════════════════
# [1] enqueue_file_state_contradiction_task — dev-queue에 Tier 2 작업 추가
# ═════════════════════════════════════════════════════════════════════════════════
#
# 작업 유형: "파일 상태 모순 분석 (Tier 2)"
# 자동 실행: dev-runner.sh가 주기적으로 폴링하여 처리
# 목표: 클러스터 내 파일 상태 모순 패턴을 자동으로 분석하고 규칙 생성
#
# SQLite task-store에 다음 구조로 저장:
#   - status: "pending" (자동 실행 대기)
#   - source: "file-state-guard" (추적 용도)
#   - meta.original_task_id: 모순이 감지된 원본 작업 ID
#   - meta.violation_type: "FILE_STATE_CONTRADICTION" | "FILE_STATE_REPETITIVE"

enqueue_file_state_contradiction_task() {
    local original_task_id="$1"
    local violation_desc="${2:-파일 상태 모순}"
    local severity="${3:-WARN}"

    [[ -z "$original_task_id" ]] && {
        printf '[FSDQB] ERROR: enqueue called with empty original_task_id\n' >&2
        return 1
    }

    # task-store CLI 호출 준비
    local task_store_cli="${BOT_HOME}/lib/task-store.mjs"

    [[ ! -f "$task_store_cli" ]] && {
        printf '[FSDQB] WARNING: task-store.mjs not found at %s\n' "$task_store_cli" >&2
        return 1
    }

    # 새 작업 ID 생성
    local new_task_id
    new_task_id="file-state-analysis-$(date -u +%s)-$(openssl rand -hex 4 2>/dev/null || echo "rand")"

    # 메타데이터 구성 (jq로 JSON 직접 생성)
    local meta_json
    meta_json=$(cat <<EOF | jq -c .
{
  "original_task_id": "$original_task_id",
  "violation_type": "FILE_STATE_CONTRADICTION",
  "violation_description": "$violation_desc",
  "severity": "$severity",
  "cluster_id": "cl-6f0c8cc1df90e995",
  "detection_ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "name": "파일 상태 모순 분석 (Tier 2)",
  "prompt": "다음 클러스터의 파일 상태 모순 패턴을 분석하고 자동 방어 규칙을 제안하세요: 클러스터=cl-6f0c8cc1df90e995, 위반=$violation_desc, 심각도=$severity, 원본=$original_task_id",
  "allowedTools": ["Read", "Bash"],
  "maxBudget": 0.05,
  "timeout": 120,
  "completionCheck": "success"
}
EOF
    )

    # task-store에 저장 시도 — propose(pending 적재, promote 대기)로 등록
    # 과거 enqueue 호출은 미존재 플래그(--status/--meta) + --title 누락으로 항상 실패했음 (2026-07-17 수리)
    if command -v node &>/dev/null; then
        local propose_out
        if propose_out=$(node "$task_store_cli" propose \
            --id "$new_task_id" \
            --title "파일 상태 모순 분석 (Tier 2)" \
            --prompt "$(echo "$meta_json" | jq -r '.prompt')" \
            --source "file-state-guard" \
            --priority low 2>/dev/null) && echo "$propose_out" | grep -q '"action":"proposed"'; then
            printf '[FSDQB] Proposed Tier 2 analysis task: %s (original=%s)\n' "$new_task_id" "$original_task_id" >&2
            return 0
        fi
        # node/propose 실패 시 수동 JSON 기록
        record_manual_task_entry "$new_task_id" "$original_task_id" "$violation_desc" "$severity"
    else
        # node 불가능 시 수동 기록
        record_manual_task_entry "$new_task_id" "$original_task_id" "$violation_desc" "$severity"
    fi
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [2] record_manual_task_entry — task-store 불가능 시 수동 JSONL 기록
# ═════════════════════════════════════════════════════════════════════════════════

record_manual_task_entry() {
    local new_task_id="$1"
    local original_task_id="$2"
    local violation_desc="$3"
    local severity="$4"

    mkdir -p "$BOT_HOME/logs" || return 1

    local task_record
    task_record=$(cat <<EOF
{
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "task_id": "$new_task_id",
  "action": "enqueue_file_state_task",
  "original_task_id": "$original_task_id",
  "violation_type": "FILE_STATE_CONTRADICTION",
  "violation_description": "$violation_desc",
  "severity": "$severity",
  "cluster_id": "cl-6f0c8cc1df90e995",
  "status": "pending",
  "source": "file-state-guard"
}
EOF
    )

    printf '%s\n' "$task_record" >> "$BOT_HOME/logs/file-state-dev-queue-log.jsonl"

    printf '[FSDQB] Manual task entry recorded: %s\n' "$new_task_id" >&2
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [3] get_pending_file_state_analysis_tasks — 대기 중인 Tier 2 작업 조회
# ═════════════════════════════════════════════════════════════════════════════════
#
# 용도: dev-runner.sh가 주기적으로 호출하여 수행할 작업 목록 조회

get_pending_file_state_analysis_tasks() {
    local log_file="$BOT_HOME/logs/file-state-dev-queue-log.jsonl"

    [[ ! -f "$log_file" ]] && {
        printf '[]'
        return 0
    }

    # 오늘 기록된 pending 작업 조회
    printf '[' > /tmp/pending-tasks.json
    local first=true
    while IFS= read -r line; do
        if printf '%s' "$line" | grep -q '"status": "pending"'; then
            if [[ "$first" == true ]]; then
                printf '%s' "$line" >> /tmp/pending-tasks.json
                first=false
            else
                printf ',%s' "$line" >> /tmp/pending-tasks.json
            fi
        fi
    done < "$log_file"
    printf ']' >> /tmp/pending-tasks.json

    cat /tmp/pending-tasks.json
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [4] Integration Hook — ask-claude.sh 후처리에 자동 통합
# ═════════════════════════════════════════════════════════════════════════════════
#
# ask-claude.sh의 후처리 단계에서 file-state-contradiction-guard.sh와 함께 호출
#
# 예시 (ask-claude.sh 의사코드):
#   source "${BOT_HOME}/lib/file-state-contradiction-guard.sh"
#   guard_file_state_contradictions "$TASK_ID" "$RAW_OUTPUT" || {
#       # 모순 감지 시 dev-queue 자동 등록
#       source "${BOT_HOME}/lib/file-state-dev-queue-bridge.sh"
#       enqueue_file_state_contradiction_task "$TASK_ID" "$(get_contradiction_stats | jq -r '.message')" "ERROR"
#   }

# ═════════════════════════════════════════════════════════════════════════════════
# Export
# ═════════════════════════════════════════════════════════════════════════════════

export -f enqueue_file_state_contradiction_task
export -f record_manual_task_entry
export -f get_pending_file_state_analysis_tasks

return 0 2>/dev/null || true
