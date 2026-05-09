#!/usr/bin/env bash
# cost-cap-audit.sh — tasks.json 비용 캡 일일 감사
#
# 목적: tasks.json의 모든 task가 적절한 maxBudget(비용 상한)을 갖는지 검사.
# 캡 부재(null) / 캡=0 / 캡 미달(평균 비용 대비 너무 낮음)을 식별하고
# Discord jarvis-system 채널에 경고 송출.
#
# 2026-04-28 신설 — 자비스 크론 모델 전수조사 결과:
#   108개 task 중 37개(34%)가 maxBudget 부재 → 비용 폭주 위험.
#   일괄 보수 적용 후, 향후 신규 task가 캡 누락하면 즉시 감지하기 위함.
#
# 호출: cron-master.sh가 매일 06:03 KST에 호출 (MASTER_AUDITS 배열 등록).
#       단독 실행도 가능: bash infra/bin/cost-cap-audit.sh

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
TASKS_JSON="${BOT_HOME}/config/tasks.json"
LEDGER="${BOT_HOME}/state/token-ledger.jsonl"
LOG_FILE="${BOT_HOME}/logs/cost-cap-audit.log"
AUDIT_RESULT="${BOT_HOME}/state/cost-cap-audit.json"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$AUDIT_RESULT")"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [cost-cap-audit] $*" | tee -a "$LOG_FILE"; }

if [[ ! -f "$TASKS_JSON" ]]; then
  log "FATAL: tasks.json not found at $TASKS_JSON"
  exit 1
fi

log "=== Cost Cap Audit start ==="

# 1. 캡 부재(null) 또는 캡=0인 task 수집
# script-only 화이트리스트: prompt가 ~/jarvis/infra/bin/*.sh, ~/.jarvis/scripts/*.sh  # ALLOW-DOTJARVIS 등
# 직접 스크립트 실행 패턴이면 LLM 비용 없으므로 maxBudget="0.00" 허용.
SCRIPT_ONLY_PATTERN='(~/jarvis/infra/bin/|~/\.jarvis/scripts/|/infra/bin/[^ ]*\.sh|/scripts/[^ ]*\.sh)'

NO_CAP=$(jq '[.tasks[] | select(.maxBudget == null)] | length' "$TASKS_JSON")
ZERO_CAP=$(jq --arg p "$SCRIPT_ONLY_PATTERN" '
  [.tasks[]
    | select((.maxBudget | tostring | tonumber? // null) == 0)
    | select((.prompt // "") != "")
    | select((.prompt // "") | test($p) | not)
  ] | length
' "$TASKS_JSON")
TOTAL=$(jq '.tasks | length' "$TASKS_JSON")

NO_CAP_IDS=$(jq -r '[.tasks[] | select(.maxBudget == null) | .id] | join(", ")' "$TASKS_JSON")
ZERO_CAP_IDS=$(jq -r --arg p "$SCRIPT_ONLY_PATTERN" '
  [.tasks[]
    | select((.maxBudget | tostring | tonumber? // null) == 0)
    | select((.prompt // "") != "")
    | select((.prompt // "") | test($p) | not)
    | .id
  ] | join(", ")
' "$TASKS_JSON")

log "총 task: $TOTAL / 캡 부재: $NO_CAP / 캡=0: $ZERO_CAP"

# 2. 평균 비용 대비 캡 부족 검사 (최근 7일 ledger)
LOW_CAP_TASKS="[]"
if [[ -f "$LEDGER" ]]; then
  CUTOFF=$(date -v-7d '+%Y-%m-%dT00:00:00' 2>/dev/null || date -d '7 days ago' '+%Y-%m-%dT00:00:00')
  # task별 평균 비용 계산
  AVG_COSTS=$(awk -v cutoff="$CUTOFF" '$0 >= cutoff' "$LEDGER" | \
    jq -s --argjson tasks "$(jq '.tasks' "$TASKS_JSON")" '
      group_by(.task) |
      map({
        task: .[0].task,
        avg_cost: (map(.cost_usd // 0) | add / length),
        n: length
      }) |
      map(. as $stat |
          ($tasks[] | select(.id == $stat.task) | .maxBudget // null) as $cap |
          if $cap != null and ($cap | tonumber) > 0 and $stat.avg_cost > ($cap | tonumber) * 0.7
          then {task: $stat.task, avg_cost: ($stat.avg_cost | tostring), cap: $cap, ratio: (($stat.avg_cost / ($cap | tonumber) * 100) | floor)}
          else empty
          end)
    ' 2>/dev/null || echo "[]")
  LOW_CAP_TASKS="$AVG_COSTS"
fi

LOW_CAP_COUNT=$(echo "$LOW_CAP_TASKS" | jq 'length' 2>/dev/null || echo 0)
log "캡 70%+ 도달 task: $LOW_CAP_COUNT"

# 3. 결과 JSON 저장 (cron-master가 읽음)
jq -n \
  --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson total "$TOTAL" \
  --argjson no_cap "$NO_CAP" \
  --argjson zero_cap "$ZERO_CAP" \
  --argjson low_cap_count "$LOW_CAP_COUNT" \
  --arg no_cap_ids "$NO_CAP_IDS" \
  --arg zero_cap_ids "$ZERO_CAP_IDS" \
  --argjson low_cap_tasks "$LOW_CAP_TASKS" \
  '{
    ts: $ts,
    total: $total,
    no_cap: $no_cap,
    zero_cap: $zero_cap,
    low_cap_count: $low_cap_count,
    no_cap_ids: $no_cap_ids,
    zero_cap_ids: $zero_cap_ids,
    low_cap_tasks: $low_cap_tasks,
    status: (if $no_cap > 0 or $zero_cap > 0 or $low_cap_count > 5 then "WARN" else "OK" end)
  }' > "$AUDIT_RESULT"

log "감사 결과 저장: $AUDIT_RESULT"

# 4. 경고 출력 (Discord 송출은 cron-master가 통합 후 처리)
if [[ "$NO_CAP" -gt 0 ]] || [[ "$ZERO_CAP" -gt 0 ]]; then
  echo "🔴 비용 캡 위험"
  [[ "$NO_CAP" -gt 0 ]] && echo "  - 캡 부재 ${NO_CAP}건: ${NO_CAP_IDS:0:200}"
  [[ "$ZERO_CAP" -gt 0 ]] && echo "  - 캡=0 ${ZERO_CAP}건: ${ZERO_CAP_IDS:0:200}"
fi

if [[ "$LOW_CAP_COUNT" -gt 5 ]]; then
  echo "🟡 캡 70%+ 도달: ${LOW_CAP_COUNT}건"
  echo "$LOW_CAP_TASKS" | jq -r '.[] | "  - \(.task) (avg=$\(.avg_cost) / cap=$\(.cap), \(.ratio)%)"' | head -10
fi

log "=== Cost Cap Audit end ==="
exit 0
