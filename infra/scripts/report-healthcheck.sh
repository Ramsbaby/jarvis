#!/usr/bin/env bash
# 자비스 보고서가 THRESHOLD_HOURS 이상 생성 안 됐으면 Discord에 경보.
# 8일 무발화 같은 재발을 구조적으로 차단하기 위한 감시 크론.
#
# 환경변수:
#   DISCORD_WEBHOOK_CEO (필수) — .env.local에서 자동 로드
#   THRESHOLD_HOURS    (기본 30) — 일일 24h + 마진 6h
#   DRY_RUN            (기본 0)  — 1이면 Discord 호출 생략, 로그만
#   BOARD_DB           (기본 ~/jarvis-board/data/board.db)

set -euo pipefail

THRESHOLD_HOURS="${THRESHOLD_HOURS:-30}"
DRY_RUN="${DRY_RUN:-0}"
BOARD_DB="${BOARD_DB:-$HOME/jarvis-board/data/board.db}"

LOG_FILE="$HOME/.jarvis/logs/report-healthcheck.log"
mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# DISCORD_WEBHOOK_CEO 자동 로드
ENV_FILE="${BOARD_DIR:-$HOME/jarvis-board}/.env.local"
if [[ -z "${DISCORD_WEBHOOK_CEO:-}" ]] && [[ -f "$ENV_FILE" ]]; then
  DISCORD_WEBHOOK_CEO=$(grep '^DISCORD_WEBHOOK_CEO=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' || true)
fi

if [[ ! -f "$BOARD_DB" ]]; then
  log "ERROR: board.db 없음 ($BOARD_DB)"
  exit 1
fi

# 최신 보고서 조회 (UTC). 레코드 없으면 NULL → CAST로 빈 값 나옴.
hours_since=$(sqlite3 "$BOARD_DB" "SELECT CAST((julianday('now') - julianday(MAX(created_at))) * 24 AS INTEGER) FROM posts WHERE type='report';")
latest=$(sqlite3 "$BOARD_DB" "SELECT COALESCE(MAX(created_at), '(없음)') FROM posts WHERE type='report';")

if [[ -z "$hours_since" ]]; then
  log "ALERT: 보고서 레코드 0건"
  hours_since=999999
fi

log "최신 보고서: $latest UTC (${hours_since}h 전, 임계값 ${THRESHOLD_HOURS}h)"

if (( hours_since <= THRESHOLD_HOURS )); then
  log "OK: 정상 범위"
  exit 0
fi

msg="🚨 자비스 보고서 ${hours_since}시간 미생성 — 마지막 ${latest} UTC. \`ai.jarvis.report-daily\` LaunchAgent 상태 확인 필요."
log "ALERT: $msg"

if (( DRY_RUN )); then
  log "[DRY-RUN] Discord 전송 스킵"
  exit 0
fi

if [[ -z "${DISCORD_WEBHOOK_CEO:-}" ]]; then
  log "ERROR: DISCORD_WEBHOOK_CEO 미설정 — 알림 전송 불가"
  exit 1
fi

# JSON escape: " → \"
body=$(printf '{"content":"%s"}' "${msg//\"/\\\"}")
resp=$(curl -s -w "\n%{http_code}" -X POST "$DISCORD_WEBHOOK_CEO" \
  -H "Content-Type: application/json" \
  -d "$body" --max-time 10 || true)
code=$(echo "$resp" | tail -1)
if [[ "$code" =~ ^2 ]]; then
  log "Discord 알림 전송 완료 (HTTP $code)"
else
  log "ERROR: Discord 전송 실패 (HTTP $code)"
  exit 1
fi
