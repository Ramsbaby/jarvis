#!/usr/bin/env bash
set -euo pipefail

# measure-kpi.sh - 자비스 컴퍼니 팀별 KPI 자동 측정
# Usage: measure-kpi.sh [--discord] [--json] [--days N]

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG="${BOT_HOME}/logs/task-runner.jsonl"
MONITORING="${BOT_HOME}/config/monitoring.json"
DAYS=7
SEND_DISCORD=false
OUTPUT_JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --discord) SEND_DISCORD=true; shift ;;
        --json)    OUTPUT_JSON=true; shift ;;
        --days)    DAYS="$2"; shift 2 ;;
        *)         shift ;;
    esac
done

# 날짜 필터 기준 (N일 전 ISO 타임스탬프)
if date -v-1d '+%Y' >/dev/null 2>&1; then
    SINCE=$(date -v-"${DAYS}"d '+%Y-%m-%dT00:00:00Z')
else
    SINCE=$(date -d "${DAYS} days ago" '+%Y-%m-%dT00:00:00Z')
fi

# 로그에서 최근 N일 분만 필터링 (macOS awk 호환)
RECENT_LOG=""
if [[ -f "$LOG" ]]; then
    RECENT_LOG=$(awk -v since="$SINCE" '{
        idx = index($0, "\"ts\":\"")
        if (idx > 0) {
            ts = substr($0, idx + 6)
            end = index(ts, "\"")
            if (end > 0) {
                ts = substr(ts, 1, end - 1)
                if (ts >= since) print
            }
        }
    }' "$LOG") || RECENT_LOG=""
fi

# 팀별 성공/전체 건수 계산 (stdout에 "ok total" 출력)
count_team() {
    local total=0 ok=0 t_total t_ok matched
    for task_id in "$@"; do
        matched=$(printf '%s\n' "$RECENT_LOG" | grep "\"task\":\"${task_id}\"" 2>/dev/null) || matched=""
        if [[ -n "$matched" ]]; then
            t_total=$(printf '%s\n' "$matched" | grep -cv "\"status\":\"start\"" 2>/dev/null || echo 0)
            t_ok=$(printf '%s\n' "$matched" | grep -c  "\"status\":\"success\"" 2>/dev/null || echo 0)
            # 개행/공백 제거 후 정수 변환
            t_total=$(printf '%d' "${t_total//[^0-9]/}" 2>/dev/null || echo 0)
            t_ok=$(printf '%d' "${t_ok//[^0-9]/}" 2>/dev/null || echo 0)
            total=$((total + t_total))
            ok=$((ok + t_ok))
        fi
    done
    printf '%d %d\n' "$ok" "$total"
}

# 팀 정의: "key label task1 task2 ..."
TEAMS=(
    "council:Council:council-insight weekly-kpi"
    "trend:Trend:news-briefing"
    "growth:Growth:profile-weekly"
    "academy:Academy:academy-support"
    "record:Record:record-daily memory-cleanup"
    "infra:Infra:infra-daily system-health security-scan rag-health disk-alert"
    "brand:Brand:brand-weekly weekly-report"
)

# 결과 수집
OVERALL_OK=0
OVERALL_TOTAL=0
# bash 3.x 호환: 배열 대신 구분자 기반 문자열
RESULTS=""

for entry in "${TEAMS[@]}"; do
    key="${entry%%:*}"
    rest="${entry#*:}"
    label="${rest%%:*}"
    tasks_str="${rest#*:}"
    # shellcheck disable=SC2086
    read -r ok total <<< "$(count_team $tasks_str)"
    OVERALL_OK=$((OVERALL_OK + ok))
    OVERALL_TOTAL=$((OVERALL_TOTAL + total))
    rate=0
    if [[ $total -gt 0 ]]; then
        rate=$((ok * 100 / total))
    fi
    RESULTS="${RESULTS}${key}|${label}|${ok}|${total}|${rate}
"
done

# --- JSON 출력 모드 ---
if $OUTPUT_JSON; then
    local_date=$(date '+%Y-%m-%d')
    overall_rate=0
    if [[ $OVERALL_TOTAL -gt 0 ]]; then
        overall_rate=$((OVERALL_OK * 100 / OVERALL_TOTAL))
    fi

    json_teams=""
    while IFS='|' read -r key label ok total rate; do
        if [[ -z "$key" ]]; then continue; fi
        if [[ -n "$json_teams" ]]; then
            json_teams="${json_teams},"
        fi
        json_teams="${json_teams}\"${key}\":{\"success\":${ok},\"total\":${total},\"rate\":${rate}}"
    done <<< "$RESULTS"

    printf '{"date":"%s","days":%d,"teams":{%s},"overall":{"success":%d,"total":%d,"rate":%d}}\n' \
        "$local_date" "$DAYS" "$json_teams" "$OVERALL_OK" "$OVERALL_TOTAL" "$overall_rate"
    exit 0
fi

# --- 텍스트 리포트 모드 ---
NOW=$(date '+%Y-%m-%d %H:%M KST')
REPORT=$(
    echo "📊 자비스 컴퍼니 KPI 리포트 (최근 ${DAYS}일)"
    echo "${NOW}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    while IFS='|' read -r key label ok total rate; do
        if [[ -z "$key" ]]; then continue; fi
        if [[ $total -eq 0 ]]; then
            printf '%-20s ⚫ NO_DATA\n' "$label"
        else
            icon="🔴 RED   "
            if [[ $rate -ge 90 ]]; then
                icon="🟢 GREEN "
            elif [[ $rate -ge 70 ]]; then
                icon="🟡 YELLOW"
            fi
            printf '%-20s %s %3d%% (%d/%d건)\n' "$label" "$icon" "$rate" "$ok" "$total"
        fi
    done <<< "$RESULTS"
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

# Vault에 KPI 기록
KPI_VAULT="${VAULT_DIR:-$HOME/vault}/02-daily/kpi"
if [[ -d "$KPI_VAULT" ]]; then
    echo "$REPORT" > "$KPI_VAULT/$(date '+%Y-%m-%d').md"
fi

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