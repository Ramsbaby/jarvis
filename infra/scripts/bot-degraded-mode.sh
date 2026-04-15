#!/usr/bin/env bash
# bot-degraded-mode.sh — Discord bot L3 Degraded Mode 진입/복구
# 트리거: watchdog.sh가 연속 3회 재시작 실패 감지 시 호출
set -euo pipefail

JARVIS_DIR="$HOME/.jarvis"
source "${JARVIS_DIR}/lib/compat.sh" 2>/dev/null || {
  IS_MACOS=false; IS_LINUX=false
  case "$(uname -s)" in Darwin) IS_MACOS=true ;; Linux) IS_LINUX=true ;; esac
}
STATE_FILE="$JARVIS_DIR/state/degraded-mode.json"
LOG="$JARVIS_DIR/logs/degraded-mode.log"
MONITORING_CONFIG="$JARVIS_DIR/config/monitoring.json"
DISCORD_SERVICE="${DISCORD_SERVICE:-ai.jarvis.discord-bot}"

log() { echo "[$(date '+%H:%M:%S')] [DEGRADED] $*" | tee -a "$LOG"; }

# ntfy 직접 푸시 (Discord bot 없이도 알림 가능)
ntfy_push() {
  local msg="$1" priority="${2:-high}"
  local topic
  topic=$(python3 -c "import json; print(json.load(open('$MONITORING_CONFIG')).get('ntfy',{}).get('topic',''))" 2>/dev/null || echo "")
  if [[ -z "$topic" ]]; then return 0; fi
  curl -sf --max-time 5 -X POST "https://ntfy.sh/$topic" \
    -H "Priority: $priority" \
    -H "Title: Jarvis Degraded Mode" \
    -d "$msg" >/dev/null 2>&1 || true
}

enter_degraded() {
  log "L3 진입 — Discord bot 3회 재시작 실패"
  local entered_at
  entered_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  python3 -c "import json; f=open('$STATE_FILE','w'); json.dump({'active':True,'entered_at':'$entered_at','level':3},f)" 2>/dev/null || \
    echo "{\"active\":true,\"entered_at\":\"$entered_at\",\"level\":3}" > "$STATE_FILE"
  ntfy_push "Discord bot 복구 실패 — Degraded Mode 진입. ntfy 직접 알림만 동작." "urgent"
  log "ntfy 직접 알림 활성화, Discord 기능 일시 중단"
}

check_recovery() {
  # Discord bot 프로세스 정상 여부 확인
  local pid=""
  local found=false
  if $IS_MACOS; then
    if launchctl list 2>/dev/null | grep -q "$DISCORD_SERVICE"; then
      pid=$(launchctl list 2>/dev/null | grep "$DISCORD_SERVICE" | awk '{print $1}')
      if [[ "$pid" != "-" && -n "$pid" ]]; then found=true; fi
    fi
  else
    pid=$(pgrep -f "discord-bot.js" 2>/dev/null | head -1 || echo "")
    if [[ -n "$pid" ]]; then found=true; fi
  fi
  if $found; then
    if [[ "$pid" != "-" && -n "$pid" ]]; then
      log "복구 감지 — Discord bot PID $pid 정상"
      python3 -c "import json; f=open('$STATE_FILE','w'); json.dump({'active':False,'recovered_at':'$(date -u +%Y-%m-%dT%H:%M:%SZ)'},f)" 2>/dev/null || \
        echo "{\"active\":false,\"recovered_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$STATE_FILE"
      ntfy_push "Degraded Mode 해제 — Discord bot 정상 복구" "default"
      return 0
    fi
  fi
  return 1
}

is_degraded() {
  if [[ ! -f "$STATE_FILE" ]]; then return 1; fi
  python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); sys.exit(0 if d.get('active') else 1)" 2>/dev/null
}

CMD="${1:-status}"
case "$CMD" in
  enter)   enter_degraded ;;
  recover) check_recovery ;;
  status)
    if is_degraded; then
      entered=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('entered_at','unknown'))" 2>/dev/null)
      log "현재 L3 Degraded Mode 활성 (진입: $entered)"
      exit 1
    else
      log "정상 모드"
      exit 0
    fi
    ;;
  escalate)
    # L4: Degraded Mode 30분 초과 시 에스컬레이션
    if ! is_degraded; then log "Degraded Mode 아님, 에스컬레이션 불필요"; exit 0; fi
    entered=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('entered_at',''))" 2>/dev/null || echo "")
    if [[ -z "$entered" ]]; then log "entered_at 없음, 스킵"; exit 0; fi
    # macOS date -d 미지원 → python3으로 계산
    elapsed_min=$(python3 -c "
from datetime import datetime, timezone
entered = datetime.fromisoformat('$entered'.replace('Z','+00:00'))
now = datetime.now(timezone.utc)
print(int((now - entered).total_seconds() / 60))
" 2>/dev/null || echo "0")
    if [[ $elapsed_min -lt 30 ]]; then log "진입 ${elapsed_min}분 경과 — 30분 미달, 에스컬레이션 보류"; exit 0; fi
    # 쿨다운 체크 — 30분 내 중복 발송 방지
    _esc_cooldown="$JARVIS_DIR/state/l4-escalation-last.txt"
    _now_ep=$(date +%s)
    _last_ep=$(cat "$_esc_cooldown" 2>/dev/null || echo "0")
    _el=$(( _now_ep - _last_ep ))
    if (( _el < 1800 )); then
      log "쿨다운 중 ($(( (1800 - _el) / 60 ))분 남음) — 중복 발송 생략"
      exit 0
    fi
    echo "$_now_ep" > "$_esc_cooldown"
    webhook=$(python3 -c "
import json
d=json.load(open('$MONITORING_CONFIG'))
w=d.get('webhooks',{})
print(w.get('jarvis-ceo') or w.get('jarvis-system') or w.get('jarvis',''))
" 2>/dev/null || echo "")
    if [[ -n "$webhook" ]]; then
      curl -sf --max-time 5 -X POST "$webhook" \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"[L4 에스컬레이션] Degraded Mode ${elapsed_min}분 지속. 즉각 확인 필요.\"}" >/dev/null 2>&1 || true
    fi
    ntfy_push "L4 에스컬레이션: Degraded Mode ${elapsed_min}분 지속" "max"
    log "L4 에스컬레이션 전송 완료 (${elapsed_min}분 경과)"
    ;;
  *)
    echo "Usage: $0 {enter|recover|status|escalate}"
    exit 1
    ;;
esac
