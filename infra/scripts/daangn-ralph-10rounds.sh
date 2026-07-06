#!/bin/bash
# 당근페이 시나리오 ralph 10라운드 순차 오케스트레이터 (2026-07-05, 화상면접 D-1)
# 단일 진입점(interview-ralph-start.sh) 반복. 수동핀(자기소개·지원동기)은 --exclude-pinned로 제외.
set -uo pipefail
LOG="$HOME/jarvis/runtime/logs/daangn-ralph-orchestrator.log"
START="$HOME/jarvis/runtime/scripts/interview-ralph-start.sh"
STOP="$HOME/jarvis/runtime/scripts/interview-ralph-stop.sh"
ROUNDS="${1:-10}"

echo "=== 당근 ralph ${ROUNDS}라운드 시작 $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LOG"

for r in $(seq 1 "$ROUNDS"); do
  # 이전 라운드 완전 종료 대기
  while pgrep -f interview-ralph-runner >/dev/null 2>&1; do sleep 8; done
  echo "[$(date '+%H:%M:%S')] ▶ Round $r 시작" >> "$LOG"

  bash "$START" --round "$r" --scenario daangnpay --exclude-pinned >> "$LOG" 2>&1

  sleep 15  # detached spawn 등록 대기
  waited=0
  while pgrep -f interview-ralph-runner >/dev/null 2>&1; do
    sleep 10; waited=$((waited+10))
    if [ "$waited" -gt 1200 ]; then
      echo "[$(date '+%H:%M:%S')] ⚠ Round $r 20분 초과 → 강제 종료" >> "$LOG"
      bash "$STOP" >> "$LOG" 2>&1 || true
      sleep 5
      break
    fi
  done
  echo "[$(date '+%H:%M:%S')] ✔ Round $r 완료 (${waited}s 소요)" >> "$LOG"
done

echo "=== ${ROUNDS}라운드 전체 완료 $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG"
