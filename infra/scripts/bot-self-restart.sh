#!/usr/bin/env bash
# bot-self-restart.sh — 봇 자기재시작 (setsid 분리 실행)
#
# 직접 launchctl을 호출하면 현재 claude 세션이 SIGTERM으로 죽음.
# 이 스크립트는 setsid로 완전히 분리된 프로세스에서 15초 후 실행.
# 현재 응답이 Discord에 전송되고 난 뒤 자동으로 재시작됨.
#
# 사용법 (claude -p Bash 도구에서):
#   bash ~/jarvis/runtime/scripts/bot-self-restart.sh
#   bash ~/jarvis/runtime/scripts/bot-self-restart.sh "재시작 이유"

set -euo pipefail
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/jarvis/runtime}}/lib/compat.sh" 2>/dev/null || true
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
REASON="${1:-manual restart}"
LOG="${BOT_HOME}/logs/bot-self-restart.log"
STAMP=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$(dirname "$LOG")"

# 호출자 추적: 부모 프로세스 체인 기록
CALLER_PID="${PPID:-?}"
CALLER_CMD=$(ps -p "$CALLER_PID" -o args= 2>/dev/null | head -c 200 || echo "unknown")
GRANDPARENT_PID=$(ps -p "$CALLER_PID" -o ppid= 2>/dev/null | tr -d ' ' || echo "?")
GRANDPARENT_CMD=$(ps -p "$GRANDPARENT_PID" -o args= 2>/dev/null | head -c 200 || echo "unknown")

echo "[$STAMP] 재시작 요청: $REASON" >> "$LOG"
echo "[$STAMP]   호출자(PPID=$CALLER_PID): $CALLER_CMD" >> "$LOG"
echo "[$STAMP]   상위(PPID=$GRANDPARENT_PID): $GRANDPARENT_CMD" >> "$LOG"

# 활성 세션 체크 — 있으면 재시작 연기 (pending marker 기록)
ACTIVE_SESSION_FILE="${BOT_HOME}/state/active-session"
PENDING_RESTART_FILE="${BOT_HOME}/state/pending-deployment-restart"

if [[ -f "$ACTIVE_SESSION_FILE" ]]; then
  echo "[$STAMP] ⏸️  활성 세션 감지 — 재시작 보류 (pending-deployment-restart 마커 기록)" >> "$LOG"
  echo "$REASON" > "$PENDING_RESTART_FILE"
  echo "⏸️  현재 활성 세션이 있어 재시작을 연기했습니다."
  echo "세션 완료 후 자동으로 재시작됩니다. (이유: $REASON)"
  exit 0
fi

# 실행할 임시 스크립트를 파일로 생성 (단따옴표 이스케이프 문제 회피)
RUNNER="/tmp/jarvis-restart-$$.sh"
cat > "$RUNNER" <<INNER
#!/usr/bin/env bash
sleep 15
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 재시작 실행 중..." >> "${LOG}"
bash "${BOT_HOME}/scripts/deploy-with-smoke.sh" >> "${LOG}" 2>&1
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] 재시작 완료" >> "${LOG}"
rm -f "${RUNNER}"
INNER
chmod +x "$RUNNER"

# nohup으로 SIGHUP 무시 + 백그라운드 실행 → 봇이 죽어도 이 프로세스는 생존
# 15초 딜레이 → 현재 Discord 응답 전송 완료 후 재시작
(nohup bash "$RUNNER" > /dev/null 2>&1 &)

echo "✅ 봇 재시작 예약됨 (15초 후 실행). 로그: $LOG"