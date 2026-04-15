#!/usr/bin/env bash
# bot-quality-analyzer.sh — Discord 봇 응답 품질 분석 크론
# 매일 discord-bot.jsonl / 대화기록 분석 → 이상 감지 시 #jarvis-system 알림
# 크론: 30 2 * * *

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"

BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
LOG_FILE="$BOT_HOME/logs/discord-bot.jsonl"
RESULTS_DIR="$BOT_HOME/results/quality"
REPORT_FILE="$RESULTS_DIR/$(date +%F).json"
MONITORING="$BOT_HOME/config/monitoring.json"

mkdir -p "$RESULTS_DIR"

# ── 중복 실행 방지 (launchd + nexus 동시 실행 가드) ───────────────
LOCK_DIR="$BOT_HOME/state/locks/bot-quality-check-$(date +%F).lock"
if mkdir "$LOCK_DIR" 2>/dev/null; then
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
else
    echo "[quality] 이미 오늘 실행 완료 또는 실행 중 — 중복 방지로 종료"
    exit 0
fi

WEBHOOK_URL=""
CEO_WEBHOOK_URL=""
if [[ -f "$MONITORING" ]]; then
    WEBHOOK_URL=$(python3 -c "import json; d=json.load(open('$MONITORING')); print(d.get('webhooks',{}).get('jarvis-system',''))" 2>/dev/null || true)
    CEO_WEBHOOK_URL=$(python3 -c "import json; d=json.load(open('$MONITORING')); print(d.get('webhooks',{}).get('jarvis-ceo',''))" 2>/dev/null || true)
fi

if [[ ! -f "$LOG_FILE" ]]; then echo "[quality] 로그 파일 없음: $LOG_FILE"; exit 0; fi

# ── 지난 24시간 로그만 분석 ───────────────────────────────────────
SINCE_EPOCH=$(date -v-24H +%s 2>/dev/null || date -d '24 hours ago' +%s)

# jq 타임스탬프 파싱 헬퍼 — 밀리초 제거 후 strptime
# "2026-03-20T02:07:46.067Z" → split T → split . → [0] → strptime
_TS_FILTER='gsub("T";" ") | split(".")[0] | strptime("%Y-%m-%d %H:%M:%S") | mktime'

# 1. 전체 완료 응답 수
TOTAL=$(jq -sc --argjson since "$SINCE_EPOCH" --argjson tsf 0 '
  [.[] | select(.msg == "Claude completed") |
   select((.ts // "") | gsub("T";" ") | split(".")[0] | strptime("%Y-%m-%d %H:%M:%S") | mktime > $since)
  ] | length
' "$LOG_FILE" 2>/dev/null || echo 0)

# 2. 에러 응답 수
ERRORS=$(jq -sc --argjson since "$SINCE_EPOCH" '
  [.[] | select(.msg == "Claude completed") |
   select((.ts // "") | gsub("T";" ") | split(".")[0] | strptime("%Y-%m-%d %H:%M:%S") | mktime > $since) |
   select(.stopReason == "error")
  ] | length
' "$LOG_FILE" 2>/dev/null || echo 0)

# 3. 90초 타임아웃 수
TIMEOUTS=$(jq -sc --argjson since "$SINCE_EPOCH" '
  [.[] | select(.msg? | strings | contains("inactivity timeout")) |
   select((.ts // "") | gsub("T";" ") | split(".")[0] | strptime("%Y-%m-%d %H:%M:%S") | mktime > $since)
  ] | length
' "$LOG_FILE" 2>/dev/null || echo 0)

# 4. max_turns 도달 수
MAX_TURNS=$(jq -sc --argjson since "$SINCE_EPOCH" '
  [.[] | select(.msg == "Claude completed") |
   select((.ts // "") | gsub("T";" ") | split(".")[0] | strptime("%Y-%m-%d %H:%M:%S") | mktime > $since) |
   select(.stopReason == "max_turns")
  ] | length
' "$LOG_FILE" 2>/dev/null || echo 0)

# 5. 120초 초과 응답 수
SLOW=$(jq -sc --argjson since "$SINCE_EPOCH" '
  [.[] | select(.msg == "Claude completed") |
   select((.ts // "") | gsub("T";" ") | split(".")[0] | strptime("%Y-%m-%d %H:%M:%S") | mktime > $since) |
   select(.elapsed != null) |
   select((.elapsed | if type == "string" then gsub("s";"") else . end | tonumber // 0) > 120)
  ] | length
' "$LOG_FILE" 2>/dev/null || echo 0)

# 6. 도구 미사용 의심 응답 (elapsed > 5s인데 toolCount = 0)
ZERO_TOOL=$(jq -sc --argjson since "$SINCE_EPOCH" '
  [.[] | select(.msg == "Claude completed") |
   select((.ts // "") | gsub("T";" ") | split(".")[0] | strptime("%Y-%m-%d %H:%M:%S") | mktime > $since) |
   select(.toolCount == 0) |
   select(.elapsed != null) |
   select((.elapsed | if type == "string" then gsub("s";"") else . end | tonumber // 0) > 5)
  ] | length
' "$LOG_FILE" 2>/dev/null || echo 0)

# 7. 금지어 노출 감지 — Jarvis가 Discord 봇 컨텍스트에서 쓰면 안 되는 표현
# "새 세션을 시작" 제외 (Jarvis 자신의 기술 설명에서 false positive 발생)
# Jarvis 응답([**Jarvis**]: 이후)에서만 검사
FORBIDDEN=0
HIST_DIR="$BOT_HOME/context/discord-history"
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d yesterday +%Y-%m-%d)
TODAY=$(date +%Y-%m-%d)
FORBIDDEN_PATTERN="Claude Code 재시작|MCP 활성화|/clear|CLAUDE\.md|설정을 확인하세요|인증을 다시|Claude Code를 재시작|새 세션을 시작하세요"
_count_forbidden() {
    local _file="$1"
    [[ -f "$_file" ]] || { echo 0; return; }
    # Jarvis 응답 블록만 추출 후 패턴 검사 (false positive 방지)
    python3 -c "
import re, sys
content = open('$_file', 'r', errors='replace').read()
# **Jarvis**: 이후 다음 **로 시작하는 블록 전까지를 Jarvis 응답으로 간주
jarvis_blocks = re.findall(r'\*\*Jarvis\*\*:.*?(?=\n##|\Z)', content, re.DOTALL)
jarvis_text = '\n'.join(jarvis_blocks)
pattern = r'$FORBIDDEN_PATTERN'
hits = len(re.findall(pattern, jarvis_text, re.IGNORECASE))
print(hits)
" 2>/dev/null || echo 0
}
if [[ "$YESTERDAY" != "$TODAY" ]]; then
    for _hist_file in "$HIST_DIR/${YESTERDAY}.md" "$HIST_DIR/${TODAY}.md"; do
        _cnt=$(_count_forbidden "$_hist_file")
        FORBIDDEN=$(( FORBIDDEN + _cnt ))
    done
else
    _cnt=$(_count_forbidden "$HIST_DIR/${TODAY}.md")
    FORBIDDEN=$(( FORBIDDEN + _cnt ))
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
    # 2000자 청킹 전송 (Discord 제한)
    python3 - "$WEBHOOK_URL" "$MSG" << 'PYEOF'
import sys, json, time, urllib.request

url = sys.argv[1]
text = sys.argv[2].replace('\\n', '\n')
LIMIT = 1900

chunks = []
while len(text) > LIMIT:
    cut = text.rfind('\n', 0, LIMIT)
    cut = cut if cut > 0 else LIMIT
    chunks.append(text[:cut])
    text = text[cut:].lstrip('\n')
if text:
    chunks.append(text)

for chunk in chunks:
    payload = json.dumps({'content': chunk}).encode('utf-8')
    req = urllib.request.Request(url, data=payload, headers={'Content-Type': 'application/json'}, method='POST')
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f'[quality] webhook error: {e}', file=sys.stderr)
    if len(chunks) > 1:
        time.sleep(0.5)
PYEOF
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
    CEO_MSG="🚨 **[봇 품질 심각 이슈]** $(date +%F)\n\n"
    for reason in "${CEO_REASONS[@]}"; do
        CEO_MSG+="• ${reason}\n"
    done
    CEO_MSG+="\n전체 응답: ${TOTAL}건 | 에러율: ${ERROR_PCT}% | 리포트: \`results/quality/$(date +%F).json\`"
    python3 - "$CEO_WEBHOOK_URL" "$CEO_MSG" << 'PYEOF'
import sys, json, time, urllib.request

url = sys.argv[1]
text = sys.argv[2].replace('\\n', '\n')
LIMIT = 1900

chunks = []
while len(text) > LIMIT:
    cut = text.rfind('\n', 0, LIMIT)
    cut = cut if cut > 0 else LIMIT
    chunks.append(text[:cut])
    text = text[cut:].lstrip('\n')
if text:
    chunks.append(text)

for chunk in chunks:
    payload = json.dumps({'content': chunk}).encode('utf-8')
    req = urllib.request.Request(url, data=payload, headers={'Content-Type': 'application/json'}, method='POST')
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f'webhook error: {e}', file=sys.stderr)
    if len(chunks) > 1:
        time.sleep(0.5)
PYEOF
    echo "[quality] 심각 이슈 → #jarvis-ceo 에스컬레이션"
fi
