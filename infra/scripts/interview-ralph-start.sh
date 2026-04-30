#!/usr/bin/env bash
# interview-ralph-start.sh
# CLI 세션·터미널이 죽어도 살아남는 detached ralph runner.
# nohup + disown 조합으로 SIGHUP 무시 + 부모 process tree에서 분리.
# 라운드 도중 Claude Code 세션 종료해도 ralph는 자기 페이스대로 끝까지 진행.
# 2026-04-26 신설 (장시간 라운드를 토큰/세션과 무관하게 완주시키기 위함).
#
# Usage:
#   bash interview-ralph-start.sh                    # 기본 24문항 1라운드
#   bash interview-ralph-start.sh --limit 5          # 5문항 빠른 검증
#   bash interview-ralph-start.sh --round 4 --limit 24
#
# 상태 확인: pgrep -af interview-ralph-runner
# 강제 종료: bash interview-ralph-stop.sh

set -euo pipefail

# disabled 상태였으면 enable 자동 (stop --disable 후 재가동 시 자연스럽게)
launchctl enable "gui/$(id -u)/ai.jarvis.interview-ralph" 2>/dev/null || true

RUNNER="$HOME/jarvis/infra/scripts/interview-ralph-runner.mjs"
LOG_DIR="$HOME/jarvis/runtime/logs"
LOG_FILE="$LOG_DIR/interview-ralph-detached.log"

if [ ! -f "$RUNNER" ]; then
  echo "❌ runner 없음: $RUNNER (LOCKED 상태일 수 있음, mv 복구 필요)"
  exit 1
fi

if pgrep -f "interview-ralph-runner" >/dev/null 2>&1; then
  echo "⚠️ 이미 가동 중. 중복 spawn 방지 — 먼저 stop 하십시오:"
  pgrep -af "interview-ralph-runner"
  exit 1
fi

mkdir -p "$LOG_DIR"

# 기본 옵션 — concurrency=4, per-gap=2000 (2026-04-30 v4.77 기본값 상향)
DEFAULT_ARGS=(--apply-forbid --apply-insights --include-followups --include-misses --per-gap 2000 --incremental-every 5 --concurrency 4)

USER_ARGS=("$@")

# v4.47 (2026-04-27): INTERVIEW_ACTIVE_SCENARIO env 자동 감지 → --scenario 자동 추가.
# 중복 주입 방지: USER_ARGS에 이미 --scenario 있으면 skip (2026-04-30 v4.74 핫픽스).
if [ -f "$HOME/jarvis/runtime/.env" ]; then
  ACTIVE_SCN=$(grep -E "^INTERVIEW_ACTIVE_SCENARIO=" "$HOME/jarvis/runtime/.env" | cut -d= -f2 | tr -d '"' | tr -d "'" | head -1)
  # shellcheck disable=SC2199
  if [ -n "${ACTIVE_SCN:-}" ] && [[ ! " ${USER_ARGS[*]:-} " =~ " --scenario " ]]; then
    DEFAULT_ARGS+=(--scenario "$ACTIVE_SCN")
    echo "🎯 active scenario 감지: $ACTIVE_SCN (시나리오 모드 자동 활성)"
  fi
fi

echo "🚀 ralph detached 시동..."
echo "   runner: $RUNNER"
echo "   log: $LOG_FILE"
echo "   args: ${DEFAULT_ARGS[*]} ${USER_ARGS[*]:-}"
echo ""

# nohup + & + disown — SIGHUP 무시 + 셸 죽어도 살아남음
nohup /opt/homebrew/bin/node "$RUNNER" "${DEFAULT_ARGS[@]}" "${USER_ARGS[@]:-}" \
  >> "$LOG_FILE" 2>&1 &

PID=$!
disown $PID 2>/dev/null || true

sleep 2
if kill -0 $PID 2>/dev/null; then
  echo "✅ detached spawn 성공 — PID $PID"
  echo "   세션·터미널 종료해도 라운드는 끝까지 진행됩니다."
  echo ""
  echo "📊 진행 상황:"
  echo "   tail -f $LOG_FILE"
  echo "   curl -s http://127.0.0.1:7779/health  # verifier 헬스"
  echo "   discord #jarvis-interview 채널"
  echo ""
  echo "⏸ 종료:"
  echo "   bash $HOME/jarvis/runtime/scripts/interview-ralph-stop.sh"
else
  echo "❌ spawn 실패 — log 확인: $LOG_FILE"
  tail -20 "$LOG_FILE" 2>/dev/null
  exit 1
fi
