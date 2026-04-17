#!/usr/bin/env bash
# system-health.sh — 시스템 헬스체크 (LLM 호출 없음)
# 정상이면 exit 0 (조용히 종료), 이상 감지 시 Discord 직접 알림
# schedule: */60 * * * *
set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
STATE_DIR="${BOT_HOME}/state"
LOGS_DIR="${BOT_HOME}/logs"
HEALTH_FILE="${STATE_DIR}/health.json"
MONITORING_JSON="${BOT_HOME}/config/monitoring.json"
LOG="${LOGS_DIR}/system-health.log"

mkdir -p "${STATE_DIR}" "${LOGS_DIR}"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"; }

# ── 1. 메트릭 수집 ────────────────────────────────────────────────────────────
DISK_PCT=$(df / | awk 'NR==2{gsub(/%/,"",$5); print int($5)}' 2>/dev/null || echo "0")

# macOS: "load averages: 2.85 3.70 3.78" → 1분 평균 (NF-2)
CPU_LOAD=$(uptime | awk '{v=$(NF-2); gsub(/,/,"",v); print v}' 2>/dev/null || echo "0")

# 메모리 여유율 — memory_pressure 없으면 vm_stat fallback
if command -v memory_pressure &>/dev/null; then
    MEM_FREE_PCT=$(memory_pressure 2>/dev/null \
        | awk '/System-wide memory free percentage/{gsub(/%/,"",$NF); print int($NF)}' \
        || echo "50")
else
    MEM_FREE_PCT=$(vm_stat 2>/dev/null \
        | awk '/Pages free/{free=$3} /Pages wired/{wired=$4} END{printf "%d", free/(free+wired)*100}' \
        || echo "50")
fi

# 크론 실패 (최근 200줄)
CRON_FAILS=$(tail -200 "${LOGS_DIR}/cron.log" 2>/dev/null | grep -cE 'ABORTED|FAILED' || echo "0")

# Discord bot 프로세스 확인 (launchctl 우선, pgrep fallback)
if launchctl list 2>/dev/null | grep -q 'ai.jarvis.discord-bot'; then
    BOT_UP=1
elif pgrep -f 'discord-bot\.js' >/dev/null 2>&1; then
    BOT_UP=1
else
    BOT_UP=0
fi

# ── 2. health.json 갱신 (항상) ───────────────────────────────────────────────
cat > "${HEALTH_FILE}" << JSON_EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "disk_percent": ${DISK_PCT},
  "mem_free_percent": ${MEM_FREE_PCT},
  "cpu_load_1m": "${CPU_LOAD}",
  "cron_recent_failures": ${CRON_FAILS},
  "discord_bot_up": ${BOT_UP}
}
JSON_EOF

# ── 3. 임계값 판단 ───────────────────────────────────────────────────────────
ALERTS=()
SEVERITY="ok"

(( DISK_PCT >= 90 ))      && ALERTS+=("🔴 디스크 ${DISK_PCT}% (임계: 90%)") && SEVERITY="crit" || true
(( DISK_PCT >= 80 && DISK_PCT < 90 )) && ALERTS+=("⚠️ 디스크 ${DISK_PCT}%") && [[ "$SEVERITY" == "ok" ]] && SEVERITY="warn" || true
(( MEM_FREE_PCT < 10 ))   && ALERTS+=("🔴 메모리 여유 ${MEM_FREE_PCT}% (임계: 10%)") && SEVERITY="crit" || true
(( MEM_FREE_PCT < 20 && MEM_FREE_PCT >= 10 )) && ALERTS+=("⚠️ 메모리 여유 ${MEM_FREE_PCT}%") && [[ "$SEVERITY" == "ok" ]] && SEVERITY="warn" || true
(( CRON_FAILS >= 3 ))     && ALERTS+=("⚠️ 크론 최근 실패 ${CRON_FAILS}건") && [[ "$SEVERITY" == "ok" ]] && SEVERITY="warn" || true
(( BOT_UP == 0 ))         && ALERTS+=("🔴 discord-bot 프로세스 없음") && SEVERITY="crit" || true

# ── 4. 정상이면 조용히 종료 ──────────────────────────────────────────────────
if [[ "${#ALERTS[@]}" -eq 0 ]]; then
    log "OK — disk=${DISK_PCT}% mem_free=${MEM_FREE_PCT}% cpu=${CPU_LOAD} cron_fails=${CRON_FAILS}"
    exit 0
fi

# ── 5. 이상 감지 → Discord 직접 전송 (LLM 없음) ─────────────────────────────
log "ALERT(${SEVERITY}) — ${ALERTS[*]}"

WEBHOOK_URL=$(python3 -c "
import json, sys
d = json.load(open('${MONITORING_JSON}'))
print(d['webhooks'].get('jarvis-system', d.get('webhook',{}).get('url','')))
" 2>/dev/null) || { log "ERROR: webhook URL 조회 실패"; exit 0; }

[[ -z "$WEBHOOK_URL" ]] && { log "ERROR: webhook URL 비어있음"; exit 0; }

# 알림 라인 배열 → Python으로 전달
ALERT_JSON=$(python3 -c "
import json, sys
alerts = json.loads(sys.argv[1])
print(json.dumps(alerts))
" "$(printf '%s\n' "${ALERTS[@]}" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip().split('\n')))")")

TITLE=$( [[ "$SEVERITY" == "crit" ]] && echo "🚨 시스템 위험 감지" || echo "⚠️ 시스템 경고" )
SUMMARY="디스크 ${DISK_PCT}% / 메모리 여유 ${MEM_FREE_PCT}% / CPU ${CPU_LOAD} / 크론 실패 ${CRON_FAILS}건"
TS=$(date '+%Y-%m-%d %H:%M KST')

python3 - "${WEBHOOK_URL}" "${TITLE}" "${SUMMARY}" "${TS}" "${ALERT_JSON}" << 'PYEOF'
import json, urllib.request, sys

webhook, title, summary, ts, alert_json = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
alerts = json.loads(alert_json)

lines = [f"**{title}**"]
for a in alerts:
    lines.append(f"- {a}")
lines.append(f"- {summary}")
lines.append(f"_{ts}_")

payload = json.dumps({"content": "\n".join(lines)}).encode()
req = urllib.request.Request(
    webhook, data=payload,
    headers={"Content-Type": "application/json"}, method="POST"
)
try:
    urllib.request.urlopen(req, timeout=10)
    print("Discord alert sent")
except Exception as e:
    print(f"Discord send failed: {e}", file=sys.stderr)
PYEOF