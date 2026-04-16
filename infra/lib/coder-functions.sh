#!/usr/bin/env bash
# coder-functions.sh — jarvis-coder 공용 함수 라이브러리
# jarvis-coder.sh에서 source하여 사용.
# 호출자가 BOT_HOME을 설정한 후 source해야 함.

: "${BOT_HOME:?BOT_HOME must be set before sourcing coder-functions.sh}"

source "${BOT_HOME}/lib/compat.sh" 2>/dev/null || true
source "${BOT_HOME}/lib/log-utils.sh" 2>/dev/null || true
source "${BOT_HOME}/lib/sprint-contract.sh" 2>/dev/null || true

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

# --- 변경 파일 문법 검증 (syntax gate) ---
# snapshot hash 이후 변경된 파일에 대해 언어별 문법+참조 검사 수행
# JS/MJS: eslint no-undef (ReferenceError 사전 차단) + bash -n / py_compile
# 실패 시 stderr에 에러 내용 출력 + return 1
_ESLINT_GATE_CONFIG="${BOT_HOME}/config/eslint-gate.config.mjs"
run_syntax_gate() {
    local snapshot_hash="${1:-}"
    [[ -z "$snapshot_hash" ]] && return 0

    local changed_files errors=0 error_details=""
    changed_files=$(git -C "$BOT_HOME" diff --name-only "$snapshot_hash" 2>/dev/null || true)
    [[ -z "$changed_files" ]] && return 0

    # eslint config 자동 생성 (없으면)
    if [[ ! -f "$_ESLINT_GATE_CONFIG" ]]; then
        mkdir -p "$(dirname "$_ESLINT_GATE_CONFIG")"
        cat > "$_ESLINT_GATE_CONFIG" << 'ESLINTEOF'
export default [{
  languageOptions: {
    ecmaVersion: 2022,
    sourceType: "module",
    globals: {
      console: "readonly", process: "readonly", Buffer: "readonly",
      __dirname: "readonly", __filename: "readonly", require: "readonly",
      module: "readonly", exports: "readonly", setTimeout: "readonly",
      setInterval: "readonly", clearTimeout: "readonly", clearInterval: "readonly",
      URL: "readonly", fetch: "readonly", Response: "readonly",
      global: "readonly", globalThis: "readonly", TextEncoder: "readonly",
      TextDecoder: "readonly", AbortController: "readonly", AbortSignal: "readonly",
      window: "readonly", document: "readonly", navigator: "readonly",
    }
  },
  rules: { "no-undef": "error" }
}];
ESLINTEOF
    fi

    # 직접 문법 검증 수행
    while IFS= read -r f; do
        local full_path="$BOT_HOME/$f"
        [[ -f "$full_path" ]] || continue

        local _out="" ext=""
        ext="${f##*.}"

        case "$ext" in
            js|mjs)
                if command -v npx >/dev/null 2>&1; then
                    # ESLint v10 flat config — eslint.config.mjs 사용
                    _out=$(NODE_OPTIONS="--no-warnings" npx eslint --config "$_ESLINT_GATE_CONFIG" "$full_path" 2>&1) || {
                        errors=$(( errors + 1 ))
                        error_details="${error_details}\n${full_path}: ${_out}"
                        _coder_log "SYNTAX_GATE 실패 (eslint): ${f}: ${_out:0:200}"
                    }
                else
                    # eslint 없으면 Node.js 문법 검사라도
                    _out=$(node --check "$full_path" 2>&1) || {
                        errors=$(( errors + 1 ))
                        error_details="${error_details}\n${full_path}: ${_out}"
                        _coder_log "SYNTAX_GATE 실패 (node --check): ${f}: ${_out:0:200}"
                    }
                fi
                ;;
            sh|bash)
                _out=$(bash -n "$full_path" 2>&1) || {
                    errors=$(( errors + 1 ))
                    error_details="${error_details}\n${full_path}: ${_out}"
                    _coder_log "SYNTAX_GATE 실패 (bash -n): ${f}: ${_out:0:200}"
                }
                ;;
            py)
                _out=$(python3 -m py_compile "$full_path" 2>&1) || {
                    errors=$(( errors + 1 ))
                    error_details="${error_details}\n${full_path}: ${_out}"
                    _coder_log "SYNTAX_GATE 실패 (py_compile): ${f}: ${_out:0:200}"
                }
                ;;
            md|txt|json|yaml|yml|csv|log)
                # 텍스트/설정 파일은 문법 검사 제외
                ;;
        esac
    done <<< "$changed_files"

    if (( errors > 0 )); then
        _coder_log "SYNTAX_GATE: ${errors}개 파일 문법/참조 에러 발견"
        echo -e "$error_details" >&2
        return 1
    fi

    _coder_log "SYNTAX_GATE: 변경 파일 문법 검증 통과"
    return 0
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

    # 문법 검증 게이트 (그룹) — 실패 시 에러 피드백 재호출
    if [[ -n "$_SNAPSHOT_HASH" ]]; then
        local _syntax_err=""
        if ! _syntax_err=$(run_syntax_gate "$_SNAPSHOT_HASH" 2>&1); then
            _coder_log "SYNTAX_GATE 실패 (그룹) — 에러 피드백 재호출 시도"

            local _fix_prompt="[SYNTAX GATE 실패 — 즉시 수정 필요]

아래 파일에서 문법/참조 에러가 발견되었습니다. 에러를 수정하세요.

에러 내용:
${_syntax_err:0:500}

규칙:
- 선언되지 않은 변수를 사용하면 안 됩니다 (ReferenceError)
- 함수를 제거했으면 해당 함수를 호출하는 코드도 함께 제거하세요
- 수정 후 다른 기능이 깨지지 않도록 주의하세요"

            "${BOT_HOME}/bin/retry-wrapper.sh" \
                "group-${FIRST_ID}-fix" "$_fix_prompt" "Read,Edit,Bash" "120" "5" "30" "" \
                > /dev/null 2>&1 || true

            local _syntax_err2=""
            if ! _syntax_err2=$(run_syntax_gate "$_SNAPSHOT_HASH" 2>&1); then
                _coder_log "SYNTAX_GATE 2차 실패 (그룹) → rollback"
                rollback_snapshot "$_SNAPSHOT_HASH"
                for tid in "${ALL_IDS[@]}"; do
                    local retries; retries=$(get_field "$tid" "retries"); retries="${retries:-0}"
                    local max_retries; max_retries=$(get_field "$tid" "maxRetries"); max_retries="${max_retries:-2}"
                    local new_retries=$(( retries + 1 ))
                    if (( new_retries >= max_retries )); then
                        update_queue "$tid" "failed" "{\"retries\": ${new_retries}, \"lastError\": \"syntax_gate_failed\"}"
                    else
                        update_queue "$tid" "queued" "{\"retries\": ${new_retries}, \"lastError\": \"syntax_gate_failed\"}"
                    fi
                done
                _discord_ceo_notify "❌ **Jarvis Coder**: 그룹 문법 에러 (자가수정 실패) → rollback\n\`\`\`${_syntax_err2:0:300}\`\`\`"
                return 0
            fi
            _coder_log "SYNTAX_GATE: 에러 피드백 후 자가수정 성공 (그룹)"
            _discord_ceo_notify "🔧 **Jarvis Coder**: 그룹 문법 에러 자가수정 완료"
        fi
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

    # Step 4.5: Sprint Contract — 성공 기준 협상
    local _SC_ENABLED=false
    if type sc_exists &>/dev/null; then
        if sc_exists "$TASK_ID"; then
            # 기존 contract 있음 → 미검증 criteria 기반 프롬프트 보강
            _SC_ENABLED=true
            local _unverified
            _unverified=$(sc_unverified_criteria "$TASK_ID")
            local _unverified_count
            _unverified_count=$(echo "$_unverified" | jq 'length' 2>/dev/null || echo "0")
            if [[ "$_unverified_count" -gt 0 ]]; then
                PROMPT="${PROMPT}

[Sprint Contract — 미검증 성공 기준 ${_unverified_count}건]
아래 기준을 충족하도록 작업하라:
$(echo "$_unverified" | jq -r '.[] | "- [\(.id)] \(.description)"' 2>/dev/null)"
                _coder_log "SPRINT_CONTRACT: 기존 contract 로드 (task=${TASK_ID}, 미검증=${_unverified_count}건)"
            else
                # 모든 criteria 이미 verified → 바로 완료
                _coder_log "SPRINT_CONTRACT: 모든 criteria 이미 verified → 즉시 완료 (task=${TASK_ID})"
                sc_archive "$TASK_ID" "completed"
                update_queue "$TASK_ID" "done" "{\"result_summary\": \"${TASK_NAME} 완료 (contract 전체 검증 통과)\"}"
                _discord_ceo_notify "✅ **Jarvis Coder**: \`${TASK_NAME}\` (\`${TASK_ID}\`) Sprint Contract 전체 검증 통과"
                return 0
            fi

            # maxIterations 초과 체크
            if sc_check_exhausted "$TASK_ID"; then
                _coder_log "SPRINT_CONTRACT: maxIterations 초과 → 실패 (task=${TASK_ID})"
                sc_archive "$TASK_ID" "failed"
                update_queue "$TASK_ID" "failed" "{\"lastError\": \"sprint_contract_max_iterations\", \"result_summary\": \"Sprint Contract maxIterations 초과\"}"
                _discord_ceo_notify "❌ **Jarvis Coder**: \`${TASK_ID}\` Sprint Contract 반복 한도 초과 → failed"
                return 0
            fi
        else
            # contract 없음 → Claude에게 성공 기준 정의 요청
            _coder_log "SPRINT_CONTRACT: contract 없음 → 생성 시도 (task=${TASK_ID})"
            local _contract_prompt
            _contract_prompt=$(sc_build_contract_prompt "$TASK_NAME" "$PROMPT")

            local _contract_result="" _contract_exit=0
            _contract_result=$("${BOT_HOME}/bin/retry-wrapper.sh" \
                "${TASK_ID}-contract" "$_contract_prompt" "Read,Bash" "60" "0.50" "30" "") || _contract_exit=$?

            if [[ $_contract_exit -eq 0 && -n "$_contract_result" ]]; then
                local _parsed_contract
                _parsed_contract=$(sc_parse_contract_response "$_contract_result") || true
                if [[ -n "$_parsed_contract" ]]; then
                    local _objective _criteria _max_iter
                    _objective=$(echo "$_parsed_contract" | jq -r '.objective // "태스크 완료"')
                    _criteria=$(echo "$_parsed_contract" | jq -c '.successCriteria // []')
                    _max_iter=$(echo "$_parsed_contract" | jq -r '.maxIterations // 5')
                    if sc_create "$TASK_ID" "$_objective" "$_criteria" "$_max_iter"; then
                        _SC_ENABLED=true
                        local _criteria_desc
                        _criteria_desc=$(echo "$_criteria" | jq -r '.[] | "- [\(.id)] \(.description)"' 2>/dev/null || true)
                        PROMPT="${PROMPT}

[Sprint Contract — 성공 기준]
아래 기준을 모두 충족하도록 작업하라:
${_criteria_desc}"
                        _coder_log "SPRINT_CONTRACT: contract 생성 성공 (task=${TASK_ID})"
                    else
                        _coder_log "SPRINT_CONTRACT: contract 생성 실패 → 기존 흐름 fallback (task=${TASK_ID})"
                    fi
                else
                    _coder_log "SPRINT_CONTRACT: contract 응답 파싱 실패 → 기존 흐름 fallback (task=${TASK_ID})"
                fi
            else
                _coder_log "SPRINT_CONTRACT: contract 생성 Claude 호출 실패 (exit=${_contract_exit}) → 기존 흐름 fallback"
            fi
        fi
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

    # Step 5.5: 문법 검증 게이트 — ReferenceError/SyntaxError 배포 방지
    # 실패 시: rollback 없이 에러 피드백으로 Claude 재호출 → 자가 수정 기회 부여
    if [[ -n "$_SNAPSHOT_HASH" ]]; then
        local _syntax_err=""
        if ! _syntax_err=$(run_syntax_gate "$_SNAPSHOT_HASH" 2>&1); then
            _coder_log "SYNTAX_GATE 실패: ${TASK_ID} — 에러 피드백 재호출 시도"

            # 에러 내용을 Claude에게 전달해서 자가 수정 요청
            local _fix_prompt="[SYNTAX GATE 실패 — 즉시 수정 필요]

아래 파일에서 문법/참조 에러가 발견되었습니다. 에러를 수정하세요.

에러 내용:
${_syntax_err:0:500}

규칙:
- 선언되지 않은 변수를 사용하면 안 됩니다 (ReferenceError)
- 함수를 제거했으면 해당 함수를 호출하는 코드도 함께 제거하세요
- 수정 후 다른 기능이 깨지지 않도록 주의하세요"

            local _FIX_EXIT=0
            "${BOT_HOME}/bin/retry-wrapper.sh" \
                "${TASK_ID}-fix" "$_fix_prompt" "Read,Edit,Bash" "120" "5" "30" "" \
                > /dev/null 2>&1 || _FIX_EXIT=$?

            # 수정 후 재검증
            local _syntax_err2=""
            if ! _syntax_err2=$(run_syntax_gate "$_SNAPSHOT_HASH" 2>&1); then
                # 2차도 실패 → rollback + failed
                _coder_log "SYNTAX_GATE 2차 실패 → rollback: ${TASK_ID}"
                rollback_snapshot "$_SNAPSHOT_HASH"
                local NEW_RETRIES=$(( RETRIES + 1 ))
                if (( NEW_RETRIES >= MAX_RETRIES )); then
                    update_queue "$TASK_ID" "failed" \
                        "{\"retries\": ${NEW_RETRIES}, \"lastError\": \"syntax_gate_failed\", \"syntax_errors\": $(echo "$_syntax_err2" | jq -Rs .)}"
                    _discord_ceo_notify "❌ **Jarvis Coder**: \`${TASK_ID}\` 문법 에러 (자가수정 실패) → failed\n\`\`\`${_syntax_err2:0:300}\`\`\`"
                else
                    update_queue "$TASK_ID" "queued" \
                        "{\"retries\": ${NEW_RETRIES}, \"lastError\": \"syntax_gate_failed\"}"
                    _discord_ceo_notify "⚠️ **Jarvis Coder**: \`${TASK_ID}\` 문법 에러 (자가수정 실패) → 재시도 (${NEW_RETRIES}/${MAX_RETRIES})"
                fi
                return 0
            fi
            _coder_log "SYNTAX_GATE: 에러 피드백 후 자가수정 성공: ${TASK_ID}"
            _discord_ceo_notify "🔧 **Jarvis Coder**: \`${TASK_ID}\` 문법 에러 자가수정 완료"
        fi
    fi

    # Step 6: Sprint Contract 검증 또는 completionCheck 재확인
    if [[ "$_SC_ENABLED" == "true" ]]; then
        # --- Sprint Contract 기반 검증 ---
        _coder_log "SPRINT_CONTRACT: 검증 시작 (task=${TASK_ID})"
        local _verify_results="" _verify_exit=0
        _verify_results=$("${BOT_HOME}/scripts/verify-sprint-contract.sh" "$TASK_ID" 2>>"$DEV_LOG") || _verify_exit=$?

        if [[ $_verify_exit -eq 2 ]]; then
            # contract 파일 없음 — fallback to legacy
            _coder_log "SPRINT_CONTRACT: contract 파일 소실 → legacy completionCheck fallback"
            _SC_ENABLED=false
        elif [[ -n "$_verify_results" && "$_verify_results" != "[]" ]]; then
            # iteration 결과 기록
            sc_update_iteration "$TASK_ID" "$_verify_results"
        fi
    fi

    if [[ "$_SC_ENABLED" == "true" ]]; then
        if sc_check_complete "$TASK_ID"; then
            # 모든 criteria verified → 완료!
            _coder_log "SPRINT_CONTRACT: 전체 criteria 검증 통과 → 완료 (task=${TASK_ID})"
            sc_archive "$TASK_ID" "completed"

            if [[ -n "$_SNAPSHOT_HASH" ]]; then
                git -C "$BOT_HOME" add -A >/dev/null 2>&1 || true
                local _CHANGED_COUNT
                _CHANGED_COUNT=$(git -C "$BOT_HOME" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
                if [[ "$_CHANGED_COUNT" != "0" ]]; then
                    git -C "$BOT_HOME" commit -m "jarvis-coder: ${TASK_ID} Sprint Contract 완료" \
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

            local _sc_done_extra
            _sc_done_extra=$(jq -n \
                --arg result_summary "${TASK_NAME} 완료 (Sprint Contract 전체 검증 통과)" \
                --argjson changed_files "$_changed_files_json" \
                --argjson execution_log "$_exec_log_json" \
                '{result_summary:$result_summary, changed_files:$changed_files, execution_log:$execution_log}')
            update_queue "$TASK_ID" "done" "$_sc_done_extra"
            _coder_log "완료: ${TASK_ID} (Sprint Contract)"
            _discord_ceo_notify "✅ **Jarvis Coder**: \`${TASK_NAME}\` (\`${TASK_ID}\`) Sprint Contract 전체 검증 통과"
        else
            # 미검증 criteria 존재
            local _sc_iter_num
            _sc_iter_num=$(sc_current_iteration "$TASK_ID")

            if sc_check_exhausted "$TASK_ID"; then
                # maxIterations 초과 → 실패
                _coder_log "SPRINT_CONTRACT: maxIterations 초과 → 실패 (task=${TASK_ID}, iteration=${_sc_iter_num})"
                rollback_snapshot "$_SNAPSHOT_HASH"
                sc_archive "$TASK_ID" "failed"
                local _sc_fail_extra
                _sc_fail_extra=$(jq -n \
                    --arg lastError "sprint_contract_max_iterations" \
                    --arg result_summary "Sprint Contract: ${_sc_iter_num}회 반복 후 미검증 criteria 잔존" \
                    '{lastError:$lastError, result_summary:$result_summary, changed_files:[], execution_log:[]}')
                update_queue "$TASK_ID" "failed" "$_sc_fail_extra"
                _discord_ceo_notify "❌ **Jarvis Coder**: \`${TASK_ID}\` Sprint Contract ${_sc_iter_num}회 반복 실패"
            else
                # 재시도 가능 → queued로 되돌림 (다음 coder 실행 시 미검증 criteria만 재작업)
                local _remaining
                _remaining=$(sc_unverified_criteria "$TASK_ID" | jq 'length' 2>/dev/null || echo "?")
                _coder_log "SPRINT_CONTRACT: 미검증 ${_remaining}건 → 재큐잉 (task=${TASK_ID}, iteration=${_sc_iter_num})"

                # 코드 변경은 유지 (rollback 안 함) — 다음 iteration에서 이어서 작업
                if [[ -n "$_SNAPSHOT_HASH" ]]; then
                    git -C "$BOT_HOME" add -A >/dev/null 2>&1 || true
                    local _CHANGED_COUNT
                    _CHANGED_COUNT=$(git -C "$BOT_HOME" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
                    if [[ "$_CHANGED_COUNT" != "0" ]]; then
                        git -C "$BOT_HOME" commit -m "jarvis-coder: ${TASK_ID} Sprint Contract iteration #${_sc_iter_num}" \
                            --no-gpg-sign --quiet 2>/dev/null || true
                    fi
                fi

                update_queue "$TASK_ID" "queued" "{\"lastError\": \"sprint_contract_partial\", \"retries\": ${RETRIES}}"
                _discord_ceo_notify "🔄 **Jarvis Coder**: \`${TASK_ID}\` Sprint Contract iteration #${_sc_iter_num} — 미검증 ${_remaining}건 남음"
            fi
        fi
        return 0
    fi

    # --- Legacy: completionCheck 기반 검증 (Sprint Contract 미적용 시) ---
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

# ── L2 자동승인 게이트 ─────────────────────────────────────────────────────────
# return 0 = 자동승인 통과 (L2), return 1 = 사람 승인 필요 (L1 유지)
#
# PASS  : priority low/medium + 코드 변경 주체 아님 + 저위험 출력 경로
# BLOCK : urgent/critical/high, 코드 변경 주체 5종, 나머지 불확실
#
_l2_auto_approve() {
    local tname="${1:-}" tdetail="${2:-}" tpri="${3:-medium}"

    # 1. 고위험 우선순위 → L1 유지
    if [[ "$tpri" =~ ^(urgent|critical|high)$ ]]; then
        return 1
    fi

    # 2. 코드 직접 변경 주체 블랙리스트 → L1 유지
    local blocked
    for blocked in dev-runner jarvis-coder agent-batch-commit oss-maintenance code-fix; do
        [[ "$tname" == *"$blocked"* ]] && return 1
    done

    # 3. 출력 경로가 저위험 디렉토리 → L2 자동승인
    if [[ "$tdetail" =~ results/|state/|docs/|rag/|config/ ]]; then
        return 0
    fi

    # 4. 나머지 불확실 → L1 유지
    return 1
}
