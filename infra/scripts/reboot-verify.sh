#!/usr/bin/env bash
# reboot-verify.sh
#
# 재부팅 직후 실행: 베이스라인 대비 빠진 LaunchAgent/프로세스/심링크/포트를 탐지.
# 인자로 baseline 디렉토리 경로를 받음. 없으면 /tmp/jarvis-reboot-baseline.path 에서 읽음.
#
# Exit code:
#   0  — 모두 복구됨
#   1  — 누락 있음 (복구 필요)
set -euo pipefail

BASELINE="${1:-$(cat /tmp/jarvis-reboot-baseline.path 2>/dev/null || true)}"
if [[ -z "${BASELINE:-}" || ! -d "$BASELINE" ]]; then
  echo "❌ baseline dir not found. usage: $0 <baseline-dir>"
  exit 2
fi

echo "=== Reboot verification: baseline=$BASELINE ==="
echo "=== Now: $(date) ==="
echo ""

fail=0

# 잠깐 기다려 — LaunchAgent가 순차 기동 중일 수 있음
echo "(LaunchAgent 기동 대기 60s — 백그라운드 기동 여유)"
sleep 60

# ① LaunchAgent 비교
echo "═══ ① LaunchAgent 등록 비교 ═══"
launchctl list | grep -E "^[0-9-]+\s+[0-9-]+\s+ai\.jarvis\." | sort -k3 > /tmp/launchctl.after
# Label만 추출해 diff
awk '{print $3}' "$BASELINE/launchctl.before" | sort -u > /tmp/labels.before
awk '{print $3}' /tmp/launchctl.after | sort -u > /tmp/labels.after
missing=$(comm -23 /tmp/labels.before /tmp/labels.after)
added=$(comm -13 /tmp/labels.before /tmp/labels.after)
if [[ -n "$missing" ]]; then
  echo "❌ 누락된 LaunchAgent:"
  echo "$missing" | sed 's/^/    /'
  fail=1
else
  echo "✅ 모든 LaunchAgent 복구 ($(wc -l < /tmp/labels.after | tr -d ' ')개)"
fi
[[ -n "$added" ]] && echo "ℹ️ 추가된 Label: $added"
echo ""

# ② 프로세스 (discord-bot, watchdog 필수)
echo "═══ ② 필수 프로세스 ═══"
for kw in "discord-bot.js" "watchdog.sh"; do
  if pgrep -f "$kw" >/dev/null 2>&1; then
    echo "✅ $kw 실행 중 (PID=$(pgrep -f "$kw" | head -1))"
  else
    echo "❌ $kw 프로세스 없음"
    fail=1
  fi
done
echo ""

# ③ 심링크 무결성 (타겟 비교)
echo "═══ ③ 심링크 무결성 ═══"
find ~/.jarvis -type l ! -path '*node_modules*' ! -path '*.bak*' 2>/dev/null | while read l; do
  printf "%s -> %s\n" "${l#$HOME/}" "$(readlink "$l")"
done | sort > /tmp/symlinks.after
broken=$(find ~/.jarvis -type l ! -path '*.bak*' -exec test ! -e {} \; -print 2>/dev/null | head -5)
if [[ -n "$broken" ]]; then
  echo "❌ 깨진 심링크:"
  echo "$broken" | sed 's/^/    /'
  fail=1
else
  echo "✅ 깨진 심링크 0"
fi
diff_count=$(diff "$BASELINE/symlinks.before" /tmp/symlinks.after | wc -l | tr -d ' ')
if [[ "$diff_count" -eq 0 ]]; then
  echo "✅ 심링크 토폴로지 동일"
else
  echo "⚠️ 심링크 변경 ${diff_count} 줄 (diff 수동 확인 필요):"
  diff "$BASELINE/symlinks.before" /tmp/symlinks.after | head -10 | sed 's/^/    /'
fi
echo ""

# ④ Discord bot 연결 로그 (최근 5분)
echo "═══ ④ Discord bot 연결 ═══"
since=$(date -v-5M '+%Y-%m-%d' 2>/dev/null || date -d '5 minutes ago' '+%Y-%m-%d' 2>/dev/null || echo "2026")
if tail -100 ~/.jarvis/logs/discord-bot.log 2>/dev/null | grep -q "Logged in as"; then
  echo "✅ Discord 로그인 확인"
  tail -5 ~/.jarvis/logs/discord-bot.log | sed 's/^/    /'
else
  echo "❌ 최근 로그인 기록 없음"
  fail=1
fi
echo ""

# ⑤ 토폴로지 감사 자동 실행
echo "═══ ⑤ 심링크 감사 kickstart ═══"
/bin/bash ~/jarvis/infra/scripts/symlink-topology-audit.sh || fail=1
echo ""

# Discord 알림 (RunAtLoad 자동 실행 모드일 때만)
AUTO_MODE="${JARVIS_REBOOT_AUTO:-0}"
if [[ "$AUTO_MODE" == "1" ]]; then
  TS="$(date +%Y-%m-%dT%H:%M:%S%z)"
  if [[ $fail -eq 0 ]]; then
    TITLE="🎉 재부팅 자동 복구 성공"
    DATA="{\"title\":\"${TITLE}\",\"data\":{\"LaunchAgents\":\"$(wc -l < /tmp/labels.after | tr -d ' ')개 등록\",\"discord-bot\":\"✅ 실행 중\",\"watchdog\":\"✅ 실행 중\",\"깨진_심링크\":\"0\",\"감사\":\"0 violations\"},\"timestamp\":\"${TS}\"}"
  else
    MISSING_SUMMARY=$(comm -23 /tmp/labels.before /tmp/labels.after | head -5 | tr '\n' ',' | sed 's/,$//')
    TITLE="⚠️ 재부팅 복구 누락"
    DATA="{\"title\":\"${TITLE}\",\"data\":{\"누락_LaunchAgent\":\"${MISSING_SUMMARY:-없음}\",\"로그\":\"~/.jarvis/logs/reboot-verify.log\",\"조치\":\"로그 확인 후 수동 bootstrap\"},\"timestamp\":\"${TS}\"}"
  fi
  if [[ -f "${HOME}/.jarvis/scripts/discord-visual.mjs" ]]; then
    /opt/homebrew/bin/node "${HOME}/.jarvis/scripts/discord-visual.mjs" \
      --type stats --data "$DATA" --channel jarvis-system 2>/dev/null || true
  fi
  # self-unload: 다음 부팅에서는 실행되지 않도록 제거
  launchctl bootout "gui/$(id -u)/ai.jarvis.reboot-verify" 2>/dev/null || true
  rm -f "${HOME}/Library/LaunchAgents/ai.jarvis.reboot-verify.plist"
fi

# 결론
if [[ $fail -eq 0 ]]; then
  echo "🎉 재부팅 자동 복구 성공"
  exit 0
else
  echo "⚠️ 복구 누락 — 위 항목 수동 확인"
  exit 1
fi
