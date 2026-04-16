#!/usr/bin/env bash
# context-loader.sh — Build system prompt from RAG, task context, context-bus, history, cross-team depends
#
# Context Assembly Pipeline — "안정 접두어 + 동적 접미어" 분리
#
# Section ordering (KV-cache friendly — stable first, dynamic last):
#   STABLE   : _capabilities.md          — 전역 가이드, 거의 불변
#   SEMI     : insight-report.md          — 1일 1회 갱신
#   SEMI     : task-specific context      — 태스크별 고정, 같은 태스크 내 불변
#   DYNAMIC  : RAG context               — 매 호출 프롬프트에 따라 변동
#   DYNAMIC  : context-bus               — 실시간 교차 채널 신호
#   DYNAMIC  : cross-team depends        — 의존 태스크 최근 결과
#   DYNAMIC  : history (last 3 results)  — 매 호출 변동
#
# Markers (grep-parseable for diagnostics):
#   <!-- SECTION:name:STABILITY -->  where STABILITY = STABLE | SEMI | DYNAMIC
#
# Required variables (set by caller before sourcing):
#   BOT_HOME, TASK_ID, PROMPT, CONTEXT_FILE, RESULTS_DIR
#
# Output variables:
#   SYSTEM_PROMPT       — assembled system prompt string
#   CTX_SECTION_SIZES   — associative "name:bytes" entries (newline-separated, for diagnostics)

load_context() {
    SYSTEM_PROMPT=""
    CTX_SECTION_SIZES=""

    # -- Helper: append section with size tracking --
    _ctx_append() {
        local name="$1" stability="$2" content="$3"
        if [[ -z "$content" ]]; then return; fi
        local size=${#content}
        SYSTEM_PROMPT="${SYSTEM_PROMPT}<!-- SECTION:${name}:${stability} -->
${content}
"
        CTX_SECTION_SIZES="${CTX_SECTION_SIZES}${name}:${stability}:${size}
"
    }

    # ===================================================================
    # ## STABLE PREFIX — 이 구간은 호출 간 거의 동일 (KV-cache 재사용 가능)
    # ===================================================================

    # --- [STABLE] Global capabilities guide (항상 첫 번째로 주입) ---
    local capabilities_file="${BOT_HOME}/context/_capabilities.md"
    local _cap_content=""
    if [[ -f "$capabilities_file" ]]; then
        _cap_content="$(cat "$capabilities_file")"
    fi
    _ctx_append "capabilities" "STABLE" "$_cap_content"

    # ===================================================================
    # ## SEMI-STABLE — 1일 또는 태스크 단위로 안정 (KV-cache 부분 재사용)
    # ===================================================================

    # --- [SEMI] Insight report (daily auto-generated behavioural metrics) ---
    local insight_file="${BOT_HOME}/context/insight-report.md"
    local _ins_content=""
    if [[ -f "$insight_file" ]]; then
        _ins_content="$(cat "$insight_file")"
    fi
    _ctx_append "insight-report" "SEMI" "$_ins_content"

    # --- [SEMI] Task-specific context file ---
    local _task_content=""
    if [[ -f "$CONTEXT_FILE" ]]; then
        _task_content="$(cat "$CONTEXT_FILE")"
    fi
    _ctx_append "task-context" "SEMI" "$_task_content"

    # ===================================================================
    # ## DYNAMIC SUFFIX — 매 호출 변동 (KV-cache 미스 구간)
    # ===================================================================

    # --- [DYNAMIC] RAG context (semantic search -> static file fallback) ---
    local rag_context=""
    local _loader_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _rag_query="${_loader_dir}/../../rag/lib/rag-query.mjs"
    if command -v node >/dev/null 2>&1 && [[ -f "$_rag_query" ]]; then
        rag_context=$(node "$_rag_query" "$PROMPT" 2>/dev/null || echo "")
    fi
    if [[ -z "$rag_context" ]] && [[ -f "$BOT_HOME/rag/memory.md" ]]; then
        rag_context=$(head -c 2000 "$BOT_HOME/rag/memory.md")
    fi
    if [[ -n "$rag_context" ]]; then
        _ctx_append "rag" "DYNAMIC" "## Long-term Memory (RAG)
${rag_context}"
    fi

    # --- [DYNAMIC] Context bus (cross-channel signal from council-insight) ---
    local context_bus="${BOT_HOME}/state/context-bus.md"
    if [[ -f "$context_bus" ]]; then
        _ctx_append "context-bus" "DYNAMIC" "## 📌 공용 게시판 (모든 팀 공유)
$(cat "$context_bus")"
    fi

    # --- [DYNAMIC] Cross-team context: depends tasks' latest results ---
    local cross_context="" cross_total=0
    local depends_json
    depends_json=$(jq -r --arg id "$TASK_ID" '.tasks[] | select(.id == $id) | .depends // [] | .[]' "${BOT_HOME}/config/tasks.json" 2>/dev/null || true)
    if [[ -n "$depends_json" ]]; then
        while IFS= read -r dep_id; do
            [[ -n "$dep_id" ]] || continue
            local dep_dir="${BOT_HOME}/results/${dep_id}"
            if [[ -d "$dep_dir" ]]; then
                local dep_file
                dep_file=$(find "$dep_dir" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
                if [[ -n "$dep_file" ]] && [[ -f "$dep_file" ]]; then
                    local dep_snippet
                    dep_snippet=$(head -c 1500 "$dep_file")
                    local dep_len=${#dep_snippet}
                    if (( cross_total + dep_len > 4500 )); then
                        break
                    fi
                    cross_context="${cross_context}
--- ${dep_id} ($(basename "$dep_file")) ---
${dep_snippet}
"
                    cross_total=$(( cross_total + dep_len ))
                fi
            fi
        done <<< "$depends_json"
    fi

    if [[ -n "$cross_context" ]]; then
        _ctx_append "cross-team" "DYNAMIC" "## Cross-team Context
${cross_context}"
    fi

    # --- [DYNAMIC] History: last 3 results, max 2000 chars each, max 6000 total ---
    local history="" history_total=0
    if [[ -d "$RESULTS_DIR" ]]; then
        while IFS= read -r file; do
            [[ -f "$file" ]] || continue
            local snippet
            snippet="$(head -c 2000 "$file")"
            local snippet_len=${#snippet}
            if (( history_total + snippet_len > 6000 )); then
                break
            fi
            history="${history}
--- Previous result: $(basename "$file") ---
${snippet}
"
            history_total=$(( history_total + snippet_len ))
        done < <(find "$RESULTS_DIR" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -3)
    fi

    if [[ -n "$history" ]]; then
        _ctx_append "history" "DYNAMIC" "## Recent History
${history}"
    fi
}
