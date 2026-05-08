#!/usr/bin/env bash
# audit-dashboard.sh — 5개 audit 결과 매주 월 09:30 KST에 한 카드로 합본
# 09:00 interview-ssot / 09:05 model-version / 09:10 docs-freshness / 09:15 skill-usage / 09:25 skill-dead-archive

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LOG_BASE="$JARVIS_HOME/runtime/logs"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"
LOG_FILE="$LOG_BASE/audit-dashboard.log"

mkdir -p "$(dirname "$LOG_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Single-instance lock
# shellcheck source=/dev/null
[ -f "$JARVIS_HOME/infra/lib/single-instance.sh" ] && source "$JARVIS_HOME/infra/lib/single-instance.sh" && single_instance "audit-dashboard"

# 각 audit log 마지막 줄에서 PASS/FAIL 추출
extract_status() {
    local log="$1" name="$2"
    [ -f "$log" ] || { echo "$name: ❓ no-log"; return; }
    local last
    last=$(tail -20 "$log" 2>/dev/null | grep -E "(PASS|FAIL|STALE|archived)" | tail -1)
    if [ -z "$last" ]; then echo "$name: ❓ no-result"
    elif echo "$last" | grep -q "PASS"; then echo "$name: ✅ PASS"
    elif echo "$last" | grep -q "STALE"; then echo "$name: 🟡 STALE"
    elif echo "$last" | grep -q "archived"; then echo "$name: 🗄️ $(echo "$last" | grep -oE 'archived=[0-9]+')"
    else echo "$name: 🔴 FAIL"
    fi
}

ITEMS=()
ITEMS+=("$(extract_status "$LOG_BASE/interview-ssot-audit.log" "interview-ssot")")
ITEMS+=("$(extract_status "$LOG_BASE/model-version-audit.log" "model-version")")
ITEMS+=("$(extract_status "$LOG_BASE/docs-freshness-audit.log" "docs-freshness")")
ITEMS+=("$(extract_status "$LOG_BASE/skill-usage-audit.log" "skill-usage")")
ITEMS+=("$(extract_status "$LOG_BASE/skill-dead-archive.log" "skill-archive")")

SUMMARY=$(printf '%s | ' "${ITEMS[@]}" | sed 's/ | $//')
# B3 fix: grep -c || echo 0 → wc -l + tr (정수 안전)
FAIL_COUNT=$(printf '%s\n' "${ITEMS[@]}" | grep "🔴" | wc -l | tr -d ' \n')
PASS_COUNT=$(printf '%s\n' "${ITEMS[@]}" | grep "✅" | wc -l | tr -d ' \n')
OVERALL="🟢 모두 통과"
[ "$FAIL_COUNT" -gt 0 ] && OVERALL="🔴 $FAIL_COUNT건 실패"

_log "dashboard: PASS=$PASS_COUNT, FAIL=$FAIL_COUNT, summary=$SUMMARY"

if [ -f "$DISCORD_VISUAL" ]; then
    PAYLOAD=$(jq -nc \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        --arg overall "$OVERALL" \
        --arg item1 "${ITEMS[0]}" \
        --arg item2 "${ITEMS[1]}" \
        --arg item3 "${ITEMS[2]}" \
        --arg item4 "${ITEMS[3]}" \
        --arg item5 "${ITEMS[4]}" \
        '{title: "📊 주간 Audit 통합 대시보드", data: {"전체": $overall, "1": $item1, "2": $item2, "3": $item3, "4": $item4, "5": $item5}, timestamp: $ts}')
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
