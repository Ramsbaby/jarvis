#!/usr/bin/env bash
# smart-standup.sh — 오너 온라인 여부 확인 후 모닝 스탠드업 실행
#
# 오너가 오프라인이면 30분 후 재시도 알림을 Discord에 남기고 조용히 종료.
# 오너가 온라인이면 즉시 company-agent.mjs --team standup 실행.
#
# Usage (crontab):
#   5 8 * * * /bin/bash ~/.jarvis/scripts/smart-standup.sh >> ~/.jarvis/logs/company-agent.log 2>&1

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
CRON_LOG="$BOT_HOME/logs/cron.log"
MONITORING_CONFIG="$BOT_HOME/config/monitoring.json"
STATE_FILE="$BOT_HOME/state/smart-standup.json"
NODE="${NODE:-$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)}"
AGENT="$BOT_HOME/discord/lib/company-agent.mjs"

log() {
    echo "[$(date '+%F %T')] [smart-standup] $1" | tee -a "$CRON_LOG"
}

mkdir -p "$(dirname "$STATE_FILE")"

# --- 1. 오너 온라인 여부 확인 ---
ONLINE=false
if /bin/bash "$BOT_HOME/scripts/discord-presence-check.sh" > /dev/null 2>&1; then
    ONLINE=true
fi

if [[ "$ONLINE" == "true" ]]; then
    # 당일 중복 실행 방지
    TODAY=$(date '+%Y-%m-%d')
    LAST_RUN_DATE=$(jq -r '.last_run_date // ""' "$STATE_FILE" 2>/dev/null || echo "")
    if [[ "$LAST_RUN_DATE" == "$TODAY" ]]; then
        log "오늘 스탠드업 이미 실행됨 ($TODAY) — 스킵"
        exit 0
    fi
    log "오너 온라인 확인 — 스탠드업 실행"
    # state 기록 (당일 날짜 저장)
    jq -n --arg d "$TODAY" '{"retries":0,"last_run":"","last_run_date":$d}' > "$STATE_FILE"
    exec "$NODE" "$AGENT" --team standup
fi

# --- 2. 오너 오프라인: 재시도 횟수 확인 ---
RETRIES=$(jq -r '.retries // 0' "$STATE_FILE" 2>/dev/null || echo "0")
MAX_RETRIES=3  # 08:05 → 08:35 → 09:05 → 09:35 (최대 4회 시도)

if [[ "$RETRIES" -ge "$MAX_RETRIES" ]]; then
    log "오너 오프라인 — 재시도 한도($MAX_RETRIES) 초과. 오늘 스탠드업 건너뜀."
    # 다음날을 위해 리셋
    echo '{"retries":0,"last_run":""}' > "$STATE_FILE"

    # jarvis 채널에 건너뜀 알림 전송
    WEBHOOK_URL=$(jq -r '.webhooks["jarvis"] // empty' "$MONITORING_CONFIG" 2>/dev/null || true)
    if [[ -n "$WEBHOOK_URL" && "$WEBHOOK_URL" != "null" ]]; then
        PAYLOAD=$(jq -n --arg msg "📵 모닝 스탠드업 건너뜀 — 오늘 오너 활동 없음 (최대 재시도 초과)" '{content: $msg}')
        curl -sS -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" > /dev/null 2>&1 || true
    fi
    exit 0
fi

# --- 3. 오프라인 — 재시도 예약 ---
NEW_RETRIES=$(( RETRIES + 1 ))
RETRY_AT=$(date -v+30M '+%H:%M' 2>/dev/null || date -d '+30 minutes' '+%H:%M' 2>/dev/null || echo "30분 후")

log "오너 오프라인 — 재시도 예약 (${RETRY_AT}, 시도 ${NEW_RETRIES}/${MAX_RETRIES})"

# state 업데이트
jq -n --argjson r "$NEW_RETRIES" --arg t "$(date '+%F %T')" \
    '{"retries": $r, "last_run": $t}' > "$STATE_FILE"

# mq-cli로 재시도 이벤트 전송 (orchestrator가 처리, DB 없으면 무시)
/bin/bash "$BOT_HOME/scripts/mq-cli.sh" send standup system \
    "{\"status\":\"delayed\",\"reason\":\"owner_offline\",\"retry_at\":\"${RETRY_AT}\",\"retries\":${NEW_RETRIES}}" \
    normal >/dev/null 2>/dev/null || true

# at 커맨드로 30분 후 재시도 (macOS launchd at은 비활성화돼 있을 수 있으므로 fallback: 직접 sleep 후 실행)
# 크론탭에서 매 30분마다 체크하도록 설계 (crontab에 5,35 8,9 * * * 패턴 사용)
# 이 스크립트 자체는 재시도를 직접 하지 않고 state만 기록 후 종료.
exit 0
