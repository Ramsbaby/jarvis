#!/usr/bin/env bash
#
# model-routing-integration.sh — Task-to-Model routing for Gemini 3.5 Flash
#
# Integration point: ask-claude.sh에서 MODEL 파라미터를 결정하기 전에 호출
# 비핵심 태스크(news-briefing, daily-summary 등)를 Gemini로 라우팅
#
# Usage: source this file, then call select_model_for_task "$TASK_ID" "$MODEL"
# Returns: 라우팅된 모델명 (또는 원본 MODEL)
#
# ADR: ADR-011 (Multi-model orchestration policy)
# Created: 2026-05-22
#

# ── 설정 로드 ────────────────────────────────────────────────────────────────
_ROUTING_CONFIG="${BOT_HOME:-${HOME}/jarvis/runtime}/config/task-routing-config.json"

# ── 라우팅 로직 ──────────────────────────────────────────────────────────────
select_model_for_task() {
    local task_id="$1"
    local original_model="${2:-}"
    local allowed_tools="${3:-}"  # 도구 목록 (Bash 포함 여부 가드용)

    # 라우팅 설정 파일이 없으면 원본 모델 반환
    if [[ ! -f "$_ROUTING_CONFIG" ]]; then
        echo "$original_model"
        return 0
    fi

    # 라우팅 비활성화 상태면 원본 모델 반환
    local routing_enabled
    routing_enabled=$(jq -r '.enabled // false' "$_ROUTING_CONFIG" 2>/dev/null || echo "false")
    if [[ "$routing_enabled" != "true" ]]; then
        echo "$original_model"
        return 0
    fi

    # 태스크 ID 기반 라우팅 규칙 검색
    local target_model
    target_model=$(jq -r \
        --arg task_id "$task_id" \
        '.routing_rules.rules[] |
        select(.enabled == true and (.task_ids | contains([$task_id]))) |
        .target_model' \
        "$_ROUTING_CONFIG" 2>/dev/null | head -1 || echo "")

    if [[ -n "$target_model" ]]; then
        # ── 가드: Bash 도구 필요 태스크에 Gemini 라우팅 차단 ──────────────────
        # Gemini 모델은 claude -p --model 로 호출 불가 + Bash 도구 미지원.
        # allowedTools에 Bash가 포함된 태스크는 Claude 전용으로 유지.
        # 2026-05-22: system-health Gemini 라우팅 → 100% 실패 사고 재발 방지.
        if [[ "$target_model" == *"gemini"* ]] && echo "${allowed_tools:-}" | grep -qiE '\bBash\b'; then
            echo "[routing-guard] BLOCKED: $task_id → $target_model (Bash 도구 필요 태스크는 Gemini 라우팅 금지)" >&2
            echo "$original_model"
            return 0
        fi
        echo "$target_model"
    else
        echo "$original_model"
    fi
}

# ── 라우팅 메트릭 기록 ────────────────────────────────────────────────────────
record_routing_metric() {
    local task_id="$1"
    local source_model="$2"
    local target_model="$3"
    local cost_source="${4:-0}"
    local cost_target="${5:-0}"
    local input_tokens="${6:-0}"
    local output_tokens="${7:-0}"
    local success="${8:-true}"
    local error_msg="${9:-}"

    local metrics_file="${BOT_HOME:-${HOME}/jarvis/runtime}/logs/routing-metrics.jsonl"
    mkdir -p "$(dirname "$metrics_file")" 2>/dev/null || true

    jq -cn \
        --arg ts "$(date -u +%FT%TZ)" \
        --arg task "$task_id" \
        --arg src_model "$source_model" \
        --arg tgt_model "$target_model" \
        --argjson cost_src "${cost_source}" \
        --argjson cost_tgt "${cost_target}" \
        --argjson cost_saved "$(echo "$cost_source - $cost_target" | bc 2>/dev/null || echo 0)" \
        --argjson input_tokens "${input_tokens}" \
        --argjson output_tokens "${output_tokens}" \
        --arg success "$success" \
        --arg error "$error_msg" \
        '{ts: $ts, task: $task, source_model: $src_model, target_model: $tgt_model, cost_source: $cost_src, cost_target: $cost_tgt, cost_saved: $cost_saved, input_tokens: $input_tokens, output_tokens: $output_tokens, success: $success, error: $error}' \
        >> "$metrics_file" 2>/dev/null || true
}

# ── 라우팅 설정 조회 ──────────────────────────────────────────────────────────
get_routing_rule() {
    local task_id="$1"

    if [[ ! -f "$_ROUTING_CONFIG" ]]; then
        return 1
    fi

    jq -r \
        --arg task_id "$task_id" \
        '.routing_rules.rules[] |
        select(.enabled == true and (.task_ids | contains([$task_id]))) |
        @json' \
        "$_ROUTING_CONFIG" 2>/dev/null | head -1 || return 1
}

# ── Fallback 정책 ──────────────────────────────────────────────────────────────
get_fallback_policy() {
    local policy_type="${1:-on_gemini_api_error}"

    if [[ ! -f "$_ROUTING_CONFIG" ]]; then
        echo "fallback_to_source_model"
        return 0
    fi

    jq -r \
        --arg policy "$policy_type" \
        ".fallback_policy[\$policy] // \"fallback_to_source_model\"" \
        "$_ROUTING_CONFIG" 2>/dev/null || echo "fallback_to_source_model"
}

# ── 예상 비용 절감 조회 ────────────────────────────────────────────────────────
get_cost_savings_estimate() {
    local task_id="$1"
    local input_tokens="${2:-0}"
    local output_tokens="${3:-0}"

    if [[ ! -f "$_ROUTING_CONFIG" ]]; then
        echo '{"savings_percent": 0}'
        return 0
    fi

    local savings_pct
    savings_pct=$(jq -r \
        --arg task_id "$task_id" \
        '.routing_rules.rules[] |
        select(.enabled == true and (.task_ids | contains([$task_id]))) |
        .estimated_savings_percent' \
        "$_ROUTING_CONFIG" 2>/dev/null | head -1 || echo "0")

    jq -cn --argjson pct "$savings_pct" '{savings_percent: $pct}'
}
