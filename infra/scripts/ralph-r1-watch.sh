#!/usr/bin/env bash
# ralph-r1-watch.sh — R1 완료 자동 감지 → snapshot 자동 실행
# 2026-04-28 비서실장 3차
#
# 사용:
#   bash ralph-r1-watch.sh r1-baseline-serial
#     → R1 완료 시그니처(✅ Round 1 done) 감지 시 즉시 snapshot 생성
#
# 동작:
#   - interview-ralph-detached.log를 60초마다 polling
#   - "✅ Round 1 done" 패턴이 감지되면 ralph-snapshot.sh 호출 후 종료
#   - 최대 4시간 watching (R1 완주 ~2.5h + 안전 마진)
#
# 주의: 이 스크립트는 R1을 stop하지 않음. 단순 감지만.

set -euo pipefail

LABEL="${1:-r1-baseline-serial}"
LOG_PATH="${HOME}/.jarvis/logs/interview-ralph-detached.log" # ALLOW-DOTJARVIS (심링크)
SNAP_SCRIPT="${HOME}/.openclaw-data/jarvis/infra/scripts/ralph-snapshot.sh"
MAX_WAIT_SEC=14400  # 4시간
POLL_SEC=60
WAITED=0

echo "🔍 Ralph R1 completion watcher started"
echo "   📁 log: $LOG_PATH"
echo "   🏷  label: $LABEL"
echo "   ⏱  poll: ${POLL_SEC}s · max wait: ${MAX_WAIT_SEC}s"

if [ ! -f "$LOG_PATH" ]; then
  echo "❌ log file not found: $LOG_PATH"
  exit 1
fi

# 시작 시점의 'Round 1 done' 카운트 — 라운드 종료 전 라인은 무시
INITIAL_DONE=$(grep -c "✅ Round 1 done" "$LOG_PATH" 2>/dev/null || echo 0)
echo "   📊 initial 'Round 1 done' count: $INITIAL_DONE (이 카운트보다 늘어나면 새 완주로 판정)"

while [ "$WAITED" -lt "$MAX_WAIT_SEC" ]; do
  CUR_DONE=$(grep -c "✅ Round 1 done" "$LOG_PATH" 2>/dev/null || echo 0)
  if [ "$CUR_DONE" -gt "$INITIAL_DONE" ]; then
    echo ""
    echo "✅ R1 completion detected (count: $INITIAL_DONE → $CUR_DONE)"
    echo "📸 invoking snapshot..."
    bash "$SNAP_SCRIPT" "$LABEL"
    exit 0
  fi
  printf "."
  sleep "$POLL_SEC"
  WAITED=$((WAITED + POLL_SEC))
done

echo ""
echo "⏱  timeout reached (${MAX_WAIT_SEC}s) — R1 still running. snapshot NOT taken automatically."
echo "   manual: bash $SNAP_SCRIPT $LABEL"
exit 2
