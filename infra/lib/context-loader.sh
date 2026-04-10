#!/usr/bin/env bash
# context-loader.sh — Build system prompt from RAG, task context, context-bus, history, cross-team depends
#
# Required variables (set by caller before sourcing):
#   BOT_HOME, TASK_ID, PROMPT, CONTEXT_FILE, RESULTS_DIR
#
# Output variable:
#   SYSTEM_PROMPT — assembled system prompt string

load_context() {
    SYSTEM_PROMPT=""

    # --- Global capabilities guide (항상 첫 번째로 주입) ---
    local capabilities_file="${BOT_HOME}/context/_capabilities.md"
    if [[ -f "$capabilities_file" ]]; then
        SYSTEM_PROMPT="$(cat "$capabilities_file")

"
    fi

    # --- Insight report (daily auto-generated behavioural metrics) ---
    local insight_file="${BOT_HOME}/context/insight-report.md"
    if [[ -f "$insight_file" ]]; then
        SYSTEM_PROMPT="${SYSTEM_PROMPT}$(cat "$insight_file")

"
    fi

    # --- RAG context (semantic search -> static file fallback) ---
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
        SYSTEM_PROMPT="## Long-term Memory (RAG)
${rag_context}

"
    fi

    # --- Task-specific context file ---
    if [[ -f "$CONTEXT_FILE" ]]; then
        SYSTEM_PROMPT="${SYSTEM_PROMPT}$(cat "$CONTEXT_FILE")"
    fi

    # --- Context bus (cross-channel signal from council-insight) ---
    local context_bus="${BOT_HOME}/state/context-bus.md"
    if [[ -f "$context_bus" ]]; then
        SYSTEM_PROMPT="${SYSTEM_PROMPT}

## 📌 공용 게시판 (모든 팀 공유)
$(cat "$context_bus")
"
    fi

    # --- History: last 3 results, max 2000 chars each, max 6000 total ---
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

    # --- Cross-team context: depends tasks' latest results ---
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
        SYSTEM_PROMPT="${SYSTEM_PROMPT}

## Cross-team Context
${cross_context}"
    fi

    if [[ -n "$history" ]]; then
        SYSTEM_PROMPT="${SYSTEM_PROMPT}

## Recent History
${history}"
    fi
}
