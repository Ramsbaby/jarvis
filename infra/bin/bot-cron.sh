#!/usr/bin/env bash
set -euo pipefail
set +H  # 히스토리 전개 비활성화 — cron 환경에서 "!_gk" 등이 잘못 해석되는 것 방지

# bot-cron.sh - Main cron entry point for AI tasks
# Usage: bot-cron.sh TASK_ID
# Reads task config from tasks.json, executes via retry-wrapper, routes output.

# === Cron environment setup ===
export BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
# 2026-09-02: /sbin 누락으로 md5sum(/sbin/md5sum) 을 못 찾아 event-watcher 가 24회 실패했다.
export PATH="${BOT_HOME}/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"  # macOS default; Linux: /home/$(id -un)

# Claude Max 구독 모드 전용 — API 키 불필요 (2026-03-17)
# claude -p는 구독 인증으로 실행, ANTHROPIC_API_KEY가 있으면 API 크레딧을 소모하므로 명시적 unset
unset ANTHROPIC_API_KEY 2>/dev/null || true

# Prevent nested claude detection (but preserve CLAUDECODE for OAuth credential inheritance)
# NOTE: CLAUDECODE unset causes OAuth authentication failure. Keep it to inherit
# credentials from the parent Claude Code session running cron-master.sh
unset CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS

# OAuth 격리 (2026-05-30) — 크론 claude 작업도 봇 전용 long-lived 토큰 사용.
# 인터랙티브/워크플로(~/.claude)와 분리 → reuse-race 유발 주체에서 제외.
# Iron Law 4: 600 파일에서만 읽음(crontab 평문 금지). SDK가 env 우선 사용.
_OAUTH_ISO_FILE="${HOME}/.claude-bot/.long-lived-token"
if [[ -r "$_OAUTH_ISO_FILE" ]]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$(cat "$_OAUTH_ISO_FILE")"
fi

# Google Workspace 변수(비밀 아님: 계정 이메일·Tasks 리스트 ID)를 .env에서 명시 로드.
# (2026-07-13 회귀 수정: 크론 env 상속이 끊겨 morning-standup의 gog 호출이
#  'GOOGLE_ACCOUNT 미설정'으로 매일 실패. 전체 .env source는 시크릿 오염 위험 → 필요한 2개만 추출·export.)
_JARVIS_ENV_FILE="${HOME}/.openclaw-data/runtime/.env"
if [[ -r "$_JARVIS_ENV_FILE" ]]; then
    for _env_key in GOOGLE_ACCOUNT GOOGLE_TASKS_LIST_ID; do
        # set -u 모드에서 안전한 간접변수 참조: declare -p 사용
        _env_val_check=""
        if declare -p "$_env_key" >/dev/null 2>&1; then
            _env_val_check="$(eval "echo \"\$$_env_key\"")"
        fi
        if [[ -z "$_env_val_check" ]]; then
            _env_val="$(grep -E "^${_env_key}=" "$_JARVIS_ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
            _env_val="${_env_val%\"}"; _env_val="${_env_val#\"}"   # 양끝 따옴표 제거
            if [[ -n "$_env_val" ]]; then export "${_env_key}=${_env_val}"; fi
        fi
    done
fi

# Batch mode: 크론 태스크는 기본적으로 토큰 절감 플래그 활성화
# (llm-gateway.sh가 감지하여 --disable-slash-commands, --no-session-persistence,
#  --setting-sources "" 를 claude -p에 추가)
# 주의: --exclude-dynamic-system-prompt-sections는 2026-05-14 제거됨
#       (Claude CLI 미지원 옵션, context-mode orphan 원인 — ajqe-dispatch.mjs L101 참조)
export JARVIS_BATCH_MODE="${JARVIS_BATCH_MODE:-1}"

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
INFRA_DIR="${HOME}/projects/jarvis/infra"
# discord egress 중앙화 — 모든 Discord 발송은 discord_route_raw/discord_route를 통해야 함
# shellcheck source=/dev/null
source "${INFRA_DIR}/lib/discord-route.sh" 2>/dev/null || true
NODE_SQLITE="node --experimental-sqlite --no-warnings"
FSM_STORE="${BOT_HOME}/lib/task-store.mjs"

# --- FSM 헬퍼 ---
_fsm_ensure() {
    # cron 태스크를 FSM DB에 등록/리셋 (failed/done → queued 재시작)
    # dev-queue v2 (2026-04-22): batch_id="bot-cron-<YYYYMMDD>" — 같은 날 돌린 cron 태스크 박스
    local _batch
    _batch="bot-cron-$(date +%Y%m%d)"
    ${NODE_SQLITE} "${FSM_STORE}" ensure "$1" "$1" "bot-cron" "" "" "$_batch" >/dev/null 2>&1 || true
}
_fsm_transition() {
    # "${3:-{}}"는 bash 3.2 중괄호 오파싱으로 값 뒤에 '}'가 붙어 extra JSON 파괴 (2026-07-17 실측)
    local task_id="$1" to_status="$2" extra="${3:-}"
    if [[ -z "$extra" ]]; then extra='{}'; fi
    ${NODE_SQLITE} "${FSM_STORE}" transition "$task_id" "$to_status" "bot-cron" "$extra" >/dev/null 2>&1 || true
}
# 공용 헬퍼 로드 — SSoT: infra/lib/cron-helpers.sh
if [[ -f "${BOT_HOME}/lib/cron-helpers.sh" ]]; then
    # shellcheck source=/dev/null
    source "${BOT_HOME}/lib/cron-helpers.sh"
fi
# ADR-007: Plugin system — regenerate effective-tasks.json, then use it
if [[ -x "${BOT_HOME}/bin/plugin-loader.sh" ]]; then
    "${BOT_HOME}/bin/plugin-loader.sh" 2>/dev/null || true
fi
if [[ -f "${BOT_HOME}/config/effective-tasks.json" ]]; then
    TASKS_FILE="${BOT_HOME}/config/effective-tasks.json"
elif [[ -f "${BOT_HOME}/config/tasks.json" ]]; then
    TASKS_FILE="${BOT_HOME}/config/tasks.json"
else
    echo "ERROR: No tasks.json or effective-tasks.json found at ${BOT_HOME}/config/" >&2
    echo "  Checked paths:" >&2
    echo "    - ${BOT_HOME}/config/effective-tasks.json" >&2
    echo "    - ${BOT_HOME}/config/tasks.json" >&2
    exit 1
fi
CRON_LOG="${BOT_HOME}/logs/cron.log"
TASK_ID="${1:?Usage: bot-cron.sh TASK_ID}"
export TASK_ID

mkdir -p "$(dirname "$CRON_LOG")"

# --- Log helper ---
log() {
    echo "[$(date '+%F %T')] [${TASK_ID}] $1" >> "$CRON_LOG"
}

# --- Continue Sites: 다단계 에러 복구 라이브러리 로드 ---
_CS_LOAD_OK=false
if [[ -f "${BOT_HOME}/lib/continue-sites.sh" ]]; then
    if source "${BOT_HOME}/lib/continue-sites.sh" 2>/dev/null; then
        _CS_LOAD_OK=true
    else
        echo "[WARNING] continue-sites.sh 로드 실패 — recovery mode 비활성화" >&2
    fi
fi
CONTINUE_SITES="${CONTINUE_SITES:-true}"
if [[ "$_CS_LOAD_OK" != "true" ]]; then
    CONTINUE_SITES="false"
fi

# --- Sprint Contract: 성공 기준 정의 라이브러리 로드 ---
_coder_log() { log "SPRINT_CONTRACT: $1"; }
if [[ -f "${BOT_HOME}/lib/sprint-contract.sh" ]]; then
    # shellcheck source=/dev/null
    source "${BOT_HOME}/lib/sprint-contract.sh" 2>/dev/null || true
fi

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

# --- TTL Cleanup: 만료된 일회성 태스크 자동 제거 (2026-05-12) ---
# addedAt + ttl <= today 이면 plist unload + 삭제 + tasks.json enabled: false
# 성공 완료(L831 _TASK_DONE=true) 직전에만 호출 — 스킵·실패 경로 제외
_ttl_cleanup() {
    local _ttl _added _num _unit _added_ts _expiry_ts _now_ts
    _ttl=$(echo "$TASK_CONFIG"  | jq -r '.ttl     // empty' 2>/dev/null || true)
    _added=$(echo "$TASK_CONFIG" | jq -r '.addedAt // empty' 2>/dev/null || true)
    [[ -z "$_ttl" || -z "$_added" ]] && return 0

    # ttl 파싱: "30d" / "2w" / "1m"
    _num=$(echo "$_ttl" | grep -oE '^[0-9]+' || true)
    _unit=$(echo "$_ttl" | grep -oE '[dwm]$'  || true)
    if [[ -z "$_num" || -z "$_unit" ]]; then
        log "TTL_WARN: 파싱 실패 — ttl='$_ttl'"
        return 0
    fi

    # addedAt → unix timestamp (macOS date -j)
    _added_ts=$(date -j -f "%Y-%m-%d" "$_added" +%s 2>/dev/null) || {
        log "TTL_WARN: addedAt 파싱 실패 — '$_added'"
        return 0
    }
    case "$_unit" in
        d) _expiry_ts=$(( _added_ts + _num * 86400 )) ;;
        w) _expiry_ts=$(( _added_ts + _num * 7 * 86400 )) ;;
        m) _expiry_ts=$(( _added_ts + _num * 30 * 86400 )) ;;
        *) log "TTL_WARN: 알 수 없는 단위 '$_unit'"; return 0 ;;
    esac

    _now_ts=$(date +%s)
    if (( _now_ts < _expiry_ts )); then
        local _days_left=$(( (_expiry_ts - _now_ts) / 86400 ))
        log "TTL: 유효 — ${_days_left}일 남음 (ttl=${_ttl}, addedAt=${_added})"
        return 0
    fi

    # 만료됨 → cleanup
    log "TTL_EXPIRED: ${TASK_ID} 만료 (ttl=${_ttl}, addedAt=${_added}) — 자동 제거 시작"

    # 1) plist 탐색 · unload · 삭제
    local _plist
    for _plist in \
        "${HOME}/Library/LaunchAgents/ai.jarvis.${TASK_ID}.plist" \
        "${HOME}/Library/LaunchAgents/com.jarvis.${TASK_ID}.plist"; do
        if [[ -f "$_plist" ]]; then
            launchctl unload "$_plist" 2>/dev/null || true
            rm -f "$_plist" 2>/dev/null || true
            log "TTL_CLEANUP: plist 제거 완료 — $_plist"
        fi
    done

    # 2) tasks.json enabled: false 갱신
    local _tasks_src="${BOT_HOME}/config/tasks.json"
    if [[ -f "$_tasks_src" ]]; then
        local _tmp_tasks
        _tmp_tasks=$(mktemp)
        if jq --arg id "$TASK_ID" \
              '(.tasks[] | select(.id == $id)) |= (. + {"enabled": false})' \
              "$_tasks_src" > "$_tmp_tasks" 2>/dev/null; then
            mv "$_tmp_tasks" "$_tasks_src"
            log "TTL_CLEANUP: tasks.json enabled=false 완료 — ${TASK_ID}"
        else
            rm -f "$_tmp_tasks" 2>/dev/null || true
            log "TTL_WARN: tasks.json 갱신 실패"
        fi
    fi

    # 3) Discord 알림 (jarvis-system) — discord_route_raw로 egress 중앙화
    local _today _msg
    _today=$(TZ=Asia/Seoul date '+%Y-%m-%d')
    _msg="🗑️ **TTL 만료 자동 제거**: \`${TASK_ID}\` — ttl=${_ttl}, addedAt=${_added}, removed=${_today}"
    discord_route_raw jarvis-system "$_msg" 2>/dev/null || true

    log "TTL_CLEANUP: 완료 — ${TASK_ID} 자동 제거됨"
}

# --- Cluster jitter: :00분 동시 실행 방지 (macOS crontab FDA 제한 우회) ---
# crontab 스케줄은 동일하게 유지, 실제 실행은 여기서 분산
# declare -A 금지 (macOS bash 3.x 비호환) → case 문 사용
_jitter=0
case "$TASK_ID" in
    # 기존: 9시대 동시 실행 분산
    infra-daily)      _jitter=120 ;;
    cost-monitor)     _jitter=30  ;;
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

# --- Read task config from tasks.json or SQLite (task-store) ---
_PHASE="config-load"
# Validate JSON syntax before parsing
if ! jq empty "$TASKS_FILE" >/dev/null 2>&1; then
    log "ERROR: Invalid JSON in $TASKS_FILE — jq validation failed"
    log "  File: $TASKS_FILE"
    log "  Size: $(wc -c < "$TASKS_FILE" 2>/dev/null || echo 'unknown') bytes"
    exit 1
fi

# Validate .tasks array exists and is not empty
_TASKS_COUNT=$(jq '.tasks | length' "$TASKS_FILE" 2>/dev/null || echo 0)
if (( _TASKS_COUNT <= 0 )); then
    log "ERROR: No tasks found in $TASKS_FILE (tasks array is empty or missing)"
    log "  File: $TASKS_FILE"
    exit 1
fi

TASK_CONFIG=$(jq -r --arg id "$TASK_ID" '.tasks[] | select(.id == $id or ((.aliases // []) | index($id)) != null)' "$TASKS_FILE" 2>/dev/null || echo "null")

# tasks.json에 없으면 SQLite에서 찾기 (debug-cron-* 태스크용)
if [[ -z "$TASK_CONFIG" || "$TASK_CONFIG" == "null" ]]; then
    _TASK_STORE="${BOT_HOME}/lib/task-store.mjs"
    if [[ -x "$(command -v node)" ]] && [[ -f "$_TASK_STORE" ]]; then
        _TASK_OBJ=$(node "$_TASK_STORE" export 2>/dev/null | jq --arg id "$TASK_ID" '.tasks[] | select(.id == $id)' 2>/dev/null)
        if [[ -n "$_TASK_OBJ" && "$_TASK_OBJ" != "null" && "$_TASK_OBJ" != "{}" ]]; then
            TASK_CONFIG="$_TASK_OBJ"
            log "Task config loaded from SQLite: $TASK_ID"
        fi
    fi
fi

# contract 태스크(-contract 접미사)는 동적으로 생성 (task-store에 없을 수 있음)
if [[ -z "$TASK_CONFIG" || "$TASK_CONFIG" == "null" || "$TASK_CONFIG" == "{}" ]]; then
    if [[ "$TASK_ID" == *"-contract" ]]; then
        # 원본 태스크 ID 추출 (예: "debug-cron-weekly-dream-insight-contract" → "debug-cron-weekly-dream-insight")
        ORIGINAL_TASK_ID="${TASK_ID%-contract}"
        log "Contract task detected — loading original task config for: $ORIGINAL_TASK_ID"

        # 원본 태스크 설정 로드
        _ORIG_OBJ=$(jq -r --arg id "$ORIGINAL_TASK_ID" '.tasks[] | select(.id == $id or ((.aliases // []) | index($id)) != null)' "$TASKS_FILE" 2>/dev/null || echo "null")

        if [[ -z "$_ORIG_OBJ" || "$_ORIG_OBJ" == "null" ]]; then
            # tasks.json에 없으면 SQLite 시도
            if [[ -x "$(command -v node)" ]] && [[ -f "$_TASK_STORE" ]]; then
                _ORIG_OBJ=$(node "$_TASK_STORE" export 2>/dev/null | jq --arg id "$ORIGINAL_TASK_ID" '.tasks[] | select(.id == $id)' 2>/dev/null)
            fi
        fi

        if [[ -n "$_ORIG_OBJ" && "$_ORIG_OBJ" != "null" && "$_ORIG_OBJ" != "{}" ]]; then
            # contract 태스크는 원본 설정을 상속하되, allowedTools는 제한
            TASK_CONFIG="$_ORIG_OBJ"
            # Contract 프롬프트는 이후 PROMPT 로딩 단계에서 생성 (아래 참조)
            _CONTRACT_MODE="true"
            log "Contract task: will generate contract prompt for original task $ORIGINAL_TASK_ID"
        else
            log "ERROR: Original task '$ORIGINAL_TASK_ID' not found for contract '$TASK_ID'"
            log "  Source file: $TASKS_FILE ($_TASKS_COUNT tasks available)"
            exit 1
        fi
        unset _ORIG_OBJ _TASK_STORE ORIGINAL_TASK_ID
    else
        log "ERROR: Task '$TASK_ID' not found in tasks.json or SQLite"
        log "  Source file: $TASKS_FILE ($_TASKS_COUNT tasks available)"
        log "  Available task IDs: $(jq -r '.tasks[].id' "$TASKS_FILE" 2>/dev/null | head -10 | tr '\n' ',' | sed 's/,$//')"
        exit 1
    fi
fi

# disabled 태스크 조용히 건너뜀
if [[ "$(echo "$TASK_CONFIG" | jq -r '.disabled // false')" == "true" ]]; then
    log "SKIPPED (disabled)"
    _TASK_DONE=true
    exit 0
fi
# enabled: false 태스크 조용히 건너뜀 (기본값 true)
# NOTE: jq `//` 연산자는 null+false 둘 다 fallback → has() 명시 검사로 교정.
if [[ "$(echo "$TASK_CONFIG" | jq -r 'if has("enabled") then .enabled else true end')" == "false" ]]; then
    log "SKIPPED (enabled: false)"
    _TASK_DONE=true
    exit 0
fi

# Contract 프롬프트 생성 (contract 태스크인 경우)
PROMPT_FILE=""  # 나중에 사용될 변수이므로 미리 초기화
if [[ "${_CONTRACT_MODE:-}" == "true" ]]; then
    # 원본 태스크의 프롬프트 로드
    _ORIG_PROMPT_FILE=$(echo "$TASK_CONFIG" | jq -r '.prompt_file // empty')
    _ORIG_PROMPT=""
    if [[ -n "$_ORIG_PROMPT_FILE" ]]; then
        _pf_path="${BOT_HOME}/prompts/${_ORIG_PROMPT_FILE}"
        if [[ -f "$_pf_path" ]]; then
            _ORIG_PROMPT=$(cat "$_pf_path")
        else
            _ORIG_PROMPT=$(echo "$TASK_CONFIG" | jq -r '.prompt // empty')
        fi
    else
        _ORIG_PROMPT=$(echo "$TASK_CONFIG" | jq -r '.prompt // empty')
    fi

    # Contract 프롬프트 생성 (직접 텍스트로 사용)
    PROMPT="[Sprint Contract 생성 요청]

아래 태스크의 성공 기준(Success Criteria)을 정의하라.

## 태스크
- 이름: ${TASK_ID%-contract}
- 설명: ${_ORIG_PROMPT}

## 출력 형식 (반드시 이 JSON만 출력, 다른 텍스트 없이):
\`\`\`json
{
  \"objective\": \"1줄 요약\",
  \"maxIterations\": 3,
  \"successCriteria\": [
    {
      \"id\": 1,
      \"description\": \"검증 가능한 기준 설명\",
      \"verifyCmd\": \"bash 명령어 (exit 0=통과, exit 1=실패). 자동 검증 불가 시 빈 문자열\"
    }
  ]
}
\`\`\`

## 규칙
- successCriteria는 1~5개, 구체적이고 검증 가능하게
- verifyCmd: 파일 존재 확인(test -f), 프로세스 상태(pgrep), 문법 검사(bash -n) 등 활용
- 자동 검증 불가한 기준은 verifyCmd를 빈 문자열(\"\")로 설정
- maxIterations: 태스크 복잡도에 따라 2~5
- JSON 블록만 출력하라. 설명/인사말 없이 \`\`\`json ... \`\`\` 블록만"
    log "Contract mode: contract 프롬프트 생성 (원본 태스크: ${TASK_ID%-contract})"
    unset _CONTRACT_MODE _ORIG_PROMPT _ORIG_PROMPT_FILE _pf_path
else
    # 일반 태스크: 기존 로직
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
    if [[ -z "$_alias" ]]; then continue; fi
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

# --- PROMPT에서 환경변수 확장 ---
# 프롬프트에서 변수 참조를 실제 값으로 교체
PROMPT="${PROMPT//\$BOT_HOME/$BOT_HOME}"
PROMPT="${PROMPT//\$\{BOT_HOME\}/$BOT_HOME}"
# Google Workspace 변수도 확장 (L35-46에서 export된 변수들)
if [[ -n "${GOOGLE_ACCOUNT:-}" ]]; then
    PROMPT="${PROMPT//\$GOOGLE_ACCOUNT/$GOOGLE_ACCOUNT}"
    PROMPT="${PROMPT//\$\{GOOGLE_ACCOUNT\}/$GOOGLE_ACCOUNT}"
fi
if [[ -n "${GOOGLE_TASKS_LIST_ID:-}" ]]; then
    PROMPT="${PROMPT//\$GOOGLE_TASKS_LIST_ID/$GOOGLE_TASKS_LIST_ID}"
    PROMPT="${PROMPT//\$\{GOOGLE_TASKS_LIST_ID\}/$GOOGLE_TASKS_LIST_ID}"
fi

# --- 2026-05-12: Skill Synthesis PROMPT suffix 자동 주입 (위치 A) ---
# skillSynthesis.enabled=true 태스크에 한해 PROMPT 끝에 SKILL_JSON 출력 지시를 동적 추가.
# 강제 출력이 아닌 선택 — LLM이 패턴 없으면 생략 가능.
_sk_enabled_a=$(echo "$TASK_CONFIG" | jq -r '.skillSynthesis.enabled // false')
if [[ "$_sk_enabled_a" == "true" ]]; then
    # 중복 주입 방지: 프롬프트(또는 prompt_file)에 이미 SKILL_JSON 지시가 있으면 suffix 생략
    if printf '%s' "$PROMPT" | grep -q "SKILL_JSON:"; then
        log "Skill synthesis suffix 생략 — 프롬프트에 이미 SKILL_JSON 지시 포함 (중복 방지)"
    else
        PROMPT="${PROMPT}

---
[선택적 Skill 합성 — 재사용 가능한 패턴·인사이트 없으면 이 섹션 전체 생략]
이번 실행에서 발견한 운영 패턴이 있다면(없으면 출력 금지):
SKILL_JSON: {\"type\":\"pattern|insight|correction|anti-pattern\",\"domain\":\"ops\",\"title\":\"한 줄(40자 이내)\",\"context\":\"발견 맥락 1문장\",\"pattern\":\"재사용 핵심 구조(30자 이상)\",\"evidence\":[\"실제 로그·명령 출력\"],\"reusable_in\":[\"재사용 가능한 태스크·상황\"],\"gain\":\"효과 1줄\"}
패턴이 없으면 강제 출력 금지. 있을 때만 1건."
        log "Skill synthesis suffix 주입 (skillSynthesis.enabled=true, task=${TASK_ID})"
    fi
fi
unset _sk_enabled_a

_PHASE="param-load"
# contract 태스크는 Bash,Read로 제한 (verifyCmd 실행 + 파일 읽기만 필요)
if [[ "$TASK_ID" == *"-contract" ]]; then
    ALLOWED_TOOLS="Bash,Read"
else
    ALLOWED_TOOLS=$(echo "$TASK_CONFIG" | jq -r '.allowedTools // "Read"')
fi
TIMEOUT=$(echo "$TASK_CONFIG" | jq -r '.timeout // 180')
MAX_BUDGET=$(echo "$TASK_CONFIG" | jq -r '.maxBudget // empty')
# tasks.json retry.max → retry-wrapper.sh MAX_RETRIES (없으면 3 기본값)
TASK_MAX_RETRIES=$(echo "$TASK_CONFIG" | jq -r '.retry.max // .maxRetries // 3')
RESULT_RETENTION=$(echo "$TASK_CONFIG" | jq -r '.resultRetention // 7')
RESULT_MAX_CHARS=$(echo "$TASK_CONFIG" | jq -r '.resultMaxChars // 2000')
MODEL=$(echo "$TASK_CONFIG" | jq -r '.model // empty')

# === Pilot Routing: DeepSeek/Qwen budget model routing (2026-05-25) ===
# Phase 1-3 파일럿: 저난이도 크론을 DeepSeek V4-Flash 또는 Qwen으로 라우팅
# config: pilot-routing-deepseek-qwen.json (status: active)
# 예외: tasks.json에서 명시적 모델이 지정된 경우 라우팅 스킵 (tasks의 의도 존경)
if [[ -z "$MODEL" && -f "${BOT_HOME}/config/pilot-routing-deepseek-qwen.json" ]]; then
    _pilot_config=$(cat "${BOT_HOME}/config/pilot-routing-deepseek-qwen.json" 2>/dev/null || echo '{}')
    _pilot_status=$(echo "$_pilot_config" | jq -r '.status // "inactive"')

    if [[ "$_pilot_status" == "active" ]]; then
        # model-selector.mjs로 라우팅 결정
        _routed_model=$(node "${BOT_HOME}/lib/model-selector.mjs" "$TASK_ID" "$MODEL" 2>&1 | tail -1)
        if [[ -n "$_routed_model" && "$_routed_model" != "$MODEL" ]]; then
            log "Model routing: $MODEL → $_routed_model (pilot phase)"
            MODEL="$_routed_model"
        fi
        unset _pilot_config _pilot_status _routed_model
    fi
fi

# TASK_AUTHOR: tasks.json의 "author" 필드, 없으면 task id를 그대로 사용
# ask-claude.sh에서 TASK_AUTHOR로 사용됨
export TASK_AUTHOR
TASK_AUTHOR=$(echo "$TASK_CONFIG" | jq -r '.author // .id // empty')
DISCORD_CHANNEL=$(echo "$TASK_CONFIG" | jq -r '.discordChannel // empty')
REQUIRES_MARKET=$(echo "$TASK_CONFIG" | jq -r '.requiresMarket // false')

# --- US Market holiday check (tasks with requiresMarket: true) ---
_is_market_closed() {
    # requiresMarket 태스크는 전부 미국 시장(TQQQ) 대상 → 뉴욕 시간 기준으로 판정한다.
    # (KST 로 판정하면 토요일 새벽 KST = 금요일 오후 ET 정규장이 "주말" 로 오판된다)
    local dow today
    dow=$(TZ=America/New_York date +%w)         # 0=sunday, 6=saturday
    today=$(TZ=America/New_York date +%Y-%m-%d)

    if [[ "$dow" -eq 0 || "$dow" -eq 6 ]]; then
        return 0  # market closed (weekend)
    fi

    # NYSE 휴장일 — 관측일(토→금, 일→월) 기준. 매년 12월에 다음 해분을 추가한다.
    # 2026: 신정·MLK·대통령의날·성금요일·메모리얼·준틴스·독립기념일(7/4 토→7/3 금)·노동절·추수감사절·성탄
    # 2027: 준틴스(6/19 토→6/18 금)·독립기념일(7/4 일→7/5 월)·성탄(12/25 토→12/24 금) 관측일 주의
    local nyse_holidays="
2026-01-01 2026-01-19 2026-02-16 2026-04-03 2026-05-25 2026-06-19 2026-07-03 2026-09-07 2026-11-26 2026-12-25
2027-01-01 2027-01-18 2027-02-15 2027-03-26 2027-05-31 2027-06-18 2027-07-05 2027-09-06 2027-11-25 2027-12-24
"
    if [[ " ${nyse_holidays//$'\n'/ } " == *" ${today} "* ]]; then
        return 0  # market closed (holiday)
    fi

    return 1  # market open
}

_MARKET_CLOSED="false"
if _is_market_closed; then
    _MARKET_CLOSED="true"
fi

ALLOW_EMPTY_RESULT=$(echo "$TASK_CONFIG" | jq -r '.allowEmptyResult // false')
# ask-claude.sh 도 이 값을 본다 — export 없이는 빈 응답을 게이트웨이 층이 먼저 실패로 분류해
# 아래 L1200대 "OK — no output" 분기에 도달하지 못한다 (2026-09-03 daily-summary 헛재시도 4회)
export ALLOW_EMPTY_RESULT
# LLM 태스크의 "보고할 것 없음" 표식 — claude CLI 가 빈 응답을 되묻기 때문에 빈 출력 대신 이 토큰을 내게 한다
EMPTY_RESULT_TOKEN=$(echo "$TASK_CONFIG" | jq -r '.emptyResultToken // empty')
SUCCESS_PATTERN=$(echo "$TASK_CONFIG" | jq -r '.successPattern // empty')
SCRIPT=$(echo "$TASK_CONFIG" | jq -r '.script // empty')
SCRIPT_ARGS=$(echo "$TASK_CONFIG" | jq -r '.scriptArgs // "daily"')
# Continue Sites: opt-out 플래그 (기본값 true = 활성화)
CONTINUE_SITES=$(echo "$TASK_CONFIG" | jq -r '.continueSites // true')
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
print(d.get(\"$TASK_ID\", ''))
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
if [[ "$REQUIRES_MARKET" == "true" && "$_MARKET_CLOSED" == "true" ]]; then
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
    SCRIPT_PATH="${SCRIPT_PATH//\$BOT_HOME/$BOT_HOME}"
    SCRIPT_PATH="${SCRIPT_PATH//\$\{BOT_HOME\}/$BOT_HOME}"
    SCRIPT_PATH="${SCRIPT_PATH//\$HOME/$HOME}"
    if [[ "$SCRIPT_PATH" == *'$'* ]]; then
        log "ERROR: unsupported env var in script path: $SCRIPT_PATH (지원: \$BOT_HOME, \$HOME)"
        _TASK_DONE=true
        exit 1
    fi
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        log "ERROR: script not found: $SCRIPT_PATH"
        if ! _permanent_disable_task "$TASK_ID" "script_not_found" "$SCRIPT_PATH"; then
            log "ERROR: _permanent_disable_task failed for $TASK_ID — manual intervention required"
        fi
        _fsm_transition "$TASK_ID" "failed" \
            "{\"exitCode\":127,\"reason\":\"script_not_found\",\"autoDisabled\":true,\"script\":\"$SCRIPT_PATH\"}"
        _TASK_DONE=true
        exit 1
    fi
    # Layer 1: script-path도 글로벌 세마포어 보호 (retry-wrapper 경유 태스크와 동일 보호)
    _SCRIPT_SLOT=""
    if [[ -f "${INFRA_DIR}/bin/system-semaphore.sh" ]]; then
        source "${INFRA_DIR}/bin/system-semaphore.sh"
        _SCRIPT_SLOT=$(acquire_slot 2>/dev/null || true)
        if [[ -z "$_SCRIPT_SLOT" ]]; then
            log "WARN: semaphore full — script-path 대기 불가, 직접 실행 (동시 호출 제한 초과 가능)"
        else
            log "semaphore acquired: slot ${_SCRIPT_SLOT} for script-path"
        fi
    fi
    # .mjs/.js 파일은 node로 명시적 실행, 아니면 shebang에 의존
    if [[ "$SCRIPT_PATH" == *.mjs || "$SCRIPT_PATH" == *.js ]]; then
        RESULT=$(node "$SCRIPT_PATH" "$SCRIPT_ARGS" 2>>"${BOT_HOME}/logs/cron.log") || EXIT_CODE=$?
        if [[ $EXIT_CODE -ne 0 ]]; then
            log "SCRIPT_EXIT: node script failed with exit code $EXIT_CODE"
        fi
    else
        if [[ ! -x "$SCRIPT_PATH" ]]; then
            log "ERROR: script not executable: $SCRIPT_PATH"
            if ! _permanent_disable_task "$TASK_ID" "script_not_executable" "$SCRIPT_PATH"; then
                log "ERROR: _permanent_disable_task failed for $TASK_ID — manual intervention required"
            fi
            _fsm_transition "$TASK_ID" "failed" \
                "{\"exitCode\":126,\"reason\":\"script_not_executable\",\"autoDisabled\":true,\"script\":\"$SCRIPT_PATH\"}"
            [[ -n "$_SCRIPT_SLOT" ]] && release_slot "$_SCRIPT_SLOT" 2>/dev/null || true
            _TASK_DONE=true
            exit 1
        fi
        RESULT=$("$SCRIPT_PATH" "$SCRIPT_ARGS" 2>>"${BOT_HOME}/logs/cron.log") || EXIT_CODE=$?
        if [[ $EXIT_CODE -ne 0 ]]; then
            log "SCRIPT_EXIT: shell script failed with exit code $EXIT_CODE"
        fi
    fi
    # 세마포어 해제
    [[ -n "$_SCRIPT_SLOT" ]] && release_slot "$_SCRIPT_SLOT" 2>/dev/null || true
else
    # Continue Sites: LLM 태스크에 다단계 복구 적용
    if [[ "$CONTINUE_SITES" != "false" ]] && type run_with_recovery &>/dev/null; then
        log "CONTINUE_SITES: enabled — 다단계 복구 모드"
        _RESULT_TMP="/tmp/bot-cron-result-${TASK_ID}-$$.txt"
        (run_with_recovery "$TASK_ID" "$BOT_HOME/bin/retry-wrapper.sh" \
            "$TASK_ID" "$PROMPT" "$ALLOWED_TOOLS" "$TIMEOUT" "$MAX_BUDGET" \
            "$RESULT_RETENTION" "$MODEL" "$TASK_MAX_RETRIES") > "$_RESULT_TMP" 2>&1
        EXIT_CODE=$?
        RESULT=$(cat "$_RESULT_TMP" 2>/dev/null || true)
        rm -f "$_RESULT_TMP"
        if [[ $EXIT_CODE -ne 0 ]]; then
            log "RETRY_WRAPPER_EXIT: recovery mode failed with exit code $EXIT_CODE"
        fi
    else
        _RESULT_TMP="/tmp/bot-cron-result-${TASK_ID}-$$.txt"
        ("$BOT_HOME/bin/retry-wrapper.sh" "$TASK_ID" "$PROMPT" "$ALLOWED_TOOLS" "$TIMEOUT" "$MAX_BUDGET" "$RESULT_RETENTION" "$MODEL" "$TASK_MAX_RETRIES") > "$_RESULT_TMP" 2>&1
        EXIT_CODE=$?
        RESULT=$(cat "$_RESULT_TMP" 2>/dev/null || true)
        rm -f "$_RESULT_TMP"
        if [[ $EXIT_CODE -ne 0 ]]; then
            log "RETRY_WRAPPER_EXIT: standard mode failed with exit code $EXIT_CODE"
        fi
    fi
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
    if [[ -n "${JARVIS_RECOVERY_STAGE:-}" ]]; then
        log "FAILED (exit: $EXIT_CODE) — Continue Sites: 전 단계(1~5) 복구 실패"
    else
        log "FAILED (exit: $EXIT_CODE)"
    fi
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
# Store duration before unsetting (used in file routing)
_TASK_DURATION="${_ACTUAL_DURATION}"
# Continue Sites: 복구 단계에서 성공한 경우 로그 보강
if [[ "${JARVIS_RECOVERY_STAGE:-1}" -gt 1 ]]; then
    log "SUCCESS (duration=${_ACTUAL_DURATION}s, recovered at stage ${JARVIS_RECOVERY_STAGE})"
else
    log "SUCCESS (duration=${_ACTUAL_DURATION}s)"
fi
unset _ACTUAL_DURATION
# circuit breaker: 성공 시 초기화
if [[ -f "$_CB_FILE" ]]; then rm -f "$_CB_FILE" 2>/dev/null || true; fi
# FSM: running → done 전이
# result 는 필수다 — task-store 의 RESULT_REQUIRED 게이트(2026-07-22)가 result 없는 done 을 거부하는데
# 이 호출은 `|| true` 로 삼켜져 script-path 태스크 전부가 running 에 남았고, 30분 뒤 stale-watcher 가
# 성공한 태스크를 failed 로 찍어 Discord 경고까지 냈다 (2026-09-04 실측: 하루 93건, cron.log 는 전부 SUCCESS).
# ask-claude 경로는 완료 워크플로우가 먼저 done 을 찍으므로 여기서는 done→done 거부가 정상이다.
_fsm_transition "$TASK_ID" "done" \
    "{\"result\":\"SUCCESS (duration=${_TASK_DURATION}s)\",\"exitCode\":0,\"durationSec\":${_TASK_DURATION:-0},\"lastError\":null}"
_FSM_RUNNING=false

# Phase 2-A 메타인지 절차적 자기 관찰 (옵트인: TASK_OBSERVE=1 or JARVIS_METACOG_OBSERVE=1)
if [[ "${TASK_OBSERVE:-0}" == "1" || "${JARVIS_METACOG_OBSERVE:-0}" == "1" ]]; then
    _OBSERVER="${INFRA_DIR}/scripts/task-run-observer.mjs"
    if [[ -f "$_OBSERVER" ]]; then
        JARVIS_OBSERVE_TASK_ID="$TASK_ID" \
        JARVIS_OBSERVE_DURATION="${_TASK_DURATION:-0}" \
        JARVIS_OBSERVE_EXIT="${EXIT_CODE:-0}" \
        JARVIS_OBSERVE_SNIPPET="${RESULT:0:500}" \
          node "$_OBSERVER" 2>>"${BOT_HOME}/logs/cron.log" &
        disown
    fi
fi

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

# ─── 2026-05-12: 마커 선처리 블록 (위치 B — pre-truncation, $RESULT 원본 직접 추출) ───────────
# SKILL_JSON:  → jarvis/runtime/skills/skills.jsonl (Skill 합성 전용)
# EUREKA_JSON: → jarvis/runtime/wiki/meta/eureka.jsonl (하위 호환)
# 원칙: $RESULT 원본에서 추출 → 파일 적재 → RESULT에서 해당 라인 제거(Discord 오염 방지)
# ─────────────────────────────────────────────────────────────────────────────────────────────

# [B1] SKILL_JSON 처리 (skillSynthesis.enabled 태스크 한정)
_sk_enabled_b=$(echo "$TASK_CONFIG" | jq -r '.skillSynthesis.enabled // false')
if [[ "$_sk_enabled_b" == "true" ]] && command -v jq >/dev/null 2>&1 \
    && printf '%s' "$RESULT" | grep -q "^SKILL_JSON:"; then
    _sk_file="${BOT_HOME}/skills/skills.jsonl"
    _sk_domain=$(echo "$TASK_CONFIG" | jq -r '.skillSynthesis.domain // "ops"')
    mkdir -p "$(dirname "$_sk_file")"
    _sk_added=0
    while IFS= read -r _sk_raw; do
        # 1) JSON 유효성
        if ! echo "$_sk_raw" | jq -e . >/dev/null 2>&1; then continue; fi
        # 2) 필수 필드 + pattern 30자 이상
        if ! echo "$_sk_raw" | jq -e '.type and .title and .pattern and (.pattern | length >= 30)' >/dev/null 2>&1; then
            log "SKILL_JSON 품질 미달 — 스킵 (필수 필드 누락/pattern<30자)"
            continue
        fi
        # 3) type enum 유효성
        if ! echo "$_sk_raw" | jq -e '.type | test("^(pattern|insight|correction|anti-pattern)$")' >/dev/null 2>&1; then
            log "SKILL_JSON type 유효성 실패 — 스킵"
            continue
        fi
        # 4) 중복 방지: title 앞 4단어로 skills.jsonl grep
        _sk_title=$(echo "$_sk_raw" | jq -r '.title // ""')
        _sk_key=$(echo "$_sk_title" | awk '{for(i=1;i<=4&&i<=NF;i++) printf $i" "}' | sed 's/[[:space:]]*$//')
        if [[ -f "$_sk_file" ]] && [[ -n "$_sk_key" ]] && grep -qF "$_sk_key" "$_sk_file" 2>/dev/null; then
            log "SKILL_JSON 중복 감지 — 스킵: ${_sk_key}"
            continue
        fi
        # 5) 원자 락 (mkdir 방식 — macOS flock CLI 미지원 대응)
        _sk_lock="${_sk_file}.lock.d"
        if ! mkdir "$_sk_lock" 2>/dev/null; then
            log "SKILL_JSON 락 획득 실패 — 스킵 (동시 쓰기 중)"
            continue
        fi
        # 6) 자동 추가 필드 주입 + append
        _sk_ts=$(TZ=Asia/Seoul date "+%Y-%m-%dT%H:%M:%S+09:00")
        _sk_date=$(TZ=Asia/Seoul date "+%Y-%m-%d %H:%M KST")
        _sk_seq=$(( $(wc -l < "$_sk_file" 2>/dev/null || echo 0) + 1 ))
        _sk_id="skill-$(TZ=Asia/Seoul date +%Y%m%d)-$(printf '%03d' "$_sk_seq")"
        _sk_full=$(echo "$_sk_raw" | jq -c \
            --arg id    "$_sk_id" \
            --arg date  "$_sk_date" \
            --arg ts    "$_sk_ts" \
            --arg domain "$_sk_domain" \
            --arg src   "auto-synthesis:${TASK_ID}" \
            '. + {id: $id, date: $date, ts: $ts, domain: (.domain // $domain), source_session: $src, auto: true}')
        echo "$_sk_full" >> "$_sk_file"
        rmdir "$_sk_lock" 2>/dev/null || true
        _sk_added=$((_sk_added + 1))
    done < <(printf '%s\n' "$RESULT" | grep "^SKILL_JSON:" | sed 's/^SKILL_JSON:[[:space:]]*//')
    [[ $_sk_added -gt 0 ]] && log "SKILL_JSON 자동 합성 — ${_sk_added}건 → skills.jsonl"
    # RESULT에서 SKILL_JSON 라인 제거 (Discord 전송 오염 방지)
    RESULT=$(printf '%s\n' "$RESULT" | grep -v "^SKILL_JSON:" || true)
    unset _sk_file _sk_domain _sk_added _sk_raw _sk_title _sk_key _sk_lock \
          _sk_ts _sk_date _sk_seq _sk_id _sk_full
fi
unset _sk_enabled_b

# [B2] EUREKA_JSON 처리 (council-insight 하위 호환 — $RESULT 원본에서 직접 추출)
if [[ "$TASK_ID" == "council-insight" ]] && command -v jq >/dev/null 2>&1 \
    && printf '%s' "$RESULT" | grep -q "^EUREKA_JSON:"; then
    _eu_file="${HOME}/.openclaw-data/runtime/wiki/meta/eureka.jsonl"
    mkdir -p "$(dirname "$_eu_file")"
    _eu_added=0
    while IFS= read -r _eu_line; do
        if echo "$_eu_line" | jq -e . >/dev/null 2>&1; then
            _eu_ts=$(TZ=Asia/Seoul date "+%Y-%m-%dT%H:%M:%S+09:00")
            echo "$_eu_line" | jq -c --arg ts "$_eu_ts" '. + {ts: $ts, source: "council-insight"}' >> "$_eu_file"
            _eu_added=$((_eu_added + 1))
        fi
    done < <(printf '%s\n' "$RESULT" | grep "^EUREKA_JSON:" | sed 's/^EUREKA_JSON:[[:space:]]*//')
    [[ $_eu_added -gt 0 ]] && log "EUREKA_JSON 적재 — ${_eu_added}건 → eureka.jsonl"
    # RESULT에서 EUREKA_JSON 라인 제거 (Discord 전송 오염 방지)
    RESULT=$(printf '%s\n' "$RESULT" | grep -v "^EUREKA_JSON:" || true)
    unset _eu_file _eu_added _eu_line _eu_ts
fi
# ─────────────────────────────────────────────────────────────────────────────────────────────

# --- Post-run verify 훅: 실제 완료 결과 검증 ─────────────────────────────────────────
# 목적: 자동화 완료 선언 전 HTTP status, 파일 존재, 프로세스 상태 확인
# 실패 시 warning만 기록 (이미 성공 EXIT_CODE=0이므로 재실패 차단)
_PHASE="post-verify"
if [[ -x "${BOT_HOME}/lib/post-run-verify.sh" ]]; then
    if "${BOT_HOME}/lib/post-run-verify.sh" "$TASK_ID" "$RESULT" "$ALLOWED_TOOLS" 2>>"${BOT_HOME}/logs/cron.log"; then
        log "POST-VERIFY: ✓ passed"
    else
        log "POST-VERIFY: ⚠ warnings (see verify.log for details)"
    fi
else
    log "WARN: post-run-verify.sh not found — skipping verify hook"
fi
# ─────────────────────────────────────────────────────────────────────────────

# --- Sprint Contract 자동 검증 (contract 태스크 전용) ─────────────────────────
# contract 태스크(-contract 접미사)인 경우, verify-sprint-contract.sh로 성공 기준 검증
_PHASE="contract-verify"
if [[ "$TASK_ID" == *"-contract" ]]; then
    # contract 태스크: 원본 태스크 ID 추출 (예: "debug-cron-cron-safe-wrapper.sh-contract" → "debug-cron-cron-safe-wrapper.sh")
    ORIGINAL_TASK_ID="${TASK_ID%-contract}"

    if [[ -x "${BOT_HOME}/scripts/verify-sprint-contract.sh" ]]; then
        log "CONTRACT_VERIFY: 시작 (원본 태스크=${ORIGINAL_TASK_ID})"
        local _verify_output=""
        local _verify_exit=0
        local _verify_stderr_file="${BOT_HOME}/logs/claude-stderr-${TASK_ID}.log"

        # verify-sprint-contract.sh 실행: stdout/stderr를 분리 캡처하여 진단 정보 보존
        _verify_output=$("${BOT_HOME}/scripts/verify-sprint-contract.sh" "$ORIGINAL_TASK_ID" 2>"$_verify_stderr_file") || _verify_exit=$?

        if [[ $_verify_exit -eq 0 ]]; then
            log "CONTRACT_VERIFY: ✓ 검증 통과 (원본 태스크=${ORIGINAL_TASK_ID})"
            # 모든 criteria가 passed — contract 검증 성공
            echo "$_verify_output"
        elif [[ $_verify_exit -eq 2 ]]; then
            # exit=2: contract 파일 없음 → 원본 태스크 결과에서 contract 추출 시도
            log "CONTRACT_VERIFY: contract 파일 없음 → 원본 태스크 결과에서 추출 시도"

            # 원본 태스크의 결과 파일 찾기
            _RESULT_DIR="${BOT_HOME}/results/${ORIGINAL_TASK_ID}"
            if [[ -d "$_RESULT_DIR" ]]; then
                # 가장 최근 결과 파일 찾기
                _LATEST_RESULT=$(find "$_RESULT_DIR" -maxdepth 1 -type f -name "*.md" | sort -V | tail -1)

                if [[ -n "$_LATEST_RESULT" && -f "$_LATEST_RESULT" ]]; then
                    log "CONTRACT_VERIFY: 원본 태스크 결과 파일 발견: $_LATEST_RESULT"

                    # 결과에서 contract JSON 추출
                    if _contract_json=$(sc_parse_contract_response "$(cat "$_LATEST_RESULT")" 2>/dev/null); then
                        log "CONTRACT_VERIFY: contract JSON 추출 성공"

                        # 저장
                        _objective=$(echo "$_contract_json" | jq -r '.objective // "Task objective"' 2>/dev/null || echo "")
                        _criteria=$(echo "$_contract_json" | jq '.successCriteria // []' 2>/dev/null || echo "[]")
                        _max_iter=$(echo "$_contract_json" | jq '.maxIterations // 3' 2>/dev/null || echo "3")

                        if sc_create "$ORIGINAL_TASK_ID" "$_objective" "$_criteria" "$_max_iter" 2>/dev/null; then
                            log "CONTRACT_VERIFY: contract 저장 완료"

                            # 다시 검증
                            _verify_output=$("${BOT_HOME}/scripts/verify-sprint-contract.sh" "$ORIGINAL_TASK_ID" 2>"$_verify_stderr_file") || _verify_exit=$?
                            if [[ $_verify_exit -eq 0 ]]; then
                                log "CONTRACT_VERIFY: ✓ 재검증 통과"
                                echo "$_verify_output"
                            else
                                log "CONTRACT_VERIFY: ✗ 재검증 실패 (exit=$_verify_exit)"
                                echo "$_verify_output" >&2
                                if [[ -s "$_verify_stderr_file" ]]; then
                                    cat "$_verify_stderr_file" >&2
                                fi
                                exit 1
                            fi
                        else
                            log "CONTRACT_VERIFY: contract 저장 실패"
                            exit 1
                        fi
                    else
                        log "CONTRACT_VERIFY: contract JSON 추출 실패"
                        exit 1
                    fi
                else
                    log "CONTRACT_VERIFY: 원본 태스크 결과 파일 없음 ($ORIGINAL_TASK_ID)"
                    exit 1
                fi
            else
                log "CONTRACT_VERIFY: 원본 태스크 결과 디렉토리 없음 ($_RESULT_DIR)"
                exit 1
            fi
        else
            # exit=1: 1개 이상의 criteria 실패
            log "CONTRACT_VERIFY: ✗ 검증 실패 (원본 태스크=${ORIGINAL_TASK_ID}, 미통과 criteria 있음)"
            # 검증 실패: stdout(criteria 결과)과 stderr 모두 기록
            echo "$_verify_output" >&2
            if [[ -s "$_verify_stderr_file" ]]; then
                cat "$_verify_stderr_file" >&2
            fi
            exit 1
        fi
    else
        log "WARN: verify-sprint-contract.sh not found — contract 검증 스킵"
    fi
fi
# ─────────────────────────────────────────────────────────────────────────────

# --- emptyResultToken: 출력의 결론이 표식이면 "보고할 것 없음" → 빈 결과로 취급, 라우팅 생략 ---
# 판정: 전체가 표식뿐 | 첫 줄이 표식 | 마지막 줄이 표식 (공백·백틱·별표는 벗겨 비교).
# 모델이 CLI 되묻기 뒤 "확인 결과 정상… NO_ISSUES" 처럼 서술을 붙여도 결론이 표식이면 정상 0건이다
# (2026-09-04 캐너리에서 확인). 원문은 ask-claude 결과 파일(runtime/results/<task>/)에 그대로 남는다.
if [[ -n "$EMPTY_RESULT_TOKEN" && -n "$RESULT" ]]; then
    _strip() { printf '%s' "$1" | tr -d '[:space:]`*'; }
    _result_all=$(_strip "$RESULT")
    _result_first=$(_strip "$(printf '%s\n' "$RESULT" | /usr/bin/grep -m1 -v '^[[:space:]]*$' || true)")
    _result_last=$(_strip "$(printf '%s\n' "$RESULT" | /usr/bin/grep -v '^[[:space:]]*$' | tail -n1 || true)")
    if [[ "$_result_all" == "$EMPTY_RESULT_TOKEN" || "$_result_first" == "$EMPTY_RESULT_TOKEN" || "$_result_last" == "$EMPTY_RESULT_TOKEN" ]]; then
        log "OK — sentinel '${EMPTY_RESULT_TOKEN}' (emptyResultToken, condition not triggered, ${#RESULT} chars) → 라우팅 생략"
        RESULT=""
    fi
    unset -f _strip; unset _result_all _result_first _result_last
fi

# --- Truncate result for non-Discord outputs (file, ntfy 등) ---
# Discord는 route-result.sh 내 1990자 청킹이 처리하므로 pre-truncation 불필요.
# file/ntfy 등 단일 출력용 라우터에는 RESULT_MAX_CHARS를 그대로 적용.
_RESULT_FOR_NON_DISCORD="$RESULT"
if [[ ${#_RESULT_FOR_NON_DISCORD} -gt $RESULT_MAX_CHARS ]]; then
    _RESULT_FOR_NON_DISCORD="${_RESULT_FOR_NON_DISCORD:0:$RESULT_MAX_CHARS}...(truncated)"
fi

# --- news-briefing: Discord 표시용에서 기계용 ```json_insights 블록 제거 ---
# (2026-07-13 수정: JSON 원본이 그대로 노출 + 길이초과로 메시지 2분할되던 노이즈.
#  결과 파일(runtime/results)에는 JSON 유지 → post-news-briefing-enqueue.sh 파싱 안전.
#  사람이 읽는 '💡 인사이트' 산문 섹션은 보존, 중복 JSON만 제거.)
_RESULT_FOR_DISCORD="$RESULT"
if [[ "$TASK_ID" == "news-briefing" ]]; then
    _RESULT_FOR_DISCORD="$(printf '%s\n' "$RESULT" | awk 'BEGIN{skip=0} /^```json_insights/{skip=1; next} skip==1 && /^```/{skip=0; next} skip==0{print}')"
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
            # Discord: 정제본 전달 (news-briefing은 json_insights 제거본) — route-result.sh 내 1990자 청킹이 분할 처리
            "$BOT_HOME/bin/route-result.sh" discord "$TASK_ID" "$_RESULT_FOR_DISCORD" "${DISCORD_CHANNEL:-}" || log "WARN: discord routing failed"
            ;;
        ntfy)
            "$BOT_HOME/bin/route-result.sh" ntfy "$TASK_ID" "$_RESULT_FOR_NON_DISCORD" || log "WARN: ntfy routing failed"
            ;;
        file)
            # Save result to task-specific log file — 원본 전체 저장 (truncation 없음)
            _log_file="${BOT_HOME}/logs/${TASK_ID}.log"
            mkdir -p "$(dirname "$_log_file")"
            {
                echo "===== Task: $TASK_ID ====="
                echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
                echo "Exit Code: $EXIT_CODE"
                echo "Duration: ${_TASK_DURATION}s"
                echo "---"
                echo "$RESULT"
            } >> "$_log_file"
            log "Result saved to: $_log_file"
            unset _log_file
            ;;
    esac
done

# --- news-briefing: 인사이트 섹션 → jarvis-ceo 채널 추가 전송 ---
case "$TASK_ID" in
    news-briefing)
        # 24h dedup: 같은 날 이미 전송했으면 중복 전송 차단
        _nb_dedup="${BOT_HOME}/state/dedup/news-briefing-ceo-insight.last_sent"
        _nb_now=$(date +%s)
        _nb_skip=0
        if [[ -f "$_nb_dedup" ]]; then
            _nb_last=$(cat "$_nb_dedup" 2>/dev/null || echo 0)
            _nb_elapsed=$(( _nb_now - _nb_last ))
            if [[ $_nb_elapsed -lt 86400 ]]; then
                log "news-briefing jarvis-ceo 전송 DEDUP_SKIP (${_nb_elapsed}s < 86400s)"
                _nb_skip=1
            fi
        fi

        if [[ "$_nb_skip" -eq 0 ]]; then
            # awk: "💡 Jarvis 적용 가능 인사이트" 이후 추출
            _insight_raw=$(echo "$RESULT" | awk '/💡 Jarvis 적용 가능 인사이트/{found=1} found{print}')
            # json_insights 코드블록 필터링 (raw JSON Discord 노출 방지)
            _insight_raw=$(echo "$_insight_raw" | awk '/^```json_insights/{skip=1} skip{if(/^```$/ || /^```[[:space:]]*$/) skip=0; next} {print}')

            if [[ -n "$_insight_raw" ]]; then
                _ceo_body="📥 **뉴스 브리핑 인사이트 인계** ($(date '+%Y-%m-%d'))
${_insight_raw}"
                    # 1990자 청킹 전송 (Discord 2000자 제한 대응)
                _ceo_total=${#_ceo_body}
                _ceo_offset=0
                while [[ $_ceo_offset -lt $_ceo_total ]]; do
                    _ceo_chunk="${_ceo_body:$_ceo_offset:1990}"
                    discord_route_raw "jarvis-ceo" "$_ceo_chunk" || true
                    _ceo_offset=$(( _ceo_offset + 1990 ))
                    [[ $_ceo_offset -lt $_ceo_total ]] && sleep 1
                done
                echo "$_nb_now" > "$_nb_dedup"
                log "인사이트 섹션 jarvis-ceo 채널 전송 완료 (${_ceo_total}자, dedup 기록)"
            fi
        fi
        unset _nb_dedup _nb_now _nb_skip _nb_last _nb_elapsed
        unset _insight_raw _ceo_webhook _ceo_header _ceo_body _ceo_total _ceo_offset _ceo_chunk _payload
        ;;
esac

# --- FSM 상태 요약: daily-summary / council-insight 완료 시 Discord에 FSM 현황 추가 ---
case "$TASK_ID" in
    daily-summary|council-insight)
        _fsm_summary=$(${NODE_SQLITE} "${FSM_STORE}" fsm-summary 2>/dev/null || true)
        if [[ -n "$_fsm_summary" ]]; then
            discord_route_raw "jarvis-system" "$_fsm_summary" || true
            log "FSM 상태 요약 Discord 전송 완료"
        fi
        unset _fsm_summary
        ;;
esac

# --- 2026-05-12: 위 [B2] 블록으로 이전 완료 (pre-truncation 방식) — 이 블록 비활성화 ---
# 구 방식: council-insight.log tail-200 grep (truncation 이후 log 의존, 취약)
# 신 방식: $RESULT 원본 직접 추출 (위치 B [B2] 블록에서 truncation 이전 처리)
# 이 주석은 이전 블록의 제거 이유를 기록하기 위해 유지.

# TTL 만료 체크 — 실제 성공 완료 시에만 실행 (스킵·실패 경로는 여기까지 오지 않음)
_ttl_cleanup

_TASK_DONE=true
log "DONE"