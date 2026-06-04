#!/usr/bin/env bash
# automation-budget.sh — 신규 자동화 예산 감사
#
# 2026-05-23 Phase 3 신설 (Compound Engineering 복원 2호).
# 트리거: LaunchAgent ai.jarvis.automation-budget (매주 월 03:50 KST)
#
# 사고 사례 (CLAUDE.md §0 신규 cron 체크리스트 2026-05-08 등재):
#   "하루에 18개 cron 신규 → 알림 폭주 + 메타 audit 부재 + 효과 측정 0건"
#
# 측정 5종 (주간):
#   1) plists_added   — ~/Library/LaunchAgents/ai.jarvis.* + com.jarvis.* 신규 plist (mtime <7d)
#   2) hooks_added    — ~/.claude/hooks/*.sh 신규/변경 (mtime <7d)
#   3) scripts_added  — ~/jarvis/infra/scripts/*.sh + ~/jarvis/infra/bin/*.sh (mtime <7d)
#   4) why_documented — 위 신규 항목 중 # Why 또는 #.*신설 코멘트 포함 비율
#   5) budget_status  — 주간 신규 합계 vs 임계 (7건/주 초과 시 ⚠️, 15건/주 초과 시 🔴)
#
# 출력: ledger jsonl + Discord 카드
set -euo pipefail

LOG="${HOME}/jarvis/runtime/logs/automation-budget.log"
LEDGER="${HOME}/jarvis/runtime/ledger/automation-budget.jsonl"

mkdir -p "$(dirname "${LEDGER}")" "$(dirname "${LOG}")"

log() { echo "[$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')] $*" | tee -a "${LOG}"; }

WEEK_AGO=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d "7 days ago" +%Y-%m-%d)
TODAY=$(TZ=Asia/Seoul date +%Y-%m-%d)

log "=== automation-budget 시작 (period=${WEEK_AGO}~${TODAY}) ==="

# ─── 1) plists_added ───
plists_files=$(find "${HOME}/Library/LaunchAgents" -maxdepth 1 -type f \
  \( -name "ai.jarvis.*.plist" -o -name "com.jarvis.*.plist" \) \
  -mtime -7 2>/dev/null)
plists_added=$(echo "$plists_files" | grep -c '\.plist$' 2>/dev/null || echo 0)

# ─── 2) hooks_added ───
hooks_files=$(find "${HOME}/.claude/hooks" -maxdepth 1 -type f \
  -name "*.sh" -mtime -7 2>/dev/null)
hooks_added=$(echo "$hooks_files" | grep -c '\.sh$' 2>/dev/null || echo 0)

# ─── 3) scripts_added ───
scripts_files=$(find \
  "${HOME}/jarvis/infra/scripts" \
  "${HOME}/jarvis/infra/bin" \
  -maxdepth 1 -type f -name "*.sh" -mtime -7 2>/dev/null)
scripts_added=$(echo "$scripts_files" | grep -c '\.sh$' 2>/dev/null || echo 0)

total_added=$((plists_added + hooks_added + scripts_added))

# ─── 4) why_documented: 신규 항목 중 "# Why" 또는 "신설" 메타 코멘트 포함 ───
why_count=0
total_inspected=0
for f in $hooks_files $scripts_files; do
  [[ -z "$f" || ! -f "$f" ]] && continue
  total_inspected=$((total_inspected + 1))
  if head -20 "$f" 2>/dev/null | grep -qE "# Why|# 사고 사례|# 트리거|# 신설|^# .* — " 2>/dev/null; then
    why_count=$((why_count + 1))
  fi
done

why_pct="0.0"
if (( total_inspected > 0 )); then
  why_pct=$(awk -v w="$why_count" -v t="$total_inspected" 'BEGIN { printf "%.1f", w * 100 / t }')
fi

# ─── 5) budget_status ───
overall="🟢 예산 정상"
flag=""
if (( total_added > 15 )); then
  overall="🔴 예산 초과"
  flag="budget_critical"
elif (( total_added > 7 )); then
  overall="🟡 예산 주의"
  flag="budget_warning"
fi

# why_documented 50% 미만이면 별도 경고
if (( total_inspected >= 3 )) && (( $(echo "$why_pct < 50" | bc -l 2>/dev/null || echo 0) )); then
  overall="${overall} + 문서화 부족"
  flag="${flag:+${flag},}why_undocumented"
fi

log "결과: plists=${plists_added} hooks=${hooks_added} scripts=${scripts_added} total=${total_added} why_pct=${why_pct}% overall=${overall}"

# ─── ledger append ───
jq -cn \
  --arg ts "$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')" \
  --arg period_start "$WEEK_AGO" \
  --arg period_end "$TODAY" \
  --argjson plists "${plists_added:-0}" \
  --argjson hooks "${hooks_added:-0}" \
  --argjson scripts "${scripts_added:-0}" \
  --argjson total "${total_added:-0}" \
  --argjson inspected "${total_inspected:-0}" \
  --arg why_pct "${why_pct:-0}" \
  --arg overall "$overall" \
  --arg flag "$flag" \
  '{ts:$ts, period:{start:$period_start, end:$period_end}, plists_added:$plists, hooks_added:$hooks, scripts_added:$scripts, total_added:$total, inspected:$inspected, why_pct:$why_pct|tonumber, overall:$overall, flag:$flag}' \
  >> "$LEDGER"

log "ledger append 완료: ${LEDGER}"

# ─── Discord 카드 송출 ───
DISCORD_SCRIPT="${HOME}/jarvis/runtime/scripts/discord-visual.mjs"
if [[ -f "$DISCORD_SCRIPT" ]]; then
  card_data=$(jq -cn \
    --arg title "Automation Budget — ${TODAY} 주간" \
    --argjson data "$(jq -cn \
      --arg overall "$overall" \
      --argjson plists "${plists_added:-0}" \
      --argjson hooks "${hooks_added:-0}" \
      --argjson scripts "${scripts_added:-0}" \
      --argjson total "${total_added:-0}" \
      --arg why_pct "${why_pct:-0}" \
      '{
        "상태": $overall,
        "plist 신규": ($plists|tostring + "건"),
        "hook 신규": ($hooks|tostring + "건"),
        "script 신규": ($scripts|tostring + "건"),
        "주간 총합": ($total|tostring + "건"),
        "Why 문서화율": ($why_pct + "%")
      }')" \
    '{title:$title, data:$data, timestamp:"'"$TODAY"'"}')
  node "$DISCORD_SCRIPT" --type stats --data "$card_data" --channel jarvis-system 2>&1 | tail -3 || true
fi

log "=== automation-budget 완료 ==="
exit 0
