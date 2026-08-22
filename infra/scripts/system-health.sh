#!/usr/bin/env bash
# system-health.sh — 시스템 헬스체크 (LLM 호출 없음)
# 정상이면 exit 0 (조용히 종료), 이상 감지 시 Discord 직접 알림
# schedule: */60 * * * *
set -euo pipefail

# cron 환경에서 PATH 재확인 (macOS 크론은 /usr/bin:/bin:/usr/sbin:/sbin만 제공)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
STATE_DIR="${BOT_HOME}/state"
LOGS_DIR="${BOT_HOME}/logs"
HEALTH_FILE="${STATE_DIR}/health.json"
MONITORING_JSON="${BOT_HOME}/config/monitoring.json"
LOG="${LOGS_DIR}/system-health.log"

mkdir -p "${STATE_DIR}" "${LOGS_DIR}"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}"; }

# ── 1. 메트릭 수집 ────────────────────────────────────────────────────────────
# 디스크 사용률
if command -v df >/dev/null 2>&1; then
    DISK_PCT=$(df / 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print int($5)}' || echo "0")
else
    DISK_PCT="0"
fi
log "METRIC: disk=${DISK_PCT}%"

# CPU 로드 — macOS: "load averages: 2.85 3.70 3.78" → 1분 평균 (NF-2)
if command -v uptime >/dev/null 2>&1; then
    CPU_LOAD=$(uptime 2>/dev/null | awk '{v=$(NF-2); gsub(/,/,"",v); print v}' || echo "0")
else
    CPU_LOAD="0"
fi
log "METRIC: cpu_load=${CPU_LOAD}"

# 메모리 여유율 — memory_pressure 없으면 vm_stat fallback
MEM_FREE_PCT="50"
if command -v memory_pressure >/dev/null 2>&1; then
    MEM_FREE_PCT=$(memory_pressure 2>/dev/null \
        | awk '/System-wide memory free percentage/{gsub(/%/,"",$NF); print int($NF)}' \
        || echo "50")
    log "METRIC: memory_free=${MEM_FREE_PCT}% (via memory_pressure)"
elif command -v vm_stat >/dev/null 2>&1; then
    MEM_FREE_PCT=$(vm_stat 2>/dev/null \
        | awk '/Pages free/{free=$3} /Pages wired/{wired=$4} END{if (free+wired>0) printf "%d", free/(free+wired)*100; else print "50"}' \
        || echo "50")
    log "METRIC: memory_free=${MEM_FREE_PCT}% (via vm_stat)"
else
    log "METRIC: memory_free=50 (default, no tools available)"
fi

# 크론 실패 (최근 200줄)
if [[ -f "${LOGS_DIR}/cron.log" ]]; then
    # [2026-08-20 수정] grep -c 는 매칭 0건이면 "0" 을 출력하면서 exit 1 을 낸다.
    # 기존의 `|| echo "0"` 이 그 위에 "0" 을 한 줄 더 붙여 CRON_FAILS 가 "0\n0" 이 됐고,
    # 105번 줄 (( CRON_FAILS >= 3 )) 이 매시간 syntax error 로 터졌다(로그 오염 + JSON 파손 위험).
    # 매칭이 0건일 때만 발현하는 조건부 버그였다.
    CRON_FAILS=$(tail -200 "${LOGS_DIR}/cron.log" 2>/dev/null | grep -cE 'ABORTED|FAILED' || true)
    CRON_FAILS="${CRON_FAILS:-0}"
    log "METRIC: cron_fails=${CRON_FAILS}"
else
    CRON_FAILS="0"
    log "METRIC: cron_fails=0 (log not found)"
fi

# Discord bot 프로세스 확인 (launchctl 우선, pgrep fallback)
BOT_UP=0
if command -v launchctl >/dev/null 2>&1; then
    if launchctl list 2>/dev/null | grep -q 'ai.jarvis.discord-bot'; then
        BOT_UP=1
        log "METRIC: bot_status=up (via launchctl)"
    elif command -v pgrep >/dev/null 2>&1 && pgrep -f 'discord-bot\.js' >/dev/null 2>&1; then
        BOT_UP=1
        log "METRIC: bot_status=up (via pgrep)"
    else
        BOT_UP=0
        log "METRIC: bot_status=down"
    fi
else
    log "METRIC: bot_status=unknown (launchctl not available)"
fi

# ── 2. health.json 갱신 (항상) ───────────────────────────────────────────────
mkdir -p "$(dirname "$HEALTH_FILE")"
if ! cat > "${HEALTH_FILE}" << JSON_EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "disk_percent": ${DISK_PCT},
  "mem_free_percent": ${MEM_FREE_PCT},
  "cpu_load_1m": "${CPU_LOAD}",
  "cron_recent_failures": ${CRON_FAILS},
  "discord_bot_up": ${BOT_UP}
}
JSON_EOF
then
    log "ERROR: Failed to write health.json to ${HEALTH_FILE}"
    exit 1
fi
log "health.json updated successfully"

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

# ── 5. 이상 감지 → Discord 라우팅으로 전송 ─────────────────────────────────
log "ALERT(${SEVERITY}) — ${ALERTS[*]}"

# discord_route를 통한 중앙화된 발송
_INFRA_DIR="${HOME}/jarvis/infra"
_ROUTE_SH="${_INFRA_DIR}/lib/discord-route.sh"

if [[ ! -f "$_ROUTE_SH" ]]; then
    log "WARN: discord-route.sh 파일 없음 (path: ${_ROUTE_SH}) — 로컬 파일만 기록 후 정상 종료"
    exit 0
fi

if ! source "$_ROUTE_SH" 2>/dev/null; then
    log "WARN: discord-route.sh 로드 실패 (구문/실행 오류) — 로컬 파일만 기록 후 정상 종료"
    exit 0
fi

# discord_route 함수 존재 확인
if ! declare -f discord_route >/dev/null 2>&1; then
    log "WARN: discord_route 함수 로드 실패 — 로컬 파일만 기록 후 정상 종료"
    exit 0
fi

TITLE=$( [[ "$SEVERITY" == "crit" ]] && echo "🚨 시스템 위험 감지" || echo "⚠️ 시스템 경고" )
SUMMARY="디스크 ${DISK_PCT}% / 메모리 여유 ${MEM_FREE_PCT}% / CPU ${CPU_LOAD} / 크론 실패 ${CRON_FAILS}건"
TS=$(date '+%Y-%m-%d %H:%M KST')

# discord_route 포맷: discord_route <critical|info|retro> "<제목>" "항목1,항목2,..."
_severity_route=$( [[ "$SEVERITY" == "crit" ]] && echo "critical" || echo "info" )
_alerts_text=$(printf "%s / " "${ALERTS[@]}" | sed 's/ \/ $//')

if ! discord_route "$_severity_route" "$TITLE" "alerts=${_alerts_text},summary=${SUMMARY},timestamp=${TS}" 2>/dev/null; then
    log "WARN: Discord 라우팅 실패 (로컬 파일만 기록: ${TITLE})"
else
    log "Discord 알림 전송 완료: ${TITLE}"
fi

# ── 6. cron-status.json 갱신 ──────────────────────────────────────────────
# 자동 감지 시스템이 STALE 경고를 내지 않도록 상태 파일 최신화
CRON_STATUS_FILE="${STATE_DIR}/cron-status.json"
if [[ -f "$CRON_STATUS_FILE" ]]; then
    # 기존 파일의 구조 유지하면서 타임스탠프만 업데이트
    jq ".ts = \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"" "$CRON_STATUS_FILE" > "${CRON_STATUS_FILE}.tmp" 2>/dev/null && \
        mv "${CRON_STATUS_FILE}.tmp" "$CRON_STATUS_FILE" && \
        log "cron-status.json updated" || \
        log "WARN: cron-status.json update failed (jq error)"
fi

# health.json과 log만으로도 성공 처리 (Discord 알림은 선택사항)
exit 0