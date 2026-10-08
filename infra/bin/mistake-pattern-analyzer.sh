#!/usr/bin/env bash
# mistake-pattern-analyzer.sh — 오답노트 반복 패턴 일일 분석 (P2 v1)
#
# v1: 패턴 빈도 분석만 (출력 only, 자동 SKILL.md 생성 X)
# 매일 03:30 cron → cron-master 통합

set -euo pipefail

WIKI_LM="${HOME}/.openclaw-data/runtime/wiki/meta/learned-mistakes.md"
LOG_FILE="${HOME}/.openclaw-data/runtime/logs/mistake-pattern-analyzer.log"
RESULT="${HOME}/.openclaw-data/runtime/state/mistake-pattern-analysis.json"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$RESULT")"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [mistake-pattern-analyzer] $*" | tee -a "$LOG_FILE"; }

[[ -f "$WIKI_LM" ]] || { log "FATAL: learned-mistakes.md 없음 ($WIKI_LM)"; exit 1; }

log "=== Mistake Pattern Analysis start ==="

# [2026-07-22] 본체+아카이브 glob 집계(아카이빙 후 카운트·키워드 분포 왜곡 방지). SIZE_KB는 활성본 기준 유지.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/learned-mistakes-glob.sh"
TOTAL=$(lm_grep "^## 2026-" | wc -l | tr -d ' \n')
SIZE_KB=$(($(wc -c < "$WIKI_LM") / 1024))
HEADERS=$(lm_grep "^## 2026-" | sed 's/^## 2026-[0-9-]* — //')

# 키워드|설명 (parallel arrays — bash assoc array 한글 키 호환성 회피)
KW_KEYS=("단정" "미확인" "편향" "검증 누락" "SSoT 미탐색" "미실측" "코드 미열람" "근본 원인 미" "조기 완료" "응답 압박")
KW_DESC=("추측을 사실처럼 단언" "검증 없이 진행" "단일 가설 확정" "Iron Law 6 위반" "SSoT Cross-Search 위반" "실측 부재" "추측만으로 판단" "증상 처방 권고" "부분 작업 후 완료 선언" "결재 옵션 강요")

# 빈도 카운트 + JSON 빌드
RESULTS="["
HIGH=0
MAX_COUNT=0
TOP_KW=""
for i in "${!KW_KEYS[@]}"; do
  kw="${KW_KEYS[$i]}"
  desc="${KW_DESC[$i]}"
  count=$(echo "$HEADERS" | grep -c "$kw" 2>/dev/null || echo 0)
  count=${count//[^0-9]/}; count=${count:-0}
  [[ $i -gt 0 ]] && RESULTS+=","
  RESULTS+="{\"keyword\":\"$kw\",\"count\":$count,\"description\":\"$desc\"}"
  (( count >= 3 )) && HIGH=$((HIGH + 1))
  if (( count > MAX_COUNT )); then
    MAX_COUNT=$count
    TOP_KW="$kw: ${count}건"
  fi
done
RESULTS+="]"

# 최근 30일 — gnu date로 cutoff 만든 후 라인 비교
CUTOFF=$(date -v-30d '+%Y-%m-%d' 2>/dev/null || date -d '30 days ago' '+%Y-%m-%d')
RECENT_30D=$(grep -oE "^## (2026-[0-9]+-[0-9]+)" "$WIKI_LM" 2>/dev/null | awk -v c="$CUTOFF" '{
  d=$2; if (d >= c) cnt++;
} END { print cnt+0 }')

# 상태 판정 — 변화량 기준(2026-10-09 자가 감사).
#   예전 기준(누적>1500·크기>1500KB·30일>50)은 9월부터 영구 참이라 WARN 이 열흘 넘게 '확인함'으로만 눌려 있었다.
#   이제 '지난 30일 건수'가 7일 이상 전 기록보다 25%↑이고 10건↑ 늘었을 때만 WARN. 첫날(기록 없음)은 기준선.
#   크기는 아카이빙이 필요하다는 정보로만 남긴다(경보 아님).
HIST="${HOME}/.openclaw-data/runtime/state/mistake-pattern-history.tsv"
TODAY=$(date '+%Y-%m-%d')
WEEK_AGO=$(date -v-7d '+%Y-%m-%d' 2>/dev/null || date -d '7 days ago' '+%Y-%m-%d')
BASE=$(awk -F'\t' -v w="$WEEK_AGO" '$1 <= w { v=$2 } END { print v }' "$HIST" 2>/dev/null || true)
STATUS="OK"
if [[ -n "$BASE" ]] && (( RECENT_30D * 4 > BASE * 5 && RECENT_30D - BASE >= 10 )); then
  STATUS="WARN"
fi
grep -q "^${TODAY}"$'\t' "$HIST" 2>/dev/null || printf '%s\t%s\n' "$TODAY" "$RECENT_30D" >> "$HIST"

# JSON 결과
cat > "$RESULT" <<JSON
{
  "ts": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "total_patterns": $TOTAL,
  "size_kb": $SIZE_KB,
  "recent_30d": $RECENT_30D,
  "high_freq_count": $HIGH,
  "top_keyword": "$TOP_KW",
  "keywords": $RESULTS,
  "status": "$STATUS"
}
JSON

log "총 $TOTAL / ${SIZE_KB}KB / 30d=$RECENT_30D(7일 전 ${BASE:-기록없음}) / 임계초과=$HIGH / 1위=$TOP_KW / status=$STATUS"
(( SIZE_KB > 1500 )) && log "참고: 활성 오답노트 ${SIZE_KB}KB — 월별 아카이빙 필요(경보 아님)"

if (( HIGH > 0 )); then
  echo "🔄 만성 패턴 (≥3회):"
  echo "$RESULTS" | jq -r '.[] | select(.count >= 3) | "  - \(.keyword): \(.count)건 (\(.description))"' | sort -t: -k2 -nr
fi

# ── P2 단정·미확인 게이트 효과 측정 (2026-06-04 신설 — 완결 루프) ──
# stop-unverified-assertion-guard.sh가 적재하는 ledger의 violation 추세로
# "검증 없는 단정" 패턴이 실제 줄어드는지 추적. 발동률 감소 = 게이트 효과.
UA_LEDGER="$HOME/.openclaw-data/runtime/ledger/unverified-assertion.jsonl"
if [[ -f "$UA_LEDGER" ]]; then
  UA_VIOL=$(grep -c '"status":"violation"' "$UA_LEDGER" 2>/dev/null || echo 0)
  UA_TOTAL=$(wc -l < "$UA_LEDGER" 2>/dev/null | tr -d ' ')
  log "P2 단정·미확인 게이트: 누적 발동 ${UA_VIOL}/${UA_TOTAL}턴 (발동률 추세 감소 = 단정 줄어듦)"
fi

log "=== Mistake Pattern Analysis end ==="
exit 0
