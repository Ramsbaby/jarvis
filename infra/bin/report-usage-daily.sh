#!/usr/bin/env bash
set -euo pipefail

# daily-usage-report.sh — Claude Max 사용량을 usage-cache.json에서 읽어 포맷팅
# bot-cron.sh의 script 필드로 호출됨. Claude API 호출 없이 직접 데이터 읽기.
# v2 2026-06-15: ok:false 시 null% 대신 에러 메시지 출력

HOME="${HOME:-$(eval echo ~)}"
CACHE="${HOME}/.claude/usage-cache.json"
UPDATE_SCRIPT="${HOME}/.claude/scripts/update-usage-cache.py"

# 1. 캐시 갱신 (최신 데이터 반영)
if [[ -x "$(command -v python3)" && -f "$UPDATE_SCRIPT" ]]; then
    python3 "$UPDATE_SCRIPT" 2>/dev/null || true
fi

# 2. 캐시 읽기
if [[ ! -f "$CACHE" ]]; then
    echo "⚠️ usage-cache.json 없음 — update-usage-cache.py 실행 필요"
    exit 0
fi

# 3. ok 필드 체크 — 실패 시 null% 대신 명확한 에러 출력
CACHE_OK=$(jq -r '.ok // false' "$CACHE" 2>/dev/null || echo "false")
if [[ "$CACHE_OK" != "true" ]]; then
    REASON=$(jq -r '.reason // "unknown"' "$CACHE" 2>/dev/null || echo "unknown")
    ERROR=$(jq -r '.error // ""' "$CACHE" 2>/dev/null || echo "")
    if [[ "$REASON" == "auth" ]]; then
        echo "⚠️ **Claude Max 사용량 조회 실패** — OAuth 토큰 만료"
        echo ""
        echo "Claude Code 세션이 시작되면 자동 갱신됩니다. (다음 날 리포트에 정상 반영)"
    else
        echo "⚠️ **Claude Max 사용량 조회 실패** (${REASON})"
        [[ -n "$ERROR" ]] && echo "\`${ERROR:0:100}\`"
    fi
    exit 0
fi

# 4. jq로 포맷팅 (스크린샷 포맷 재현)
jq -r '
  def emoji(pct): if pct >= 80 then "🔴" elif pct >= 60 then "🟡" else "🟢" end;
  def bar(pct):
    (pct / 2 | floor) as $filled |
    ("█" * $filled) + ("░" * (50 - $filled)) + " \(pct)%";

  "**Claude Max 현재 사용량**\n" +
  "- 5시간: \(.fiveH.pct)% / 잔여 \(.fiveH.remain)% " + emoji(.fiveH.pct) + " (리셋 \(.fiveH.resetIn) 후)\n" +
  "- 7일: \(.sevenD.pct)% / 잔여 \(.sevenD.remain)% " + emoji(.sevenD.pct) + " (리셋 \(.sevenD.resetIn) 후)\n" +
  "- Sonnet 7일: \(.sonnet.pct)% / 잔여 \(.sonnet.remain)% " + emoji(.sonnet.pct) + " (리셋 \(.sonnet.resetIn) 후)\n\n" +
  "전체 여유. " + emoji([.fiveH.pct, .sevenD.pct, .sonnet.pct] | max)
' "$CACHE"
