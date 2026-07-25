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
# Phase 2: Never-Run Reaper — 스케줄 기반 판단 (addedAt + 예상실행횟수)
#
# 판단 기준: "지금까지 몇 번 실행됐어야 하나?" 계산 후 실제 0회면 dead로 판정
#   - addedAt 기준으로 경과 일수 계산
#   - schedule 파싱: 매분(*/N) → 하루 수백회, 매일(0 H * * *) → 1회/일
#                    주간(0 H * * 0) → 1회/주, 이벤트 트리거 → 제외
#   - 경과 일수 동안 예상 실행횟수 ≥ MIN_EXPECTED_RUNS 이고 실제 0회 → dead
#
# 자동 비활성화 조건 (세 가지 모두 충족):
#   1. addedAt 기준 14일 이상 경과
#   2. 스케줄 계산 기준 예상 실행횟수 ≥ 3회
#   3. cron.log에 실제 실행 이력 0건
# ══════════════════════════════════════════════════════════════════════════════
CRON_LOG="${BOT_HOME}/logs/cron.log"
DEAD_IDS=""      # 자동 비활성화 대상
DEAD_CSV=""
DEAD_COUNT=0
WARN_IDS=""      # 아직 판단 보류 (신규/희소 스케줄)
WARN_COUNT=0
MIN_EXPECTED_RUNS=3
MIN_AGE_DAYS=14

if [[ -f "$TASKS_CONFIG" && -f "$CRON_LOG" ]]; then
    # Python으로 스케줄 기반 예상 실행횟수 계산 후 dead/warn 분류
    REAPER_RESULT=$(python3 - <<'PYEOF' 2>/dev/null
import json, re
from datetime import date, datetime

TODAY = date.today()
MIN_AGE = 14
MIN_RUNS = 3

def expected_runs_per_day(schedule):
    """cron 표현식에서 하루 예상 실행 횟수 반환. 이벤트 트리거는 -1."""
    if not schedule or schedule.strip() == '':
        return -1  # 이벤트 트리거 / 온디맨드
    parts = schedule.split()
    if len(parts) != 5:
        return -1
    minute, hour, dom, month, dow = parts
    # 분 단위 (*/N or *)
    if re.match(r'^\*/(\d+)$', minute):
        interval = int(re.match(r'^\*/(\d+)$', minute).group(1))
        return 60 / interval * 24
    if minute == '*':
        return 60 * 24
    # 시간 단위 (hour 부분이 */N)
    if re.match(r'^\*/(\d+)$', hour):
        interval = int(re.match(r'^\*/(\d+)$', hour).group(1))
        return 24 / interval
    # 주간 (dow 가 특정 요일)
    if dow not in ('*', '') and dom == '*':
        days_per_week = len(dow.split(',')) if ',' in dow else 1
        if '-' in dow:
            parts_dow = dow.split('-')
            days_per_week = int(parts_dow[1]) - int(parts_dow[0]) + 1
        return days_per_week / 7
    # 월간 (dom이 특정 일)
    if dom not in ('*', '') and dow == '*':
        return 1 / 30
    # 기본: 하루 1회
    return 1.0

try:
    data = json.load(open('$TASKS_CONFIG'))
    tasks = data.get('tasks', data) if isinstance(data, dict) else data
    log_content = open('$CRON_LOG').read()

    for t in tasks:
        if not isinstance(t, dict): continue
        if not t.get('enabled', True) or t.get('disabled', False): continue
        tid = t.get('id', '')
        if not tid: continue
        # 이벤트 트리거 태스크 제외
        if t.get('event_trigger'): continue
        if '[' + tid + ']' in log_content: continue  # 실행 이력 있음

        # addedAt 파싱
        added_str = t.get('addedAt', '')
        try:
            added = date.fromisoformat(added_str)
        except Exception:
            added = TODAY
        age_days = (TODAY - added).days

        schedule = t.get('schedule', '')
        runs_per_day = expected_runs_per_day(schedule)

        if runs_per_day < 0:
            continue  # 이벤트/온디맨드 제외

        expected = runs_per_day * age_days

        if age_days >= MIN_AGE and expected >= MIN_RUNS:
            print(f'DEAD|{tid}|age={age_days}d|expected={expected:.1f}runs')
        elif age_days < MIN_AGE:
            print(f'WARN|{tid}|age={age_days}d|신규 — 관망')
        else:
            # 희소 스케줄 (월간 등) — 아직 시점 미도래 가능성
            print(f'WARN|{tid}|age={age_days}d|expected={expected:.1f}runs — 희소 스케줄')
except Exception as e:
    import sys
    print(f'ERROR:{e}', file=sys.stderr)
PYEOF
    )

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        TYPE="${line%%|*}"; REST="${line#*|}"
        TID="${REST%%|*}"
        DETAIL="${REST#*|}"
        case "$TYPE" in
            DEAD)
                DEAD_IDS="${DEAD_IDS}\n- \`${TID}\` (${DETAIL})"
                DEAD_CSV="${DEAD_CSV}${TID},"
                DEAD_COUNT=$((DEAD_COUNT + 1))
                ;;
            WARN)
                WARN_IDS="${WARN_IDS}\n- \`${TID}\` (${DETAIL})"
                WARN_COUNT=$((WARN_COUNT + 1))
                ;;
        esac
    done <<< "$REAPER_RESULT"

    # ── Dead 태스크: 자동 비활성화 ──────────────────────────────────────────
    if (( DEAD_COUNT > 0 )); then
        log "Never-Run Reaper: dead 태스크 ${DEAD_COUNT}개 → tasks.json 자동 비활성화"
        DISABLED_RESULT=$(python3 - <<PYEOF 2>/dev/null || echo "ERROR"
import json, sys
tasks_file = '${TASKS_CONFIG}'
dead_ids = set(filter(None, '${DEAD_CSV}'.rstrip(',').split(',')))
try:
    with open(tasks_file) as f:
        data = json.load(f)
    tasks = data.get('tasks', data) if isinstance(data, dict) else data
    done = []
    for t in tasks:
        if isinstance(t, dict) and t.get('id') in dead_ids:
            t['enabled'] = False
            done.append(t.get('id'))
    if isinstance(data, dict):
        data['tasks'] = tasks
    with open(tasks_file, 'w') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(','.join(done))
except Exception as e:
    print('ERROR:' + str(e), file=sys.stderr); sys.exit(1)
PYEOF
        )
        node "${BOT_HOME}/scripts/gen-tasks-index.mjs" 2>/dev/null || true
        log "자동 비활성화 완료: ${DISABLED_RESULT}"
        discord_alert "🪓 **Never-Run Reaper**: dead 태스크 **${DEAD_COUNT}개 자동 비활성화**
기준: addedAt 14일+ 경과 & 예상실행 3회+ & 실제 0회${DEAD_IDS}"
    fi

    # ── 신규/희소 스케줄 태스크: 일 1회 알림만 ──────────────────────────────
    if (( WARN_COUNT > 0 )); then
        NEVER_RUN_THROTTLE="${BOT_HOME}/state/never-run-reaper-last-alert.txt"
        _TODAY=$(date +%Y-%m-%d)
        _LAST=$(cat "$NEVER_RUN_THROTTLE" 2>/dev/null || echo "")
        if [[ "$_LAST" != "$_TODAY" ]]; then
            discord_alert "👀 **Never-Run Reaper**: 관망 중 **${WARN_COUNT}개** (신규 or 희소 스케줄 — 자동 처리 보류)${WARN_IDS}"
            echo "$_TODAY" > "$NEVER_RUN_THROTTLE"
            log "Never-Run 관망 ${WARN_COUNT}개 → 일 1회 알림"
        else
            log "Never-Run 관망 ${WARN_COUNT}개 — 오늘 이미 알림, skip"
        fi
    fi

    if (( DEAD_COUNT == 0 && WARN_COUNT == 0 )); then
        log "Never-Run Reaper: 모든 active 태스크 실행 이력 정상"
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
        # ── 일 1회 throttle ──
        GHOST_THROTTLE="${BOT_HOME}/state/ghost-detector-last-alert.txt"
        _TODAY=$(date +%Y-%m-%d)
        _LAST_GHOST=$(cat "$GHOST_THROTTLE" 2>/dev/null || echo "")
        if [[ "$_LAST_GHOST" == "$_TODAY" ]]; then
            log "Ghost: ${GHOST_COUNT}개 감지 — 오늘 이미 알림 전송됨, skip"
        else
            discord_alert "🔍 **Ghost Detector**: ${GHOST_COUNT}개 고스트 태스크 (로그에 있지만 tasks.json 미등록)${GHOST_IDS}
등록하거나 발생원 제거 권장."
            echo "$_TODAY" > "$GHOST_THROTTLE"
            log "Ghost: ${GHOST_COUNT}개 감지 → Discord 알림 전송 (일 1회 throttle 적용)"
        fi
    else
        log "Ghost: 고스트 태스크 없음"
    fi
fi

exit 0