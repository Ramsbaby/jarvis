#!/usr/bin/env bash
set -euo pipefail

# daily-usage-report.sh — Claude Max 사용량을 usage-cache.json에서 읽어 포맷팅
# bot-cron.sh의 script 필드로 호출됨. Claude API 호출 없이 직접 데이터 읽기.

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

# 3. jq로 포맷팅 (스크린샷 포맷 재현)
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
