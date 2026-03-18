#!/usr/bin/env bash
set -euo pipefail

# bot-cron.sh - Main cron entry point for AI tasks
# Usage: bot-cron.sh TASK_ID
# Reads task config from tasks.json, executes via retry-wrapper, routes output.

# === Cron environment setup ===
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"  # macOS default; Linux: /home/$(id -un)

# Claude Max 구독 모드 전용 — API 키 불필요 (2026-03-17)
# claude -p는 구독 인증으로 실행, ANTHROPIC_API_KEY가 있으면 API 크레딧을 소모하므로 명시적 unset
unset ANTHROPIC_API_KEY 2>/dev/null || true

# Prevent nested claude detection
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NODE_SQLITE="node --experimental-sqlite --no-warnings"
FSM_STORE="${BOT_HOME}/lib/task-store.mjs"

# --- FSM 헬퍼 ---
_fsm_ensure() {
    # cron 태스크를 FSM DB에 등록/리셋 (failed/done → queued 재시작)
    ${NODE_SQLITE} "${FSM_STORE}" ensure "$1" "$1" "bot-cron" 2>/dev/null || true
}
_fsm_transition() {
    local task_id="$1" to_status="$2" extra="${3:-{}}"
    ${NODE_SQLITE} "${FSM_STORE}" transition "$task_id" "$to_status" "bot-cron" "$extra" 2>/dev/null || true
}
_fsm_discord_alert() {
    # 태스크 실패 시 Discord jarvis 채널에 직접 알림 (webhook)
    local msg="$1"
    local webhook_url
    webhook_url=$(jq -r '.webhooks["jarvis"] // empty' "${BOT_HOME}/config/monitoring.json" 2>/dev/null || true)
    if [[ -n "${webhook_url:-}" ]]; then
        local payload; payload=$(jq -n --arg m "$msg" '{content: $m}')
        curl -sS -X POST "$webhook_url" \
            -H "Content-Type: application/json" \
            -d "$payload" > /dev/null 2>&1 || true
    fi
}
# ADR-007: Plugin system — regenerate effective-tasks.json, then use it
if [[ -x "${BOT_HOME}/bin/plugin-loader.sh" ]]; then
    "${BOT_HOME}/bin/plugin-loader.sh" 2>/dev/null || true
fi
if [[ -f "${BOT_HOME}/config/effective-tasks.json" ]]; then
    TASKS_FILE="${BOT_HOME}/config/effective-tasks.json"
else
    TASKS_FILE="${BOT_HOME}/config/tasks.json"
fi
CRON_LOG="${BOT_HOME}/logs/cron.log"
TASK_ID="${1:?Usage: bot-cron.sh TASK_ID}"

mkdir -p "$(dirname "$CRON_LOG")"

# --- Log helper ---
log() {
    echo "[$(date '+%F %T')] [${TASK_ID}] $1" >> "$CRON_LOG"
}

# --- Completion trap: 비정상 종료 시에도 반드시 로그 기록 ---
_TASK_DONE=false
_SENTINEL_FILE=""
_FSM_RUNNING=false   # FSM running 전이 성공 여부 추적
_cleanup() {
    local rc=$?
    [[ -n "$_SENTINEL_FILE" ]] && rmdir "$_SENTINEL_FILE" 2>/dev/null || true
    if [[ "$_TASK_DONE" == "false" ]]; then
        log "ABORTED (unexpected exit: $rc — signal or set -e trigger)"
        # FSM: 비정상 종료 시 running → failed 전이 (FSM이 running 상태였을 때만)
        if [[ "$_FSM_RUNNING" == "true" ]]; then
            _fsm_transition "$TASK_ID" "failed" \
                "{\"lastError\":\"aborted: exit ${rc}\"}" 2>/dev/null || true
        fi
    fi
}
trap _cleanup EXIT

# --- Cluster jitter: :00분 동시 실행 방지 (macOS crontab FDA 제한 우회) ---
# crontab 스케줄은 동일하게 유지, 실제 실행은 여기서 분산
# declare -A 금지 (macOS bash 3.x 비호환) → case 문 사용
_jitter=0
case "$TASK_ID" in
    # 기존: 9시대 동시 실행 분산
    infra-daily)      _jitter=120 ;;
    cost-monitor)     _jitter=300 ;;
    monthly-review)   _jitter=480 ;;
    brand-weekly)     _jitter=360 ;;
    measure-kpi)      _jitter=180 ;;
    # 신규: */30 동시 실행 분산 (rate-limit-check + system-health 충돌 방지)
    system-health)    _jitter=60  ;;
    rate-limit-check) _jitter=90  ;;
    # 매시 :00 충돌 분산
    github-monitor)   _jitter=45  ;;
    # 22:30 / 23:00 집중 완화
    record-daily)     _jitter=120 ;;
    council-insight)  _jitter=30  ;;
    # dev-event-watcher: 제거됨 (2026-03-16, 미사용 잔재)
esac
if [[ "$_jitter" -gt 0 ]]; then
    sleep "$_jitter"
fi
unset _jitter

# --- Read task config from tasks.json ---
TASK_CONFIG=$(jq -r --arg id "$TASK_ID" '.tasks[] | select(.id == $id or ((.aliases // []) | index($id)) != null)' "$TASKS_FILE")
if [[ -z "$TASK_CONFIG" || "$TASK_CONFIG" == "null" ]]; then
    log "ERROR: Task '$TASK_ID' not found in tasks.json"
    exit 1
fi

# disabled 태스크 조용히 건너뜀
if [[ "$(echo "$TASK_CONFIG" | jq -r '.disabled // false')" == "true" ]]; then
    log "SKIPPED (disabled)"
    _TASK_DONE=true
    exit 0
fi

PROMPT=$(echo "$TASK_CONFIG" | jq -r '.prompt')
BYPASS_RAG=$(echo "$TASK_CONFIG" | jq -r '.bypassRag // false')
CONTEXT_FILE_NAME=$(echo "$TASK_CONFIG" | jq -r '.contextFile // empty')

# LT-2: bypassRag=true 이면 contextFile 내용을 프롬프트에 직접 주입 (Read 툴 호출 생략)
if [[ "$BYPASS_RAG" == "true" && -n "$CONTEXT_FILE_NAME" ]]; then
    _ctx_path="${BOT_HOME}/context/${CONTEXT_FILE_NAME}"
    if [[ -f "$_ctx_path" ]]; then
        _ctx_content=$(cat "$_ctx_path")
        PROMPT="[컨텍스트 직접 주입: ${CONTEXT_FILE_NAME}]

${_ctx_content}

---

${PROMPT}"
        log "RAG bypass: ${CONTEXT_FILE_NAME} injected ($(wc -c < "$_ctx_path" | tr -d ' ') bytes)"
        unset _ctx_path _ctx_content
    fi
fi

ALLOWED_TOOLS=$(echo "$TASK_CONFIG" | jq -r '.allowedTools // "Read"')
TIMEOUT=$(echo "$TASK_CONFIG" | jq -r '.timeout // 180')
MAX_BUDGET=$(echo "$TASK_CONFIG" | jq -r '.maxBudget // empty')
# tasks.json retry.max → retry-wrapper.sh MAX_RETRIES (없으면 3 기본값)
TASK_MAX_RETRIES=$(echo "$TASK_CONFIG" | jq -r '.retry.max // .maxRetries // 3')
RESULT_RETENTION=$(echo "$TASK_CONFIG" | jq -r '.resultRetention // 7')
RESULT_MAX_CHARS=$(echo "$TASK_CONFIG" | jq -r '.resultMaxChars // 2000')
MODEL=$(echo "$TASK_CONFIG" | jq -r '.model // empty')
DISCORD_CHANNEL=$(echo "$TASK_CONFIG" | jq -r '.discordChannel // empty')
REQUIRES_MARKET=$(echo "$TASK_CONFIG" | jq -r '.requiresMarket // false')
ALLOW_EMPTY_RESULT=$(echo "$TASK_CONFIG" | jq -r '.allowEmptyResult // false')
SUCCESS_PATTERN=$(echo "$TASK_CONFIG" | jq -r '.successPattern // empty')
SCRIPT=$(echo "$TASK_CONFIG" | jq -r '.script // empty')
SCRIPT_ARGS=$(echo "$TASK_CONFIG" | jq -r '.scriptArgs // "daily"')
# output is a JSON array like ["discord","file"]
OUTPUT_MODES=$(echo "$TASK_CONFIG" | jq -r '.output[]? // empty')

# --- Strategy parameters (OpenJarvis 차용: 태스크별 전략 설정) ---
# tasks.json에 "strategy": { "maxOutputTokens": 2000, "contextMode": "depends_only" } 형태로 설정
export JARVIS_MAX_OUTPUT_TOKENS
export JARVIS_CONTEXT_MODE
JARVIS_MAX_OUTPUT_TOKENS=$(echo "$TASK_CONFIG" | jq -r '.strategy.maxOutputTokens // empty')
JARVIS_CONTEXT_MODE=$(echo "$TASK_CONFIG" | jq -r '.strategy.contextMode // empty')

# --- Market holiday guard (tasks with requiresMarket: true) ---
if [[ "$REQUIRES_MARKET" == "true" ]]; then
    if ! /bin/bash "$BOT_HOME/scripts/market-holiday-guard.sh" > /dev/null 2>&1; then
        log "SKIPPED — market closed today (holiday or weekend)"
        _TASK_DONE=true
        exit 0
    fi
fi

# --- Duplicate run guard (atomic mkdir lock) ---
# mkdir은 POSIX에서 atomic 연산이므로 check-then-act race condition 없음.
# 기존 방식(-f 체크 후 touch)은 두 프로세스가 동시에 파일 없음을 확인하면
# 이중 실행이 발생하는 TOCTOU race condition이 있었음.
_SENTINEL_DIR="${BOT_HOME}/state/active-tasks"
_sentinel_path="${_SENTINEL_DIR}/${TASK_ID}.lock"
mkdir -p "$_SENTINEL_DIR"
if ! mkdir "$_sentinel_path" 2>/dev/null; then
    log "SKIPPED — already running (lock dir exists)"
    _TASK_DONE=true
    exit 0
fi
_SENTINEL_FILE="$_sentinel_path"  # cleanup 대상: mkdir 성공 후에만 설정

# --- Circuit breaker: 연속 실패 3회+ 시 60분 skip ---
# 목적: API 불가 상태 시 동일 태스크가 수백 건 누적 실패하는 패턴 방지
_CB_DIR="${BOT_HOME}/state/circuit-breaker"
_CB_FILE="${_CB_DIR}/${TASK_ID}.json"
mkdir -p "$_CB_DIR"
_cb_fail=0
_cb_last_fail=0
if [[ -f "$_CB_FILE" ]]; then
    _cb_fail=$(python3 -c "import json; d=json.load(open('$_CB_FILE')); print(d.get('consecutive_fails',0))" 2>/dev/null || echo 0)
    _cb_last_fail=$(python3 -c "import json; d=json.load(open('$_CB_FILE')); print(d.get('last_fail_ts',0))" 2>/dev/null || echo 0)
fi
_cb_now=$(date +%s)
_CB_COOLDOWN=$(echo "$TASK_CONFIG" | jq -r '.circuitBreakerCooldown // 3600')  # 태스크별 설정 가능, 기본 60분
if [[ "$_cb_fail" -ge 3 ]] && (( _cb_now - _cb_last_fail < _CB_COOLDOWN )); then
    _cb_remaining=$(( _CB_COOLDOWN - (_cb_now - _cb_last_fail) ))
    log "SKIPPED [CB_OPEN] ${TASK_ID} — Circuit Breaker 격리 중 (연속 ${_cb_fail}회 실패, 쿨다운 ${_cb_remaining}s 남음)"
    # FSM: ensure → queued 상태 확보 후 skipped 전이 (CB 차단을 FSM에 기록)
    _fsm_ensure "$TASK_ID"
    _fsm_transition "$TASK_ID" "skipped" \
        "{\"reason\":\"cb_open\",\"consecutiveFails\":${_cb_fail},\"cooldownRemaining\":${_cb_remaining}}"
    _TASK_DONE=true
    exit 0
fi
unset _cb_now _CB_COOLDOWN

# --- FSM: cron 태스크를 DB에 ensure (없으면 queued로 등록, failed/done이면 재시작) ---
TASK_NAME_FSM=$(echo "$TASK_CONFIG" | jq -r '.name // .id // empty')
_fsm_ensure "$TASK_ID"

# --- depends 체크: schedule 태스크만 적용 (event_trigger 태스크 제외) ---
_TASK_TRIGGER=$(echo "$TASK_CONFIG" | jq -r '.event_trigger // empty')
if [[ -z "$_TASK_TRIGGER" ]]; then
    if _DEPS_RESULT=$(${NODE_SQLITE} "${FSM_STORE}" check-deps "$TASK_ID" 2>/dev/null); then
        if echo "$_DEPS_RESULT" | grep -q '"ok":false'; then
            _MISSING=$(echo "$_DEPS_RESULT" | \
                node --no-warnings -e \
                "const c=[];process.stdin.on('data',d=>c.push(d));process.stdin.on('end',()=>{try{const r=JSON.parse(c.join(''));console.log((r.missing||[]).join(','));}catch{console.log('unknown');}});" \
                2>/dev/null || true)
            log "DEFERRED $TASK_ID — deps 미충족: ${_MISSING:-unknown} (queued 유지)"
            _TASK_DONE=true
            exit 0
        fi
    fi
fi
unset _TASK_TRIGGER _DEPS_RESULT _MISSING

# --- FSM: queued → running 전이 ---
_fsm_transition "$TASK_ID" "running" "{\"name\":\"${TASK_NAME_FSM}\"}"
_FSM_RUNNING=true

log "START"

# --- Lounge announce: task started ---
"$BOT_HOME/bin/lounge-announce.sh" "$TASK_ID" "running" 2>/dev/null || true

# --- Execute: script 필드가 있으면 직접 실행, 없으면 retry-wrapper ---
RESULT=""
EXIT_CODE=0
if [[ -n "$SCRIPT" ]]; then
    # script 경로의 ~ 확장
    SCRIPT_PATH="${SCRIPT/#\~/$HOME}"
    if [[ ! -x "$SCRIPT_PATH" ]]; then
        log "ERROR: script not found or not executable: $SCRIPT_PATH"
        _TASK_DONE=true
        exit 1
    fi
    RESULT=$("$SCRIPT_PATH" "$SCRIPT_ARGS" 2>>"${BOT_HOME}/logs/cron.log") || EXIT_CODE=$?
else
    RESULT=$("$BOT_HOME/bin/retry-wrapper.sh" "$TASK_ID" "$PROMPT" "$ALLOWED_TOOLS" "$TIMEOUT" "$MAX_BUDGET" "$RESULT_RETENTION" "$MODEL" "$TASK_MAX_RETRIES") || EXIT_CODE=$?
fi

if [[ $EXIT_CODE -ne 0 ]]; then
    # successPattern: 출력에 패턴이 있으면 exit code 무시하고 성공 처리
    if [[ -n "$SUCCESS_PATTERN" ]] && echo "$RESULT" | grep -qF "$SUCCESS_PATTERN"; then
        log "SUCCESS (exit=${EXIT_CODE} overridden by successPattern match)"
        EXIT_CODE=0
    fi
fi
if [[ $EXIT_CODE -ne 0 ]]; then
    "$BOT_HOME/bin/lounge-announce.sh" "$TASK_ID" "--done" 2>/dev/null || true
    log "FAILED (exit: $EXIT_CODE)"
    # circuit breaker: 실패 횟수 증가
    _cb_new=$(( _cb_fail + 1 ))
    printf '{"consecutive_fails":%d,"last_fail_ts":%d,"task_id":"%s"}\n' \
        "$_cb_new" "$(date +%s)" "$TASK_ID" > "$_CB_FILE" 2>/dev/null || true
    # FSM: running → failed 전이
    _fsm_transition "$TASK_ID" "failed" \
        "{\"lastError\":\"exit_code=${EXIT_CODE}\",\"consecutiveFails\":${_cb_new}}"
    _FSM_RUNNING=false
    # P4: FSM failed 이벤트 버스 발행 → auto-diagnose.sh 자동 트리거
    if [[ -f "${BOT_HOME}/lib/event-bus.sh" ]]; then
        source "${BOT_HOME}/lib/event-bus.sh"
        emit_event "task.failed" \
            "{\"task_id\":\"${TASK_ID}\",\"exit_code\":${EXIT_CODE},\"retries\":${_cb_new}}" \
            "bot-cron"
        log "EVENT: task.failed 발행 (task_id=${TASK_ID}, retries=${_cb_new})"
    fi
    # FSM: 연속 3회 실패 시 Discord 경고 알림
    if [[ "$_cb_new" -ge 3 ]]; then
        _fsm_discord_alert "⚠️ **bot-cron Circuit Breaker**: \`${TASK_ID}\` 연속 ${_cb_new}회 실패 — 쿨다운 진입. 수동 확인 권장."
    fi
    unset _cb_new
    _TASK_DONE=true
    exit "$EXIT_CODE"
fi

"$BOT_HOME/bin/lounge-announce.sh" "$TASK_ID" "--done" 2>/dev/null || true
log "SUCCESS"
# circuit breaker: 성공 시 초기화
[[ -f "$_CB_FILE" ]] && rm -f "$_CB_FILE" 2>/dev/null || true
# FSM: running → done 전이
_fsm_transition "$TASK_ID" "done"
_FSM_RUNNING=false

# --- Truncate result to maxChars before routing ---
if [[ ${#RESULT} -gt $RESULT_MAX_CHARS ]]; then
    RESULT="${RESULT:0:$RESULT_MAX_CHARS}...(truncated)"
fi

# --- Route output based on tasks.json output field ---
if [[ -z "$RESULT" ]]; then
    if [[ "$ALLOW_EMPTY_RESULT" == "true" ]]; then
        log "OK — no output (allowEmptyResult=true, condition not triggered)"
    else
        log "WARN: No output to route (empty result)"
    fi
fi
for mode in $OUTPUT_MODES; do
    if [[ -z "$RESULT" ]]; then continue; fi
    case "$mode" in
        discord)
            "$BOT_HOME/bin/route-result.sh" discord "$TASK_ID" "$RESULT" "${DISCORD_CHANNEL:-}" || log "WARN: discord routing failed"
            ;;
        ntfy)
            "$BOT_HOME/bin/route-result.sh" ntfy "$TASK_ID" "$RESULT" || log "WARN: ntfy routing failed"
            ;;
        file)
            # Already saved by ask-claude.sh, no-op
            ;;
    esac
done

# --- FSM 상태 요약: daily-summary / council-insight 완료 시 Discord에 FSM 현황 추가 ---
case "$TASK_ID" in
    daily-summary|council-insight)
        _fsm_summary=$(${NODE_SQLITE} "${FSM_STORE}" fsm-summary 2>/dev/null || true)
        if [[ -n "$_fsm_summary" ]]; then
            _webhook=$(jq -r '.webhooks["jarvis"] // empty' "${BOT_HOME}/config/monitoring.json" 2>/dev/null || true)
            if [[ -n "${_webhook:-}" ]]; then
                _payload=$(jq -n --arg m "$_fsm_summary" '{content: $m}')
                curl -sS -X POST "$_webhook" \
                    -H "Content-Type: application/json" \
                    -d "$_payload" > /dev/null 2>&1 || true
                log "FSM 상태 요약 Discord 전송 완료"
            fi
            unset _webhook _payload
        fi
        unset _fsm_summary
        ;;
esac

_TASK_DONE=true
log "DONE"
