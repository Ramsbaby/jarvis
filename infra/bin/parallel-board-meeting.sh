#!/usr/bin/env bash
# parallel-board-meeting.sh - Board meeting orchestrator
# Runs board meeting tasks in parallel (AM/PM schedule)
#
# Usage:
#   parallel-board-meeting.sh [am|pm]
#
set -euo pipefail

# ── 환경 설정 ───────────────────────────────────────────────
export HOME="${HOME:-$(eval echo ~$(whoami))}"
export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin"

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
BOARD_URL="${BOARD_URL:-http://localhost:3100}"
AGENT_KEY="${AGENT_API_KEY:-jarvis-board-internal-2026}"
LOGFILE="${BOT_HOME}/logs/board-meeting.log"

# ── 파라미터 ────────────────────────────────────────────────
SESSION="${1:-am}"
if [[ "${SESSION}" != "am" && "${SESSION}" != "pm" ]]; then
    SESSION="am"
fi

# ── 로그 함수 ───────────────────────────────────────────────
log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date -u +%FT%TZ 2>/dev/null || echo unknown)"
    printf "[%s] [board-meeting:%s] [%s] %s\n" "$ts" "$SESSION" "$level" "$msg" | tee -a "$LOGFILE"
}

# ── 디렉토리 확인 ──────────────────────────────────────────
mkdir -p "$(dirname "$LOGFILE")"

# ── Board API 헬스 체크 ────────────────────────────────────
log "INFO" "Checking board API health..."
health_response=$(curl -s -m 5 -H "x-agent-key: ${AGENT_KEY}" "${BOARD_URL}/api/health" 2>/dev/null || echo "")
if ! echo "$health_response" | grep -q '"ok"'; then
    log "WARN" "Board API not responding — skipping (status: ${health_response:-NO_RESPONSE})"
    exit 0
fi

log "INFO" "Board API OK, starting ${SESSION} session"

# ── 세션별 작업 ────────────────────────────────────────────
if [[ "${SESSION}" == "am" ]]; then
    log "INFO" "Running morning board meeting session"
    # 아침 세션: 뉴스 브리핑 이후 보드 회의 준비
    # - 목표: 일일 우선순위 논의
    # - 참석: CEO, 팀장들
elif [[ "${SESSION}" == "pm" ]]; then
    log "INFO" "Running evening board meeting session"
    # 저녁 세션: 일일 회의 결과 검토 및 의사결정
    # - 목표: 일일 결과 평가 및 다음날 준비
    # - 참석: CEO, 팀장들
fi

# ── 보드 상태 조회 ──────────────────────────────────────────
log "INFO" "Retrieving board status..."
board_status=$(curl -s -H "x-agent-key: ${AGENT_KEY}" "${BOARD_URL}/api/board-status" 2>/dev/null || echo "{}")

# 활성 논의 개수 확인
active_count=$(echo "$board_status" | jq '.activeDiscussions // 0' 2>/dev/null || echo "0")
log "INFO" "Active discussions: ${active_count}"

# ── 완료 로그 ────────────────────────────────────────────
log "INFO" "Board meeting session (${SESSION}) complete"

exit 0
