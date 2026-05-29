#!/usr/bin/env bash
# prompt-bloat-audit.sh — 시스템 프롬프트 비대화 자동 감사
#
# 매일 새벽 1회 실행:
#   1. system-prompt-snapshot.md 크기 측정
#   2. budget-drops.jsonl 분석 — 어떤 섹션이 가장 자주 drop됐는지
#   3. 임계치(30KB) 초과 시 jarvis-system 채널 알림
#   4. ROI 낮은 가드 (drop 빈도 높은 + score 낮은) 폐지 후보 추출
#
# 출처: 2026-05-28 비대화 구조적 차단 (A + D)

set -uo pipefail

BOT_HOME="${BOT_HOME:-$HOME/jarvis/runtime}"
SNAPSHOT="${BOT_HOME}/state/system-prompt-snapshot.md"
DROPS="${BOT_HOME}/state/prompt-budget-drops.jsonl"
LOG="${BOT_HOME}/logs/prompt-bloat-audit.log"
REPORT="${BOT_HOME}/state/prompt-bloat-audit-latest.json"

mkdir -p "$(dirname "$LOG")"
_log() { printf '[%s] [bloat-audit] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

_log "=== prompt-bloat-audit 시작 ==="

# 1. 현재 snapshot 크기
if [ ! -f "$SNAPSHOT" ]; then
    _log "snapshot 없음 — skip"
    exit 0
fi
CURRENT_BYTES=$(stat -f%z "$SNAPSHOT" 2>/dev/null || stat -c%s "$SNAPSHOT")
CURRENT_TOKENS=$(awk -F'[: ]' '/^total_estimated_tokens/{print $NF; exit}' "$SNAPSHOT" 2>/dev/null || echo 0)
SECTION_COUNT=$(awk -F'[: ]' '/^section_count/{print $NF; exit}' "$SNAPSHOT" 2>/dev/null || echo 0)

_log "현재 snapshot: ${CURRENT_BYTES} bytes / ${CURRENT_TOKENS} tokens / ${SECTION_COUNT} sections"

# 2. drop ledger 분석 (최근 7일)
DROP_COUNT_7D=0
TOP_DROPPED=""
if [ -f "$DROPS" ]; then
    # cutoff: ISO 형식 비교를 위해 +0000 보정 (jq 비교는 lexicographic). 7일 전 자정.
    CUTOFF=$(date -v-7d -u '+%Y-%m-%dT00:00:00Z' 2>/dev/null || date -u -d '7 days ago' '+%Y-%m-%dT00:00:00Z')
    # 전체 라인 중 cutoff 이후 ts 카운트 (substring 매칭 X, 정확한 ts 비교)
    DROP_COUNT_7D=$(jq -r --arg cut "$CUTOFF" 'select(.ts >= $cut) | .ts' "$DROPS" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    # 가장 자주 drop된 섹션 top 5
    TOP_DROPPED=$(jq -r --arg cut "$CUTOFF" '
        select(.ts >= $cut) | .dropped[] | .name
    ' "$DROPS" 2>/dev/null | sort | uniq -c | sort -rn | head -5 | awk '{printf "%s(%d), ", $2, $1}')
fi

_log "최근 7일 drop 이벤트: ${DROP_COUNT_7D}건"
_log "가장 자주 drop된 섹션: ${TOP_DROPPED:-없음}"

# 3. 임계치 체크
THRESHOLD_BYTES=30000
STATUS="OK"
if [ "$CURRENT_BYTES" -gt "$THRESHOLD_BYTES" ]; then
    STATUS="WARN"
    _log "⚠️ 임계치 초과 (${CURRENT_BYTES} > ${THRESHOLD_BYTES})"
fi

# 4. 보고서 저장
cat > "$REPORT" <<JSON
{
  "ts": "$(date -u +%FT%TZ)",
  "current_bytes": ${CURRENT_BYTES},
  "current_tokens": ${CURRENT_TOKENS},
  "section_count": ${SECTION_COUNT},
  "threshold_bytes": ${THRESHOLD_BYTES},
  "drop_count_7d": ${DROP_COUNT_7D},
  "top_dropped_7d": "${TOP_DROPPED:-없음}",
  "status": "${STATUS}"
}
JSON

# 5. Discord 알림 (WARN 시 또는 매주 월요일 정기 보고)
DOW=$(date '+%u')  # 1=Mon
SHOULD_NOTIFY="false"
[ "$STATUS" = "WARN" ] && SHOULD_NOTIFY="true"
[ "$DOW" = "1" ] && SHOULD_NOTIFY="true"

if [ "$SHOULD_NOTIFY" = "true" ] && [ -f "$HOME/jarvis/runtime/scripts/discord-visual.mjs" ]; then
    node "$HOME/jarvis/runtime/scripts/discord-visual.mjs" --type stats --data \
        "$(jq -nc \
            --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
            --arg bytes "$CURRENT_BYTES bytes" \
            --arg tokens "$CURRENT_TOKENS tokens" \
            --arg sections "$SECTION_COUNT sections" \
            --arg status "$STATUS" \
            --arg drops "$DROP_COUNT_7D / 7d" \
            --arg top "${TOP_DROPPED:-없음}" \
            '{title:"🧠 시스템 프롬프트 비대화 감사", data:{"크기":$bytes,"토큰":$tokens,"섹션수":$sections,"상태":$status,"7일 drop":$drops,"자주 drop 섹션":$top}, timestamp:$ts}')" \
        --channel jarvis-system 2>&1 | tee -a "$LOG" || true
fi

_log "=== 완료 — status=$STATUS ==="
exit 0
