#!/usr/bin/env bash
# bot-quality-analyzer.sh — Discord 봇 응답 품질 분석 크론
# 매일 discord-bot.jsonl / 대화기록 분석 → 이상 감지 시 #jarvis-system 알림
# 크론: 30 2 * * *

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
LOG_FILE="$BOT_HOME/logs/discord-bot.jsonl"
RESULTS_DIR="$BOT_HOME/results/quality"
REPORT_FILE="$RESULTS_DIR/$(date +%F).json"
MONITORING="$BOT_HOME/config/monitoring.json"

mkdir -p "$RESULTS_DIR"

WEBHOOK_URL=""
CEO_WEBHOOK_URL=""
if [[ -f "$MONITORING" ]]; then
    WEBHOOK_URL=$(python3 -c "import json; d=json.load(open('$MONITORING')); print(d.get('webhooks',{}).get('jarvis-system',''))" 2>/dev/null || true)
    CEO_WEBHOOK_URL=$(python3 -c "import json; d=json.load(open('$MONITORING')); print(d.get('webhooks',{}).get('jarvis-ceo',''))" 2>/dev/null || true)
fi

if [[ ! -f "$LOG_FILE" ]]; then echo "[quality] 로그 파일 없음: $LOG_FILE"; exit 0; fi

# ── 지난 24시간 로그만 분석 ───────────────────────────────────────
SINCE_EPOCH=$(date -v-24H +%s 2>/dev/null || date -d '24 hours ago' +%s)

# 1. 전체 완료 응답 수
TOTAL=$(jq -sc --argjson since "$SINCE_EPOCH" '
  [.[] | select(.msg == "Claude completed") |
   select((.ts // "") | gsub("[TZ]"; " ") | strptime("%Y-%m-%d %H:%M:%S") | mktime > $since)
  ] | length
' "$LOG_FILE" 2>/dev/null || echo 0)

# 2. 에러 응답 수
ERRORS=$(jq -sc --argjson since "$SINCE_EPOCH" '
  [.[] | select(.msg == "Claude completed") |
   select((.ts // "") | gsub("[TZ]"; " ") | strptime("%Y-%m-%d %H:%M:%S") | mktime > $since) |
   select(.stopReason == "error")
  ] | length
' "$LOG_FILE" 2>/dev/null || echo 0)

# 3. 90초 타임아웃 수
TIMEOUTS=$(jq -sc --argjson since "$SINCE_EPOCH" '
  [.[] | select(.msg? | strings | contains("inactivity timeout")) |
   select((.ts // "") | gsub("[TZ]"; " ") | strptime("%Y-%m-%d %H:%M:%S") | mktime > $since)
  ] | length
' "$LOG_FILE" 2>/dev/null || echo 0)

# 4. max_turns 도달 수
MAX_TURNS=$(jq -sc --argjson since "$SINCE_EPOCH" '
  [.[] | select(.msg == "Claude completed") |
   select((.ts // "") | gsub("[TZ]"; " ") | strptime("%Y-%m-%d %H:%M:%S") | mktime > $since) |
   select(.stopReason == "max_turns")
  ] | length
' "$LOG_FILE" 2>/dev/null || echo 0)

# 5. 120초 초과 응답 수
SLOW=$(jq -sc --argjson since "$SINCE_EPOCH" '
  [.[] | select(.msg == "Claude completed") |
   select((.ts // "") | gsub("[TZ]"; " ") | strptime("%Y-%m-%d %H:%M:%S") | mktime > $since) |
   select(.elapsed != null) |
   select((.elapsed | gsub("s";"") | tonumber) > 120)
  ] | length
' "$LOG_FILE" 2>/dev/null || echo 0)

# 6. 도구 미사용 의심 응답 (elapsed > 5s인데 toolCount = 0)
ZERO_TOOL=$(jq -sc --argjson since "$SINCE_EPOCH" '
  [.[] | select(.msg == "Claude completed") |
   select((.ts // "") | gsub("[TZ]"; " ") | strptime("%Y-%m-%d %H:%M:%S") | mktime > $since) |
   select(.toolCount == 0) |
   select(.elapsed != null) |
   select((.elapsed | gsub("s";"") | tonumber) > 5)
  ] | length
' "$LOG_FILE" 2>/dev/null || echo 0)

# 7. 금지어 노출 감지 (최근 24시간 대화 기록 — 어제+오늘 파일 검색)
FORBIDDEN=0
HIST_DIR="$BOT_HOME/context/discord-history"
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d)
TODAY=$(date +%Y-%m-%d)
FORBIDDEN_PATTERN="Claude Code 재시작|MCP 활성화|새 세션을 시작|/clear|CLAUDE\.md|설정을 확인하세요|인증을 다시"
if [[ "$YESTERDAY" != "$TODAY" ]]; then
    # 어제/오늘이 다를 때만 2개 파일 검사 (낮에 수동 실행 시 중복 방지)
    for _hist_file in "$HIST_DIR/${YESTERDAY}.md" "$HIST_DIR/${TODAY}.md"; do
        if [[ -f "$_hist_file" ]]; then
            _cnt=$(grep -cEi "$FORBIDDEN_PATTERN" "$_hist_file" 2>/dev/null || echo 0)
            FORBIDDEN=$(( FORBIDDEN + _cnt ))
        fi
    done
else
    # 같은 날짜: 오늘 파일만 검사
    if [[ -f "$HIST_DIR/${TODAY}.md" ]]; then
        _cnt=$(grep -cEi "$FORBIDDEN_PATTERN" "$HIST_DIR/${TODAY}.md" 2>/dev/null || echo 0)
        FORBIDDEN=$(( FORBIDDEN + _cnt ))
    fi
fi

# ── 에러율 계산 ───────────────────────────────────────────────────
ERROR_PCT=0
if [[ "$TOTAL" -gt 0 ]]; then
    ERROR_PCT=$(( ERRORS * 100 / TOTAL ))
fi

# ── 보고서 저장 ───────────────────────────────────────────────────
cat > "$REPORT_FILE" <<EOJSON
{
  "date": "$(date +%F)",
  "analyzed_period": "24h",
  "total_completions": $TOTAL,
  "error_count": $ERRORS,
  "error_pct": $ERROR_PCT,
  "timeout_90s": $TIMEOUTS,
  "max_turns_hit": $MAX_TURNS,
  "slow_over_120s": $SLOW,
  "zero_tool_suspicious": $ZERO_TOOL,
  "forbidden_word_hits": $FORBIDDEN
}
EOJSON

echo "[quality] $(date +%F): 응답 ${TOTAL}건 | 에러 ${ERROR_PCT}% | 타임아웃 ${TIMEOUTS} | 금지어 ${FORBIDDEN}"

# ── 이상 판단 ────────────────────────────────────────────────────
ISSUES=()
if [[ "$ERROR_PCT"  -ge 10 ]]; then ISSUES+=("에러율 **${ERROR_PCT}%** (기준 <10%)"); fi
if [[ "$TIMEOUTS"   -ge 3  ]]; then ISSUES+=("90초 타임아웃 **${TIMEOUTS}건**"); fi
if [[ "$MAX_TURNS"  -ge 5  ]]; then ISSUES+=("max_turns 도달 **${MAX_TURNS}건** — budget 설정 검토"); fi
if [[ "$ZERO_TOOL"  -ge 8  ]]; then ISSUES+=("도구 미사용 의심 **${ZERO_TOOL}건** — 시스템 프롬프트 점검"); fi
if [[ "$SLOW"       -ge 5  ]]; then ISSUES+=("120초 초과 응답 **${SLOW}건**"); fi
if [[ "$FORBIDDEN"  -ge 1  ]]; then ISSUES+=("금지어 노출 **${FORBIDDEN}건** — 프롬프트 점검 필요"); fi

if [[ ${#ISSUES[@]} -eq 0 ]]; then echo "[quality] 이상 없음"; exit 0; fi

# ── Discord 알림 ──────────────────────────────────────────────────
MSG="🔍 **봇 품질 이상 감지** ($(date +%F))\n\n"
for issue in "${ISSUES[@]}"; do
    MSG+="• ${issue}\n"
done
MSG+="\n전체: ${TOTAL}건 | 에러율: ${ERROR_PCT}% | 리포트: \`results/quality/$(date +%F).json\`"

if [[ -n "$WEBHOOK_URL" ]]; then
    curl -sf -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"${MSG}\"}" > /dev/null 2>&1 || true
    echo "[quality] 이상 ${#ISSUES[@]}건 → #jarvis-system 전송"
else
    echo "[quality] WEBHOOK 없음 — 로컬 기록만"
fi

# ── CEO 에스컬레이션 (심각 이슈만) ───────────────────────────────────
# 에러율 ≥20% 또는 금지어 ≥1 → #jarvis-ceo 별도 알림
CEO_ESCALATE=0
CEO_REASONS=()
if [[ "$ERROR_PCT" -ge 20 ]]; then CEO_ESCALATE=1; CEO_REASONS+=("에러율 **${ERROR_PCT}%** (임계 20% 초과)"); fi
if [[ "$FORBIDDEN" -ge 1  ]]; then CEO_ESCALATE=1; CEO_REASONS+=("금지어 노출 **${FORBIDDEN}건** — 즉시 프롬프트 점검 필요"); fi

if [[ "$CEO_ESCALATE" -eq 1 && -n "$CEO_WEBHOOK_URL" ]]; then
    CEO_MSG="🚨 **[봇 품질 심각 이슈]** $(date +%F)\\n\\n"
    for reason in "${CEO_REASONS[@]}"; do
        CEO_MSG+="• ${reason}\\n"
    done
    CEO_MSG+="\\n전체 응답: ${TOTAL}건 | 에러율: ${ERROR_PCT}% | 리포트: \`results/quality/$(date +%F).json\`"
    curl -sf -X POST "$CEO_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"${CEO_MSG}\"}" > /dev/null 2>&1 || true
    echo "[quality] 심각 이슈 → #jarvis-ceo 에스컬레이션"
fi
