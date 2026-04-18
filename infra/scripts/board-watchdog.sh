#!/usr/bin/env bash
# board-watchdog.sh
#
# jarvis-board 3중 헬스체크 + auto-recovery.
#
#   1) Local   — http://localhost:3100/api/health (Next.js 서버)
#   2) Tunnel  — cloudflared tunnel info <tunnel-name> (active connector ≥1)
#   3) External — $BOARD_EXT_URL (2xx/3xx/4xx 응답)
#
# 실패 레이어 식별 후 해당 LaunchAgent만 kickstart. Discord 알림 24h 스로틀.
# 원장: $HOME/jarvis/runtime/state/board-watchdog.jsonl (10MB rotate).
#
# 환경변수:
#   BOARD_EXT_URL   외부 URL (필수). ~/.jarvis/.env 또는 shell profile에서 export.
#   BOARD_TUNNEL_NAME cloudflared 터널 이름 (기본: jarvis-board)
#
# LaunchAgent ai.jarvis.board-watchdog (StartInterval 300)로 기동.
set -euo pipefail

# ~/.jarvis/.env 자동 로드 (로컬 운영용 env var)
if [ -f "${HOME}/.jarvis/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${HOME}/.jarvis/.env"
  set +a
fi

LEDGER="${HOME}/jarvis/runtime/state/board-watchdog.jsonl"
THROTTLE_DIR="${HOME}/jarvis/runtime/state/board-watchdog-throttle"
LOCAL_URL="http://localhost:3100/api/health"
FALLBACK_URL="http://localhost:3100/"
EXT_URL="${BOARD_EXT_URL:-}"
TUNNEL_NAME="${BOARD_TUNNEL_NAME:-jarvis-board}"

if [ -z "$EXT_URL" ]; then
  echo "[ERROR] BOARD_EXT_URL 환경변수 미설정. ~/.jarvis/.env 에 추가하세요." >&2
  exit 1
fi
TS="$(date +%Y-%m-%dT%H:%M:%S%z)"
EPOCH="$(date +%s)"

mkdir -p "$(dirname "$LEDGER")" "$THROTTLE_DIR"

emit() {
  printf '{"ts":"%s","layer":"%s","status":"%s","detail":"%s"}\n' \
    "$TS" "$1" "$2" "$3" >> "$LEDGER"
}

alert_throttled() {
  local layer="$1" detail="$2"
  local key marker last
  key="$(printf '%s' "$layer" | shasum -a 1 | awk '{print $1}')"
  marker="${THROTTLE_DIR}/${key}"
  if [[ -f "$marker" ]]; then
    last=$(cat "$marker" 2>/dev/null || echo 0)
    (( EPOCH - last < 86400 )) && return 0
  fi
  if [[ -f "${HOME}/jarvis/runtime/scripts/discord-visual.mjs" ]]; then
    /opt/homebrew/bin/node "${HOME}/jarvis/runtime/scripts/discord-visual.mjs" \
      --type stats \
      --data "{\"title\":\"🚨 jarvis-board ${layer} down — auto-recovering\",\"data\":{\"layer\":\"${layer}\",\"detail\":\"${detail}\",\"ledger\":\"${LEDGER}\"},\"timestamp\":\"${TS}\"}" \
      --channel jarvis-system 2>/dev/null || true
  fi
  echo "$EPOCH" > "$marker"
}

kickstart() {
  local label="$1"
  launchctl kickstart -k "gui/$(id -u)/${label}" 2>&1 | head -1 || true
}

failures=0
recoveries=0

# Layer 1: local server (고부하 재부팅 대비 retry with backoff)
local_ok=false
for attempt in 1 2 3; do
  if curl -s -f -o /dev/null --max-time 5 "$LOCAL_URL" 2>/dev/null \
     || curl -s -f -o /dev/null --max-time 5 "$FALLBACK_URL" 2>/dev/null; then
    local_ok=true
    break
  fi
  # 1차 실패 시 15초 grace (재부팅 직후 board 기동 지연 대응)
  [[ $attempt -lt 3 ]] && sleep 15
done
if $local_ok; then
  emit "local" "ok" ":3100 responding"
else
  emit "local" "fail" "3 attempts over 30s failed"
  alert_throttled "local" "Next.js :3100 not responding after 3 retries"
  kickstart "ai.jarvis.board"
  failures=$((failures+1))
  recoveries=$((recoveries+1))
fi

# Layer 2: tunnel connector
connectors=$(cloudflared tunnel info "$TUNNEL_NAME" 2>/dev/null | grep -cE "^[0-9a-f]{8}-" || echo 0)
if (( connectors == 0 )); then
  emit "tunnel" "fail" "0 active connectors"
  alert_throttled "tunnel" "cloudflared tunnel has 0 active connectors"
  kickstart "ai.jarvis.cloudflared-tunnel"
  failures=$((failures+1))
  recoveries=$((recoveries+1))
else
  emit "tunnel" "ok" "${connectors} active connectors"
fi

# Layer 3: external
ext_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$EXT_URL" 2>/dev/null || echo 000)
if [[ "$ext_code" == "000" ]] || [[ "$ext_code" == 5?? ]]; then
  emit "external" "fail" "http=${ext_code}"
  # local+tunnel 둘 다 ok인데 external fail이면 DNS/CF 쪽 문제. kickstart 불가, 알림만.
  alert_throttled "external" "${EXT_URL} returned ${ext_code}"
  failures=$((failures+1))
else
  emit "external" "ok" "http=${ext_code}"
fi

# Rotation
if [[ -f "$LEDGER" ]]; then
  size=$(stat -f "%z" "$LEDGER" 2>/dev/null || echo 0)
  if (( size > 10485760 )); then
    gzip -c "$LEDGER" > "${LEDGER%.jsonl}-$(date +%Y%m%d).jsonl.gz"
    : > "$LEDGER"
  fi
fi

if (( failures == 0 )); then
  echo "✅ board healthy (all 3 layers)"
  exit 0
elif (( recoveries > 0 )); then
  echo "🔧 ${failures} failure(s), kickstarted ${recoveries} LaunchAgent(s)"
  exit 1
else
  echo "⚠️  ${failures} failure(s), no recoverable layer"
  exit 2
fi