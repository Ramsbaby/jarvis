#!/usr/bin/env bash
# llm-cost-cap-monitor.sh — 일일 LLM 비용 cap 가드 (매시간)
# token-ledger.jsonl 일일 합계 → cap 비교 → 80%/100% 알림 + 마커
#
# 환경변수:
#   LLM_DAILY_CAP_USD   default 20.00
#   LLM_DAILY_WARN_PCT  default 80

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LEDGER="$JARVIS_HOME/runtime/state/token-ledger.jsonl"
LOG_FILE="$JARVIS_HOME/runtime/logs/llm-cost-cap-monitor.log"
CAP_MARKER="$JARVIS_HOME/runtime/state/llm-daily-cap-exceeded"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"

CAP="${LLM_DAILY_CAP_USD:-20.00}"
WARN_PCT="${LLM_DAILY_WARN_PCT:-80}"

mkdir -p "$(dirname "$LOG_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

TODAY=$(date +%Y-%m-%d)
# 오늘 KST 시작 = 어제 UTC 15:00 (단순 startsWith 사용)
TODAY_UTC_PREFIX_TODAY=$(date -u +%Y-%m-%dT)
TODAY_UTC_PREFIX_YESTERDAY=$(date -u -v-1d +%Y-%m-%dT 2>/dev/null || date -u -d '-1 day' +%Y-%m-%dT)

[ -f "$LEDGER" ] || { _log "no ledger"; exit 0; }

# 오늘 KST = UTC 어제 15:00 ~ 오늘 14:59
# cli-session 제외 (사용자 명시적 사용 — cap 무관). cron 자율 비용만 cap 적용.
KST_START=$(date -v-1d +%Y-%m-%dT15:00:00 2>/dev/null || date -d '-1 day' +%Y-%m-%dT15:00:00)
KST_END=$(date +%Y-%m-%dT15:00:00)
TOTAL_TODAY=$(jq -s --arg s "$KST_START" --arg e "$KST_END" \
    '[.[] | select(.ts >= $s and .ts < $e) | select(.source != "cli-session")] | map(.cost_usd // 0) | add // 0' \
    "$LEDGER" 2>/dev/null)
# cli-session은 별도 metric (가시성용)
CLI_TODAY=$(jq -s --arg s "$KST_START" --arg e "$KST_END" \
    '[.[] | select(.ts >= $s and .ts < $e) | select(.source == "cli-session")] | map(.cost_usd // 0) | add // 0' \
    "$LEDGER" 2>/dev/null)

PCT=$(awk -v t="$TOTAL_TODAY" -v c="$CAP" 'BEGIN{ printf "%.0f", (t/c)*100 }')

_log "cron=\$$TOTAL_TODAY / cap=\$$CAP ($PCT%) | cli-session=\$$CLI_TODAY (cap 무관)"

# Status 결정
STATUS="🟢 정상"
NEED_ALERT=false
if [ "$PCT" -ge 100 ]; then
    STATUS="🚨 CAP 초과"
    touch "$CAP_MARKER"
    NEED_ALERT=true
elif [ "$PCT" -ge "$WARN_PCT" ]; then
    STATUS="🟡 경고 ($WARN_PCT% 도달)"
    NEED_ALERT=true
else
    [ -f "$CAP_MARKER" ] && rm -f "$CAP_MARKER"
fi

if [ "$NEED_ALERT" = "true" ] && [ -f "$DISCORD_VISUAL" ]; then
    PAYLOAD=$(jq -nc \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        --arg s "$STATUS" \
        --arg t "\$$TOTAL_TODAY" \
        --arg c "\$$CAP" \
        --arg p "$PCT%" \
        --arg cli "\$$CLI_TODAY" \
        '{title: "💰 LLM 일일 비용 (cron 자율)", data: {"상태": $s, "cron 누적": $t, "cap": $c, "사용률": $p, "cli-session(별도)": $cli}, timestamp: $ts}')
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
