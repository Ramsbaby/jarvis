#!/usr/bin/env bash
# interview-ralph-stop.sh
# ralph runner를 안전하게 중단합니다 — daemon plist bootout만으로는 진행 중 라운드가 안 멈춥니다.
# 송출 메커니즘: runner ↔ 봇 fast-path ↔ verifier-server ping-pong → #jarvis-interview webhook
# 따라서 PID kill이 필수 1순위.
# 2026-04-26 실증 사고 후 신설 (SKILL.md "끄기" 절차 자동화).
# --lock 옵션: 다른 worktree 세션이 동시에 ralph spawn 중일 때, runner 파일을 .LOCKED로 이름 변경하여 영구 차단.

set -euo pipefail

LOCK_MODE=0
DISABLE_MODE=0
for arg in "$@"; do
  case "$arg" in
    --lock)    LOCK_MODE=1 ;;
    --disable) DISABLE_MODE=1 ;;
    -h|--help)
      echo "Usage: $0 [--lock] [--disable]"
      echo "  --lock      runner 파일을 .LOCKED로 이름 변경 (다중 worktree 세션 spawn 차단)"
      echo "  --disable   LaunchAgent를 disabled 상태로 등록 (1시간 후 자동 부활 영구 차단)"
      echo "              복구: launchctl enable gui/\$(id -u)/ai.jarvis.interview-ralph"
      exit 0 ;;
  esac
done

PATTERN="interview-ralph-runner"
RUNNER_PATH="$HOME/.openclaw-data/jarvis/infra/scripts/interview-ralph-runner.mjs"

echo "🔍 진행 중 ralph runner 검색..."
PIDS=$(pgrep -f "$PATTERN" || true)

if [ -z "$PIDS" ]; then
  echo "🟢 ralph 정지 상태 — 죽일 process 없음."
  if [ "$LOCK_MODE" = "0" ]; then
    exit 0
  fi
  echo "→ --lock 모드: 정지 상태이지만 spawn 차단을 위해 runner lock 진행..."
fi

if [ -n "$PIDS" ]; then
echo "🔴 발견된 PID: $PIDS"
echo "→ SIGTERM 송출..."
echo "$PIDS" | xargs kill 2>/dev/null || true

# 2026-04-26 결함 수정: 단일 사이클로는 child spawn 못 잡음.
# 5초 동안 polling 하면서 재spawn 발견 시 즉시 SIGKILL.
DEADLINE=$(($(date +%s) + 8))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  CUR=$(pgrep -f "$PATTERN" || true)
  [ -z "$CUR" ] && break
  echo "⚠️  잔존/신규 PID: $CUR — SIGKILL..."
  echo "$CUR" | xargs kill -9 2>/dev/null || true
  sleep 1
done

FINAL=$(pgrep -f "$PATTERN" || true)
if [ -z "$FINAL" ]; then
  echo "✅ ralph 종료 완료 (재spawn 8초 폴링 통과)."
else
  echo "❌ 일부 process 잔존: $FINAL — 수동 점검 필요."
  exit 1
fi
fi  # end of if [ -n "$PIDS" ]

UID_VAL=$(id -u)
if launchctl list 2>/dev/null | grep -q "ai.jarvis.interview-ralph"; then
  echo "→ LaunchAgent bootout..."
  launchctl bootout "gui/${UID_VAL}/ai.jarvis.interview-ralph" 2>/dev/null || true
  echo "✅ LaunchAgent 해제."
fi

if [ "$DISABLE_MODE" = "1" ]; then
  echo "→ LaunchAgent disable (1시간 자동 부활 영구 차단)..."
  launchctl disable "gui/${UID_VAL}/ai.jarvis.interview-ralph" 2>/dev/null || true
  echo "✅ Disabled — 복구 시: launchctl enable gui/${UID_VAL}/ai.jarvis.interview-ralph"
fi

if [ "$LOCK_MODE" = "1" ]; then
  if [ -f "$RUNNER_PATH" ]; then
    echo "→ runner 파일 lock (다중 worktree 세션 spawn 차단)..."
    mv "$RUNNER_PATH" "${RUNNER_PATH}.LOCKED"
    echo "✅ runner LOCKED — 복구: mv ${RUNNER_PATH}.LOCKED ${RUNNER_PATH}"
  elif [ -f "${RUNNER_PATH}.LOCKED" ]; then
    echo "ℹ️  runner 이미 LOCKED 상태."
  else
    echo "⚠️  runner 파일을 찾을 수 없음: $RUNNER_PATH"
  fi
fi

echo ""
echo "📂 state 파일은 보존 (재시작 시 누적 사용):"
ls -la ~/.openclaw-data/jarvis/runtime/state/ralph-*.{json,jsonl} 2>/dev/null | awk '{print "   " $NF}' || echo "   (state 파일 없음 — 첫 라운드 미완)"
