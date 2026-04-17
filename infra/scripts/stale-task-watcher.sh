#!/usr/bin/env bash
# stale-task-watcher.sh — running 상태 태스크 이상 감지 자동 전이
#
# 역할: STALE_MINUTES 이상 running 상태인 태스크를 failed로 전이 + Discord 알림
# 크론: */30 * * * *  (30분마다)
#
# 설계 근거:
#   dev-runner.sh trap으로 queued 복구는 되나, trap이 발동 못한 비정상 종료
#   (OOM, 머신 리부트 후 재기동 등) 시 running 태스크가 영원히 잔류.
#   task_transitions 히스토리를 읽어 마지막 running 전이 시각 기준으로 판단.

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

JARVIS_HOME="${JARVIS_HOME:-${HOME}/jarvis/runtime}"
BOT_HOME="${BOT_HOME:-$JARVIS_HOME}"
NODE_SQLITE="node --experimental-sqlite --no-warnings"
LOG="${JARVIS_HOME}/logs/stale-task-watcher.log"
MONITORING_CONFIG="${JARVIS_HOME}/config/monitoring.json"
TASKS_CONFIG="${JARVIS_HOME}/config/tasks.json"
# 전역 기본값: tasks.json에 timeout 없는 태스크에 적용 (단위: 분)
STALE_MINUTES_DEFAULT="${STALE_TASK_MINUTES:-30}"

mkdir -p "$(dirname "$LOG")"

# 단일 인스턴스 보장 — 이미 실행 중이면 즉시 종료
STALE_PID_FILE="/tmp/jarvis-stale-watcher.pid"
if [[ -f "$STALE_PID_FILE" ]]; then
  OLD_PID=$(cat "$STALE_PID_FILE" 2>/dev/null || echo "")
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[$(date '+%H:%M:%S')] stale-watcher already running (PID $OLD_PID) — skip"
    exit 0
  fi
fi
echo $$ > "$STALE_PID_FILE"
trap 'rm -f "$STALE_PID_FILE"' EXIT

log() { echo "[$(date '+%F %T')] [stale-watcher] $1" | tee -a "$LOG"; }

# ── Discord 알림 ─────────────────────────────────────────────────────────────
WEBHOOK_URL="$(jq -r '.webhooks["jarvis-system"] // empty' "$MONITORING_CONFIG" 2>/dev/null || true)"

discord_alert() {
    local msg="$1"
    if [[ -n "${WEBHOOK_URL:-}" ]]; then
        local payload; payload=$(jq -n --arg m "$msg" '{content: $m}')
        curl -sS -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "$payload" > /dev/null 2>&1 || true
    fi
}

# ── running 태스크 목록 조회 ──────────────────────────────────────────────────
TASKS_JSON=$(${NODE_SQLITE} "${BOT_HOME}/lib/task-store.mjs" list 2>/dev/null || echo "[]")
NOW_MS=$(( $(date +%s) * 1000 ))
STALE_COUNT=0
FAILED_IDS=""

while IFS= read -r task_json; do
    if [[ -z "$task_json" ]]; then continue; fi

    TASK_ID=$(echo "$task_json"   | jq -r '.id        // empty')
    STATUS=$(echo  "$task_json"   | jq -r '.status    // empty')
    UPDATED=$(echo "$task_json"   | jq -r '.updated_at // 0')
    TASK_NAME=$(echo "$task_json" | jq -r '.name      // .id // "unknown"')

    if [[ "$STATUS" != "running" ]]; then continue; fi
    if [[ -z "$TASK_ID" ]]; then continue; fi

    # P2: tasks.json에서 태스크별 timeout 읽기 → stale 임계 = timeout × 2 (여유 버퍼)
    # effective-tasks.json 우선 사용 (plugin-loader 결과), 없으면 tasks.json 폴백
    if [[ -f "${JARVIS_HOME}/config/effective-tasks.json" ]]; then
        _TASK_TIMEOUT=$(jq -r --arg id "$TASK_ID" \
            '.tasks[] | select(.id==$id) | .timeout // empty' \
            "${JARVIS_HOME}/config/effective-tasks.json" 2>/dev/null || echo "")
    else
        _TASK_TIMEOUT=$(jq -r --arg id "$TASK_ID" \
            '.tasks[] | select(.id==$id) | .timeout // empty' \
            "${TASKS_CONFIG}" 2>/dev/null || echo "")
    fi
    # tasks.json에 없으면 tasks.db meta.timeout 조회 (동적 생성 태스크: dispatch-*, synth-* 등)
    if [[ -z "$_TASK_TIMEOUT" ]]; then
        _TASK_TIMEOUT=$(echo "$task_json" | jq -r '.meta.timeout // empty' 2>/dev/null || echo "")
    fi
    # 최종 기본값: 900s (동적 태스크 안전 마진 — stale 임계 30분. 300s 기본값 10분은 오탐 발생)
    [[ "$_TASK_TIMEOUT" =~ ^[0-9]+$ ]] || _TASK_TIMEOUT=900
    # stale 임계 = timeout × 2 (단위: ms), 최소 60초 보장
    _STALE_MS=$(( _TASK_TIMEOUT * 2 * 1000 ))
    (( _STALE_MS < 60000 )) && _STALE_MS=60000

    AGE_MS=$(( NOW_MS - UPDATED ))
    if (( AGE_MS <= _STALE_MS )); then continue; fi

    AGE_MIN=$(( AGE_MS / 60000 ))
    _THRESHOLD_MIN=$(( _STALE_MS / 60000 ))
    log "STALE 감지: ${TASK_ID} (${TASK_NAME}) — ${AGE_MIN}분 경과 (임계: timeout=${_TASK_TIMEOUT}s × 2 = ${_THRESHOLD_MIN}분)"

    # running → failed 전이
    EXTRA="{\"lastError\":\"stale: running ${AGE_MIN}min without completion\",\"staleSince\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"threshold_s\":$((_STALE_MS/1000))}"
    if ${NODE_SQLITE} "${BOT_HOME}/lib/task-store.mjs" \
        transition "$TASK_ID" "failed" "stale-watcher" "$EXTRA" 2>>"$LOG"; then
        log "전이 완료: ${TASK_ID} → failed"
        STALE_COUNT=$(( STALE_COUNT + 1 ))
        FAILED_IDS="${FAILED_IDS} \`${TASK_ID}\`(임계${_THRESHOLD_MIN}분)"
    else
        log "ERROR: 전이 실패 — ${TASK_ID} (task-store 오류, 로그 확인)"
    fi
    unset _TASK_TIMEOUT _STALE_MS _THRESHOLD_MIN

done < <(echo "$TASKS_JSON" | jq -c '.[]' 2>/dev/null || true)

# ── CB 쿨다운 만료된 skipped 태스크 자동 복구 ────────────────────────────────
log "CB 쿨다운 만료 체크 시작"
node --experimental-sqlite --no-warnings -e "
const {DatabaseSync} = require('node:sqlite');
const fs = require('fs');
const path = require('path');
const BOT_HOME = process.env.BOT_HOME || process.env.JARVIS_HOME || require('os').homedir() + '/jarvis/runtime';
const DB_PATH = BOT_HOME + '/state/tasks.db';
if (!fs.existsSync(DB_PATH)) { process.exit(0); }
const db = new DatabaseSync(DB_PATH);
const now = Date.now();

// skipped + cb_open 태스크 조회
const tasks = db.prepare(\"SELECT id, meta FROM tasks WHERE status='skipped'\").all();
tasks.forEach(t => {
  let meta = {};
  try { meta = JSON.parse(t.meta || '{}'); } catch {}
  if (meta.reason !== 'cb_open') return;

  const cbFile = BOT_HOME + '/state/circuit-breaker/' + t.id + '.json';
  if (!fs.existsSync(cbFile)) {
    // CB 파일 없으면 그냥 queued로 복구
    db.prepare(\"UPDATE tasks SET status='queued', updated_at=? WHERE id=?\").run(now, t.id);
    db.prepare(
      \"INSERT INTO task_transitions (task_id, from_status, to_status, triggered_by, created_at) VALUES (?,?,?,?,?)\"
    ).run(t.id, 'skipped', 'queued', 'stale-watcher/cb-recovery', now);
    console.log('[cb-recovery] ' + t.id + ': skipped → queued (cb file missing)');
    return;
  }

  let cbData = {};
  try { cbData = JSON.parse(fs.readFileSync(cbFile, 'utf-8')); } catch {}
  const cooldownUntil = cbData.cooldownUntil || 0;
  // cooldownUntil 없는 구형 CB 파일: last_fail_ts + 3600s 계산
  const lastFailTs = cbData.last_fail_ts || 0;
  const effectiveCooldownUntil = cooldownUntil || ((lastFailTs + 3600) * 1000);

  if (now > effectiveCooldownUntil) {
    // 쿨다운 만료 → queued 복구 + CB 파일 삭제
    const newMeta = Object.assign({}, meta, { reason: null, cooldownExpiredAt: new Date(now).toISOString() });
    db.prepare(\"UPDATE tasks SET status='queued', meta=?, updated_at=? WHERE id=?\")
      .run(JSON.stringify(newMeta), now, t.id);
    db.prepare(
      \"INSERT INTO task_transitions (task_id, from_status, to_status, triggered_by, created_at) VALUES (?,?,?,?,?)\"
    ).run(t.id, 'skipped', 'queued', 'stale-watcher/cb-recovery', now);
    try { fs.unlinkSync(cbFile); } catch {}
    console.log('[cb-recovery] ' + t.id + ': skipped → queued (cooldown expired)');
  } else {
    const remainMs = effectiveCooldownUntil - now;
    console.log('[cb-recovery] ' + t.id + ': 쿨다운 진행 중 (' + Math.ceil(remainMs/60000) + '분 남음)');
  }
});
" 2>/dev/null | while IFS= read -r line; do log "$line"; done || true

# ── 결과 Discord 보고 ─────────────────────────────────────────────────────────
if (( STALE_COUNT > 0 )); then
    MSG="🕒 **stale-task-watcher**: ${STALE_COUNT}개 태스크 stale 감지 → \`failed\` 전이 완료
태스크:${FAILED_IDS}
기준: tasks.json timeout × 2 (태스크별 동적 임계). \`dev-runner\` 재큐 여부 확인 권장."
    discord_alert "$MSG"
    log "Discord 알림 전송 완료 (${STALE_COUNT}건)"
else
    log "정상: 태스크별 동적 stale 임계 초과 running 태스크 없음 (기본값 timeout×2)"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2: Never-Run Reaper — 로그 0건인 active 태스크 감지
# ══════════════════════════════════════════════════════════════════════════════
CRON_LOG="${BOT_HOME}/logs/cron.log"
NEVER_RUN_IDS=""
NEVER_RUN_COUNT=0

if [[ -f "$TASKS_CONFIG" && -f "$CRON_LOG" ]]; then
    ACTIVE_IDS=$(python3 -c "
import json
try:
    data = json.load(open('$TASKS_CONFIG'))
    tasks = data.get('tasks', data) if isinstance(data, dict) else data
    for t in tasks:
        if isinstance(t, dict) and not t.get('disabled', False):
            print(t.get('id',''))
except Exception:
    pass
" 2>/dev/null) || true

    for tid in $ACTIVE_IDS; do
        [[ -z "$tid" ]] && continue
        HIT=$(grep -c "\[${tid}\]" "$CRON_LOG" 2>/dev/null | tr -d '\n' || echo "0")
        if [[ "$HIT" -eq 0 ]]; then
            NEVER_RUN_IDS="${NEVER_RUN_IDS}\n- \`${tid}\`"
            NEVER_RUN_COUNT=$((NEVER_RUN_COUNT + 1))
        fi
    done

    if (( NEVER_RUN_COUNT > 0 )); then
        discord_alert "👻 **Never-Run Reaper**: ${NEVER_RUN_COUNT}개 태스크 로그 0건 (active인데 미실행)${NEVER_RUN_IDS}
tasks.json disable 또는 삭제 권장."
        log "Never-Run: ${NEVER_RUN_COUNT}개 감지"
    else
        log "Never-Run: 모든 active 태스크 실행 이력 정상"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3: Ghost Detector — 로그에 있지만 tasks.json에 없는 task_id
# ══════════════════════════════════════════════════════════════════════════════
GHOST_IDS=""
GHOST_COUNT=0

if [[ -f "$TASKS_CONFIG" && -f "$CRON_LOG" ]]; then
    ALL_CONFIG_IDS=$(python3 -c "
import json
try:
    data = json.load(open('$TASKS_CONFIG'))
    tasks = data.get('tasks', data) if isinstance(data, dict) else data
    for t in tasks:
        if isinstance(t, dict): print(t.get('id',''))
except Exception:
    pass
" 2>/dev/null) || true

    LOG_IDS=$(grep -oP '\[([a-zA-Z0-9_-]+)\]' "$CRON_LOG" 2>/dev/null | tr -d '[]' | sort -u) || true

    for lid in $LOG_IDS; do
        [[ -z "$lid" ]] && continue
        case "$lid" in
            FAILED*|SUCCESS*|START*|DONE*|WARN*|ERROR*|INFO*|DEBUG*|cb-recovery*|log-utils*) continue ;;
        esac
        if ! echo "$ALL_CONFIG_IDS" | grep -qxF "$lid"; then
            GHOST_IDS="${GHOST_IDS}\n- \`${lid}\`"
            GHOST_COUNT=$((GHOST_COUNT + 1))
        fi
    done

    if (( GHOST_COUNT > 0 )); then
        discord_alert "🔍 **Ghost Detector**: ${GHOST_COUNT}개 고스트 태스크 (로그에 있지만 tasks.json 미등록)${GHOST_IDS}
등록하거나 발생원 제거 권장."
        log "Ghost: ${GHOST_COUNT}개 감지"
    else
        log "Ghost: 고스트 태스크 없음"
    fi
fi

exit 0