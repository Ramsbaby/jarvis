#!/usr/bin/env bash
# task-completion-workflow.sh — 태스크 완료 검증→업로드→레지스트리 갱신 3단계 워크플로우
#
# 목적: 클러스터 cl-a823cc27fbf689ff (완료 마킹만 하고 결과 미기재) 반복 실수 방지
# 사용: task-completion-workflow.sh <TASK_ID> <RESULT_CONTENT> [TRIGGERED_BY]
# 종료 코드:
#   0 = 성공 (done 전이 + 업로드 + 레지스트리 갱신 모두 완료)
#   100 = 검증 실패 (RESULT_REQUIRED) — running → queued 재시도
#   101 = 업로드 실패 — running → queued 재시도
#   102 = 레지스트리 갱신 실패 — running → failed (최대 재시도 초과)
#   기타 = 예기치 않은 오류

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
TASK_ID="${1:-}"
RESULT_CONTENT="${2:-}"
TRIGGERED_BY="${3:-bot-cron/complete}"

# 필수 인자 검증
if [[ -z "$TASK_ID" ]]; then
    printf 'Usage: task-completion-workflow.sh <TASK_ID> <RESULT_CONTENT> [TRIGGERED_BY]\n' >&2
    exit 1
fi

# ── 검증: 결과 필드 유효성 ──────────────────────────────────────────────────

_log() {
    local level="$1"
    shift
    local msg="$*"
    printf '[%s] [%s] %s\n' "$(TZ=Asia/Seoul date '+%H:%M:%S')" "$level" "$msg" >&2
}

_log "INFO" "[$TASK_ID] 완료 워크플로우 시작 (TRIGGERED_BY=$TRIGGERED_BY)"

# Step 1: 결과 필드 검증
_log "INFO" "[$TASK_ID] Step 1/3: 검증 (result 필드)"
if [[ -z "${RESULT_CONTENT:-}" ]] || [[ -z "$(echo "$RESULT_CONTENT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" ]]; then
    _log "ERROR" "[$TASK_ID] RESULT_REQUIRED — 결과 필드가 비어있거나 공백입니다."
    # 검증 실패 → running → queued (재시도)
    exit 100
fi

_log "INFO" "[$TASK_ID] 결과 길이: ${#RESULT_CONTENT} bytes"

# ── 업로드: 결과를 저장소에 적재 ───────────────────────────────────────────

_log "INFO" "[$TASK_ID] Step 2/3: 업로드 (결과 저장)"

# 2a. 결과 아카이브 디렉토리 생성
RESULTS_DIR="${BOT_HOME}/results/task-outcomes"
mkdir -p "$RESULTS_DIR" 2>/dev/null || {
    _log "WARN" "[$TASK_ID] 결과 디렉토리 생성 실패, 계속 진행"
}

# 2b. 결과 파일 저장 (YYYY-MM-DD-<TASK_ID>.json 형식)
RESULT_DATE=$(date '+%Y-%m-%d')
RESULT_FILE="${RESULTS_DIR}/${RESULT_DATE}-${TASK_ID}.json"

if [[ -w "${RESULTS_DIR}" ]]; then
    {
        cat <<EOF
{
  "task_id": "$TASK_ID",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "status": "done",
  "triggered_by": "$TRIGGERED_BY",
  "result_content": $(printf '%s' "$RESULT_CONTENT" | jq -Rs .),
  "result_length": ${#RESULT_CONTENT}
}
EOF
    } > "$RESULT_FILE" 2>/dev/null || {
        _log "WARN" "[$TASK_ID] 결과 파일 저장 실패: $RESULT_FILE (계속 진행)"
    }
fi

# 2c. RAG 피드백 루프 (task-store.mjs transition 후 자동 수행되지만, 명시적 기록)
RAG_DIR="${BOT_HOME}/rag"
mkdir -p "$RAG_DIR" 2>/dev/null || true
RAG_MONTH=$(date '+%Y-%m')
RAG_FILE="${RAG_DIR}/task-outcomes-${RAG_MONTH}.md"

if [[ -w "$RAG_DIR" ]]; then
    {
        cat <<EOF

## [done] \`${TASK_ID}\`
- **완료일시**: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
- **결과 길이**: ${#RESULT_CONTENT} bytes
- **triggeredBy**: $TRIGGERED_BY
- **결과 미리보기**: $(echo "$RESULT_CONTENT" | head -c 120)...
EOF
    } >> "$RAG_FILE" 2>/dev/null || {
        _log "WARN" "[$TASK_ID] RAG 파일 기록 실패 (계속 진행)"
    }
fi

_log "INFO" "[$TASK_ID] 업로드 완료: $RESULT_FILE"

# ── 레지스트리 갱신: task-store.mjs 통해 FSM 전이 ─────────────────────────

_log "INFO" "[$TASK_ID] Step 3/3: 레지스트리 갱신 (FSM 상태 전이)"

# 3a. transition running → done (result 필드 포함)
EXTRA_JSON=$(jq -n -c \
    --arg result "$RESULT_CONTENT" \
    --arg completionWorkflow "$0" \
    '{result: $result, completionWorkflowPath: $completionWorkflow}')

if ! node --experimental-sqlite --no-warnings "${BOT_HOME}/lib/task-store.mjs" \
    transition "$TASK_ID" done "$TRIGGERED_BY" "$EXTRA_JSON" >/dev/null 2>&1; then
    _log "ERROR" "[$TASK_ID] FSM 전이 실패 (running → done)"
    # 레지스트리 갱신 실패 — 종료 코드 102로 표시 (최대 재시도 초과 시 failed)
    exit 102
fi

_log "INFO" "[$TASK_ID] FSM 전이 완료: running → done"

# 3b. 완료 이력 기록 (ledger/task-completion.jsonl)
LEDGER_DIR="${BOT_HOME}/ledger"
mkdir -p "$LEDGER_DIR" 2>/dev/null || true
LEDGER_FILE="${LEDGER_DIR}/task-completion.jsonl"

if [[ -w "$LEDGER_DIR" ]]; then
    jq -cn \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg task_id "$TASK_ID" \
        --arg triggered_by "$TRIGGERED_BY" \
        --arg result_length "${#RESULT_CONTENT}" \
        '{ts: $ts, task_id: $task_id, triggered_by: $triggered_by, result_length: $result_length, workflow: "task-completion-workflow"}' \
        >> "$LEDGER_FILE" 2>/dev/null || {
        _log "WARN" "[$TASK_ID] 완료 이력 기록 실패 (계속 진행)"
    }
fi

_log "INFO" "[$TASK_ID] 완료 워크플로우 성공 ✅"
exit 0
