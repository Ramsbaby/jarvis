#!/usr/bin/env bash
# doctor-ledger-audit.sh — 최근 7일 doctor-ledger.jsonl 주간 분석.
#
# 감지:
#   - 7일 중 3회+ FAIL 반복한 영역 (구조적 결함 신호)
#   - 자동 조치 반복 실패
#   - red/yellow 카운트 추이
#
# 출력: jarvis-system 채널 Discord 카드 + stdout 리포트.

set -euo pipefail

LEDGER="${HOME}/jarvis/runtime/state/doctor-ledger.jsonl"
REPORT_LOG="${HOME}/jarvis/runtime/logs/doctor-weekly-audit.log"

mkdir -p "$(dirname "$REPORT_LOG")"

log() { echo "[$(TZ=Asia/Seoul date '+%Y-%m-%d %H:%M:%S KST')] $*" | tee -a "$REPORT_LOG"; }

if [ ! -f "$LEDGER" ]; then
  log "doctor-ledger.jsonl 없음 — 주간 감사 불가 (/doctor가 한 번도 안 실행됨)"
  exit 0
fi

log "🧠 doctor-weekly-audit 시작"

# 7일 전 타임스탬프 (UTC 기준 — ledger ts는 UTC)
SEVEN_DAYS_AGO=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                 || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                 || echo "1970-01-01T00:00:00Z")

# 최근 7일 엔트리 추출
ENTRIES=$(jq -c --arg cutoff "$SEVEN_DAYS_AGO" 'select(.ts >= $cutoff)' "$LEDGER" 2>/dev/null)
ENTRY_COUNT=$(echo "$ENTRIES" | grep -c '^{' || true)

if [ "$ENTRY_COUNT" -lt 3 ]; then
  log "7일 내 엔트리 $ENTRY_COUNT건 — 추이 분석에 최소 3회 필요, skip"
  exit 0
fi

log "7일 엔트리: $ENTRY_COUNT건"

# 영역별 FAIL/WARN 반복 카운트 (metrics 필드 내 boolean/flag 기준)
FAIL_AREAS=$(echo "$ENTRIES" \
  | jq -r 'select(.metrics != null) | .metrics | to_entries[]
           | select(.value == false or .value == "fail" or .value == "❌")
           | .key' 2>/dev/null \
  | sort | uniq -c | awk '$1 >= 3 {print $2 " (" $1 "회)"}')

RED_TOTAL=$(echo "$ENTRIES" | jq -s '[.[].red // 0] | add // 0')
YELLOW_TOTAL=$(echo "$ENTRIES" | jq -s '[.[].yellow // 0] | add // 0')
AUTO_REPAIR_TOTAL=$(echo "$ENTRIES" | jq -s '[.[].auto_repairs // 0] | add // 0')

# 2026-04-25 추가 (NEW-2): cron-scan entry는 .red/.yellow/.metrics 대신 .ok/.warn/.fail 스키마.
# 기존 합산에서 0으로 빠지므로 type 별도 분리 카운트.
CRON_SCAN_COUNT=$(echo "$ENTRIES" | jq -s '[.[] | select(.type == "cron-scan")] | length')
CRON_FAIL_TOTAL=$(echo "$ENTRIES" | jq -s '[.[] | select(.type == "cron-scan") | .fail // 0] | add // 0')
CRON_WARN_TOTAL=$(echo "$ENTRIES" | jq -s '[.[] | select(.type == "cron-scan") | .warn // 0] | add // 0')
CRON_OK_TOTAL=$(echo "$ENTRIES" | jq -s '[.[] | select(.type == "cron-scan") | .ok // 0] | add // 0')

log "7일 슬래시(scan): 🔴 $RED_TOTAL · 🟡 $YELLOW_TOTAL · 🔧 자동조치 $AUTO_REPAIR_TOTAL건"
log "7일 cron(cron-scan): ${CRON_SCAN_COUNT}회 · ok=$CRON_OK_TOTAL · warn=$CRON_WARN_TOTAL · fail=$CRON_FAIL_TOTAL"

if [ -n "$FAIL_AREAS" ]; then
  log "⚠️ 7일 중 3회+ 반복 FAIL 영역:"
  echo "$FAIL_AREAS" | while read -r line; do log "  - $line"; done
else
  log "✅ 반복 FAIL 영역 없음"
fi

# Discord 시각화 카드 송출 (실패해도 exit 0)
DISCORD_SUMMARY=$(jq -cn \
  --arg red "$RED_TOTAL" \
  --arg yellow "$YELLOW_TOTAL" \
  --arg repairs "$AUTO_REPAIR_TOTAL" \
  --arg fails "${FAIL_AREAS:-반복 FAIL 영역 없음}" \
  --arg count "$ENTRY_COUNT" \
  '{
    overall: (if ($fails == "반복 FAIL 영역 없음") then "✅ 안정" else "⚠️ 주의" end),
    red: ($red | tonumber),
    yellow: ($yellow | tonumber),
    findings: [("7일 엔트리: " + $count + "건"),
               ("🔴 누적 " + $red + " · 🟡 누적 " + $yellow),
               ($fails | split("\n") | map(select(length > 0))[] // "반복 FAIL 영역 없음")],
    healthy: [("자동조치 " + $repairs + "건 수행")]
  }' 2>/dev/null)

if command -v node >/dev/null 2>&1 && [ -f "${HOME}/jarvis/infra/scripts/discord-visual.mjs" ]; then
  node "${HOME}/jarvis/infra/scripts/discord-visual.mjs" \
    --type system-doctor \
    --data "$(jq -cn \
      --arg title "Jarvis Doctor Weekly — $(TZ=Asia/Seoul date '+%m-%d %H:%M KST')" \
      --argjson summary "$DISCORD_SUMMARY" \
      '{title:$title, summary:$summary, timestamp:""}')" \
    --channel jarvis-system 2>&1 | tee -a "$REPORT_LOG" || log "Discord 송출 실패 (exit 0 유지)"
fi

log "✅ doctor-weekly-audit 완료"
