#!/bin/bash
# 당근페이 집중 ralph — 핵심 13문항만(미스·동적 제외), N라운드 순차. 2026-07-05
set -uo pipefail
LOG="$HOME/jarvis/runtime/logs/daangn-ralph-focused.log"
START="$HOME/jarvis/runtime/scripts/interview-ralph-start-focused.sh"
STOP="$HOME/jarvis/runtime/scripts/interview-ralph-stop.sh"
ROUNDS="${1:-4}"

echo "=== 당근 집중 ralph ${ROUNDS}라운드 시작 $(date '+%H:%M:%S') ===" > "$LOG"
for r in $(seq 1 "$ROUNDS"); do
  while pgrep -f interview-ralph-runner >/dev/null 2>&1; do sleep 6; done
  echo "[$(date '+%H:%M:%S')] ▶ Round $r 시작" >> "$LOG"
  bash "$START" --round "$r" --scenario daangnpay --all-questions --exclude-pinned >> "$LOG" 2>&1
  sleep 12
  waited=0
  while pgrep -f interview-ralph-runner >/dev/null 2>&1; do
    sleep 8; waited=$((waited+8))
    if [ "$waited" -gt 600 ]; then
      echo "[$(date '+%H:%M:%S')] ⚠ Round $r 10분 초과 → 종료" >> "$LOG"
      bash "$STOP" >> "$LOG" 2>&1 || true; sleep 4; break
    fi
  done
  echo "[$(date '+%H:%M:%S')] ✔ Round $r 완료 (${waited}s)" >> "$LOG"
done
echo "=== ${ROUNDS}라운드 전체 완료 $(date '+%H:%M:%S') ===" >> "$LOG"
