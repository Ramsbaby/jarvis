#!/usr/bin/env bash
set -euo pipefail

# bot-cron.sh - Main cron entry point for AI tasks
# Usage: bot-cron.sh TASK_ID
# Reads task config from tasks.json, executes via retry-wrapper, routes output.

# === Cron environment setup ===
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"  # macOS default; Linux: /home/$(id -un)

# Load API key from zshrc (cron uses /bin/bash, not zsh, so zshrc is not sourced)
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  _key=$(grep -m1 'export ANTHROPIC_API_KEY=' "${HOME}/.zshrc" 2>/dev/null | sed 's/.*ANTHROPIC_API_KEY="\(.*\)"/\1/')
  if [[ -n "$_key" ]]; then export ANTHROPIC_API_KEY="$_key"; fi
  unset _key
fi

# Prevent nested claude detection
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
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
_cleanup() {
    local rc=$?
    [[ -n "$_SENTINEL_FILE" ]] && rmdir "$_SENTINEL_FILE" 2>/dev/null || true
    if [[ "$_TASK_DONE" == "false" ]]; then
        log "ABORTED (unexpected exit: $rc — signal or set -e trigger)"
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
    dev-event-watcher) _jitter=45 ;;
esac
if [[ "$_jitter" -gt 0 ]]; then
    sleep "$_jitter"
fi
unset _jitter

# --- Read task config from tasks.json ---
TASK_CONFIG=$(jq -r --arg id "$TASK_ID" '.tasks[] | select(.id == $id)' "$TASKS_FILE")
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
ALLOWED_TOOLS=$(echo "$TASK_CONFIG" | jq -r '.allowedTools // "Read"')
TIMEOUT=$(echo "$TASK_CONFIG" | jq -r '.timeout // 180')
MAX_BUDGET=$(echo "$TASK_CONFIG" | jq -r '.maxBudget // empty')
RESULT_RETENTION=$(echo "$TASK_CONFIG" | jq -r '.resultRetention // 7')
RESULT_MAX_CHARS=$(echo "$TASK_CONFIG" | jq -r '.resultMaxChars // 2000')
MODEL=$(echo "$TASK_CONFIG" | jq -r '.model // empty')
DISCORD_CHANNEL=$(echo "$TASK_CONFIG" | jq -r '.discordChannel // empty')
REQUIRES_MARKET=$(echo "$TASK_CONFIG" | jq -r '.requiresMarket // false')
ALLOW_EMPTY_RESULT=$(echo "$TASK_CONFIG" | jq -r '.allowEmptyResult // false')
SCRIPT=$(echo "$TASK_CONFIG" | jq -r '.script // empty')
SCRIPT_ARGS=$(echo "$TASK_CONFIG" | jq -r '.scriptArgs // "daily"')
# output is a JSON array like ["discord","file"]
OUTPUT_MODES=$(echo "$TASK_CONFIG" | jq -r '.output[]? // empty')

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
_CB_COOLDOWN=3600  # 60분 쿨다운
if [[ "$_cb_fail" -ge 3 ]] && (( _cb_now - _cb_last_fail < _CB_COOLDOWN )); then
    _cb_remaining=$(( _CB_COOLDOWN - (_cb_now - _cb_last_fail) ))
    log "SKIPPED — circuit breaker OPEN (연속 ${_cb_fail}회 실패, 쿨다운 ${_cb_remaining}s 남음)"
    _TASK_DONE=true
    exit 0
fi
unset _cb_now _CB_COOLDOWN

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
    RESULT=$("$BOT_HOME/bin/retry-wrapper.sh" "$TASK_ID" "$PROMPT" "$ALLOWED_TOOLS" "$TIMEOUT" "$MAX_BUDGET" "$RESULT_RETENTION" "$MODEL") || EXIT_CODE=$?
fi

if [[ $EXIT_CODE -ne 0 ]]; then
    "$BOT_HOME/bin/lounge-announce.sh" "$TASK_ID" "--done" 2>/dev/null || true
    log "FAILED (exit: $EXIT_CODE)"
    # circuit breaker: 실패 횟수 증가
    _cb_new=$(( _cb_fail + 1 ))
    printf '{"consecutive_fails":%d,"last_fail_ts":%d,"task_id":"%s"}\n' \
        "$_cb_new" "$(date +%s)" "$TASK_ID" > "$_CB_FILE" 2>/dev/null || true
    unset _cb_new
    _TASK_DONE=true
    exit "$EXIT_CODE"
fi

"$BOT_HOME/bin/lounge-announce.sh" "$TASK_ID" "--done" 2>/dev/null || true
log "SUCCESS"
# circuit breaker: 성공 시 초기화
[[ -f "$_CB_FILE" ]] && rm -f "$_CB_FILE" 2>/dev/null || true

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

_TASK_DONE=true
log "DONE"
