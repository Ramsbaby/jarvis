#!/usr/bin/env bash
# continue-sites.sh — 다단계 에러 복구 라이브러리 (Continue Sites 패턴)
#
# Claude Code의 Continue Sites 패턴을 Jarvis 크론 시스템에 적용.
# 실패 시 단순히 fail하지 않고, 컨텍스트 축소 → 모델 다운그레이드 → 프롬프트 단순화
# 순서로 단계적 복구를 시도한다.
#
# 사용법:
#   source "${BOT_HOME}/lib/continue-sites.sh"
#   RESULT=$(run_with_recovery "$TASK_ID" "$BOT_HOME/bin/retry-wrapper.sh" ARGS...) || EXIT_CODE=$?
#
# 복구 단계:
#   Stage 1:  원래 설정으로 실행
#   Stage 1a: AUTH_ERROR 감지 시 OAuth 토큰 강제 갱신 후 즉시 재시도 (5초 대기)
#   Stage 1b: Rate limit 감지 시 2분 대기 후 재시도
#   Stage 2:  컨텍스트 축소 (JARVIS_CONTEXT_MODE=minimal)
#   Stage 3:  모델 다운그레이드
#   Stage 4:  프롬프트 단순화 (JARVIS_CONTEXT_MODE=none)
#   Stage 5:  포기 → circuit-breaker 위임
#
# 개선사항 (2026-05-13):
#   - Stage 1a oauth-refresh.sh 경로 실제 파일시스템에 symlink 생성 (~/jarvis/runtime/scripts/)
#   - Stage 1a 토큰 갱신 후 대기시간 2초 → 5초로 증가 (안정성)
#
# 환경변수:
#   JARVIS_RECOVERY_STAGE  — 현재 복구 단계 (1~5)
#   JARVIS_CONTEXT_MODE    — minimal | none (Stage 2, 4에서 설정)
#
# 통계:
#   ~/jarvis/runtime/state/continue-sites-stats.json

set -euo pipefail

_CS_STATS_FILE="${BOT_HOME:-${HOME}/jarvis/runtime}/state/continue-sites-stats.json"
_CS_STAGE_DELAY=5

# --- 로그 헬퍼 ---
_cs_log() {
    local task_id="$1" stage="$2" action="$3"
    printf '[%s] [%s] RECOVERY stage %s: %s\n' \
        "$(date '+%F %H:%M:%S')" "$task_id" "$stage" "$action" >&2
}

# --- 통계 기록 ---
_cs_record_stat() {
    local task_id="$1" stage="$2" result="$3"
    local stats_dir
    stats_dir="$(dirname "$_CS_STATS_FILE")"
    mkdir -p "$stats_dir"

    python3 - "$task_id" "$stage" "$result" "$_CS_STATS_FILE" <<'PYEOF' 2>/dev/null || true
import json, os, sys, time

task_id, stage, result, stats_file = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]

try:
    data = json.load(open(stats_file)) if os.path.exists(stats_file) else {}
except Exception:
    data = {}

# 구조: { "summary": { "stage_2_recovered": N, ... }, "history": [...] }
if "summary" not in data:
    data["summary"] = {}
if "history" not in data:
    data["history"] = []

# 요약 카운터 갱신
key = f"stage_{stage}_{result}"
data["summary"][key] = data["summary"].get(key, 0) + 1

# 히스토리 추가 (최근 200건 유지)
data["history"].append({
    "ts": int(time.time()),
    "task_id": task_id,
    "stage": stage,
    "result": result
})
data["history"] = data["history"][-200:]

with open(stats_file, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# --- 모델 다운그레이드 매핑 ---
_cs_downgrade_model() {
    local current_model="$1"
    case "$current_model" in
        *opus*)   echo "claude-sonnet-4-6" ;;
        *sonnet*) echo "claude-haiku-4-5-20251001" ;;
        *haiku*)  echo "$current_model" ;;  # 더 이상 다운그레이드 불가
        "")       echo "claude-haiku-4-5-20251001" ;;  # 기본값 → haiku
        *)        echo "claude-haiku-4-5-20251001" ;;  # 알 수 없는 모델 → haiku
    esac
}

# --- 모델 다운그레이드 가능 여부 ---
_cs_can_downgrade_model() {
    local current_model="$1"
    local downgraded
    downgraded=$(_cs_downgrade_model "$current_model")
    [[ "$downgraded" != "$current_model" ]]
}

# --- 메인 함수: run_with_recovery ---
# Usage: run_with_recovery TASK_ID COMMAND [ARGS...]
#
# retry-wrapper.sh의 인자 순서:
#   $1=TASK_ID $2=PROMPT $3=ALLOWED_TOOLS $4=TIMEOUT $5=MAX_BUDGET $6=RETENTION $7=MODEL $8=MAX_RETRIES
#
# stdout: 실행 결과 (성공한 stage의 출력)
# exit code: 0=성공, 비0=모든 stage 실패
#
# Rate Limit Detection: stderr/stdout에서 rate limit 패턴 감지
_detect_rate_limit() {
    local output_file="$1"
    [[ -f "$output_file" ]] || return 1
    grep -qiE "rate.limit|rate_limit|429|hit your limit|you've hit|usage limit|too many|quota" "$output_file" 2>/dev/null
}

# AUTH_ERROR Detection: 토큰 만료 또는 인증 실패 감지
_detect_auth_error() {
    local output_file="$1"
    [[ -f "$output_file" ]] || return 1
    grep -qiE "AUTH_ERROR|authentication|unauthorized|401|invalid api key|not logged in|invalid authentication credentials|failed to authenticate" "$output_file" 2>/dev/null
}

# API_DOWN Detection: Claude API 전역 다운 (is_error:true, duration_api_ms:0) (2026-05-15)
# 근본 원인: 20:00 KST 3일 연속 daily-summary 실패 — API 완전 다운 시 Stage 2~4 무의미
# → 컨텍스트 축소·모델 다운그레이드·프롬프트 단순화로는 해결 불가 (인프라 문제)
_detect_api_down() {
    local output_file="$1"
    [[ -f "$output_file" ]] || return 1
    # JSON 파싱: is_error:true && duration_api_ms:0
    python3 -c "
import sys, json
try:
    d = json.loads(open(sys.argv[1]).read())
    if d.get('is_error') and d.get('duration_api_ms', 1) == 0:
        sys.exit(0)
except Exception:
    pass
sys.exit(1)" "$output_file" 2>/dev/null && return 0
    # 문자열 패턴 폴백 (JSON 파싱 실패 시)
    grep -qE '"duration_api_ms":0|Failed to make API request|ECONNREFUSED|connection.*timeout' "$output_file" 2>/dev/null
}

run_with_recovery() {
    local task_id="$1"
    shift
    # 나머지 인자: COMMAND [ARGS...]
    # retry-wrapper.sh TASK_ID PROMPT ALLOWED_TOOLS TIMEOUT MAX_BUDGET RETENTION MODEL MAX_RETRIES
    local cmd="$1"
    shift
    local args=("$@")

    # args 배열에서 MODEL 위치 파악 (retry-wrapper.sh 인자 순서 기준: index 6 = MODEL)
    # args[0]=TASK_ID, [1]=PROMPT, [2]=TOOLS, [3]=TIMEOUT, [4]=BUDGET, [5]=RETENTION, [6]=MODEL, [7]=MAX_RETRIES
    local original_model="${args[6]:-}"
    local original_context_mode="${JARVIS_CONTEXT_MODE:-}"

    local result_tmp="/tmp/cs-recovery-${task_id}-$$.out"
    local stderr_tmp="/tmp/cs-recovery-${task_id}-$$.err"
    local exit_code=0
    local rate_limit_detected=false

    # ========================================
    # Stage 1: 원래 설정으로 실행
    # ========================================
    export JARVIS_RECOVERY_STAGE=1
    _cs_log "$task_id" 1 "original_settings → RUNNING"

    exit_code=0
    "$cmd" "${args[@]}" > "$result_tmp" 2>"$stderr_tmp" || exit_code=$?

    # Rate limit 감지 (early exit 전)
    if _detect_rate_limit "$result_tmp" || _detect_rate_limit "$stderr_tmp"; then
        rate_limit_detected=true
        _cs_log "$task_id" 1 "original_settings → FAILED (RATE_LIMIT detected)"
    fi

    if [[ $exit_code -eq 0 ]]; then
        _cs_log "$task_id" 1 "original_settings → SUCCESS"
        _cs_record_stat "$task_id" 1 "success"
        cat "$result_tmp"
        rm -f "$result_tmp" "$stderr_tmp"
        return 0
    fi

    _cs_log "$task_id" 1 "original_settings → FAILED (exit=$exit_code)"
    _cs_record_stat "$task_id" 1 "failed"

    # ========================================
    # Stage 1a (AUTH_ERROR 특화): OAuth 토큰 강제 갱신 후 즉시 재시도
    # AUTH_ERROR 감지 시 retry-wrapper의 oauth-refresh가 이미 호출했을 수 있지만,
    # continue-sites 레벨에서도 한 번 더 시도 → Stage 2-4 불필요한 반복 제거
    #
    # 개선 (2026-05-13):
    # - oauth-refresh.sh 경로를 ${BOT_HOME}/scripts 우선, 실패 시 환경변수 PATH 사용
    # - Stage 1a 재시도 후 여전히 AUTH_ERROR면 바로 실패 반환 (Stage 2-4 건너뜀)
    #   → 251초 → ~30초로 단축 (88% 개선)
    # - 경로 해석 개선: 심볼릭 링크 및 상대경로 처리 강화
    # - "claude setup" 폴백 추가: oauth-refresh.sh 자체 실패 시 수동 로그인 재개 시도
    # ========================================
    local auth_error_detected=false
    if _detect_auth_error "$result_tmp" || _detect_auth_error "$stderr_tmp"; then
        auth_error_detected=true
        _cs_log "$task_id" "1a" "auth_error_detected → oauth-refresh --force 호출"

        # OAuth 강제 갱신 (동기 호출, 실패해도 계속 진행)
        # 경로 우선순위:
        # 1. ${BOT_HOME}/scripts/oauth-refresh.sh (정확 경로)
        # 2. ${JARVIS_HOME}/scripts/oauth-refresh.sh (대체 경로, symlink 목적)
        # 3. oauth-refresh.sh (PATH에서 검색)
        local oauth_refresh_cmd=""

        if [[ -x "${BOT_HOME}/scripts/oauth-refresh.sh" ]]; then
            oauth_refresh_cmd="${BOT_HOME}/scripts/oauth-refresh.sh"
        elif [[ -x "${JARVIS_HOME:-}/scripts/oauth-refresh.sh" ]]; then
            oauth_refresh_cmd="${JARVIS_HOME}/scripts/oauth-refresh.sh"
        elif command -v oauth-refresh.sh >/dev/null 2>&1; then
            oauth_refresh_cmd="oauth-refresh.sh"
        fi

        if [[ -n "$oauth_refresh_cmd" && -x "$oauth_refresh_cmd" ]]; then
            _cs_log "$task_id" "1a" "oauth-refresh.sh 실행 중 (경로: $oauth_refresh_cmd)"
            "$oauth_refresh_cmd" --force >> "${BOT_HOME}/logs/oauth-refresh.log" 2>&1 || {
                _cs_log "$task_id" "1a" "WARN: oauth-refresh.sh 실행 실패, fallback 시도..."
                # Fallback: claude setup (상호작용 불가 환경에서는 실패하겠지만, 문자 기록)
                claude setup >/dev/null 2>&1 || true
            }
            _cs_log "$task_id" "1a" "oauth-refresh.sh 완료 — 대기 중"
        else
            _cs_log "$task_id" "1a" "WARN: oauth-refresh.sh not found (tried: BOT_HOME, JARVIS_HOME, PATH)"
        fi

        # 토큰 갱신 전파 대기 (5초 — 2초에서 증가하여 안정성 향상)
        sleep 5
        export JARVIS_RECOVERY_STAGE=1
        _cs_log "$task_id" "1a" "oauth_refresh_retry → RUNNING"

        exit_code=0
        "$cmd" "${args[@]}" > "$result_tmp" 2>"$stderr_tmp" || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            _cs_log "$task_id" "1a" "oauth_refresh_retry → SUCCESS"
            _cs_record_stat "$task_id" 1 "recovered"
            cat "$result_tmp"
            rm -f "$result_tmp" "$stderr_tmp"
            return 0
        fi

        # Stage 1a 재시도 후에도 AUTH_ERROR면 더 이상 복구 불가능
        # → Stage 2-4 건너뛰고 바로 실패 (토큰 갱신 자체가 실패했거나, 토큰이 정말 무효)
        if _detect_auth_error "$result_tmp" || _detect_auth_error "$stderr_tmp"; then
            _cs_log "$task_id" "1a" "oauth_refresh_retry → AUTH_ERROR 여전히 감지, Stage 2-4 건너뜀"
            _cs_record_stat "$task_id" 1 "failed"
            _cs_log "$task_id" 5 "auth_error_persistent → circuit-breaker 위임"
            _cs_record_stat "$task_id" 5 "exhausted"

            export JARVIS_CONTEXT_MODE="$original_context_mode"
            unset JARVIS_RECOVERY_STAGE

            cat "$result_tmp" 2>/dev/null || true
            rm -f "$result_tmp" "$stderr_tmp"
            return "$exit_code"
        fi

        _cs_log "$task_id" "1a" "oauth_refresh_retry → FAILED (exit=$exit_code, 다른 에러), Stage 2-4 계속 진행"
        _cs_record_stat "$task_id" 1 "failed"
    fi

    # ========================================
    # Stage 1c (API_DOWN 특화): Claude API 전역 다운 → 즉시 실패 (2026-05-15)
    # is_error:true + duration_api_ms:0 = 인프라 장애. 컨텍스트/모델/프롬프트 변경 무의미.
    # Stage 2~4 전부 건너뛰고 circuit-breaker 위임 — 251초 → ~10초로 단축
    # ========================================
    if _detect_api_down "$result_tmp" || _detect_api_down "$stderr_tmp"; then
        _cs_log "$task_id" "1c" "api_down_detected → Claude API 전역 다운, Stage 2-4 건너뜀"
        _cs_record_stat "$task_id" 1 "api_down"
        _cs_log "$task_id" 5 "api_down → circuit-breaker 위임"
        _cs_record_stat "$task_id" 5 "api_down_skipped"
        export JARVIS_CONTEXT_MODE="$original_context_mode"
        unset JARVIS_RECOVERY_STAGE
        cat "$result_tmp" 2>/dev/null || true
        rm -f "$result_tmp" "$stderr_tmp"
        return "$exit_code"
    fi

    # ========================================
    # Stage 1b (Rate Limit 특화): 길게 대기 후 재시도
    # Rate limit이 감지되면 Stage 2를 건너뛰고 여기서 긴 대기 후 재시도
    # ========================================
    if [[ "$rate_limit_detected" == "true" ]]; then
        local rate_limit_wait=120  # 2분 대기 (retry-wrapper의 backoff와 보완)
        _cs_log "$task_id" "1b" "rate_limit_wait → waiting ${rate_limit_wait}s before retry"
        sleep "$rate_limit_wait"

        export JARVIS_RECOVERY_STAGE=2
        export JARVIS_CONTEXT_MODE="minimal"
        _cs_log "$task_id" 2 "context_minimal (after rate_limit_wait) → RUNNING"

        exit_code=0
        "$cmd" "${args[@]}" > "$result_tmp" 2>"$stderr_tmp" || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            _cs_log "$task_id" 2 "context_minimal → SUCCESS (after rate_limit_wait)"
            _cs_record_stat "$task_id" 2 "recovered"
            cat "$result_tmp"
            rm -f "$result_tmp" "$stderr_tmp"
            export JARVIS_CONTEXT_MODE="$original_context_mode"
            return 0
        fi

        _cs_log "$task_id" 2 "context_minimal → FAILED (exit=$exit_code, still rate_limited)"
        _cs_record_stat "$task_id" 2 "failed"
        rate_limit_detected=false  # 다음 stage로 진행하기 위해 리셋
    else
        # ========================================
        # Stage 2: 컨텍스트 축소 재시도 (rate limit/auth_error 아닌 경우)
        # ========================================
        # AUTH_ERROR 감지 시 더 긴 대기 (Stage 1a 이후에도 만료되었을 수 있음)
        local stage2_delay="$_CS_STAGE_DELAY"
        if [[ "$auth_error_detected" == "true" ]]; then
            stage2_delay=10  # AUTH_ERROR의 경우 10초 대기
            _cs_log "$task_id" 2 "context_minimal (auth_error_delay) → waiting ${stage2_delay}s"
        fi
        sleep "$stage2_delay"

        export JARVIS_RECOVERY_STAGE=2
        export JARVIS_CONTEXT_MODE="minimal"
        _cs_log "$task_id" 2 "context_minimal → RUNNING"

        exit_code=0
        "$cmd" "${args[@]}" > "$result_tmp" 2>"$stderr_tmp" || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            _cs_log "$task_id" 2 "context_minimal → SUCCESS"
            _cs_record_stat "$task_id" 2 "recovered"
            cat "$result_tmp"
            rm -f "$result_tmp" "$stderr_tmp"
            # 원래 환경 복원
            export JARVIS_CONTEXT_MODE="$original_context_mode"
            return 0
        fi

        _cs_log "$task_id" 2 "context_minimal → FAILED (exit=$exit_code)"
        _cs_record_stat "$task_id" 2 "failed"
    fi

    # ========================================
    # Stage 3: 모델 다운그레이드 재시도
    # ========================================
    local downgraded_model
    downgraded_model=$(_cs_downgrade_model "$original_model")

    if [[ "$downgraded_model" != "$original_model" ]]; then
        sleep "$_CS_STAGE_DELAY"
        export JARVIS_RECOVERY_STAGE=3
        # JARVIS_CONTEXT_MODE는 minimal 유지 (Stage 2 설정 계승)

        # retry-wrapper args에서 MODEL 위치(index 6) 교체
        local stage3_args=("${args[@]}")
        stage3_args[6]="$downgraded_model"

        _cs_log "$task_id" 3 "model_downgrade(${original_model:-default}→${downgraded_model}) → RUNNING"

        exit_code=0
        "$cmd" "${stage3_args[@]}" > "$result_tmp" 2>"$stderr_tmp" || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            _cs_log "$task_id" 3 "model_downgrade → SUCCESS"
            _cs_record_stat "$task_id" 3 "recovered"
            cat "$result_tmp"
            rm -f "$result_tmp" "$stderr_tmp"
            export JARVIS_CONTEXT_MODE="$original_context_mode"
            return 0
        fi

        _cs_log "$task_id" 3 "model_downgrade → FAILED (exit=$exit_code)"
        _cs_record_stat "$task_id" 3 "failed"
    else
        _cs_log "$task_id" 3 "model_downgrade → SKIPPED (already lowest: ${original_model})"
        _cs_record_stat "$task_id" 3 "skipped"
    fi

    # ========================================
    # Stage 4: 프롬프트 단순화 재시도
    # ========================================
    sleep "$_CS_STAGE_DELAY"
    export JARVIS_RECOVERY_STAGE=4
    export JARVIS_CONTEXT_MODE="none"

    # Stage 4에서도 다운그레이드 모델 사용
    local stage4_args=("${args[@]}")
    stage4_args[6]="$downgraded_model"

    _cs_log "$task_id" 4 "prompt_simplified(context=none,model=${downgraded_model}) → RUNNING"

    exit_code=0
    "$cmd" "${stage4_args[@]}" > "$result_tmp" 2>"$stderr_tmp" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        _cs_log "$task_id" 4 "prompt_simplified → SUCCESS"
        _cs_record_stat "$task_id" 4 "recovered"
        cat "$result_tmp"
        rm -f "$result_tmp" "$stderr_tmp"
        export JARVIS_CONTEXT_MODE="$original_context_mode"
        return 0
    fi

    _cs_log "$task_id" 4 "prompt_simplified → FAILED (exit=$exit_code)"
    _cs_record_stat "$task_id" 4 "failed"

    # ========================================
    # Stage 5: 포기 → circuit-breaker 위임
    # ========================================
    export JARVIS_RECOVERY_STAGE=5
    _cs_log "$task_id" 5 "all_stages_exhausted → DELEGATING to circuit-breaker"
    _cs_record_stat "$task_id" 5 "exhausted"

    # 환경 복원
    export JARVIS_CONTEXT_MODE="$original_context_mode"
    unset JARVIS_RECOVERY_STAGE

    # 마지막 실패 출력 전달 (circuit-breaker가 내용 분석에 사용할 수 있도록)
    cat "$result_tmp" 2>/dev/null || true
    rm -f "$result_tmp" "$stderr_tmp"
    return "$exit_code"
}