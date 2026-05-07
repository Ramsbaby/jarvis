#!/usr/bin/env bash
# supervisor-tick.sh — Jarvis Supervisor MVP (Phase 1)
#
# 역할: 5분마다 health 4 source를 수집해 이전 snapshot과 비교, 신규 결함만 Discord 송출.
# 자가 회복(L1~L5)은 Phase 2에서 추가. 본 tick은 collect + alert까지만.
#
# 호출: ai.jarvis.supervisor LaunchAgent (*/5 * * * *)
# state: ~/jarvis/runtime/state/supervisor-snapshot.json (delta 비교용)
#        ~/jarvis/runtime/state/supervisor-tick-ledger.jsonl (30일 retention)
# log:   ~/jarvis/runtime/logs/supervisor.log

set -euo pipefail

# ── 환경 ──────────────────────────────────────────────────────────
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
DOT_JARVIS="${HOME}/.jarvis"
LOG="${BOT_HOME}/logs/supervisor.log"
SNAPSHOT="${BOT_HOME}/state/supervisor-snapshot.json"
LEDGER="${BOT_HOME}/state/supervisor-tick-ledger.jsonl"
LOCK_DIR="/tmp/jarvis-supervisor.lock.d"
mkdir -p "$(dirname "$LOG")" "$(dirname "$SNAPSHOT")"

log() { echo "[$(date '+%F %T')] [supervisor] $*" >> "$LOG"; }

# ── single-instance lock (mkdir atomic) ───────────────────────────
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        log "이미 실행 중 (PID $owner) — skip"
        exit 0
    fi
    rm -rf "$LOCK_DIR" && mkdir "$LOCK_DIR"
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

log "=== tick 시작 ==="

# ── 1. Health Collector (4 source — cron-master 사각지대만) ───────
# 옵션 A 영역 분리 (2026-05-07):
# - cron-master.sh (매일 06:03)        : LA status + auto-disable + bootstrap + 영구실패 분류
# - supervisor (5분마다, 본 스크립트)  : circuit + .err + heartbeat + RAG (cron-master 미커버)
# LA status는 cron-master에 위임 — 알림 중복 방지
CIRCUIT_OPEN='[]'
ERR_FILES='[]'
HEARTBEAT_AGE=0

# 1-A. Circuit breakers OPEN
CIRCUIT_OPEN_LIST=()
for f in "$DOT_JARVIS"/state/circuit-breaker/*.json "$DOT_JARVIS"/state/*-circuit.json; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .json)
    state=$(jq -r '.state // "unknown"' "$f" 2>/dev/null)
    if [ "$state" = "open" ]; then
        CIRCUIT_OPEN_LIST+=("$name")
    fi
done
if [ ${#CIRCUIT_OPEN_LIST[@]} -gt 0 ]; then
    CIRCUIT_OPEN=$(printf '%s\n' "${CIRCUIT_OPEN_LIST[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
fi

# 1-C. .err files (24h, size > 0)
# 2026-05-07 BLOCKER fix: BOT_HOME/logs ↔ DOT_JARVIS/logs 동일 inode 감지 → dedup.
# 양쪽이 같은 디렉토리면 한 번만 스캔. realpath 차이 비교로 자동 dedup.
# pipefail 환경에서 head/xargs SIGPIPE로 전체 fail 방지.
_LOGS_BOT=$(realpath "$BOT_HOME/logs" 2>/dev/null || echo "$BOT_HOME/logs")
_LOGS_DOT=$(realpath "$DOT_JARVIS/logs" 2>/dev/null || echo "$DOT_JARVIS/logs")
_LOG_PATHS=("$_LOGS_BOT")
[ "$_LOGS_BOT" != "$_LOGS_DOT" ] && _LOG_PATHS+=("$_LOGS_DOT")
[ -d "$BOT_HOME/state/results" ] && _LOG_PATHS+=("$BOT_HOME/state/results")

set +o pipefail
ERR_FILES=$(find "${_LOG_PATHS[@]}" \
    -mtime -1 -name "*.err" -size +0c 2>/dev/null \
    | sort -u \
    | head -10 \
    | xargs -I{} basename {} 2>/dev/null \
    | sort -u \
    | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null) || ERR_FILES='[]'
set -o pipefail
[ -z "$ERR_FILES" ] && ERR_FILES='[]'

# 1-D. Discord bot heartbeat
if [ -f "$DOT_JARVIS/state/bot-heartbeat" ]; then
    HEARTBEAT_AGE=$(( $(date +%s) - $(stat -f %m "$DOT_JARVIS/state/bot-heartbeat") ))
fi

# 1-E. RAG indexer health (last RAG index line within 2h)
RAG_LAST_AGE_MIN=999
if [ -f "$DOT_JARVIS/logs/rag-index.log" ]; then
    last_ts=$(grep -E "^\[2026.*RAG index:" "$DOT_JARVIS/logs/rag-index.log" 2>/dev/null | tail -1 | grep -oE "^\[[^]]+" | tr -d "[")
    if [ -n "$last_ts" ]; then
        last_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${last_ts%.*}" +%s 2>/dev/null || echo 0)
        if [ "$last_epoch" -gt 0 ]; then
            RAG_LAST_AGE_MIN=$(( ($(date +%s) - last_epoch) / 60 ))
        fi
    fi
fi

# ── 2. snapshot 빌드 ───────────────────────────────────────────────
TICK_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NEW_SNAPSHOT=$(jq -cn \
    --arg ts "$TICK_TS" \
    --argjson circuit_open "$CIRCUIT_OPEN" \
    --argjson err_files "$ERR_FILES" \
    --argjson heartbeat_age "$HEARTBEAT_AGE" \
    --argjson rag_age_min "$RAG_LAST_AGE_MIN" \
    '{ts:$ts, circuit_open:$circuit_open, err_files:$err_files, heartbeat_age:$heartbeat_age, rag_age_min:$rag_age_min}')

# ── 3. delta 감지 (이전 snapshot과 비교) ──────────────────────────
ALERT_NEW='{"new_circuit_open":[],"new_err_files":[]}'
if [ -f "$SNAPSHOT" ]; then
    PREV=$(cat "$SNAPSHOT" 2>/dev/null || echo '{}')

    NEW_CIRCUIT=$(jq -c --argjson prev "$(echo "$PREV" | jq '.circuit_open // []')" \
        '.circuit_open - $prev' <<<"$NEW_SNAPSHOT")
    NEW_ERR=$(jq -c --argjson prev "$(echo "$PREV" | jq '.err_files // []')" \
        '.err_files - $prev' <<<"$NEW_SNAPSHOT")

    ALERT_NEW=$(jq -cn \
        --argjson cb "$NEW_CIRCUIT" \
        --argjson err "$NEW_ERR" \
        '{new_circuit_open:$cb, new_err_files:$err}')
else
    log "최초 tick — 이전 snapshot 없음, baseline 기록"
fi

# ── 4. critical 즉시 알림 (delta 무관) ────────────────────────────
CRITICAL=()
if [ "$HEARTBEAT_AGE" -gt 300 ]; then
    CRITICAL+=("Discord 봇 heartbeat ${HEARTBEAT_AGE}s 정지")
fi
if [ "$RAG_LAST_AGE_MIN" -gt 120 ]; then
    CRITICAL+=("RAG 인덱싱 ${RAG_LAST_AGE_MIN}분 멈춤")
fi

# ── 5. Self-Heal Dispatch (fix-library 호출, default dry-run) ─────
# Phase 2 (2026-05-07): 결함 발견 시 결정론적 fix 함수 호출.
# LLM 자가진단은 bot-heal.sh에 위임 (fix_delegate_bot_heal). supervisor 자체는 LLM 호출 X.
# 첫 1주는 SUPERVISOR_HEAL_DRYRUN=1 강제 — audit log만, 실제 실행 X.
FIX_LIB="$(dirname "$0")/lib/fix-library.sh"
HEAL_DISPATCHED=0
if [ -f "$FIX_LIB" ]; then
    export SUPERVISOR_HEAL_DRYRUN="${SUPERVISOR_HEAL_DRYRUN:-1}"
    # shellcheck source=/dev/null
    source "$FIX_LIB"

    # 5-A. critical 즉시 fix
    if [ "$HEARTBEAT_AGE" -gt 300 ]; then
        fix_dispatch "heartbeat_dead" "$HEARTBEAT_AGE" || true
        HEAL_DISPATCHED=$((HEAL_DISPATCHED + 1))
    fi
    if [ "$RAG_LAST_AGE_MIN" -gt 120 ]; then
        fix_dispatch "rag_stuck" "" || true
        HEAL_DISPATCHED=$((HEAL_DISPATCHED + 1))
    fi

    # 5-B. delta circuit OPEN 신규 → reset 시도
    while IFS= read -r circuit; do
        if [ -n "$circuit" ]; then
            fix_dispatch "circuit_open" "$circuit" || true
            HEAL_DISPATCHED=$((HEAL_DISPATCHED + 1))
        fi
    done < <(echo "$ALERT_NEW" | jq -r '.new_circuit_open[]?' 2>/dev/null)

    if [ "$HEAL_DISPATCHED" -gt 0 ]; then
        log "Self-heal dispatched: ${HEAL_DISPATCHED}건 (DRYRUN=$SUPERVISOR_HEAL_DRYRUN)"
    fi
fi

# ── 6. 알림 송출 (신규 또는 critical 있을 때만) ───────────────────
NEED_ALERT=false
DELTA_COUNT=$(echo "$ALERT_NEW" | jq '[.new_circuit_open, .new_err_files] | map(length) | add // 0')
[ "$DELTA_COUNT" -gt 0 ] && NEED_ALERT=true
[ "${#CRITICAL[@]}" -gt 0 ] && NEED_ALERT=true

if [ "$NEED_ALERT" = "true" ]; then
    # Discord 카드 송출
    if [ ${#CRITICAL[@]} -gt 0 ]; then
        CRITICAL_JSON=$(printf '%s\n' "${CRITICAL[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
    else
        CRITICAL_JSON='[]'
    fi
    SUMMARY=$(jq -cn \
        --argjson delta "$ALERT_NEW" \
        --argjson critical "$CRITICAL_JSON" \
        --arg heartbeat "${HEARTBEAT_AGE}s" \
        --arg rag_age "${RAG_LAST_AGE_MIN}분" \
        '{red: $critical, yellow: ($delta | [.new_circuit_open[], .new_err_files[]]), green: []}')

    TITLE="Supervisor — $(date '+%m-%d %H:%M KST')"
    if node "$DOT_JARVIS/scripts/discord-visual.mjs" \
        --type system-doctor \
        --data "$(jq -cn --arg t "$TITLE" --argjson s "$SUMMARY" '{title:$t, summary:$s}')" \
        --channel jarvis-system >/dev/null 2>&1; then
        log "Discord 알림 송출 완료 (delta=$DELTA_COUNT, critical=${#CRITICAL[@]})"
    else
        log "Discord 알림 실패 (계속 진행)"
    fi
fi

# ── 6. snapshot 저장 + ledger append ───────────────────────────────
echo "$NEW_SNAPSHOT" > "$SNAPSHOT"

jq -cn \
    --arg ts "$TICK_TS" \
    --argjson snapshot "$NEW_SNAPSHOT" \
    --argjson alert "$ALERT_NEW" \
    --argjson critical_count "${#CRITICAL[@]}" \
    --argjson alerted "$NEED_ALERT" \
    '{ts:$ts, snapshot:$snapshot, delta:$alert, critical_count:$critical_count, alerted:$alerted}' \
    >> "$LEDGER"

log "tick 완료 (circuit=$(echo "$CIRCUIT_OPEN" | jq length), err=$(echo "$ERR_FILES" | jq length), hb=${HEARTBEAT_AGE}s, rag=${RAG_LAST_AGE_MIN}min, alerted=$NEED_ALERT)"
exit 0
