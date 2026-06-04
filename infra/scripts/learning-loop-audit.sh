#!/usr/bin/env bash
# learning-loop-audit.sh — Compound Engineering 복리 감사
#
# 2026-05-23 Phase 3 신설 (Compound Engineering 복원 1호).
# 트리거: LaunchAgent ai.jarvis.learning-loop-audit (매주 일 09:00 KST)
#
# 사고 사례 (learned-mistakes.md 2026-05-23 메타 root cause):
#   "추가만 하고 검증·제거 안 함" → 룰 2,260건 누적 vs hook 강제 0개.
#   학습 입력(오답노트)과 학습 적용(hook 코드) 비율이 1:0 → 복리 정체.
#
# 측정 7종 (주간):
#   1) mistakes_added — learned-mistakes.md `^## ` 신규 등재 건수
#   2) hooks_added    — ~/.claude/hooks/*.sh 신규/변경 (7일)
#   3) ratio          — mistakes_added / max(hooks_added,1) — 1.0 가까울수록 건강
#   4) eureka_added   — eureka.jsonl 신규 라인
#   5) retros_added   — wiki/retros/ 신규 파일
#   6) ghost_count    — ghost-tool-detector 최근 결과
#   7) coverage_pct   — rule-hook-coverage-audit 최근 결과
#
# 출력: ledger jsonl + Discord 카드 + Discord critical (ratio > 10 or ghost > 0)
set -euo pipefail

LOG="${HOME}/jarvis/runtime/logs/learning-loop-audit.log"
LEDGER="${HOME}/jarvis/runtime/ledger/learning-loop-audit.jsonl"

mkdir -p "$(dirname "${LEDGER}")" "$(dirname "${LOG}")"

log() { echo "[$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')] $*" | tee -a "${LOG}"; }

WEEK_AGO=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d "7 days ago" +%Y-%m-%d)
TODAY=$(TZ=Asia/Seoul date +%Y-%m-%d)

log "=== learning-loop-audit 시작 (period=${WEEK_AGO}~${TODAY}) ==="

# ─── 1) mistakes_added: 주간 신규 오답노트 ───
MISTAKES_FILE="${HOME}/jarvis/runtime/wiki/meta/learned-mistakes.md"
mistakes_added=0
if [[ -f "$MISTAKES_FILE" ]]; then
  # `## YYYY-MM-DD —` 형태에서 최근 7일 매칭
  mistakes_added=$(grep -cE "^## ${WEEK_AGO}|^## 2026-05-(17|18|19|20|21|22|23)" "$MISTAKES_FILE" 2>/dev/null || echo 0)
  # 좀 더 정확하게: 마지막 7일 날짜 패턴 동적 생성
  date_pattern=""
  for i in 0 1 2 3 4 5 6 7; do
    d=$(date -v-${i}d +%Y-%m-%d 2>/dev/null || date -d "${i} days ago" +%Y-%m-%d)
    date_pattern="${date_pattern}|^## ${d}"
  done
  date_pattern="${date_pattern#|}"
  mistakes_added=$(grep -cE "$date_pattern" "$MISTAKES_FILE" 2>/dev/null || echo 0)
fi

# ─── 2) hooks_added: ~/.claude/hooks/*.sh 7일 mtime ───
hooks_added=$(find "${HOME}/.claude/hooks" -name "*.sh" -type f -mtime -7 2>/dev/null | wc -l | tr -d ' ')

# ─── 3) ratio ───
ratio=$(awk -v m="$mistakes_added" -v h="$hooks_added" 'BEGIN { printf "%.2f", m / (h > 0 ? h : 1) }')

# ─── 4) eureka_added: eureka.jsonl 7일 신규 라인 ───
EUREKA_FILE="${HOME}/jarvis/runtime/wiki/meta/eureka.jsonl"
eureka_added=0
if [[ -f "$EUREKA_FILE" ]]; then
  # ts 필드가 7일 이내인 라인 카운트
  eureka_added=$(jq -r --arg cutoff "$WEEK_AGO" '
    select(.ts != null) | select(.ts >= $cutoff) | .ts
  ' "$EUREKA_FILE" 2>/dev/null | wc -l | tr -d ' ')
fi

# ─── 5) retros_added: wiki/retros/ 7일 신규 파일 ───
retros_added=$(find "${HOME}/jarvis/runtime/wiki/retros" -name "*.md" -mtime -7 -type f 2>/dev/null | wc -l | tr -d ' ')

# ─── 6) ghost_count: 최근 ghost-tool-detector 결과 ───
ghost_count=0
GHOST_LEDGER="${HOME}/jarvis/runtime/ledger/ghost-tool-detector.jsonl"
if [[ -f "$GHOST_LEDGER" ]]; then
  ghost_count=$(tail -1 "$GHOST_LEDGER" 2>/dev/null | jq -r '.detected // 0' 2>/dev/null || echo 0)
fi

# ─── 7) coverage_pct: 최근 rule-hook-coverage-audit 결과 ───
coverage_pct="0.0"
COV_LEDGER="${HOME}/jarvis/runtime/ledger/rule-hook-coverage-audit.jsonl"
if [[ -f "$COV_LEDGER" ]]; then
  coverage_pct=$(tail -1 "$COV_LEDGER" 2>/dev/null | jq -r '.coverage_pct // 0.0' 2>/dev/null || echo "0.0")
fi

# ─── 판정 ───
overall="🟢 건강"
flag=""
if (( $(echo "$ratio > 20" | bc -l 2>/dev/null || echo 0) )); then
  overall="🔴 복리 정체"
  flag="ratio_critical"
elif (( $(echo "$ratio > 10" | bc -l 2>/dev/null || echo 0) )); then
  overall="🟡 적용률 저조"
  flag="ratio_warning"
fi
(( ghost_count > 0 )) && overall="🟡 ghost 잔존" && flag="${flag:+${flag},}ghost_present"

log "결과: mistakes=${mistakes_added} hooks=${hooks_added} ratio=${ratio} eureka=${eureka_added} retros=${retros_added} ghost=${ghost_count} cov=${coverage_pct}% overall=${overall}"

# ─── ledger append ───
jq -cn \
  --arg ts "$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')" \
  --arg period_start "$WEEK_AGO" \
  --arg period_end "$TODAY" \
  --argjson mistakes "${mistakes_added:-0}" \
  --argjson hooks "${hooks_added:-0}" \
  --arg ratio "${ratio:-0}" \
  --argjson eureka "${eureka_added:-0}" \
  --argjson retros "${retros_added:-0}" \
  --argjson ghost "${ghost_count:-0}" \
  --arg coverage "${coverage_pct:-0}" \
  --arg overall "$overall" \
  --arg flag "$flag" \
  '{ts:$ts, period:{start:$period_start, end:$period_end}, mistakes_added:$mistakes, hooks_added:$hooks, ratio:$ratio|tonumber, eureka_added:$eureka, retros_added:$retros, ghost_count:$ghost, coverage_pct:$coverage|tonumber, overall:$overall, flag:$flag}' \
  >> "$LEDGER"

log "ledger append 완료: ${LEDGER}"

# ─── Discord 카드 송출 ───
DISCORD_SCRIPT="${HOME}/jarvis/runtime/scripts/discord-visual.mjs"
if [[ -f "$DISCORD_SCRIPT" ]]; then
  card_data=$(jq -cn \
    --arg title "Learning Loop — ${TODAY} 주간" \
    --argjson data "$(jq -cn \
      --arg overall "$overall" \
      --argjson mistakes "${mistakes_added:-0}" \
      --argjson hooks "${hooks_added:-0}" \
      --arg ratio "${ratio:-0}" \
      --argjson eureka "${eureka_added:-0}" \
      --argjson retros "${retros_added:-0}" \
      --argjson ghost "${ghost_count:-0}" \
      --arg coverage "${coverage_pct:-0}" \
      '{
        "상태": $overall,
        "오답노트 신규": ($mistakes|tostring + "건"),
        "Hook 코드 변경": ($hooks|tostring + "건"),
        "복리율 (적용/입력)": ("ratio=" + $ratio),
        "Eureka 신규": ($eureka|tostring + "건"),
        "회고 신규": ($retros|tostring + "건"),
        "ghost 도구": ($ghost|tostring + "건"),
        "rule→hook coverage": ($coverage + "%")
      }')" \
    '{title:$title, data:$data, timestamp:"'"$TODAY"'"}')
  channel="jarvis-system"
  [[ "$flag" == *critical* ]] && channel="jarvis-system"
  node "$DISCORD_SCRIPT" --type stats --data "$card_data" --channel "$channel" 2>&1 | tail -3 || true
fi

log "=== learning-loop-audit 완료 ==="
exit 0
