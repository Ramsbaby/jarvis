#!/usr/bin/env bash
# coder-functions.sh — jarvis-coder 공용 함수 라이브러리
# jarvis-coder.sh에서 source하여 사용.
# 호출자가 BOT_HOME을 설정한 후 source해야 함.

: "${BOT_HOME:?BOT_HOME must be set before sourcing coder-functions.sh}"

source "${BOT_HOME}/lib/compat.sh" 2>/dev/null || true
source "${BOT_HOME}/lib/log-utils.sh" 2>/dev/null || true

_TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

DB_FILE="${BOT_HOME}/state/tasks.db"
NODE_SQLITE="node --experimental-sqlite --no-warnings"
DEV_LOG="${BOT_HOME}/logs/jarvis-coder.log"
COMPLETION_CHECK_TIMEOUT=10

mkdir -p "$(dirname "$DEV_LOG")"

# --- 로깅 ---
_coder_log() {
    echo "[$(date '+%F %T')] [jarvis-coder] $1" >> "$DEV_LOG"
}

# --- Discord 긴급 알림 ---
_discord_alert() {
    local msg="$1"
    local monitoring_config="${BOT_HOME}/config/monitoring.json"
    local webhook_url
    webhook_url=$(jq -r '.webhooks["jarvis-system"] // .webhooks["jarvis"] // empty' "$monitoring_config" 2>/dev/null || true)
    if [[ -n "${webhook_url:-}" ]]; then
        local payload; payload=$(jq -n --arg m "$msg" '{content: $m}')
        curl -sS -X POST "$webhook_url" \
            -H "Content-Type: application/json" \
            -d "$payload" > /dev/null 2>&1 || true
    fi
}

# --- Discord #jarvis-ceo 채널 알림 ---
_discord_ceo_notify() {
    local msg="$1"
    local monitoring_config="${BOT_HOME}/config/monitoring.json"
    local ceo_webhook
    ceo_webhook=$(jq -r '(.webhooks["jarvis-ceo"] // .webhooks["jarvis"] // empty)' "$monitoring_config" 2>/dev/null || true)
    if [[ -n "${ceo_webhook:-}" ]]; then
        local payload; payload=$(jq -n --arg m "$msg" '{content: $m}')
        curl -sS -X POST "$ceo_webhook" -H "Content-Type: application/json" -d "$payload" > /dev/null 2>&1 || true
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
        local _err_msg="⚠️ **Jarvis Coder**: \`update_queue\` 실패 (task=\`${task_id}\`, status=\`${new_status}\`)
오류: ${_uq_out:0:300}
수동 확인: \`node task-store.mjs get ${task_id}\`"
        _coder_log "ERROR: update_queue 실패 (task=${task_id}, status=${new_status}): ${_uq_out}"
        _discord_alert "$_err_msg"
        return 1
    }

    # Board API 상태 동기화 (done/failed만)
    if [[ -n "${BOARD_URL:-}" && -n "${AGENT_API_KEY:-}" ]]; then
        local board_status=""
        if [[ "$new_status" == "done" ]]; then
            board_status="done"
        elif [[ "$new_status" == "failed" ]]; then
            board_status="failed"
        fi
        if [[ -n "$board_status" ]]; then
            local board_patch_body
            board_patch_body=$(jq -n \
                --arg status "$board_status" \
                --arg result_summary "$(echo "$extra_json" | jq -r '.result_summary // empty' 2>/dev/null || true)" \
                --argjson changed_files "$(echo "$extra_json" | jq '.changed_files // []' 2>/dev/null || echo '[]')" \
                --argjson execution_log "$(echo "$extra_json" | jq '.execution_log // []' 2>/dev/null || echo '[]')" \
                '{status:$status, result_summary:$result_summary, changed_files:$changed_files, execution_log:$execution_log}' 2>/dev/null \
                || echo "{\"status\":\"${board_status}\"}")
            curl -sf --max-time 5 \
                -X PATCH "${BOARD_URL}/api/dev-tasks/${task_id}" \
                -H "Content-Type: application/json" \
                -H "x-agent-key: ${AGENT_API_KEY}" \
                -d "$board_patch_body" > /dev/null 2>&1 || true
        fi
    fi
}

# --- completionCheck 실행 ---
run_completion_check() {
    local check="$1"
    local _cc_out

    if [[ -z "$check" || "$check" == "null" ]]; then
        return 1
    fi

    local expanded="${check//\~/$HOME}"

    if [[ "$expanded" == /* && -x "$expanded" ]]; then
        if [[ -n "${_TIMEOUT_CMD}" ]]; then
            _cc_out=$(${_TIMEOUT_CMD} "$COMPLETION_CHECK_TIMEOUT" "$expanded" 2>&1) || {
                _coder_log "completionCheck 실패 (스크립트): exit=$?, output=${_cc_out:0:200}"
                return 1
            }
        else
            _cc_out=$("$expanded" 2>&1) || {
                _coder_log "completionCheck 실패 (스크립트): exit=$?, output=${_cc_out:0:200}"
                return 1
            }
        fi
        return 0
    fi

    if [[ -n "${_TIMEOUT_CMD}" ]]; then
        _cc_out=$(${_TIMEOUT_CMD} "$COMPLETION_CHECK_TIMEOUT" bash -c "$expanded" 2>&1) || {
            _coder_log "completionCheck 실패 (인라인): exit=$?, cmd=${expanded:0:100}, output=${_cc_out:0:200}"
            return 1
        }
    else
        _cc_out=$(bash -c "$expanded" 2>&1) || {
            _coder_log "completionCheck 실패 (인라인): exit=$?, cmd=${expanded:0:100}, output=${_cc_out:0:200}"
            return 1
        }
    fi
    return 0
}

# --- Git snapshot ---
rollback_snapshot() {
    local snap="${1:-}"
    if [[ -z "$snap" ]]; then
        _coder_log "rollback: snapshot 없음, 건너뜀"
        return 0
    fi

    local current_hash
    current_hash=$(git -C "$BOT_HOME" rev-parse HEAD 2>/dev/null)

    if [[ "$current_hash" == "$snap" ]]; then
        _coder_log "rollback: HEAD가 snapshot과 동일, 변경 없음"
        return 0
    fi

    local human_commits
    human_commits=$(git -C "$BOT_HOME" log --oneline "${snap}..HEAD" 2>/dev/null \
        | grep -cvE "^[0-9a-f]+ (snapshot:|jarvis-coder:)" || true)
    if (( human_commits > 0 )); then
        _coder_log "rollback 건너뜀: snapshot 이후 인간 커밋 ${human_commits}개 보호"
        return 0
    fi

    _coder_log "rollback: ${current_hash:0:8} → ${snap:0:8}"
    git -C "$BOT_HOME" reset --hard "$snap" --quiet 2>/dev/null || {
        _coder_log "ERROR: git reset 실패, 수동 복구 필요"
        return 1
    }
    _coder_log "rollback: 완료"
}

# --- 태스크 선택 ---
pick_next_task() {
    ${NODE_SQLITE} "${BOT_HOME}/lib/task-store.mjs" pick-and-lock 2>>"$DEV_LOG"
}

# --- 그룹 태스크 선택 (같은 parent_id를 가진 태스크 일괄) ---
pick_next_group() {
    local result
    result=$(${NODE_SQLITE} "${BOT_HOME}/lib/task-store.mjs" pick-group-and-lock 2>>"$DEV_LOG")
    if [[ "$result" == "[]" || -z "$result" ]]; then
        echo ""
        return
    fi
    echo "$result"
}

get_field() {
    local task_id="$1"
    local field="$2"
    ${NODE_SQLITE} "${BOT_HOME}/lib/task-store.mjs" field "$task_id" "$field" 2>>"$DEV_LOG"
}

# ============================================================
# run_task_group — 그룹 태스크 일괄 실행 (하나의 Claude 세션)
# ============================================================
run_task_group() {
    local GROUP_JSON="$1"
    local TASK_IDS
    TASK_IDS=$(echo "$GROUP_JSON" | jq -r '.[]')
    local TASK_COUNT
    TASK_COUNT=$(echo "$GROUP_JSON" | jq 'length')

    _coder_log "그룹 태스크 시작: ${TASK_COUNT}건"

    local COMBINED_PROMPT="## 이 세션에서 처리할 태스크 (총 ${TASK_COUNT}건, 동일 논의 결의안)
모든 태스크를 순서대로 처리하라. 하나의 논의에서 도출된 연관 작업이므로 전체 맥락을 고려하라.
각 태스크를 처리할 때 다른 태스크와의 충돌이 없도록 주의하라.

"
    local MAX_TIMEOUT=0 TOTAL_BUDGET="0" FIRST_ID=""
    local ALL_IDS=() ALL_NAMES=()

    local idx=0
    while IFS= read -r tid; do
        [[ -z "$tid" ]] && continue
        idx=$((idx + 1))
        ALL_IDS+=("$tid")
        [[ -z "$FIRST_ID" ]] && FIRST_ID="$tid"
        local name prompt timeout budget
        name=$(get_field "$tid" "name"); prompt=$(get_field "$tid" "prompt"); prompt="${prompt:-$name}"
        timeout=$(get_field "$tid" "timeout"); timeout="${timeout:-300}"
        budget=$(get_field "$tid" "maxBudget"); budget="${budget:-1.00}"
        ALL_NAMES+=("$name")
        COMBINED_PROMPT="${COMBINED_PROMPT}### 태스크 ${idx}: ${name}
${prompt}

---

"
        if (( timeout > MAX_TIMEOUT )); then MAX_TIMEOUT=$timeout; fi
        TOTAL_BUDGET=$(echo "$TOTAL_BUDGET + $budget" | bc 2>/dev/null || echo "$budget")
    done <<< "$TASK_IDS"

    MAX_TIMEOUT=$(( (MAX_TIMEOUT * 3) / 2 ))
    [[ "$MAX_TIMEOUT" -lt 300 ]] && MAX_TIMEOUT=300

    # git snapshot
    local _SNAPSHOT_HASH=""
    if git -C "$BOT_HOME" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$BOT_HOME" add -A >/dev/null 2>&1 || true
        if git -C "$BOT_HOME" diff --cached --quiet 2>/dev/null; then
            _SNAPSHOT_HASH=$(git -C "$BOT_HOME" rev-parse HEAD 2>/dev/null)
        else
            git -C "$BOT_HOME" commit -m "snapshot: jarvis-coder group [${FIRST_ID}+${TASK_COUNT}]" \
                --no-gpg-sign --quiet 2>/dev/null || true
            _SNAPSHOT_HASH=$(git -C "$BOT_HOME" rev-parse HEAD 2>/dev/null)
        fi
    fi

    # retry-wrapper 1회
    local RESULT="" EXIT_CODE=0
    RESULT=$("${BOT_HOME}/bin/retry-wrapper.sh" \
        "group-${FIRST_ID}" "$COMBINED_PROMPT" "Bash,Read,Write" "$MAX_TIMEOUT" "$TOTAL_BUDGET" "30" "") || EXIT_CODE=$?

    if [[ $EXIT_CODE -ne 0 ]]; then
        _coder_log "그룹 실행 실패 (exit: ${EXIT_CODE})"
        rollback_snapshot "$_SNAPSHOT_HASH"
        for tid in "${ALL_IDS[@]}"; do
            local retries; retries=$(get_field "$tid" "retries"); retries="${retries:-0}"
            local max_retries; max_retries=$(get_field "$tid" "maxRetries"); max_retries="${max_retries:-2}"
            local new_retries=$(( retries + 1 ))
            if (( new_retries >= max_retries )); then
                update_queue "$tid" "failed" "{\"retries\": ${new_retries}, \"lastError\": \"group_exec_failed\"}"
            else
                update_queue "$tid" "queued" "{\"retries\": ${new_retries}, \"lastError\": \"group_exec_failed\"}"
            fi
        done
        _discord_ceo_notify "❌ **Jarvis Coder**: 그룹 태스크 실패 (${TASK_COUNT}건)"
        return 0
    fi

    # 성공: commit 1회 + 전체 done
    if [[ -n "$_SNAPSHOT_HASH" ]]; then
        git -C "$BOT_HOME" add -A >/dev/null 2>&1 || true
        local _CHANGED_COUNT
        _CHANGED_COUNT=$(git -C "$BOT_HOME" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$_CHANGED_COUNT" != "0" ]]; then
            local names_str; names_str=$(printf '%s, ' "${ALL_NAMES[@]}")
            git -C "$BOT_HOME" commit -m "jarvis-coder: 그룹 완료 [${names_str%, }] (${TASK_COUNT}건)" \
                --no-gpg-sign --quiet 2>/dev/null || true
        fi
    fi

    local _changed_files_json="[]" _exec_log_json="[]"
    if [[ -n "$_SNAPSHOT_HASH" ]]; then
        _changed_files_json=$(git -C "$BOT_HOME" diff --name-only "${_SNAPSHOT_HASH}..HEAD" 2>/dev/null \
            | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
        _exec_log_json=$(git -C "$BOT_HOME" log --oneline "${_SNAPSHOT_HASH}..HEAD" 2>/dev/null \
            | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
    fi

    for tid in "${ALL_IDS[@]}"; do
        local name; name=$(get_field "$tid" "name")
        local _done_extra
        _done_extra=$(jq -n \
            --arg result_summary "${name} 완료 (그룹 실행)" \
            --argjson changed_files "$_changed_files_json" \
            --argjson execution_log "$_exec_log_json" \
            '{result_summary:$result_summary, changed_files:$changed_files, execution_log:$execution_log}')
        update_queue "$tid" "done" "$_done_extra"
    done

    _coder_log "그룹 완료: ${TASK_COUNT}건"
    _discord_ceo_notify "✅ **Jarvis Coder**: 그룹 태스크 ${TASK_COUNT}건 완료"
    return 0
}

# ============================================================
# run_one_task — 단일 태스크 실행 (전체 생명주기)
# ============================================================
run_one_task() {
    local TASK_ID="$1"
    local TASK_NAME PROMPT COMPLETION_CHECK MAX_BUDGET TIMEOUT ALLOWED_TOOLS PATCH_ONLY RETRIES MAX_RETRIES
    TASK_NAME=$(get_field "$TASK_ID" "name")
    PROMPT=$(get_field "$TASK_ID" "prompt")
    # prompt 미설정 시 name을 fallback으로 사용 (ensure로 등록된 태스크 방어)
    PROMPT="${PROMPT:-$TASK_NAME}"
    COMPLETION_CHECK=$(get_field "$TASK_ID" "completionCheck")
    MAX_BUDGET=$(get_field "$TASK_ID" "maxBudget")
    TIMEOUT=$(get_field "$TASK_ID" "timeout")
    ALLOWED_TOOLS=$(get_field "$TASK_ID" "allowedTools")
    PATCH_ONLY=$(get_field "$TASK_ID" "patchOnly")
    RETRIES=$(get_field "$TASK_ID" "retries"); RETRIES="${RETRIES:-0}"
    MAX_RETRIES=$(get_field "$TASK_ID" "maxRetries"); MAX_RETRIES="${MAX_RETRIES:-2}"

    TIMEOUT="${TIMEOUT:-300}"
    ALLOWED_TOOLS="${ALLOWED_TOOLS:-Bash,Read,Write}"
    MAX_BUDGET="${MAX_BUDGET:-1.00}"

    _coder_log "태스크 시작: ${TASK_ID} (${TASK_NAME}), 시도 $((RETRIES+1))/${MAX_RETRIES}"

    # Step 1: completionCheck 사전 판별
    if run_completion_check "$COMPLETION_CHECK"; then
        _coder_log "completionCheck 통과: ${TASK_ID} → 이미 완료됨"
        update_queue "$TASK_ID" "running" || _coder_log "WARN: running 전이 실패"
        if ! update_queue "$TASK_ID" "done"; then
            ${NODE_SQLITE} "${BOT_HOME}/lib/task-store.mjs" force-done "${TASK_ID}" 2>/dev/null || \
                _coder_log "WARN: force-done 실패 (task=${TASK_ID})"
        fi
        _discord_ceo_notify "✅ **Jarvis Coder**: \`${TASK_ID}\` 완료 (completionCheck 통과, LLM 생략)"
        return 0
    fi

    _coder_log "completionCheck 미통과: ${TASK_ID} → claude -p 실행"

    # Step 2: git snapshot
    local _SNAPSHOT_HASH=""
    if git -C "$BOT_HOME" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$BOT_HOME" add -A >/dev/null 2>&1 || true
        if git -C "$BOT_HOME" diff --cached --quiet 2>/dev/null; then
            _SNAPSHOT_HASH=$(git -C "$BOT_HOME" rev-parse HEAD 2>/dev/null)
        else
            git -C "$BOT_HOME" commit -m "snapshot: jarvis-coder ${TASK_ID} 실행 전 ($(date '+%F %T'))" \
                --no-gpg-sign --quiet 2>/dev/null || true
            _SNAPSHOT_HASH=$(git -C "$BOT_HOME" rev-parse HEAD 2>/dev/null)
        fi
    fi

    # Step 3: running 전이 (pick-and-lock이 이미 처리)
    _coder_log "running: ${TASK_ID} (already locked by pick-and-lock)"

    # Step 4: patchOnly
    if [[ "$PATCH_ONLY" == "true" ]]; then
        PROMPT="${PROMPT}

중요: 실제 파일을 수정하지 말 것. 패치 파일만 ~/.jarvis/state/dev-patches/${TASK_ID}.patch 에 unified diff 형식으로 생성하라."
    fi

    # Step 5: retry-wrapper.sh 호출
    local RESULT="" EXIT_CODE=0
    RESULT=$("${BOT_HOME}/bin/retry-wrapper.sh" \
        "$TASK_ID" "$PROMPT" "$ALLOWED_TOOLS" "$TIMEOUT" "$MAX_BUDGET" "30" "") || EXIT_CODE=$?

    if [[ $EXIT_CODE -ne 0 ]]; then
        if [[ $EXIT_CODE -eq 100 ]]; then
            _coder_log "세마포어 포화: ${TASK_ID} → retry 소모 없이 재큐잉"
            update_queue "$TASK_ID" "queued" "{\"retries\": ${RETRIES}, \"lastError\": \"semaphore_full\"}"
            return 0
        fi
        local NEW_RETRIES=$(( RETRIES + 1 ))
        _coder_log "실패: ${TASK_ID} (exit: ${EXIT_CODE}, 시도 ${NEW_RETRIES}/${MAX_RETRIES})"
        rollback_snapshot "$_SNAPSHOT_HASH"
        if [[ $NEW_RETRIES -ge $MAX_RETRIES ]]; then
            local _fail_extra
            _fail_extra=$(jq -n \
                --argjson retries "$NEW_RETRIES" \
                --arg lastError "exit_code=${EXIT_CODE}" \
                --arg result_summary "실패: exit_code=${EXIT_CODE}, ${NEW_RETRIES}/${MAX_RETRIES} 시도 소진" \
                '{retries:$retries, lastError:$lastError, result_summary:$result_summary, changed_files:[], execution_log:[]}')
            update_queue "$TASK_ID" "failed" "$_fail_extra"
            _discord_ceo_notify "❌ **Jarvis Coder**: \`${TASK_ID}\` 실패 (한도 ${MAX_RETRIES}회 도달)"
        else
            local local_extra="{\"retries\": ${NEW_RETRIES}, \"lastError\": \"exit_code=${EXIT_CODE}\"}"
            update_queue "$TASK_ID" "queued" "$local_extra"
        fi
        return 0
    fi

    # Step 6: completionCheck 재확인
    local _CHECK_PASSED=false
    if [[ -z "$COMPLETION_CHECK" || "$COMPLETION_CHECK" == "null" ]]; then
        _CHECK_PASSED=true
    elif run_completion_check "$COMPLETION_CHECK"; then
        _CHECK_PASSED=true
    fi

    if [[ "$_CHECK_PASSED" == "true" ]]; then
        if [[ -n "$_SNAPSHOT_HASH" ]]; then
            git -C "$BOT_HOME" add -A >/dev/null 2>&1 || true
            local _CHANGED_COUNT
            _CHANGED_COUNT=$(git -C "$BOT_HOME" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$_CHANGED_COUNT" == "0" ]]; then
                _coder_log "WARN: 변경 파일 0건 — 유령 태스크 방지, failed 처리: ${TASK_ID}"
                local NEW_RETRIES=$(( RETRIES + 1 ))
                if (( NEW_RETRIES >= MAX_RETRIES )); then
                    update_queue "$TASK_ID" "failed" "{\"retries\": ${NEW_RETRIES}, \"lastError\": \"no_files_changed\"}"
                    _discord_ceo_notify "⚠️ **Jarvis Coder**: \`${TASK_ID}\` 변경 파일 0건 — failed 처리"
                else
                    update_queue "$TASK_ID" "queued" "{\"retries\": ${NEW_RETRIES}, \"lastError\": \"no_files_changed\"}"
                fi
                return 0
            fi
            git -C "$BOT_HOME" commit -m "jarvis-coder: ${TASK_ID} 완료 (자동)" \
                --no-gpg-sign --quiet 2>/dev/null || true
        fi
        local _changed_files_json="[]" _exec_log_json="[]" _result_summary=""
        _result_summary="${TASK_NAME} 완료"
        if [[ -n "$_SNAPSHOT_HASH" ]]; then
            _changed_files_json=$(git -C "$BOT_HOME" diff --name-only "${_SNAPSHOT_HASH}..HEAD" 2>/dev/null \
                | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
            _exec_log_json=$(git -C "$BOT_HOME" log --oneline "${_SNAPSHOT_HASH}..HEAD" 2>/dev/null \
                | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
        fi
        local _done_extra
        _done_extra=$(jq -n \
            --arg result_summary "$_result_summary" \
            --argjson changed_files "$_changed_files_json" \
            --argjson execution_log "$_exec_log_json" \
            '{result_summary:$result_summary, changed_files:$changed_files, execution_log:$execution_log}')
        update_queue "$TASK_ID" "done" "$_done_extra"
        _coder_log "완료: ${TASK_ID}"
        _discord_ceo_notify "✅ **Jarvis Coder**: \`${TASK_NAME}\` (\`${TASK_ID}\`) 완료"
    else
        local NEW_RETRIES=$(( RETRIES + 1 ))
        rollback_snapshot "$_SNAPSHOT_HASH"
        if [[ $NEW_RETRIES -ge $MAX_RETRIES ]]; then
            local _cc_fail_extra
            _cc_fail_extra=$(jq -n \
                --argjson retries "$NEW_RETRIES" \
                --arg lastError "completionCheck_failed" \
                --arg result_summary "실패: completionCheck 미통과, ${NEW_RETRIES}/${MAX_RETRIES} 시도 소진" \
                '{retries:$retries, lastError:$lastError, result_summary:$result_summary, changed_files:[], execution_log:[]}')
            update_queue "$TASK_ID" "failed" "$_cc_fail_extra"
            _discord_ceo_notify "❌ **Jarvis Coder**: \`${TASK_ID}\` completionCheck 미통과 → failed"
        else
            local local_extra_cc="{\"retries\": ${NEW_RETRIES}, \"lastError\": \"completionCheck_failed\"}"
            update_queue "$TASK_ID" "queued" "$local_extra_cc"
        fi
        _coder_log "completionCheck 미통과: ${TASK_ID} (${NEW_RETRIES}/${MAX_RETRIES})"
    fi
    return 0
}
