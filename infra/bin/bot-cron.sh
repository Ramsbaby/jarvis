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

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
NODE_SQLITE="node --experimental-sqlite --no-warnings"
FSM_STORE="${BOT_HOME}/lib/task-store.mjs"

# --- FSM 헬퍼 ---
_fsm_ensure() {
    # cron 태스크를 FSM DB에 등록/리셋 (failed/done → queued 재시작)
    ${NODE_SQLITE} "${FSM_STORE}" ensure "$1" "$1" "bot-cron" >/dev/null 2>&1 || true
}
_fsm_transition() {
    local task_id="$1" to_status="$2" extra="${3:-{}}"
    ${NODE_SQLITE} "${FSM_STORE}" transition "$task_id" "$to_status" "bot-cron" "$extra" >/dev/null 2>&1 || true
}
_fsm_discord_alert() {
    # 태스크 실패 시 Discord jarvis-system 채널에 직접 알림 (webhook)
    local msg="$1"
    local webhook_url
    webhook_url=$(jq -r '.webhooks["jarvis-system"] // .webhooks["jarvis"] // empty' "${BOT_HOME}/config/monitoring.json" 2>/dev/null || true)
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
_PHASE="init"        # 현재 실행 단계 — ABORTED 발생 위치 식별용
_cleanup() {
    local rc=$?
    if [[ -n "$_SENTINEL_FILE" ]]; then rmdir "$_SENTINEL_FILE" 2>/dev/null || true; fi
    if [[ "$_TASK_DONE" == "false" ]]; then
        log "ABORTED (unexpected exit: $rc — phase=${_PHASE}, signal or set -e trigger)"
        # FSM: 비정상 종료 시 running → failed 전이 (FSM이 running 상태였을 때만)
        if [[ "$_FSM_RUNNING" == "true" ]]; then
            _fsm_transition "$TASK_ID" "failed" \
                "{\"lastError\":\"aborted: exit ${rc}, phase=${_PHASE}\"}" 2>/dev/null || true
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
    # jarvis-coder / dev-runner (alias, backwards compat)
    jarvis-coder|dev-runner) _jitter=0 ;;
esac
if [[ "$_jitter" -gt 0 ]]; then
    sleep "$_jitter"
fi
unset _jitter

# --- Read task config from tasks.json ---
_PHASE="config-load"
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
# enabled: false 태스크 조용히 건너뜀 (기본값 true)
if [[ "$(echo "$TASK_CONFIG" | jq -r '.enabled // true')" == "false" ]]; then
    log "SKIPPED (enabled: false)"
    _TASK_DONE=true
    exit 0
fi

# Progressive Disclosure: prompt_file 필드가 있으면 파일에서 프롬프트 로드 (없으면 prompt 필드 폴백)
PROMPT_FILE=$(echo "$TASK_CONFIG" | jq -r '.prompt_file // empty')
if [[ -n "$PROMPT_FILE" ]]; then
    _pf_path="${BOT_HOME}/prompts/${PROMPT_FILE}"
    if [[ -f "$_pf_path" ]]; then
        PROMPT=$(cat "$_pf_path")
        log "Progressive Disclosure: 프롬프트 파일 로드 (${PROMPT_FILE}, $(wc -c < "$_pf_path" | tr -d ' ')bytes)"
    else
        log "WARN: prompt_file '${PROMPT_FILE}' 없음 — prompt 필드로 폴백"
        PROMPT=$(echo "$TASK_CONFIG" | jq -r '.prompt // empty')
    fi
    unset _pf_path
else
    PROMPT=$(echo "$TASK_CONFIG" | jq -r '.prompt // empty')
fi
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

# autoInject: SSoT 파일을 프롬프트 앞에 자동 주입 (하드코딩 방지)
# tasks.json: "autoInject": ["portfolio", "goals"] 또는 절대경로 직접 지정 가능
# 별칭 매핑: portfolio → state/portfolio.json, goals → config/goals.json
_INJECT_PREFIX=""
while IFS= read -r _alias; do
    [[ -z "$_alias" ]] && continue
    case "$_alias" in
        portfolio) _inject_path="${BOT_HOME}/state/portfolio.json" ;;
        goals)     _inject_path="${BOT_HOME}/config/goals.json" ;;
        /*)        _inject_path="$_alias" ;;  # 절대경로 직접 지정
        *)         _inject_path="${BOT_HOME}/state/${_alias}" ;;
    esac
    if [[ -f "$_inject_path" ]]; then
        _inject_label=$(basename "$_inject_path")
        _INJECT_PREFIX="${_INJECT_PREFIX}[자동 주입 — SSoT: ${_inject_label}]
$(cat "$_inject_path")

---

"
        log "autoInject: ${_inject_label} ($(wc -c < "$_inject_path" | tr -d ' ')bytes)"
    else
        log "WARN: autoInject 파일 없음: ${_inject_path}"
    fi
done < <(echo "$TASK_CONFIG" | jq -r '.autoInject[]? // empty' 2>/dev/null)
if [[ -n "$_INJECT_PREFIX" ]]; then
    PROMPT="${_INJECT_PREFIX}${PROMPT}"
fi
unset _INJECT_PREFIX _alias _inject_path _inject_label

_PHASE="param-load"
ALLOWED_TOOLS=$(echo "$TASK_CONFIG" | jq -r '.allowedTools // "Read"')
TIMEOUT=$(echo "$TASK_CONFIG" | jq -r '.timeout // 180')
MAX_BUDGET=$(echo "$TASK_CONFIG" | jq -r '.maxBudget // empty')
# tasks.json retry.max → retry-wrapper.sh MAX_RETRIES (없으면 3 기본값)
TASK_MAX_RETRIES=$(echo "$TASK_CONFIG" | jq -r '.retry.max // .maxRetries // 3')
RESULT_RETENTION=$(echo "$TASK_CONFIG" | jq -r '.resultRetention // 7')
RESULT_MAX_CHARS=$(echo "$TASK_CONFIG" | jq -r '.resultMaxChars // 2000')
MODEL=$(echo "$TASK_CONFIG" | jq -r '.model // empty')
# TASK_AUTHOR: tasks.json의 "author" 필드, 없으면 task id를 그대로 사용
# ask-claude.sh에서 TASK_AUTHOR로 사용됨
export TASK_AUTHOR
TASK_AUTHOR=$(echo "$TASK_CONFIG" | jq -r '.author // .id // empty')
DISCORD_CHANNEL=$(echo "$TASK_CONFIG" | jq -r '.discordChannel // empty')
REQUIRES_MARKET=$(echo "$TASK_CONFIG" | jq -r '.requiresMarket // false')
ALLOW_EMPTY_RESULT=$(echo "$TASK_CONFIG" | jq -r '.allowEmptyResult // false')
SUCCESS_PATTERN=$(echo "$TASK_CONFIG" | jq -r '.successPattern // empty')
SCRIPT=$(echo "$TASK_CONFIG" | jq -r '.script // empty')
SCRIPT_ARGS=$(echo "$TASK_CONFIG" | jq -r '.scriptArgs // "daily"')
# output is a JSON array like ["discord","file"]
OUTPUT_MODES=$(echo "$TASK_CONFIG" | jq -r '.output[]? // empty')

# --- MCP config: 싱글톤 Serena 선택적 공유 ---
# tasks.json에 "mcpConfig": "serena" 이면 serena-mcp.json 사용 (코드 탐색 태스크용)
# 없거나 "empty"면 기존 empty-mcp.json (기본값, 토큰 절약)
MCP_CONFIG_NAME=$(echo "$TASK_CONFIG" | jq -r '.mcpConfig // "empty"')
export JARVIS_MCP_CONFIG="${BOT_HOME}/config/${MCP_CONFIG_NAME}-mcp.json"
if [[ ! -f "$JARVIS_MCP_CONFIG" ]]; then
    log "WARN: MCP config not found: ${JARVIS_MCP_CONFIG}, falling back to empty"
    export JARVIS_MCP_CONFIG="${BOT_HOME}/config/empty-mcp.json"
fi

# --- Strategy parameters (OpenJarvis 차용: 태스크별 전략 설정) ---
# tasks.json에 "strategy": { "maxOutputTokens": 2000, "contextMode": "depends_only" } 형태로 설정
export JARVIS_MAX_OUTPUT_TOKENS
export JARVIS_CONTEXT_MODE
JARVIS_MAX_OUTPUT_TOKENS=$(echo "$TASK_CONFIG" | jq -r '.strategy.maxOutputTokens // empty')
JARVIS_CONTEXT_MODE=$(echo "$TASK_CONFIG" | jq -r '.strategy.contextMode // empty')

# --- Prompt regression: md5 기반 변경 감지 → regression 큐 등록 ──────────────
_PROMPT_HASH_FILE="${BOT_HOME}/state/prompt-hashes.json"
_REGRESSION_QUEUE="${BOT_HOME}/state/regression-queue.json"
_cur_md5=""
if [[ -n "$PROMPT_FILE" && -f "${BOT_HOME}/prompts/${PROMPT_FILE}" ]]; then
    _cur_md5=$(shasum "${BOT_HOME}/prompts/${PROMPT_FILE}" 2>/dev/null | awk '{print $1}' || true)
elif [[ -n "${PROMPT:-}" ]]; then
    _cur_md5=$(printf '%s' "$PROMPT" | shasum 2>/dev/null | awk '{print $1}' || true)
fi
if [[ -n "$_cur_md5" ]]; then
    _prev_md5=$(python3 -c "
import json, os
f = '$_PROMPT_HASH_FILE'
d = json.load(open(f)) if os.path.exists(f) else {}
print(d.get('$TASK_ID', ''))
" 2>/dev/null || echo "")
    if [[ -n "$_prev_md5" && "$_prev_md5" != "$_cur_md5" ]]; then
        log "REGRESSION: 프롬프트 변경 감지 (${TASK_ID}) — 다음 3회 실행 태깅 시작"
        _ctx_refs=$(jq -r --arg id "$TASK_ID" \
            '[.tasks[] | select((.context // [] | contains([$id]))) | .id] | join(" ")' \
            "$TASKS_FILE" 2>/dev/null || echo "")
        python3 - "$TASK_ID" "$_ctx_refs" "$_REGRESSION_QUEUE" <<'PYEOF' 2>/dev/null || true
import json, os, sys, time
trigger, refs_str, q_file = sys.argv[1], sys.argv[2], sys.argv[3]
refs = [r for r in refs_str.split() if r]
tasks_to_tag = list({trigger} | set(refs))
try:
    q = json.load(open(q_file)) if os.path.exists(q_file) else {}
except Exception:
    q = {}
ts = int(time.time())
for t in tasks_to_tag:
    q[t] = {"remaining": 3, "triggered_at": ts, "trigger_task": trigger}
with open(q_file, "w") as f:
    json.dump(q, f, indent=2)
PYEOF
    fi
    # 현재 해시 저장 (변경 여부 무관하게 항상 갱신)
    python3 - "$TASK_ID" "$_cur_md5" "$_PROMPT_HASH_FILE" <<'PYEOF' 2>/dev/null || true
import json, os, sys
task_id, md5val, hf = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(hf)) if os.path.exists(hf) else {}
except Exception:
    d = {}
d[task_id] = md5val
with open(hf, "w") as f:
    json.dump(d, f, indent=2)
PYEOF
    unset _prev_md5 _ctx_refs
fi
unset _cur_md5
# ─────────────────────────────────────────────────────────────────────────────

# --- Market holiday guard (tasks with requiresMarket: true) ---
if [[ "$REQUIRES_MARKET" == "true" ]]; then
    log "SKIPPED — market closed today (holiday or weekend)"
    _TASK_DONE=true
    exit 0
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

# --- oncePerDay 가드: 오늘 이미 성공 실행된 태스크는 중복 실행 방지 ---
_ONCE_PER_DAY=$(echo "$TASK_CONFIG" | jq -r '.oncePerDay // false')
if [[ "$_ONCE_PER_DAY" == "true" ]]; then
    _TODAY_START=$(TZ=Asia/Seoul date '+%Y-%m-%d')
    _last_done=$(${NODE_SQLITE} "${FSM_STORE}" last-done "${TASK_ID}" 2>/dev/null || echo "")
    # last-done 명령이 없을 수 있으므로 task_transitions 직접 조회
    _last_done_dt=$(python3 -c "
import sqlite3, os
db_path = os.path.join('${BOT_HOME}', 'state', 'tasks.db')
try:
    conn = sqlite3.connect(db_path)
    row = conn.execute(
        \"\"\"SELECT datetime(created_at/1000, 'unixepoch', 'localtime')
           FROM task_transitions
           WHERE task_id=? AND to_status='done'
           ORDER BY created_at DESC LIMIT 1\"\"\",
        ('${TASK_ID}',)
    ).fetchone()
    print(row[0][:10] if row else '')
except Exception:
    print('')
" 2>/dev/null || echo "")
    if [[ "$_last_done_dt" == "$_TODAY_START" ]]; then
        log "SKIPPED [ONCE_PER_DAY] ${TASK_ID} — 오늘 이미 실행됨 (${_last_done_dt})"
        rmdir "$_SENTINEL_FILE" 2>/dev/null || true
        _SENTINEL_FILE=""
        _TASK_DONE=true
        exit 0
    fi
fi
unset _ONCE_PER_DAY _TODAY_START _last_done _last_done_dt

# --- Circuit breaker: 연속 실패 3회+ 시 60분 skip ---
# 목적: API 불가 상태 시 동일 태스크가 수백 건 누적 실패하는 패턴 방지
_CB_DIR="${BOT_HOME}/state/circuit-breaker"
_CB_FILE="${_CB_DIR}/${TASK_ID}.json"
mkdir -p "$_CB_DIR"
_PHASE="circuit-breaker"
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
_PHASE="fsm-ensure"
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

# --- RAG rebuild sentinel guard ---
# skipDuringRagRebuild: true인 태스크는 RAG 재인덱싱 중 실행 금지.
# 이유: system-health 등 Claude 에이전트가 RAG 오류를 "수정"하려다 진행 중인 인덱싱을 파괴하는 사고 방지.
_SKIP_DURING_RAG=$(echo "$TASK_CONFIG" | jq -r '.skipDuringRagRebuild // false')
if [[ "$_SKIP_DURING_RAG" == "true" ]] && [[ -f "${BOT_HOME}/state/rag-rebuilding.json" ]]; then
    _RAG_PID=$(python3 -c "import json; d=json.load(open('${BOT_HOME}/state/rag-rebuilding.json')); print(d.get('pid','?'))" 2>/dev/null || echo "?")
    log "SKIPPED — RAG 재인덱싱 진행 중 (PID ${_RAG_PID}). skipDuringRagRebuild=true 설정에 의해 실행 보류."
    _TASK_DONE=true
    exit 0
fi
unset _SKIP_DURING_RAG _RAG_PID

# --- FSM: queued → running 전이 ---
_fsm_transition "$TASK_ID" "running" "{\"name\":\"${TASK_NAME_FSM}\"}"
_FSM_RUNNING=true

log "START"

# --- Lounge announce: task started ---

# --- allowedTools 기본값 경고: 프롬프트 기반 태스크가 "Read" 단독이면 Bash/Write 필요 시 실패 ---
if [[ -z "$SCRIPT" && "$ALLOWED_TOOLS" == "Read" ]]; then
    log "WARN: allowedTools='Read'(기본값) — tasks.json에 allowedTools 미설정. Bash/Write 필요 시 실패함."
fi

# --- Execute: script 필드가 있으면 직접 실행, 없으면 retry-wrapper ---
_PHASE="execute"
_TASK_START_S=$(date +%s)
RESULT=""
EXIT_CODE=0
if [[ -n "$SCRIPT" ]]; then
    # script 경로의 ~ 확장
    SCRIPT_PATH="${SCRIPT/#\~/$HOME}"
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        log "ERROR: script not found: $SCRIPT_PATH"
        _TASK_DONE=true
        exit 1
    fi
    # .mjs/.js 파일은 node로 명시적 실행, 아니면 shebang에 의존
    if [[ "$SCRIPT_PATH" == *.mjs || "$SCRIPT_PATH" == *.js ]]; then
        RESULT=$(node "$SCRIPT_PATH" "$SCRIPT_ARGS" 2>>"${BOT_HOME}/logs/cron.log") || EXIT_CODE=$?
    else
        if [[ ! -x "$SCRIPT_PATH" ]]; then
            log "ERROR: script not executable: $SCRIPT_PATH"
            _TASK_DONE=true
            exit 1
        fi
        RESULT=$("$SCRIPT_PATH" "$SCRIPT_ARGS" 2>>"${BOT_HOME}/logs/cron.log") || EXIT_CODE=$?
    fi
else
    RESULT=$("$BOT_HOME/bin/retry-wrapper.sh" "$TASK_ID" "$PROMPT" "$ALLOWED_TOOLS" "$TIMEOUT" "$MAX_BUDGET" "$RESULT_RETENTION" "$MODEL" "$TASK_MAX_RETRIES") || EXIT_CODE=$?
fi

# --- 실행 시간 측정 + timeout 80% 초과 시 경고 ---
_TASK_END_S=$(date +%s)
_ACTUAL_DURATION=$(( _TASK_END_S - _TASK_START_S ))
_TIMEOUT_WARN=$(( TIMEOUT * 8 / 10 ))
if [[ $_ACTUAL_DURATION -ge $_TIMEOUT_WARN ]]; then
    log "WARN: 실행시간 ${_ACTUAL_DURATION}s >= timeout(${TIMEOUT}s)의 80% — timeout 증가 권장"
fi
unset _TASK_END_S _TIMEOUT_WARN

if [[ $EXIT_CODE -ne 0 ]]; then
    # successPattern: 출력에 패턴이 있으면 exit code 무시하고 성공 처리
    if [[ -n "$SUCCESS_PATTERN" ]] && echo "$RESULT" | grep -qF "$SUCCESS_PATTERN"; then
        log "SUCCESS (exit=${EXIT_CODE} overridden by successPattern match)"
        EXIT_CODE=0
    fi
fi
if [[ $EXIT_CODE -ne 0 ]]; then
    log "FAILED (exit: $EXIT_CODE)"
    # AUTH_ERROR 즉시 감지: 첫 실패에서 ntfy 발송 (Circuit Breaker 3회 대기 없이)
    if echo "$RESULT" | grep -qE '"is_error":true.*"duration_api_ms":0|AUTH_ERROR|Not logged in'; then
        _auth_cooldown="${BOT_HOME}/state/auth-alerted-expired.ts"
        _auth_last=$(cat "$_auth_cooldown" 2>/dev/null || echo "0")
        if (( $(date +%s) - _auth_last >= 1800 )); then
            date +%s > "$_auth_cooldown"
            _ntfy_topic=$(jq -r '.ntfy.topic // empty' "${BOT_HOME}/config/monitoring.json" 2>/dev/null || echo "")
            if [[ -n "$_ntfy_topic" ]]; then
                curl -s --max-time 10 \
                    -H "Title: Jarvis 토큰 만료" -H "Priority: urgent" -H "Tags: rotating_light" \
                    -d "🔴 AUTH_ERROR: ${TASK_ID} 실패. Claude 토큰 만료. claude login 필요 ($(date '+%H:%M'))" \
                    "https://ntfy.sh/${_ntfy_topic}" >/dev/null 2>&1 || true
            fi
            log "AUTH_ERROR ntfy 발송 — ${TASK_ID}"
        fi
        unset _auth_cooldown _auth_last _ntfy_topic
    fi
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
    # FSM: 연속 3회 실패 시 cb-auto-fix.sh 먼저 시도 → 복구 성공 시 경고 생략
    if [[ "$_cb_new" -ge 3 ]]; then
        _CB_AUTO_FIX="${BOT_HOME}/scripts/cb-auto-fix.sh"
        if [[ -x "$_CB_AUTO_FIX" ]] && "$_CB_AUTO_FIX" "$TASK_ID" "$_cb_new" 2>/dev/null; then
            log "CB Auto-Fix 성공: ${TASK_ID} — Discord 경고 생략"
        else
            _EXTRA_DETAIL="${CB_AUTO_FIX_DETAIL:-}"
            if [[ -n "$_EXTRA_DETAIL" ]]; then
                _fsm_discord_alert "⚠️ **bot-cron Circuit Breaker**: \`${TASK_ID}\` 연속 ${_cb_new}회 실패 — 쿨다운 진입.\n${_EXTRA_DETAIL}"
            else
                _fsm_discord_alert "⚠️ **bot-cron Circuit Breaker**: \`${TASK_ID}\` 연속 ${_cb_new}회 실패 — 쿨다운 진입. 수동 확인 권장."
            fi
        fi
        unset _CB_AUTO_FIX _EXTRA_DETAIL
    fi
    unset _cb_new
    _TASK_DONE=true
    exit "$EXIT_CODE"
fi

_PHASE="post-execute"
log "SUCCESS (duration=${_ACTUAL_DURATION}s)"
unset _ACTUAL_DURATION
# circuit breaker: 성공 시 초기화
if [[ -f "$_CB_FILE" ]]; then rm -f "$_CB_FILE" 2>/dev/null || true; fi
# FSM: running → done 전이
_fsm_transition "$TASK_ID" "done"
_FSM_RUNNING=false

# event_trigger 디바운스 동기화: LaunchAgent 직접 실행도 event-watcher last_run에 기록
# → event-watcher/rag-watch가 중복 실행하지 않도록 방지 (ADR: 이중 트리거 방지)
_EVENT_TRIGGER_FIELD=$(echo "$TASK_CONFIG" | jq -r '.event_trigger // empty' 2>/dev/null || true)
if [[ -n "${_EVENT_TRIGGER_FIELD:-}" ]]; then
    _EW_LAST_RUN="${BOT_HOME}/state/events/${TASK_ID}.last_run"
    mkdir -p "${BOT_HOME}/state/events"
    date +%s > "$_EW_LAST_RUN" 2>/dev/null || true
fi
unset _EVENT_TRIGGER_FIELD _EW_LAST_RUN

# --- Prompt regression: 태깅된 태스크 결과를 regression/events/에 기록 ───────
_reg_remaining=$(python3 -c "
import json, os
f = '$_REGRESSION_QUEUE'
q = json.load(open(f)) if os.path.exists(f) else {}
print(q.get('$TASK_ID', {}).get('remaining', 0))
" 2>/dev/null || echo 0)
if [[ "${_reg_remaining:-0}" -gt 0 ]]; then
    _reg_dir="${BOT_HOME}/logs/regression/events/${TASK_ID}"
    mkdir -p "$_reg_dir"
    _reg_ts=$(date -u +%Y%m%dT%H%M%SZ)
    # exit code 비정상 비율: cron.log의 log_capture WARN 카운트 (최근 200줄)
    _warn_count=$(tail -200 "${CRON_LOG}" 2>/dev/null | grep -c "\[${TASK_ID}\].*WARN" 2>/dev/null || echo 0)
    _result_snip="${RESULT:0:300}"
    python3 - "$TASK_ID" "$EXIT_CODE" "$_warn_count" "$_reg_ts" \
              "$_reg_dir" "$_result_snip" "$_REGRESSION_QUEUE" <<'PYEOF' 2>/dev/null || true
import json, os, sys
task_id, exit_code_s, warn_s, ts, reg_dir, snippet, q_file = sys.argv[1:]
exit_code = int(exit_code_s)
warn_cnt  = int(warn_s)
# anomaly_rate: log_capture WARN 비율 (최근 100 lines 기준 추정치)
anomaly_rate = round(warn_cnt / 100.0, 3)
event = {
    "task_id": task_id, "timestamp": ts,
    "exit_code": exit_code, "exit_ok": exit_code == 0,
    "log_capture_warn_count": warn_cnt,
    "anomaly_rate": anomaly_rate,
}
try:
    q = json.load(open(q_file)) if os.path.exists(q_file) else {}
except Exception:
    q = {}
entry = q.get(task_id, {})
remaining = max(0, entry.get("remaining", 0) - 1)
event["remaining_after"] = remaining
event["trigger_task"] = entry.get("trigger_task", "")
event["result_snippet"] = snippet
os.makedirs(reg_dir, exist_ok=True)
with open(f"{reg_dir}/{ts}.json", "w") as f:
    json.dump(event, f, indent=2, ensure_ascii=False)
if remaining <= 0:
    q.pop(task_id, None)
else:
    entry["remaining"] = remaining
    q[task_id] = entry
with open(q_file, "w") as f:
    json.dump(q, f, indent=2)
PYEOF
    log "REGRESSION: 결과 태깅 완료 (${TASK_ID}, 남은 횟수: $(( _reg_remaining - 1 )))"
    unset _reg_dir _reg_ts _warn_count _result_snip
fi
unset _reg_remaining
# ─────────────────────────────────────────────────────────────────────────────

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

# --- news-briefing: 인사이트 섹션 → jarvis-ceo 채널 추가 전송 ---
case "$TASK_ID" in
    news-briefing)
        _insight_raw=$(echo "$RESULT" | awk '/💡 Jarvis 적용 가능 인사이트/{found=1} found{print}')
        if [[ -n "$_insight_raw" ]]; then
            _ceo_webhook=$(jq -r '.webhooks["jarvis-ceo"] // empty' "${BOT_HOME}/config/monitoring.json" 2>/dev/null || true)
            if [[ -n "${_ceo_webhook:-}" ]]; then
                _ceo_msg="📥 **뉴스 브리핑 인사이트 인계** ($(date '+%Y-%m-%d'))\n${_insight_raw}"
                _payload=$(jq -n --arg m "$_ceo_msg" '{content: $m}')
                curl -sS -X POST "$_ceo_webhook" \
                    -H "Content-Type: application/json" \
                    -d "$_payload" > /dev/null 2>&1 || true
                log "인사이트 섹션 jarvis-ceo 채널 전송 완료"
            fi
        fi
        unset _insight_raw _ceo_webhook _ceo_msg _payload
        ;;
esac

# --- FSM 상태 요약: daily-summary / council-insight 완료 시 Discord에 FSM 현황 추가 ---
case "$TASK_ID" in
    daily-summary|council-insight)
        _fsm_summary=$(${NODE_SQLITE} "${FSM_STORE}" fsm-summary 2>/dev/null || true)
        if [[ -n "$_fsm_summary" ]]; then
            _webhook=$(jq -r '.webhooks["jarvis-system"] // .webhooks["jarvis"] // empty' "${BOT_HOME}/config/monitoring.json" 2>/dev/null || true)
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
