#!/usr/bin/env bash
set -euo pipefail

# measure-kpi.sh - 자비스 컴퍼니 팀별 KPI 자동 측정
# Usage: measure-kpi.sh [--discord] [--days N]

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG="${BOT_HOME}/logs/task-runner.jsonl"
MONITORING="${BOT_HOME}/config/monitoring.json"
DAYS=7
SEND_DISCORD=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --discord) SEND_DISCORD=true; shift ;;
        --days)    DAYS="$2"; shift 2 ;;
        *)         shift ;;
    esac
done

# 팀별 SUCCESS/FAIL 집계 (bash 3.x 호환, local 변수 명시)
team_kpi() {
    local label="$1"; shift
    local total=0 ok=0 t_total t_ok matched
    for task_id in "$@"; do
        matched=$(grep "\"task\":\"${task_id}\"" "$LOG" 2>/dev/null) || matched=""
        if [[ -n "$matched" ]]; then
            t_total=$(printf '%s\n' "$matched" | grep -cv "\"status\":\"start\"" 2>/dev/null) || t_total=0
            t_ok=$(printf '%s\n' "$matched" | grep -c  "\"status\":\"success\"" 2>/dev/null) || t_ok=0
            total=$((total + t_total))
            ok=$((ok + t_ok))
        fi
    done
    if [[ $total -eq 0 ]]; then
        printf '%-20s ⚫ NO_DATA\n' "$label"
    else
        local rate=$((ok * 100 / total))
        local icon="🔴 RED   "
        [[ $rate -ge 90 ]] && icon="🟢 GREEN "
        [[ $rate -ge 70 && $rate -lt 90 ]] && icon="🟡 YELLOW"
        printf '%-20s %s %3d%% (%d/%d건)\n' "$label" "$icon" "$rate" "$ok" "$total"
    fi
}

# 리포트 생성
NOW=$(date '+%Y-%m-%d %H:%M KST')
REPORT=$(
    echo "📊 자비스 컴퍼니 KPI 리포트 (최근 ${DAYS}일)"
    echo "${NOW}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    team_kpi "감사팀 (Council)"  council-insight weekly-kpi
    team_kpi "정보팀 (Trend)"    news-briefing
    team_kpi "성장팀 (Career)"   career-weekly
    team_kpi "학습팀 (Academy)"  academy-support
    team_kpi "기록팀 (Record)"   record-daily memory-cleanup
    team_kpi "인프라팀 (Infra)"  infra-daily system-health security-scan rag-health disk-alert
    team_kpi "브랜드팀 (Brand)"  brand-weekly weekly-report
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
)

# 최종 판정
if echo "$REPORT" | grep -q "🔴"; then
    VERDICT="⚠️ RED 팀 감지 — 감사팀 상세 보고 확인 필요"
elif echo "$REPORT" | grep -q "🟡"; then
    VERDICT="🟡 일부 팀 개선 필요"
else
    VERDICT="✅ 전 팀 목표 달성"
fi

REPORT="${REPORT}
${VERDICT}"

echo "$REPORT"

# Discord 전송
if $SEND_DISCORD; then
    WEBHOOK=$(jq -r '.webhooks["bot-ceo"]' "$MONITORING" 2>/dev/null || echo "")
    if [[ -n "$WEBHOOK" && "$WEBHOOK" != "null" ]]; then
        PAYLOAD=$(jq -n --arg c "$REPORT" '{"content":$c}')
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$WEBHOOK" \
            -H "Content-Type: application/json" -d "$PAYLOAD")
        if [[ "$HTTP" != "204" ]]; then echo "⚠️ Discord 전송 실패: HTTP $HTTP" >&2; fi
    fi
fi
