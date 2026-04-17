#!/usr/bin/env bash
# rag-index-claude-conversations.sh — Claude conversations RAG indexing wrapper
# Purpose: Convert Claude sessions to JSONL + trigger rag-index pipeline
# Cron: 0 */6 * * * (every 6 hours)

set -euo pipefail

# Color codes for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get current time in KST
log_timestamp() {
  TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S'
}

# Logging with timestamp
log_info() {
  echo "[$(log_timestamp)] [rag-conv] INFO $1"
}

log_error() {
  echo "[$(log_timestamp)] [rag-conv] ERROR $1" >&2
}

# Configuration
INFRA_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
CONV_DIR="${INFRA_HOME}/data/claude-conversations"
JSONL_DIR="${INFRA_HOME}/data/claude-conversations-jsonl"
STATE_FILE="${INFRA_HOME}/state/rag-conv-state.json"
LOG_FILE="${INFRA_HOME}/logs/rag-conversations.log"

# Ensure directories exist
mkdir -p "$JSONL_DIR" "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"

# Initialize state file if missing
if [[ ! -f "$STATE_FILE" ]]; then
  echo '{"last_conversion":null,"converted_count":0,"failed_count":0}' > "$STATE_FILE"
fi

exec >> "$LOG_FILE" 2>&1

log_info "========== RAG 대화 변환 시작 =========="

# Find all .jsonl files in conversations directory
if [[ ! -d "$CONV_DIR" ]]; then
  log_error "대화 디렉토리 없음: $CONV_DIR"
  exit 1
fi

# Convert Claude sessions to JSONL format (if conversion script exists)
CONVERTER_SCRIPT="${INFRA_HOME}/scripts/claude-session-to-jsonl.mjs"
CONVERTED=0
SKIPPED=0

if [[ -f "$CONVERTER_SCRIPT" ]]; then
  log_info "변환 시작..."
  TEMP_OUT=$(mktemp)
  trap 'rm -f "$TEMP_OUT"' EXIT

  node "$CONVERTER_SCRIPT" "$CONV_DIR" "$JSONL_DIR" > "$TEMP_OUT" 2>&1 || true

  # Parse conversion results (expected format: "converted:N skipped:M")
  if grep -q "converted:" "$TEMP_OUT"; then
    RESULT=$(grep "converted:" "$TEMP_OUT" | tail -1)
    log_info "변환 완료 — $RESULT"
    CONVERTED=$(echo "$RESULT" | grep -oP "converted:\K\d+" || echo 0)
  else
    log_info "변환 완료 — 신규 항목 없음"
  fi
else
  log_info "변환 스크립트 없음, 기존 JSONL 파일 사용"
fi

# Trigger main RAG index
log_info "rag-index 트리거 (cron-safe-wrapper 경유)"

# Use the main RAG indexing wrapper
if [[ -f "${INFRA_HOME}/bin/cron-safe-wrapper.sh" ]]; then
  bash "${INFRA_HOME}/bin/cron-safe-wrapper.sh" \
    rag-index 2700 \
    /bin/bash "${INFRA_HOME}/bin/rag-index-safe.sh" \
    >> "$LOG_FILE" 2>&1 || true
else
  log_error "cron-safe-wrapper.sh 없음"
  exit 1
fi

log_info "========== RAG 대화 변환 완료 =========="
exit 0