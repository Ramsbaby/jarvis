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

JARVIS_HOME="${JARVIS_HOME:-$HOME/.jarvis}"
BOT_HOME="${BOT_HOME:-$JARVIS_HOME}"
NODE_SQLITE="node --experimental-sqlite --no-warnings"
LOG="${JARVIS_HOME}/logs/stale-task-watcher.log"
MONITORING_CONFIG="${JARVIS_HOME}/config/monitoring.json"
STALE_MINUTES="${STALE_TASK_MINUTES:-30}"
STALE_MS=$(( STALE_MINUTES * 60 * 1000 ))

mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%F %T')] [stale-watcher] $1" | tee -a "$LOG"; }

# ── Discord 알림 ─────────────────────────────────────────────────────────────
WEBHOOK_URL="$(jq -r '.webhooks["jarvis"] // empty' "$MONITORING_CONFIG" 2>/dev/null || true)"

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

    AGE_MS=$(( NOW_MS - UPDATED ))
    if (( AGE_MS <= STALE_MS )); then continue; fi

    AGE_MIN=$(( AGE_MS / 60000 ))
    log "STALE 감지: ${TASK_ID} (${TASK_NAME}) — ${AGE_MIN}분 경과"

    # running → failed 전이
    EXTRA="{\"lastError\":\"stale: running ${AGE_MIN}min without completion\",\"staleSince\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}"
    if ${NODE_SQLITE} "${BOT_HOME}/lib/task-store.mjs" \
        transition "$TASK_ID" "failed" "stale-watcher" "$EXTRA" 2>>"$LOG"; then
        log "전이 완료: ${TASK_ID} → failed"
        STALE_COUNT=$(( STALE_COUNT + 1 ))
        FAILED_IDS="${FAILED_IDS} \`${TASK_ID}\`"
    else
        log "ERROR: 전이 실패 — ${TASK_ID} (task-store 오류, 로그 확인)"
    fi

done < <(echo "$TASKS_JSON" | jq -c '.[]' 2>/dev/null || true)

# ── 결과 Discord 보고 ─────────────────────────────────────────────────────────
if (( STALE_COUNT > 0 )); then
    MSG="🕒 **stale-task-watcher**: ${STALE_COUNT}개 태스크 stale 감지 → \`failed\` 전이 완료
태스크:${FAILED_IDS}
기준: running ${STALE_MINUTES}분 초과 → 자동 실패 처리. \`dev-runner\` 재큐 여부 확인 권장."
    discord_alert "$MSG"
    log "Discord 알림 전송 완료 (${STALE_COUNT}건)"
else
    log "정상: ${STALE_MINUTES}분 초과 running 태스크 없음"
fi

exit 0
