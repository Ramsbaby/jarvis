#!/usr/bin/env bash
set -euo pipefail

# dev-runner.sh — 자율 개발 큐 러너
# Usage: dev-runner.sh [daily]
# 큐에서 다음 실행 가능한 태스크 1개를 선택하여 실행.
# completionCheck로 사전 완료 여부를 판별하고, 미완료 시에만 claude -p 호출.
#
# 안전장치:
#   - 실행 전 git snapshot (자동 커밋) → 실패 시 git revert
#   - completionCheck에 문법 검증 포함 권장
#   - 비정상 종료 시 running → queued 자동 복구 (trap)

# JARVIS_HOME → BOT_HOME 우선순위: 환경변수 JARVIS_HOME > BOT_HOME > 스크립트 상대경로
JARVIS_HOME="${JARVIS_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BOT_HOME="${BOT_HOME:-$JARVIS_HOME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/compat.sh" 2>/dev/null || true
source "${BOT_HOME}/lib/log-utils.sh" 2>/dev/null || true

_TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

DB_FILE="${BOT_HOME}/state/tasks.db"
NODE_SQLITE="node --experimental-sqlite --no-warnings"
DEV_LOG="${BOT_HOME}/logs/dev-runner.log"
COMPLETION_CHECK_TIMEOUT=10

mkdir -p "$(dirname "$DEV_LOG")"

# --- 로깅 ---
_log() {
    echo "[$(date '+%F %T')] [dev-runner] $1" >> "$DEV_LOG"
}

# --- Discord 긴급 알림 (webhook 직접 호출, Nexus 의존 없음) ---
_discord_alert() {
    local msg="$1"
    local monitoring_config="${BOT_HOME}/config/monitoring.json"
    local webhook_url
    webhook_url=$(jq -r '.webhooks["jarvis"] // empty' "$monitoring_config" 2>/dev/null || true)
    if [[ -n "${webhook_url:-}" ]]; then
        local payload; payload=$(jq -n --arg m "$msg" '{content: $m}')
        curl -sS -X POST "$webhook_url" \
            -H "Content-Type: application/json" \
            -d "$payload" > /dev/null 2>&1 || true
    fi
}

# --- tasks.db 상태 전이 ---
update_queue() {
    local task_id="$1"
    local new_status="$2"
    local extra_json="${3:-{}}"

    local _uq_out
    _uq_out=$(${NODE_SQLITE} "${BOT_HOME}/lib/task-store.mjs" \
        transition "$task_id" "$new_status" "bash" "$extra_json" 2>&1) || {
        local _err_msg="⚠️ **dev-runner**: \`update_queue\` 실패 (task=\`${task_id}\`, status=\`${new_status}\`)
오류: ${_uq_out:0:300}
수동 확인: \`node task-store.mjs get ${task_id}\`"
        _log "ERROR: update_queue 실패 (task=${task_id}, status=${new_status}): ${_uq_out}"
        _discord_alert "$_err_msg"
        return 1
    }
}

# --- completionCheck 실행 (bash -c, eval 아님) ---
run_completion_check() {
    local check="$1"
    local _cc_out

    if [[ -z "$check" || "$check" == "null" ]]; then
        return 1
    fi

    # ~ 확장
    local expanded="${check//\~/$HOME}"

    # 스크립트 파일 경로인 경우 직접 실행
    if [[ "$expanded" == /* && -x "$expanded" ]]; then
        if [[ -n "${_TIMEOUT_CMD}" ]]; then
            _cc_out=$(${_TIMEOUT_CMD} "$COMPLETION_CHECK_TIMEOUT" "$expanded" 2>&1) || {
                _log "completionCheck 실패 (스크립트): exit=$?, output=${_cc_out:0:200}"
                return 1
            }
        else
            _cc_out=$("$expanded" 2>&1) || {
                _log "completionCheck 실패 (스크립트): exit=$?, output=${_cc_out:0:200}"
                return 1
            }
        fi
        return 0
    fi

    # 인라인 bash 명령
    if [[ -n "${_TIMEOUT_CMD}" ]]; then
        _cc_out=$(${_TIMEOUT_CMD} "$COMPLETION_CHECK_TIMEOUT" bash -c "$expanded" 2>&1) || {
            _log "completionCheck 실패 (인라인): exit=$?, cmd=${expanded:0:100}, output=${_cc_out:0:200}"
            return 1
        }
    else
        _cc_out=$(bash -c "$expanded" 2>&1) || {
            _log "completionCheck 실패 (인라인): exit=$?, cmd=${expanded:0:100}, output=${_cc_out:0:200}"
            return 1
        }
    fi
    return 0
}

# --- P0: Git snapshot (실행 전 자동 커밋) ---
_SNAPSHOT_HASH=""

create_snapshot() {
    if ! git -C "$BOT_HOME" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        _log "WARNING: git repo 아님, snapshot 생략"
        return 0
    fi

    # 현재 변경사항을 스냅샷 커밋 (나중에 revert 가능)
    git -C "$BOT_HOME" add -A >/dev/null 2>&1 || true
    if git -C "$BOT_HOME" diff --cached --quiet 2>/dev/null; then
        # staged 변경 없으면 현재 HEAD가 스냅샷
        _SNAPSHOT_HASH=$(git -C "$BOT_HOME" rev-parse HEAD 2>/dev/null)
        _log "snapshot: 변경 없음, HEAD=${_SNAPSHOT_HASH:0:8}"
    else
        git -C "$BOT_HOME" commit -m "snapshot: dev-runner 실행 전 자동 저장 ($(date '+%F %T'))" \
            --no-gpg-sign --quiet 2>/dev/null || true
        _SNAPSHOT_HASH=$(git -C "$BOT_HOME" rev-parse HEAD 2>/dev/null)
        _log "snapshot: 커밋 생성 ${_SNAPSHOT_HASH:0:8}"
    fi
}

rollback_snapshot() {
    if [[ -z "$_SNAPSHOT_HASH" ]]; then
        _log "rollback: snapshot 없음, 건너뜀"
        return 0
    fi

    local current_hash
    current_hash=$(git -C "$BOT_HOME" rev-parse HEAD 2>/dev/null)

    if [[ "$current_hash" == "$_SNAPSHOT_HASH" ]]; then
        _log "rollback: HEAD가 snapshot과 동일, 변경 없음"
        return 0
    fi

    # snapshot 이후의 변경을 되돌림
    _log "rollback: ${current_hash:0:8} → ${_SNAPSHOT_HASH:0:8}"
    git -C "$BOT_HOME" reset --hard "$_SNAPSHOT_HASH" --quiet 2>/dev/null || {
        _log "ERROR: git reset 실패, 수동 복구 필요"
        return 1
    }
    _log "rollback: 완료"
}

# --- P2: priority 기반 태스크 선택 ---
pick_next_task() {
    ${NODE_SQLITE} "${BOT_HOME}/lib/task-store.mjs" pick 2>>"$DEV_LOG"
}

# --- 태스크 필드 읽기 ---
get_field() {
    local task_id="$1"
    local field="$2"
    ${NODE_SQLITE} "${BOT_HOME}/lib/task-store.mjs" field "$task_id" "$field" 2>>"$DEV_LOG"
}

# ============================================================
# 메인 실행
# ============================================================

if [[ ! -f "$DB_FILE" ]]; then
    echo "dev-queue 비어있음: tasks.db 없음"
    exit 0
fi

# 큐에 queued 태스크가 있는지 확인
QUEUED_COUNT=$(${NODE_SQLITE} "${BOT_HOME}/lib/task-store.mjs" count-queued 2>>"$DEV_LOG")
if [[ "$QUEUED_COUNT" -eq 0 ]]; then
    _log "큐 비어있음 (all done/failed)"
    echo "dev-queue 비어있음: 대기 중인 개발 작업 없음"
    exit 0
fi

# 다음 태스크 선택
TASK_ID=$(pick_next_task)
if [[ -z "$TASK_ID" ]]; then
    _log "실행 가능 태스크 없음 (의존성 미충족 또는 재시도 한도 초과)"
    echo "dev-queue: 실행 가능한 태스크 없음 (의존성 대기 또는 재시도 한도)"
    exit 0
fi

TASK_NAME=$(get_field "$TASK_ID" "name")
PROMPT=$(get_field "$TASK_ID" "prompt")
COMPLETION_CHECK=$(get_field "$TASK_ID" "completionCheck")
MAX_BUDGET=$(get_field "$TASK_ID" "maxBudget")
TIMEOUT=$(get_field "$TASK_ID" "timeout")
ALLOWED_TOOLS=$(get_field "$TASK_ID" "allowedTools")
PATCH_ONLY=$(get_field "$TASK_ID" "patchOnly")
RETRIES=$(get_field "$TASK_ID" "retries"); RETRIES="${RETRIES:-0}"
MAX_RETRIES=$(get_field "$TASK_ID" "maxRetries"); MAX_RETRIES="${MAX_RETRIES:-2}"

# 기본값
TIMEOUT="${TIMEOUT:-300}"
ALLOWED_TOOLS="${ALLOWED_TOOLS:-Bash,Read,Write}"
MAX_BUDGET="${MAX_BUDGET:-1.00}"

_log "태스크 선택: ${TASK_ID} (${TASK_NAME}), 시도 $((RETRIES+1))/${MAX_RETRIES}"

# --- Step 1: completionCheck 사전 판별 ---
if run_completion_check "$COMPLETION_CHECK"; then
    _log "completionCheck 통과: ${TASK_ID} → 이미 완료됨 (LLM 호출 없이 done)"
    update_queue "$TASK_ID" "done"
    cat <<DONE_MSG
## dev-runner 결과

**${TASK_NAME}** (${TASK_ID})
completionCheck 통과 → 이미 완료 확인. LLM 호출 없이 done 처리.
DONE_MSG
    exit 0
fi

_log "completionCheck 미통과: ${TASK_ID} → claude -p 실행"

# --- Step 2: git snapshot 생성 (P0: 롤백 대비) ---
create_snapshot

# --- Step 3: status를 running으로 변경 + 비정상 종료 시 복구 trap ---
_RUNNING_TASK_ID="$TASK_ID"
_dev_cleanup() {
    local rc=$?
    if [[ -n "${_RUNNING_TASK_ID:-}" && $rc -ne 0 ]]; then
        _log "비정상 종료 (exit: $rc): ${_RUNNING_TASK_ID} → queued로 복구 + rollback"
        rollback_snapshot 2>/dev/null || true
        update_queue "$_RUNNING_TASK_ID" "queued" 2>/dev/null || true
    fi
}
trap _dev_cleanup EXIT

update_queue "$TASK_ID" "running"

# --- Step 4: patchOnly 프롬프트 접미사 ---
if [[ "$PATCH_ONLY" == "true" ]]; then
    PROMPT="${PROMPT}

중요: 실제 파일을 수정하지 말 것. 패치 파일만 ~/.jarvis/state/dev-patches/${TASK_ID}.patch 에 unified diff 형식으로 생성하라."
fi

# --- Step 5: retry-wrapper.sh 호출 ---
RESULT=""
EXIT_CODE=0
RESULT=$("${BOT_HOME}/bin/retry-wrapper.sh" \
    "$TASK_ID" \
    "$PROMPT" \
    "$ALLOWED_TOOLS" \
    "$TIMEOUT" \
    "$MAX_BUDGET" \
    "30" \
    "") || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    NEW_RETRIES=$((RETRIES + 1))
    _log "실패: ${TASK_ID} (exit: ${EXIT_CODE}, 시도 ${NEW_RETRIES}/${MAX_RETRIES})"

    # P0: 실패 시 롤백
    rollback_snapshot
    _log "실패 후 rollback 완료"

    # P2: 실패 메타데이터 기록
    local_extra="{\"retries\": ${NEW_RETRIES}, \"lastError\": \"exit_code=${EXIT_CODE}\"}"

    if [[ $NEW_RETRIES -ge $MAX_RETRIES ]]; then
        update_queue "$TASK_ID" "failed" "$local_extra"
        echo "## dev-runner 결과

**${TASK_NAME}** (${TASK_ID})
실패 (재시도 한도 ${MAX_RETRIES}회 도달). 수동 확인 필요.
rollback: snapshot ${_SNAPSHOT_HASH:0:8}로 복구됨."
    else
        update_queue "$TASK_ID" "queued" "$local_extra"
        echo "## dev-runner 결과

**${TASK_NAME}** (${TASK_ID})
실패 (시도 ${NEW_RETRIES}/${MAX_RETRIES}). 내일 재시도 예정.
rollback: snapshot ${_SNAPSHOT_HASH:0:8}로 복구됨."
    fi
    _RUNNING_TASK_ID=""
    exit 0
fi

# --- Step 6: 실행 후 completionCheck 재확인 ---
if run_completion_check "$COMPLETION_CHECK"; then
    # 성공: snapshot 이후 변경을 정식 커밋
    if [[ -n "$_SNAPSHOT_HASH" ]]; then
        git -C "$BOT_HOME" add -A >/dev/null 2>&1 || true
        git -C "$BOT_HOME" commit -m "dev-runner: ${TASK_ID} 완료 (자동)" \
            --no-gpg-sign --quiet 2>/dev/null || true
        _log "성공 커밋 생성"
    fi
    update_queue "$TASK_ID" "done"
    _log "완료: ${TASK_ID} (completionCheck 통과)"
    RESULT_SUMMARY="completionCheck 통과 → 작업 완료 확인"
else
    # completionCheck 미통과 → 롤백 + 재시도
    NEW_RETRIES=$((RETRIES + 1))
    _log "부분 완료: ${TASK_ID} (실행 성공, completionCheck 미통과, 시도 ${NEW_RETRIES}/${MAX_RETRIES})"

    # P0: completionCheck 실패 시에도 롤백 (반수정 상태 방지)
    rollback_snapshot
    _log "completionCheck 미통과 → rollback 완료"

    update_queue "$TASK_ID" "queued" "{\"lastError\": \"completionCheck_failed\"}"
    RESULT_SUMMARY="실행 성공하였으나 completionCheck 미통과. rollback 후 다음 실행 시 재시도."
fi

# --- Step 7: 결과 출력 (bot-cron.sh → Discord 라우팅) ---
if [[ ${#RESULT} -gt 1500 ]]; then
    RESULT="${RESULT:0:1500}...(truncated)"
fi

_RUNNING_TASK_ID=""

cat <<EOF
## dev-runner 결과

**${TASK_NAME}** (${TASK_ID})
${RESULT_SUMMARY}

### 실행 결과
${RESULT}
EOF
