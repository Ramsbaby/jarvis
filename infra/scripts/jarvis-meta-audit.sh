#!/usr/bin/env bash
# jarvis-meta-audit.sh — 자비스의 audit-of-audits + dead cron 감지 + 효과 측정 (3-in-1)
#
# 매주 월 09:40 KST (audit-dashboard 09:30 직후)
#
# 1. Meta audit — 모든 ai.jarvis.* LaunchAgent의 last exit 점검 (자비스 자체 cron fail 감지)
# 2. Dead cron — 4주간 0회 발화 또는 PASS만 → 후보 카드
# 3. 효과 측정 — 각 cron의 "방어 카운트" (alerted=true / failed-detected / mismatch-fixed)

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LOG_FILE="$JARVIS_HOME/runtime/logs/jarvis-meta-audit.log"
LOGS_DIR="$JARVIS_HOME/runtime/logs"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"

mkdir -p "$(dirname "$LOG_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Single-instance lock
# shellcheck source=/dev/null
[ -f "$JARVIS_HOME/infra/lib/single-instance.sh" ] && source "$JARVIS_HOME/infra/lib/single-instance.sh" && single_instance "jarvis-meta-audit"

CUTOFF_4W=$(date -v-28d +%s 2>/dev/null || date -d '-28 days' +%s)

# ── 1. Meta audit — LaunchAgent last exit ────────────────────────────
META_FAILS=()
TOTAL_LA=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    EXIT_CODE=$(echo "$line" | awk '{print $2}')
    LABEL=$(echo "$line" | awk '{print $3}')
    [ -z "$LABEL" ] && continue
    TOTAL_LA=$((TOTAL_LA + 1))
    if [ "$EXIT_CODE" != "0" ] && [ "$EXIT_CODE" != "-" ]; then
        META_FAILS+=("$LABEL (exit=$EXIT_CODE)")
    fi
done < <(launchctl list 2>/dev/null | grep "ai.jarvis." || true)

# ── 2. Dead cron 감지 — 4주간 stdout 로그 발화 0회 ──────────────────
DEAD_CRONS=()
for la in $HOME/Library/LaunchAgents/ai.jarvis.*.plist; do
    [ -f "$la" ] || continue
    LABEL=$(basename "$la" .plist)
    NAME=$(echo "$LABEL" | sed 's/^ai\.jarvis\.//')
    STDOUT_LOG="$LOGS_DIR/${NAME}-stdout.log"
    if [ -f "$STDOUT_LOG" ]; then
        MTIME=$(stat -f %m "$STDOUT_LOG" 2>/dev/null || echo 0)
        if [ "$MTIME" -lt "$CUTOFF_4W" ]; then
            DEAD_CRONS+=("$NAME")
        fi
    fi
done

# ── 3. 효과 측정 — 주요 audit cron의 alerted/FAIL 카운트 (지난 7일) ──
# B3 fix: grep -c || echo 0 → wc -l + tr (정수 안전)
SUPERVISOR_ALERTS=$(awk -v c="$(date -v-7d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '-7 days' +%Y-%m-%dT%H:%M:%S)" \
    -F'"ts":"' 'NF>1 && $2 > c' "$JARVIS_HOME/runtime/state/supervisor-tick-ledger.jsonl" 2>/dev/null \
    | grep '"alerted":true' | wc -l | tr -d ' \n')
DOCS_REGENS=$(grep "재생성: 성공" "$LOGS_DIR/docs-freshness-audit.log" 2>/dev/null | wc -l | tr -d ' \n')
MODEL_VIOLATIONS=$(grep "FAIL: 모델 정책 위반" "$LOGS_DIR/model-version-audit.log" 2>/dev/null | wc -l | tr -d ' \n')

_log "meta: total=$TOTAL_LA, fails=${#META_FAILS[@]} | dead 4w=${#DEAD_CRONS[@]} | 7d 효과: supervisor_alert=$SUPERVISOR_ALERTS, docs_regen=$DOCS_REGENS, model_fail=$MODEL_VIOLATIONS"

# Discord 합본 카드
if [ -f "$DISCORD_VISUAL" ]; then
    META_FAIL_LIST="(없음)"
    [ "${#META_FAILS[@]}" -gt 0 ] && META_FAIL_LIST=$(printf '%s | ' "${META_FAILS[@]}" | head -c 200 | sed 's/ | $//')
    DEAD_LIST="(없음)"
    [ "${#DEAD_CRONS[@]}" -gt 0 ] && DEAD_LIST=$(printf '%s | ' "${DEAD_CRONS[@]}" | head -c 200 | sed 's/ | $//')

    PAYLOAD=$(jq -nc \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        --arg total "$TOTAL_LA" \
        --arg fails "${#META_FAILS[@]} ($META_FAIL_LIST)" \
        --arg dead "${#DEAD_CRONS[@]} ($DEAD_LIST)" \
        --arg sup "$SUPERVISOR_ALERTS" \
        --arg docs "$DOCS_REGENS" \
        --arg model "$MODEL_VIOLATIONS" \
        '{title:"🔬 Meta-Audit (자비스 audit-of-audits)", data:{"LaunchAgent 총합":$total,"실패 cron":$fails,"Dead 4주":$dead,"7일 supervisor 알림":$sup,"7일 docs 재생성":$docs,"7일 model 위반":$model}, timestamp:$ts}')
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
