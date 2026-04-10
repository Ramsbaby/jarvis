#!/usr/bin/env bash
set -euo pipefail

REPORT_TYPE="${1:-daily}"
BOARD_URL="${BOARD_URL:-http://localhost:3100}"  # 로컬 실행 전용 — NAT loopback 우회
BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
LOG_FILE="${BOT_HOME}/logs/report-generate.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# REPORT_SECRET: 환경변수 우선, 없으면 .env.local에서 절대경로로 로드
ENV_FILE="${BOARD_DIR:-${BOT_HOME:-${HOME}/.local/share/jarvis}/board}/.env.local"
if [[ -z "${REPORT_SECRET:-}" ]] && [[ -f "$ENV_FILE" ]]; then
  REPORT_SECRET=$(grep '^REPORT_SECRET=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' || true)
fi

if [[ -z "${REPORT_SECRET:-}" ]]; then
  log "ERROR: REPORT_SECRET not set (env 없음, .env.local 로드 실패)"
  exit 1
fi

# Calculate period based on report type
TODAY=$(date '+%Y-%m-%d')
NOW=$(date '+%Y-%m-%d 23:59:59')

case "$REPORT_TYPE" in
  daily)
    PERIOD_START="${TODAY} 00:00:00"
    PERIOD_END="$NOW"
    ;;
  weekly)
    # Start of this week (Sunday or Monday - use 7 days ago)
    WEEK_START=$(date -v-6d '+%Y-%m-%d' 2>/dev/null || date --date='6 days ago' '+%Y-%m-%d')
    PERIOD_START="${WEEK_START} 00:00:00"
    PERIOD_END="$NOW"
    ;;
  monthly)
    MONTH_START="${TODAY:0:7}-01"
    PERIOD_START="${MONTH_START} 00:00:00"
    PERIOD_END="$NOW"
    ;;
  *)
    log "ERROR: Unknown report type: $REPORT_TYPE"
    exit 1
    ;;
esac

log "Generating $REPORT_TYPE report: $PERIOD_START ~ $PERIOD_END"

RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -H "x-agent-key: ${BOARD_API_KEY:-jarvis-internal}" \
  -d "{\"type\":\"${REPORT_TYPE}\",\"period_start\":\"${PERIOD_START}\",\"period_end\":\"${PERIOD_END}\"}" \
  "${BOARD_URL}/api/reports/generate?secret=${REPORT_SECRET}" \
  --max-time 60) || { log "ERROR: curl 실패 (네트워크/타임아웃)"; exit 1; }

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')  # macOS 호환 (head -n -1 BSD 미지원)

if [[ "$HTTP_CODE" == "200" ]]; then
  log "SUCCESS: $BODY"
else
  log "ERROR: HTTP $HTTP_CODE - $BODY"
  exit 1
fi
