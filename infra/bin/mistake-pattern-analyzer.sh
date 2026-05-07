#!/usr/bin/env bash
# mistake-pattern-analyzer.sh — 오답노트 반복 패턴 일일 분석 (P2 v1)
#
# v1: 패턴 빈도 분석만 (출력 only, 자동 SKILL.md 생성 X)
# 매일 03:30 cron → cron-master 통합

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
WIKI_LM="${BOT_HOME}/wiki/meta/learned-mistakes.md"
LOG_FILE="${BOT_HOME}/logs/mistake-pattern-analyzer.log"
RESULT="${BOT_HOME}/state/mistake-pattern-analysis.json"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$RESULT")"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [mistake-pattern-analyzer] $*" | tee -a "$LOG_FILE"; }

[[ -f "$WIKI_LM" ]] || { log "FATAL: learned-mistakes.md 없음 ($WIKI_LM)"; exit 1; }

log "=== Mistake Pattern Analysis start ==="

TOTAL=$(grep -c "^## 2026-" "$WIKI_LM" 2>/dev/null || echo 0)
SIZE_KB=$(($(wc -c < "$WIKI_LM") / 1024))
HEADERS=$(grep "^## 2026-" "$WIKI_LM" 2>/dev/null | sed 's/^## 2026-[0-9-]* — //')

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

# 상태 판정
STATUS="OK"
(( TOTAL > 1500 )) && STATUS="WARN"
(( RECENT_30D > 50 )) && STATUS="WARN"
(( SIZE_KB > 1500 )) && STATUS="WARN"

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

log "총 $TOTAL / ${SIZE_KB}KB / 30d=$RECENT_30D / 임계초과=$HIGH / 1위=$TOP_KW / status=$STATUS"

if (( HIGH > 0 )); then
  echo "🔄 만성 패턴 (≥3회):"
  echo "$RESULTS" | jq -r '.[] | select(.count >= 3) | "  - \(.keyword): \(.count)건 (\(.description))"' | sort -t: -k2 -nr
fi

log "=== Mistake Pattern Analysis end ==="
exit 0
