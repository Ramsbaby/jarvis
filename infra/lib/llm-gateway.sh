#!/usr/bin/env bash
# --- PATH 강화 (cron 환경에서 경로 누락 방지) ---
export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin"

# llm-gateway.sh — Multi-provider LLM call with automatic fallback
#
# Usage (sourced):
#   source "$BOT_HOME/lib/llm-gateway.sh"
#   llm_call --prompt "..." --system "..." --timeout 180 \
#            --model "..." --output "/tmp/out.json" \
#            [--allowed-tools "Read,Bash"] [--max-budget "1.00"] \
#            [--work-dir "/tmp/work"] [--mcp-config "path"]
#
# Provider chain (tried in order):
#   1. claude -p       (Claude Max, $0, supports tools)
#   2. OpenAI API      (if OPENAI_API_KEY set, text-only)
#   3. Ollama          (if ollama running, text-only)
#
# Output: JSON compatible with claude -p --output-format json
#   { "result": "...", "cost_usd": 0, "usage": {"input_tokens": 0, "output_tokens": 0} }
#
# ADR-006: LLM Gateway Multi-Provider

LLM_GATEWAY_VERSION="1.3.0"
LLM_GATEWAY_BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

_TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

# Source structured logging
if [[ -f "${LLM_GATEWAY_BOT_HOME}/lib/log-utils.sh" ]]; then
    source "${LLM_GATEWAY_BOT_HOME}/lib/log-utils.sh"
else
    # Fallback: minimal logging if log-utils.sh not found
    log_info()  { echo "[llm-gateway] $*" >&2; }
    log_warn()  { echo "[llm-gateway] WARN: $*" >&2; }
    log_error() { echo "[llm-gateway] ERROR: $*" >&2; }
    log_debug() { :; }
fi

# Load API keys from .env if available
# .env 경로 우선순위: runtime/discord/.env → (legacy) infra/discord/.env
_LLM_GW_ENV_FILE=""
if [[ -f "${LLM_GATEWAY_BOT_HOME}/../runtime/discord/.env" ]]; then
    _LLM_GW_ENV_FILE="${LLM_GATEWAY_BOT_HOME}/../runtime/discord/.env"
elif [[ -f "${LLM_GATEWAY_BOT_HOME}/discord/.env" ]]; then
    _LLM_GW_ENV_FILE="${LLM_GATEWAY_BOT_HOME}/discord/.env"
fi
if [[ -n "$_LLM_GW_ENV_FILE" ]]; then
    while IFS='=' read -r key val; do
        key=$(echo "$key" | xargs)
        [[ -z "$key" || "$key" == \#* ]] && continue
        val=$(echo "$val" | sed "s/^[\"']//;s/[\"']$//")
        case "$key" in
            OPENAI_API_KEY)       export OPENAI_API_KEY="${OPENAI_API_KEY:-$val}" ;;
            DEEPSEEK_API_KEY)     export DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-$val}" ;;
            LANGFUSE_PUBLIC_KEY)  export LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-$val}" ;;
            LANGFUSE_SECRET_KEY)  export LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-$val}" ;;
            LANGFUSE_BASE_URL)    export LANGFUSE_BASE_URL="${LANGFUSE_BASE_URL:-$val}" ;;
        esac
    done < "$_LLM_GW_ENV_FILE"
    unset _LLM_GW_ENV_FILE
fi

# Source Langfuse tracing (no-op if keys not configured)
if [[ -f "${LLM_GATEWAY_BOT_HOME}/lib/langfuse-trace.sh" ]]; then
    source "${LLM_GATEWAY_BOT_HOME}/lib/langfuse-trace.sh"
else
    lf_start_timer()           { :; }
    lf_trace_generation()      { :; }
    lf_trace_generation_error() { :; }
fi

# Helper: run python3 JSON builder, capture stderr on failure
_llm_py() {
    local label="$1"; shift
    local _stderr
    _stderr=$(mktemp)
    local result
    result=$(python3 "$@" 2>"$_stderr")
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        local err_msg
        err_msg=$(tail -1 "$_stderr" 2>/dev/null)
        log_warn "python3 ${label}: ${err_msg:-exit $rc}"
    fi
    rm -f "$_stderr"
    [[ $rc -eq 0 ]] && echo "$result"
    return $rc
}

# --- Provider: claude -p ---
_llm_claude_cli() {
    local prompt="$1" system="$2" timeout="$3" model="$4" output="$5"
    local allowed_tools="$6" max_budget="$7" work_dir="$8" mcp_config="$9"

    command -v claude >/dev/null 2>&1 || return 1

    local cmd=()
    if [[ -n "${_TIMEOUT_CMD:-}" ]]; then
        cmd+=("${_TIMEOUT_CMD}" "$timeout")
    fi
    cmd+=(claude -p
        --output-format json
        --permission-mode bypassPermissions
        --strict-mcp-config
        --mcp-config "${mcp_config:-${LLM_GATEWAY_BOT_HOME}/config/empty-mcp.json}"
    )

    # --- Batch mode (JARVIS_BATCH_MODE=1) ---
    # 크론/배치 태스크 토큰 절감:
    #   --disable-slash-commands     : 스킬 정의를 시스템 프롬프트에서 제외
    #   --no-session-persistence     : 세션 파일 디스크 저장 생략 (일회성 실행)
    #   --exclude-dynamic-system-prompt-sections : cwd/env/memory-paths/git-status를
    #                                  user message로 이동 → prompt cache prefix 재사용 향상
    #   --setting-sources ""         : user/project/local 설정 로드 차단
    # 주의: --exclude-dynamic-system-prompt-sections는 default system prompt일 때만 적용됨
    #       (ask-claude.sh는 --append-system-prompt만 사용하므로 호환)
    # 주의: --bare는 OAuth 비호환 (Jarvis는 Claude Max OAuth 사용) → 미사용
    if [[ "${JARVIS_BATCH_MODE:-0}" == "1" ]]; then
        cmd+=(
            --disable-slash-commands
            --no-session-persistence
            # --exclude-dynamic-system-prompt-sections  # 2026-05-15 재제거 — claude 2.1.x 미지원 (unknown option)
            # 사고 이력: fafa0aa(제거) → 450a136(복구) → 현재(재제거)
            # 증거: claude -p --exclude-dynamic-system-prompt-sections → "error: unknown option" (exit 0 + empty output)
            # 결과: false-success guard → claude_exit=1 → needs_tools=true → "no fallback" → system-health 연속 실패
            # 복구 조건: claude --help에서 이 플래그가 확인되면 그때 재추가
            --setting-sources ""
        )
    fi

    # --- xhigh effort option (Opus 4.7 only, added 2026-05-13) ---
    # Triggered by LLM_EFFORT environment variable or explicit caller setting.
    # Used in skills where reasoning depth is decisive (e.g. /verify, /plan-review).
    if [[ -n "${LLM_EFFORT:-}" ]]; then
        cmd+=(--effort "${LLM_EFFORT}")
    fi

    [[ -n "$system" ]]        && cmd+=(--append-system-prompt "$system")
    [[ -n "$allowed_tools" ]] && cmd+=(--allowedTools "$allowed_tools")
    [[ -n "$max_budget" ]]    && cmd+=(--max-budget-usd "$max_budget")
    [[ -n "$model" ]]         && cmd+=(--model "$model")
    [[ -n "$work_dir" ]]      && cmd+=(--plugin-dir "${work_dir}/.empty-plugins")

    # -- 로 옵션 종료: -로 시작하는 프롬프트가 옵션으로 오인되는 것을 방지
    cmd+=(-- "$prompt")

    # OAuth 격리 (2026-06-11 사고 재발 방지): 배치 claude -p는 격리 장수명 토큰(setup-token, 1년)을 사용.
    # 메인 ~/.claude/.credentials.json은 대화형 CLI 전용 단일 갱신 주체 — 배치가 만료 상태로 접근하면
    # refresh 경쟁/reuse-revoke의 트리거가 됨 (oauth-incident-ledger cli-login-session-expired-20260611).
    # CLAUDE_CODE_OAUTH_TOKEN이 이미 주입돼 있으면(bot-cron 경유) 그대로 존중.
    local _run=(env ANTHROPIC_API_KEY= CLAUDECODE="${CLAUDECODE:-}")
    local _iso_token_file="${HOME}/.claude-bot/.long-lived-token"
    if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        _run+=(CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN}")
    elif [[ -s "$_iso_token_file" ]]; then
        _run+=(CLAUDE_CODE_OAUTH_TOKEN="$(cat "$_iso_token_file")")
    else
        log_warn "격리 토큰 없음 — 메인 credentials.json 폴백 (갱신 경쟁 위험)"
    fi

    local stderr_tmp
    stderr_tmp=$(mktemp)

    # DEV_TASK_ID가 설정되면 stream-json 모드: 도구 호출을 Board에 실시간 전송
    local exit_code=0
    if [[ -n "${DEV_TASK_ID:-}" ]]; then
        cmd=("${cmd[@]/--output-format json/--output-format stream-json}")
        local stream_forwarder="${LLM_GATEWAY_BOT_HOME}/lib/stream-to-board.sh"
        if [[ -x "$stream_forwarder" ]]; then
            "${_run[@]}" "${cmd[@]}" < /dev/null 2>"$stderr_tmp" \
                | bash "$stream_forwarder" "$DEV_TASK_ID" "$output"
            exit_code=${PIPESTATUS[0]}
        else
            # forwarder 없으면 기존 json 모드로 폴백
            cmd=("${cmd[@]/--output-format stream-json/--output-format json}")
            "${_run[@]}" "${cmd[@]}" < /dev/null > "$output" 2>"$stderr_tmp"
            exit_code=$?
        fi
    else
        "${_run[@]}" "${cmd[@]}" < /dev/null > "$output" 2>"$stderr_tmp"
        exit_code=$?
    fi
    if [[ $exit_code -ne 0 ]]; then
        if [[ -s "$stderr_tmp" ]]; then
            log_warn "claude-cli stderr (exit ${exit_code}): $(tail -5 "$stderr_tmp" | tr '\n' ' ')"
        fi
        # claude -p는 오류도 JSON stdout으로 반환할 수 있음 — 내용 로깅
        if [[ -s "$output" ]]; then
            local _out_snippet
            _out_snippet=$(python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('result','')[:120].replace('\n',' '))
except:
    pass
" < "$output" 2>/dev/null || true)
            [[ -n "$_out_snippet" ]] && log_warn "claude-cli output on failure: ${_out_snippet}"
        fi
        # 인증 실패(401) 즉시 Discord critical 알림 — 야간 침묵 사망 방지 (2026-06-11 사고).
        # alert-send.sh 자체 쿨다운(기본 300s)이 폭주를 막는다. 실패해도 본 함수 결과에 영향 없음.
        if grep -qiE "Failed to authenticate|authentication_error" "$stderr_tmp" "$output" 2>/dev/null; then
            bash "${HOME}/jarvis/infra/scripts/alert-send.sh" critical \
                "🔑 claude 배치 인증 실패 (401)" \
                "task=${TASK_ID:-unknown} model=${model:-auto} — OAuth 토큰 사망 의심. long-lived-token-healthcheck·oauth-incident-ledger 확인 필요" \
                >/dev/null 2>&1 || true
        fi
    fi
    rm -f "$stderr_tmp"
    return "$exit_code"
}

# --- Provider: Google Gemini 3.5 Flash API ---
# Model: gemini-3.5-flash-latest (1M context, $1.50/$9.00 per 1M tokens)
# 비핵심 태스크(뉴스 브리핑, 요약, 로그 분석) 전용
# Ref: https://ai.google.dev/
_llm_gemini_35_flash_api() {
    local prompt="$1" system="$2" timeout="$3" model="$4" output="$5"

    # Node.js 클라이언트 사용 (fetch + JSON 구현)
    local gemini_client="${LLM_GATEWAY_BOT_HOME}/lib/gemini-3-5-flash-client.mjs"
    if [[ ! -f "$gemini_client" ]]; then
        log_warn "Gemini 3.5 Flash client not found: $gemini_client"
        return 1
    fi

    # 환경 변수 준비 (API 키 로드)
    local api_key="${GEMINI_API_KEY:-}"
    if [[ -z "$api_key" ]]; then
        # .env 파일에서 자동 로드 시도
        if [[ -f "${LLM_GATEWAY_BOT_HOME}/../runtime/discord/.env" ]]; then
            api_key=$(grep '^GEMINI_API_KEY=' "${LLM_GATEWAY_BOT_HOME}/../runtime/discord/.env" | cut -d'=' -f2 | tr -d '"'\''')
        fi
    fi

    if [[ -z "$api_key" ]]; then
        log_warn "Gemini API key not found (GEMINI_API_KEY or .env)"
        return 1
    fi

    # Node.js를 통해 Gemini API 호출
    local result_tmp
    result_tmp=$(mktemp)
    local exit_code=0

    # 프롬프트 + 시스템 프롬프트 병합
    local combined_prompt="$prompt"
    if [[ -n "$system" ]]; then
        combined_prompt="${system}

${prompt}"
    fi

    # Timeout 적용 (bash timeout 명령 사용)
    if [[ -n "${_TIMEOUT_CMD:-}" ]]; then
        "${_TIMEOUT_CMD}" "$timeout" \
            node --input-type=module -e "
import { gemini35Chat } from '${gemini_client}';
(async () => {
  try {
    const result = await gemini35Chat([
      { role: 'user', parts: [{ text: \`${combined_prompt//\`/\\\`}\` }] }
    ], { apiKey: '${api_key}', maxTokens: 4096 });
    console.log(JSON.stringify({
      result: result.text,
      cost_usd: result.cost_usd,
      usage: result.usage,
      subtype: 'gemini_35_flash',
      is_error: false
    }));
  } catch (err) {
    console.log(JSON.stringify({
      result: '',
      cost_usd: 0,
      usage: { input_tokens: 0, output_tokens: 0 },
      subtype: 'gemini_35_flash_error',
      is_error: true,
      error: err.message
    }));
    process.exit(1);
  }
})();
" > "$result_tmp" 2>&1 || exit_code=$?
    else
        node --input-type=module -e "
import { gemini35Chat } from '${gemini_client}';
(async () => {
  try {
    const result = await gemini35Chat([
      { role: 'user', parts: [{ text: \`${combined_prompt//\`/\\\`}\` }] }
    ], { apiKey: '${api_key}', maxTokens: 4096 });
    console.log(JSON.stringify({
      result: result.text,
      cost_usd: result.cost_usd,
      usage: result.usage,
      subtype: 'gemini_35_flash',
      is_error: false
    }));
  } catch (err) {
    console.log(JSON.stringify({
      result: '',
      cost_usd: 0,
      usage: { input_tokens: 0, output_tokens: 0 },
      subtype: 'gemini_35_flash_error',
      is_error: true,
      error: err.message
    }));
    process.exit(1);
  }
})();
" > "$result_tmp" 2>&1 || exit_code=$?
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_warn "Gemini 3.5 Flash API failed (exit $exit_code)"
        if [[ -s "$result_tmp" ]]; then
            log_warn "Gemini error: $(tail -1 "$result_tmp" | head -c 120)"
        fi
        rm -f "$result_tmp"
        return 1
    fi

    # 결과 파일로 복사
    if [[ ! -s "$result_tmp" ]]; then
        log_warn "Gemini 3.5 Flash: empty response"
        rm -f "$result_tmp"
        return 1
    fi

    cp "$result_tmp" "$output"
    rm -f "$result_tmp"

    local result_text
    result_text=$(jq -r '.result // ""' "$output" 2>/dev/null)
    if [[ -z "$result_text" ]]; then
        log_warn "Gemini 3.5 Flash: no result in JSON"
        return 1
    fi

    log_info "Gemini 3.5 Flash API succeeded"
    return 0
}

# --- Provider: DeepSeek API ---
# OpenAI-compatible chat completions endpoint
# Model: deepseek-chat (DeepSeek V4-Flash, MIT, $0.14/$0.28 per 1M tokens)
# Ref: https://api-docs.deepseek.com/
_llm_deepseek_api() {
    local prompt="$1" system="$2" timeout="$3" model="$4" output="$5"

    [[ -z "${DEEPSEEK_API_KEY:-}" ]] && return 1

    # Map internal aliases → DeepSeek model names
    local api_model="deepseek-chat"
    case "${model:-}" in
        *flash*|*deepseek*)      api_model="deepseek-chat" ;;
        *deepseek-reasoner*)     api_model="deepseek-reasoner" ;;
    esac

    local body
    body=$(_llm_py "deepseek-body" -c "
import json, sys, os
messages = []
if sys.argv[2]:
    messages.append({'role': 'system', 'content': sys.argv[2]})
messages.append({'role': 'user', 'content': sys.argv[1]})
body = {
    'model': sys.argv[3],
    'max_tokens': int(os.environ.get('JARVIS_MAX_OUTPUT_TOKENS') or 0) or 4096,
    'messages': messages
}
print(json.dumps(body))
" "$prompt" "${system:-}" "$api_model") || return 1

    local response _curl_err
    _curl_err=$(mktemp)
    response=$(curl -s --max-time "$timeout" \
        -H "Authorization: Bearer ${DEEPSEEK_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "https://api.deepseek.com/chat/completions" 2>"$_curl_err") || { log_warn "deepseek curl: $(cat "$_curl_err")"; rm -f "$_curl_err"; return 1; }
    rm -f "$_curl_err"

    # Convert to claude -p compatible JSON format + cost tracking
    _llm_py "deepseek-convert" -c "
import json, sys
r = json.loads(sys.argv[1])
if 'error' in r:
    print(r['error'].get('message', 'unknown'), file=sys.stderr)
    sys.exit(1)
choices = r.get('choices', [])
if not choices:
    sys.exit(1)
result = choices[0].get('message', {}).get('content', '')
usage = r.get('usage', {})
input_tokens  = usage.get('prompt_tokens', 0)
output_tokens = usage.get('completion_tokens', 0)
# DeepSeek V4-Flash pricing: \$0.14/1M input, \$0.28/1M output (cache miss)
cost_usd = (input_tokens * 0.00000014) + (output_tokens * 0.00000028)
out = {
    'result': result,
    'cost_usd': round(cost_usd, 8),
    'usage': {
        'input_tokens': input_tokens,
        'output_tokens': output_tokens
    },
    'subtype': 'deepseek_api',
    'is_error': False
}
print(json.dumps(out))
" "$response" > "$output" || return 1

    local result_text
    result_text=$(jq -r '.result // ""' "$output" 2>/dev/null)
    [[ -z "$result_text" ]] && return 1
    return 0
}

# --- Provider: OpenAI API ---
_llm_openai_api() {
    local prompt="$1" system="$2" timeout="$3" model="$4" output="$5"

    [[ -z "${OPENAI_API_KEY:-}" ]] && return 1

    local api_model="gpt-4o"
    case "${model:-}" in
        *haiku*|*fast*) api_model="gpt-4o-mini" ;;
    esac

    local body
    body=$(_llm_py "openai-body" -c "
import json, sys, os
messages = []
if sys.argv[2]:
    messages.append({'role': 'system', 'content': sys.argv[2]})
messages.append({'role': 'user', 'content': sys.argv[1]})
body = {
    'model': sys.argv[3],
    'max_tokens': int(os.environ.get('JARVIS_MAX_OUTPUT_TOKENS') or 0) or 4096,
    'messages': messages
}
print(json.dumps(body))
" "$prompt" "${system:-}" "$api_model") || return 1

    local response _curl_err
    _curl_err=$(mktemp)
    response=$(curl -s --max-time "$timeout" \
        -H "Authorization: Bearer ${OPENAI_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "https://api.openai.com/v1/chat/completions" 2>"$_curl_err") || { log_warn "openai curl: $(cat "$_curl_err")"; rm -f "$_curl_err"; return 1; }
    rm -f "$_curl_err"

    # Convert to claude -p compatible JSON format
    _llm_py "openai-convert" -c "
import json, sys
r = json.loads(sys.argv[1])
if 'error' in r:
    print(r['error'].get('message', 'unknown'), file=sys.stderr)
    sys.exit(1)
choices = r.get('choices', [])
if not choices:
    sys.exit(1)
result = choices[0].get('message', {}).get('content', '')
usage = r.get('usage', {})
out = {
    'result': result,
    'cost_usd': 0,
    'usage': {
        'input_tokens': usage.get('prompt_tokens', 0),
        'output_tokens': usage.get('completion_tokens', 0)
    },
    'subtype': 'openai_api_fallback',
    'is_error': False
}
print(json.dumps(out))
" "$response" > "$output" || return 1

    local result_text
    result_text=$(jq -r '.result // ""' "$output" 2>/dev/null)
    [[ -z "$result_text" ]] && return 1
    return 0
}

# --- Provider: Ollama ---
_llm_ollama() {
    local prompt="$1" system="$2" timeout="$3" model="$4" output="$5"

    # Check if ollama is running (legitimate probe — keep silent)
    curl -s --max-time 2 "http://localhost:11434/api/tags" >/dev/null 2>&1 || return 1

    local ollama_model="llama3.2:latest"

    local body
    body=$(_llm_py "ollama-body" -c "
import json, sys
body = {
    'model': sys.argv[1],
    'prompt': sys.argv[2],
    'stream': False
}
if sys.argv[3]:
    body['system'] = sys.argv[3]
print(json.dumps(body))
" "$ollama_model" "$prompt" "${system:-}") || return 1

    local response _curl_err
    _curl_err=$(mktemp)
    response=$(curl -s --max-time "$timeout" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "http://localhost:11434/api/generate" 2>"$_curl_err") || { log_warn "ollama curl: $(cat "$_curl_err")"; rm -f "$_curl_err"; return 1; }
    rm -f "$_curl_err"

    # Convert to claude -p compatible JSON format
    _llm_py "ollama-convert" -c "
import json, sys
r = json.loads(sys.argv[1])
result = r.get('response', '')
if not result:
    sys.exit(1)
out = {
    'result': result,
    'cost_usd': 0,
    'usage': {
        'input_tokens': r.get('prompt_eval_count', 0),
        'output_tokens': r.get('eval_count', 0)
    },
    'subtype': 'ollama_fallback',
    'is_error': False
}
print(json.dumps(out))
" "$response" > "$output" || return 1

    local result_text
    result_text=$(jq -r '.result // ""' "$output" 2>/dev/null)
    [[ -z "$result_text" ]] && return 1
    return 0
}

# Variable Thinking: 프롬프트 복잡도 기반 모델 자동 선택
# Returns: "budget" | "small" | "large"
# [2026-03-31] 한국어 단순 태스크 키워드 확장 — Haiku 라우팅 적중률 향상 (~50% 비용 절감)
_detect_complexity() {
    local prompt="$1"
    local word_count
    word_count=$(echo "$prompt" | wc -w | tr -d ' \n')
    # 명시적 복잡 태스크: 단어 수와 무관하게 large 강제
    if echo "$prompt" | grep -qiE '아키텍처|리팩터링|설계.*전략|전략.*설계|멀티.*에이전트|심층.*분석|비교.*분석'; then
        echo "large"
        return
    fi
    # 단순 상태 확인/수치 조회/알림 패턴 → budget (Haiku)
    if echo "$prompt" | grep -qiE '(df |du |ls |ps |tail |head |ping |curl.*-s)|(디스크|메모리|CPU|상태|확인|조회|알림.*발송|발송.*알림|체크)([ \n]|$)'; then
        echo "budget"
        return
    fi
    # 50단어 미만 + 복잡 키워드 없으면 budget
    if [[ "$word_count" -lt 50 ]] && ! echo "$prompt" | grep -qiE '분석|설계|비교|전략|아키텍처|코드|구현|리뷰|검토|평가'; then
        echo "budget"
        return
    fi
    if [[ "$word_count" -lt 300 ]]; then
        echo "small"
    else
        echo "large"
    fi
}

# --- Main entry point ---
# llm_call --prompt "..." --system "..." --timeout 180 --model "..." --output "/tmp/out.json" \
#          [--allowed-tools "Read,Bash"] [--max-budget "1.00"] [--work-dir "/tmp"] [--mcp-config "path"]
llm_call() {
    local prompt="" system="" timeout="180" model="" output=""
    local allowed_tools="" max_budget="" work_dir="" mcp_config=""
    # 임시파일은 각 sub-function에서 인라인 정리

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prompt)        prompt="$2";        shift 2 ;;
            --system)        system="$2";        shift 2 ;;
            --timeout)       timeout="$2";       shift 2 ;;
            --model)         model="$2";         shift 2 ;;
            --output)        output="$2";        shift 2 ;;
            --allowed-tools) allowed_tools="$2"; shift 2 ;;
            --max-budget)    max_budget="$2";    shift 2 ;;
            --work-dir)      work_dir="$2";      shift 2 ;;
            --mcp-config)    mcp_config="$2";    shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$prompt" || -z "$output" ]]; then
        log_error "llm_call requires --prompt and --output"
        return 2
    fi

    # Langfuse: start timer before provider chain
    lf_start_timer

    # Variable Thinking: model 미지정 시 복잡도 기반 자동 선택
    if [[ -z "$model" ]]; then
        local complexity
        complexity=$(_detect_complexity "$prompt")
        case "$complexity" in
            budget) model="claude-haiku-4-5-20251001" ;;
            small)  model="claude-sonnet-4-6" ;;
            large)  model="claude-opus-4-7" ;;
        esac
        log_debug "auto-selected model=$model (complexity=$complexity)"
    fi

    # Determine if task requires tool use (non-text-only)
    local needs_tools=false
    if [[ -n "$allowed_tools" && "$allowed_tools" != "Read" ]]; then
        needs_tools=true
    fi

    # --- Provider chain ---

    # 1. claude -p (primary — supports tools, $0 cost)
    local claude_exit=0
    _llm_claude_cli "$prompt" "$system" "$timeout" "$model" "$output" \
                    "$allowed_tools" "$max_budget" "$work_dir" "$mcp_config" \
        || claude_exit=$?

    if [[ $claude_exit -eq 0 ]]; then
        # False-success guard: stream-json 경로에서 claude가 exit 0이어도 output 파일이 비어있으면
        # stream-to-board.sh가 result 이벤트를 받지 못한 것 → 실패로 처리
        if [[ ! -s "$output" ]]; then
            log_warn "claude-cli: exit=0 but output file is empty (stream-json false-success) — treating as failure"
            claude_exit=1
        else
            lf_trace_generation --task-id "${TASK_ID:-llm-gateway}" \
                --name "${TASK_ID:-llm-call}" --model "$model" \
                --provider "claude-cli" --output "$output"
            return 0
        fi
    fi
    log_warn "claude -p failed (exit $claude_exit)"

    # If task needs tools, no fallback is possible
    if [[ "$needs_tools" == "true" ]]; then
        log_error "Task requires tools ($allowed_tools) — no fallback available"
        return $claude_exit
    fi

    log_info "Trying fallback providers (text-only mode)..."

    # 2. Gemini 3.5 Flash API (비핵심 태스크 primary fallback — $1.50/$9.00 per 1M tokens)
    # task-routing-config.json에 의해 라우팅된 태스크 또는 명시적 Gemini 지정 모델
    if [[ "$model" == *"gemini"* ]] || [[ "${ROUTED_MODEL_SOURCE:-}" == "ask-claude.sh" ]]; then
        log_info "Trying Gemini 3.5 Flash API (routed or explicit model=$model)..."
        if _llm_gemini_35_flash_api "$prompt" "$system" "$timeout" "$model" "$output"; then
            log_info "Gemini 3.5 Flash API succeeded (fallback)"
            lf_trace_generation --task-id "${TASK_ID:-llm-gateway}" \
                --name "${TASK_ID:-llm-call}" --model "gemini-3.5-flash-latest" \
                --provider "gemini-api" --output "$output"
            return 0
        fi
        log_warn "Gemini 3.5 Flash API failed"
    fi

    # 3. DeepSeek API (비용 민감 태스크 차선 fallback — $0.14/$0.28 per 1M tokens)
    # deepseek-flash 모델명이 명시되거나 DEEPSEEK_API_KEY가 설정된 경우 시도
    if [[ -n "${DEEPSEEK_API_KEY:-}" ]]; then
        log_info "Trying DeepSeek API..."
        if _llm_deepseek_api "$prompt" "$system" "$timeout" "$model" "$output"; then
            log_info "DeepSeek API succeeded (fallback)"
            lf_trace_generation --task-id "${TASK_ID:-llm-gateway}" \
                --name "${TASK_ID:-llm-call}" --model "deepseek-chat" \
                --provider "deepseek-api" --output "$output"
            return 0
        fi
        log_warn "DeepSeek API failed"
    fi

    # 4. OpenAI API
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        log_info "Trying OpenAI API..."
        if _llm_openai_api "$prompt" "$system" "$timeout" "$model" "$output"; then
            log_info "OpenAI API succeeded (fallback)"
            lf_trace_generation --task-id "${TASK_ID:-llm-gateway}" \
                --name "${TASK_ID:-llm-call}" --model "$model" \
                --provider "openai-api" --output "$output"
            return 0
        fi
        log_warn "OpenAI API failed"
    fi

    # 5. Ollama (local)
    log_info "Trying Ollama (local)..."
    if _llm_ollama "$prompt" "$system" "$timeout" "$model" "$output"; then
        log_info "Ollama succeeded (fallback)"
        lf_trace_generation --task-id "${TASK_ID:-llm-gateway}" \
            --name "${TASK_ID:-llm-call}" --model "$model" \
            --provider "ollama" --output "$output"
        return 0
    fi
    log_warn "Ollama failed"

    # All providers exhausted
    lf_trace_generation_error --task-id "${TASK_ID:-llm-gateway}" \
        --name "${TASK_ID:-llm-call}" --model "$model" \
        --provider "all-failed" --error "All LLM providers exhausted"
    log_error "All providers failed"
    return 1
}
