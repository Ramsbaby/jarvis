#!/bin/bash
# sap-exam-bot-precheck.sh — SAP 시험 전 디스코드 봇 사전점검 + 자가치유 + jarvis-dev 알림
# 일회성 LaunchAgent(ai.jarvis.sap-exam-precheck)가 2026-07-05 08:20 KST에 실행.
# 검증: LaunchAgent 로드 / 봇 프로세스 / 최근 치명 에러 / Claude 인증 / 디스크·메모리
# 불건강 시: 봇 자동 재시작(kickstart) 후 재검. 결과를 jarvis-dev로 송출. 실행 후 자기 자신(LA) 제거.
set -uo pipefail

LABEL="ai.jarvis.sap-exam-precheck"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
ENV_FILE="$HOME/jarvis/runtime/.env"
LOG="$HOME/jarvis/runtime/logs/sap-exam-precheck.log"
LEDGER="$HOME/jarvis/runtime/ledger/bot-response-bus.jsonl"
BOTLOG="$HOME/jarvis/runtime/logs/discord-bot.jsonl"
CH_DEV="1469905074661757049"   # jarvis-dev
BOT_LABEL="ai.jarvis.discord-bot"
MODE="${1:-scheduled}"          # scheduled | test

ts() { date '+%Y-%m-%d %H:%M:%S KST'; }
logline() { echo "[$(ts)] $*" >> "$LOG"; }

# --- DISCORD_TOKEN 만 추출 (값 미출력, 전체 source 안 함) ---
DISCORD_TOKEN=""
if [ -f "$ENV_FILE" ]; then
  DISCORD_TOKEN="$(grep -E '^DISCORD_TOKEN=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
  DISCORD_TOKEN="${DISCORD_TOKEN%\"}"; DISCORD_TOKEN="${DISCORD_TOKEN#\"}"
  DISCORD_TOKEN="${DISCORD_TOKEN%\'}"; DISCORD_TOKEN="${DISCORD_TOKEN#\'}"
  DISCORD_TOKEN="${DISCORD_TOKEN// /}"
fi

send_dev() {  # $1 = content (마크다운)
  local content="$1"
  if [ -z "$DISCORD_TOKEN" ]; then logline "WARN: DISCORD_TOKEN 없음 — 송출 생략"; return 0; fi
  local payload
  payload=$(python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1]}))' "$content")
  curl -s -o /dev/null -w '%{http_code}' -X POST \
    "https://discord.com/api/v10/channels/${CH_DEV}/messages" \
    -H "Authorization: Bot ${DISCORD_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$payload" 2>/dev/null
}

# ===== 헬스 체크 =====
# 권위 신호 = 봇 프로세스 존재(pgrep). launchctl은 참고용(pipefail+SIGPIPE 오판 방지 위해 변수 캡처 후 grep).
FAILS=()
OK=()

proc_up() { pgrep -f "discord-bot.js" >/dev/null 2>&1; }
la_loaded() { grep -q "$BOT_LABEL" <<<"$LC_LIST"; }

LC_LIST="$(launchctl list 2>/dev/null || true)"

# 1) 봇 프로세스 (권위 신호)
if proc_up; then OK+=("봇 프로세스 살아있음"); else FAILS+=("봇 프로세스 없음"); fi
# 2) LaunchAgent 로드 (참고)
if la_loaded; then OK+=("LaunchAgent 로드됨"); else OK+=("LaunchAgent 목록 미확인 — 프로세스 기준 판정"); fi

# --- 봇 프로세스가 정말 없을 때만 자가치유 (멀쩡한 봇 오재시작 방지) ---
if ! proc_up; then
  logline "봇 프로세스 없음 → kickstart 재시작 시도"
  launchctl kickstart -k "gui/$(id -u)/${BOT_LABEL}" 2>>"$LOG" || true
  sleep 20
  LC_LIST="$(launchctl list 2>/dev/null || true)"
  if proc_up; then OK+=("봇 프로세스 복구됨[재시작 후]"); else FAILS+=("봇 프로세스 재시작 실패"); fi
fi

# 3) 최근 치명 에러 (마지막 100줄)
ERRC=$(tail -100 "$BOTLOG" 2>/dev/null | grep -acE '"level":"error"|fatal|uncaughtException|crash' || true)
if [ "${ERRC:-0}" -eq 0 ]; then OK+=("최근 치명 에러 0"); else OK+=("최근 에러 ${ERRC}건[경미]"); fi

# 4) Claude 인증 유효성 (accessToken으로 /v1/models 조회 — refresh 호출 안 함)
CRED="$HOME/.claude/.credentials.json"
CLAUDE_OK="미확인"
if [ -f "$CRED" ]; then
  ATOK="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["claudeAiOauth"]["accessToken"])' "$CRED" 2>/dev/null || true)"
  if [ -n "${ATOK:-}" ]; then
    HC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://api.anthropic.com/v1/models \
      -H "Authorization: Bearer ${ATOK}" -H "anthropic-beta: oauth-2025-04-20" -H "anthropic-version: 2023-06-01" 2>/dev/null || echo "000")
    if [ "$HC" = "200" ]; then CLAUDE_OK="정상(200)"; OK+=("Claude 인증 정상"); else CLAUDE_OK="이상(HTTP $HC)"; FAILS+=("Claude 인증 이상 HTTP $HC"); fi
  fi
fi

# 5) 디스크·메모리
DISK_USE=$(df -h / 2>/dev/null | awk 'NR==2{print $5}')
MEM_FREE=$(vm_stat 2>/dev/null | awk '/Pages free/{gsub("\\.","",$3); printf "%.0f", $3*4096/1024/1024}')
OK+=("디스크 사용 ${DISK_USE:-?} / 여유메모리 ${MEM_FREE:-?}MB")

# 6) 최근 성공 응답
LAST_OK=$(tail -30 "$LEDGER" 2>/dev/null | python3 -c "
import sys,json
last='기록없음'
for l in sys.stdin:
  try:
    d=json.loads(l)
    if not d.get('is_error'): last=d.get('ts','')[:19].replace('T',' ')+' ('+d.get('channel','')+')'
  except: pass
print(last)
" 2>/dev/null || echo "확인불가")
OK+=("마지막 성공 응답: ${LAST_OK}")

# ===== 결과 조립 =====
if [ "${#FAILS[@]}" -eq 0 ]; then
  HEAD="✅ **SAP 시험 봇 사전점검 — 정상**"
  VERDICT="봇이 준비됐습니다. 스크린샷 문제 올리시면 \`정답: X\`로 바로 답합니다. 화이팅입니다, 주인님."
else
  HEAD="🚨 **SAP 시험 봇 사전점검 — 조치 필요**"
  VERDICT="자동 재시작을 시도했습니다. 미해결 항목: ${FAILS[*]} — 즉시 확인 권장."
fi

TAG=""
[ "$MODE" = "test" ] && TAG=" _(사전 테스트 실행 — 실제 점검은 내일 08:20)_"

BODY="${HEAD}${TAG}
$(printf -- '- %s\n' "${OK[@]}")
$(if [ "${#FAILS[@]}" -gt 0 ]; then printf -- '- ⚠️ %s\n' "${FAILS[@]}"; fi)
${VERDICT}
_점검 시각: $(ts)_"

logline "결과: FAILS=${#FAILS[@]} Claude=$CLAUDE_OK disk=$DISK_USE"
HTTP=$(send_dev "$BODY")
logline "jarvis-dev 송출 HTTP=$HTTP"

# ===== 자기 자신(LaunchAgent) 제거 (scheduled 모드에서만, 일회성) =====
if [ "$MODE" = "scheduled" ]; then
  ( sleep 5; launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null; rm -f "$PLIST"; echo "[$(ts)] self-clean 완료" >> "$LOG" ) &
fi

exit 0
