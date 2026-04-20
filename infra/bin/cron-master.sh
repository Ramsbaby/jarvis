#!/usr/bin/env bash
# cron-master.sh — 크론 총괄책임자.
#
# 매일 아침 1회(06:03 KST) 호출되어 모든 감사 결과를 수집하여
# jarvis-system 채널에 "한 장짜리 종합 리포트"로 요약 출력한다.
#
# 2026-04-20 신설 배경:
#   기존 cron-monitoring-orchestrator.sh는 crontab에 등록돼 있었으나
#   파일 자체가 존재하지 않는 유령 상태였다. 개별 감사 9개가 각자 뛰고
#   일부(cron-auditor, launchagents-audit, token-ledger-audit,
#   tasks-prompt-path-audit)는 Discord 경보도 안 보내서 daily-usage-check
#   plist 우회 사건이 3일간 방치되었다. 본 스크립트는 그 공백을 구조적으로
#   채우는 총괄책임자다.
#
# 설계 원칙:
#   - 이미 돌고 있는 감사들을 재실행하지 않고 "로그에서 결과만 수집"한다
#     (멱등성 + 가벼움)
#   - 정상이면 한 줄로 "✅ 모두 정상", 문제가 있으면 상세 리포트
#   - bot-cron.sh가 stdout을 route-result.sh로 보내 Discord로 라우팅한다

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG_DIR="$BOT_HOME/logs"
LA_DIR="$HOME/Library/LaunchAgents"
NOW=$(date '+%Y-%m-%d %H:%M:%S')
CUTOFF=$(date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
  || date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "1970-01-01 00:00:00")

ISSUES=()
add_issue() { ISSUES+=("$1"); }

# ── 1. 최근 24h cron.log FAILED/ERROR ────────────────────────────────────────
FAIL_COUNT=0
FAIL_SAMPLES=""
if [[ -f "$LOG_DIR/cron.log" ]]; then
  FAIL_LINES=$(grep -E 'FAILED|ERROR' "$LOG_DIR/cron.log" \
    | awk -v c="[$CUTOFF" '$0 >= c' \
    | grep -v 'not found in tasks.json' || true)
  if [[ -n "$FAIL_LINES" ]]; then
    FAIL_COUNT=$(echo "$FAIL_LINES" | wc -l | tr -d ' ')
    FAIL_SAMPLES=$(echo "$FAIL_LINES" \
      | grep -oE '\[[a-z][a-z0-9-]+\]' | sort -u | head -5 | tr '\n' ' ')
    add_issue "FAIL 실행 ${FAIL_COUNT}건 (${FAIL_SAMPLES})"
  fi
fi

# ── 2. LaunchAgent 언로드 탐지 (plist는 있는데 launchctl list에 없음) ────────
# launchctl list를 한 번만 호출해 snapshot으로 비교 (race condition 방지)
LOADED_SET=$(launchctl list 2>/dev/null | awk 'NR>1 {print $3}' | sort -u)
UNLOADED=()
for p in "$LA_DIR"/com.jarvis.*.plist "$LA_DIR"/ai.jarvis.*.plist; do
  [[ -f "$p" ]] || continue
  label=$(basename "$p" .plist)
  if ! echo "$LOADED_SET" | grep -qx "$label"; then
    UNLOADED+=("$label")
  fi
done
if [[ ${#UNLOADED[@]} -gt 0 ]]; then
  add_issue "LaunchAgent 언로드 ${#UNLOADED[@]}건 (${UNLOADED[*]})"
fi

# ── 3. output:discord BYPASS (cron-auditor 섹션 4 결과 파싱) ──────────────────
BYPASS_LIST=""
if [[ -x "$BOT_HOME/../infra/scripts/cron-auditor.sh" ]] \
   || [[ -x "$HOME/jarvis/infra/scripts/cron-auditor.sh" ]]; then
  AUDITOR_OUT=$(timeout 60 bash "$HOME/jarvis/infra/scripts/cron-auditor.sh" 2>/dev/null || true)
  BYPASS_LIST=$(echo "$AUDITOR_OUT" \
    | awk '/^## \[output:discord BYPASS/,/^## \[요약\]/' \
    | grep -E '  [a-z]' | awk '{print $1}' | tr '\n' ' ' || true)
  if [[ -n "$BYPASS_LIST" ]]; then
    bypass_count=$(echo "$BYPASS_LIST" | wc -w | tr -d ' ')
    add_issue "Discord 파이프 BYPASS ${bypass_count}건 (${BYPASS_LIST})"
  fi
fi

# ── 4. 유령 crontab 엔트리 탐지 (파일 없는 스크립트 호출) ────────────────────
PHANTOM_COUNT=0
while IFS= read -r script; do
  [[ -n "$script" && ! -f "$script" ]] && PHANTOM_COUNT=$((PHANTOM_COUNT+1))
done < <(crontab -l 2>/dev/null | grep -v '^#' | grep -v '^$' \
         | grep -oE '/[^[:space:]]+\.(sh|py|mjs|js)' | sort -u || true)
if [[ "$PHANTOM_COUNT" -gt 0 ]]; then
  add_issue "crontab 유령 스크립트 호출 ${PHANTOM_COUNT}개"
fi

# ── 5. 리포트 출력 (stdout → bot-cron.sh가 Discord로 라우팅) ─────────────────

echo "🔍 **크론 마스터 종합 리포트** — ${NOW} KST"
echo ""
if [[ ${#ISSUES[@]} -eq 0 ]]; then
  echo "✅ **상태: 정상** — 최근 24h 모든 크론·감사 이상 없음"
else
  echo "⚠️ **상태: 주의** — ${#ISSUES[@]}건 검출"
  echo ""
  for i in "${ISSUES[@]}"; do
    echo "  - ${i}"
  done
fi

echo ""
echo "---"
echo "📊 **상세**"
echo "  · FAIL 실행 (24h): ${FAIL_COUNT}"
echo "  · LaunchAgent 언로드: ${#UNLOADED[@]}"
echo "  · Discord BYPASS: $(echo "$BYPASS_LIST" | wc -w | tr -d ' ')"
echo "  · crontab 유령 스크립트: ${PHANTOM_COUNT}"
echo "  · 리포트 생성: ${NOW} KST"
