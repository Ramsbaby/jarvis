#!/usr/bin/env bash
# ssot-blocking-sync-audit.sh — CLI ↔ 디스코드 봇 BLOCKING 룰 양쪽 SSoT 동기화 점검
#
# 2026-05-25 신설 — Surface Memory Boundary 메타 가드의 코드 hook.
# 사고 사례: 2026-05-25 jarvis-core.md L16 "삼성물산 발표일 예측" 사고 사례가
#            CLI 전용 룰로만 존재하고 persona-discord.md에 미주입 → 디스코드 봇 깊이 부족 응답.
#            "룰만 등재되고 hook 없으면 학습 무효" 패턴.
#
# 동작:
#   1) jarvis-core.md에서 BLOCKING 섹션 제목 추출
#   2) "봇 적용 대상 키워드" 필터링 (응답·깊이·말투·인지·예측·분석·판단·가드 등)
#   3) persona-discord.md에서 동일 추출
#   4) jarvis-core 봇 적용 대상 중 persona-discord에 없는 것 → GAP
#   5) GAP 발견 시 Discord critical + ledger 적재
#   6) GAP 0이면 silent (cron spam 방지)
#
# 트리거: LaunchAgent ai.jarvis.ssot-blocking-sync-audit (매주 월 04:10 KST)

set -euo pipefail

LOG="${HOME}/jarvis/runtime/logs/ssot-blocking-sync-audit.log"
LEDGER="${HOME}/jarvis/runtime/ledger/ssot-blocking-sync-audit.jsonl"

CLI_FILE="${HOME}/.claude/rules/jarvis-core.md"
BOT_FILE="${HOME}/jarvis/runtime/context/owner/persona-discord.md"

# 봇 적용 대상 BLOCKING 키워드 (디스코드 봇 응답에도 가드되어야 하는 룰의 핵심 단어)
BOT_RELEVANT_KEYWORDS="응답|깊이|말투|인지|예측|분석|판단|가드|존댓말|시간 표기|호칭|페르소나|시적|얕|편견|편향"

mkdir -p "$(dirname "$LEDGER")" "$(dirname "$LOG")"

log() { echo "[$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')] $*" | tee -a "${LOG}"; }
log "=== ssot-blocking-sync-audit 시작 ==="

# ─── 1) jarvis-core.md BLOCKING 섹션 제목 추출 ───
# 패턴 1: `- **제목** (...BLOCKING...)`
# 패턴 2: `#### 제목 (BLOCKING)`
cli_titles=$(grep -E "BLOCKING" "$CLI_FILE" 2>/dev/null | \
  grep -E "^- \*\*|^####" | \
  sed -E 's/^- \*\*([^*]+)\*\*.*/\1/; s/^#### ([^(]+) *\(.*\).*/\1/' | \
  sed 's/[[:space:]]*$//' || true)

cli_count=$(echo "$cli_titles" | grep -c . || echo 0)
log "jarvis-core.md BLOCKING 섹션 헤더: ${cli_count}개"

# ─── 2) 봇 적용 대상 키워드 필터링 ───
cli_bot_relevant=$(echo "$cli_titles" | grep -E "$BOT_RELEVANT_KEYWORDS" || true)
cli_bot_count=$(echo "$cli_bot_relevant" | grep -c . || echo 0)
log "→ 봇 적용 대상 (키워드 매칭): ${cli_bot_count}개"
if [ -n "$cli_bot_relevant" ]; then
  echo "$cli_bot_relevant" | while IFS= read -r t; do
    [ -z "$t" ] && continue
    log "  • $t"
  done
fi

# ─── 3) persona-discord.md BLOCKING 섹션 제목 추출 ───
# 패턴: `## 제목 (BLOCKING...)`
bot_titles=$(grep -E "BLOCKING" "$BOT_FILE" 2>/dev/null | \
  grep -E "^## " | \
  sed -E 's/^## ([^(]+) *\(.*\).*/\1/' | \
  sed 's/[[:space:]]*$//' || true)

bot_count=$(echo "$bot_titles" | grep -c . || echo 0)
log "persona-discord.md BLOCKING 섹션 헤더: ${bot_count}개"
if [ -n "$bot_titles" ]; then
  echo "$bot_titles" | while IFS= read -r t; do
    [ -z "$t" ] && continue
    log "  • $t"
  done
fi

# ─── 4) GAP 검출 — jarvis-core 봇 적용 대상 중 persona-discord에 없는 것 ───
gaps=""
gap_count=0
if [ -n "$cli_bot_relevant" ]; then
  while IFS= read -r cli_title; do
    [ -z "$cli_title" ] && continue
    # cli_title의 핵심 키워드 (' —' 또는 ' ('  앞까지) 추출하여 bot_titles에 grep
    # 예: "모델 깊이 가드 — 스케일업..." → "모델 깊이 가드"
    # head -c 20 사용 시 UTF-8 multi-byte 중간 잘림 → fuzzy 매칭 실패. sed 결과 그대로 사용.
    cli_key=$(echo "$cli_title" | sed -E 's/ —.*//; s/ \(.*//')
    if ! echo "$bot_titles" | grep -qF "$cli_key"; then
      gaps="${gaps}${gaps:+|}${cli_title}"
      gap_count=$((gap_count + 1))
    fi
  done <<< "$cli_bot_relevant"
fi

log "GAP 검출: ${gap_count}건"
if [ -n "$gaps" ]; then
  echo "$gaps" | tr '|' '\n' | while IFS= read -r g; do
    [ -z "$g" ] && continue
    log "  🚨 $g (persona-discord.md 미등재)"
  done
fi

# ─── 5) ledger 적재 ───
gaps_json=$(echo "$gaps" | tr '|' '\n' | jq -R . 2>/dev/null | jq -sc . 2>/dev/null || echo '[]')
status="ok"
(( gap_count > 0 )) && status="critical"

jq -cn \
  --arg ts "$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')" \
  --argjson cli "${cli_count:-0}" \
  --argjson cli_bot "${cli_bot_count:-0}" \
  --argjson bot "${bot_count:-0}" \
  --argjson gaps "${gap_count:-0}" \
  --arg status "$status" \
  --argjson gap_list "$gaps_json" \
  '{ts:$ts, cli_total:$cli, cli_bot_relevant:$cli_bot, bot_total:$bot, gap_count:$gaps, status:$status, gaps:$gap_list}' \
  >> "$LEDGER"

# ─── 6) Discord critical alert (GAP 발견 시만) ───
if (( gap_count > 0 )); then
  ALERT_SCRIPT="${HOME}/jarvis/runtime/scripts/alert.sh"
  if [ -x "$ALERT_SCRIPT" ]; then
    title="🚨 SSoT BLOCKING 룰 동기화 GAP ${gap_count}건"
    detail="jarvis-core.md(CLI) BLOCKING 봇 적용 대상 ${cli_bot_count}개 중 ${gap_count}개가 persona-discord.md에 미등재. 양쪽 SSoT 동기화 필요. 상세: ${LEDGER}"
    bash "$ALERT_SCRIPT" critical "$title" "$detail" 2>&1 | tee -a "$LOG" || true
  fi
fi

log "=== ssot-blocking-sync-audit 종료 (status=${status}) ==="
exit 0
