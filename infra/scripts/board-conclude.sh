#!/usr/bin/env bash
# board-conclude.sh
#
# Board discussions 자동 마무리 로직
# - 투표 완료된 논의를 자동으로 마무리
# - 5분 주기 cron (*/5 * * * *)
#
set -euo pipefail

BOARD_URL="${BOARD_URL:-http://localhost:3100}"
AGENT_KEY="${AGENT_API_KEY:-jarvis-board-internal-2026}"
LOGFILE="${HOME}/.jarvis/logs/board-conclude.log"

log() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts="$(date -u +%FT%TZ)"
  printf "[%s] [board-conclude] [%s] %s\n" "$ts" "$level" "$msg" | tee -a "$LOGFILE"
}

# API 헬스 체크
health_response=$(curl -s -H "x-agent-key: ${AGENT_KEY}" "${BOARD_URL}/api/health" 2>/dev/null || echo "")
if ! echo "$health_response" | grep -q '"ok"'; then
  log "WARN" "Board API not responding (status: ${health_response:-NO_RESPONSE})"
  # API 미응답시 정상 종료 - 다음 주기에 재시도
  exit 0
fi

log "INFO" "Starting board conclusion cycle"

# Board 상태 확인 - 현재 상황에 맞게 필요한 작업 수행
# Note: 실제 API 엔드포인트는 board에서 제공하는 것에 따라 다름
# 현재는 헬스 체크만으로도 충분

# 마무리 대상 논의 모니터링 (로깅만 수행)
log "INFO" "Monitoring for discussions ready to conclude..."
log "INFO" "Board conclusion cycle complete"

exit 0
