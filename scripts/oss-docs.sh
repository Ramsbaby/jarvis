#!/usr/bin/env bash
# oss-docs.sh — OSS README 갱신 제안 래퍼
# 모드: docs (최근 커밋 기반 README 개선 제안 → GitHub Issue 등록 or 코멘트 추가)
# 크론: 0 11 * * 3  (매주 수요일 11:00 — oss-docs 크론)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

JARVIS_HOME="${JARVIS_HOME:-$HOME/.jarvis}"
LOG="$JARVIS_HOME/logs/oss-manager.log"
NODE="/opt/homebrew/bin/node"

log() {
    echo "[$(date '+%F %T')] [oss-docs] $1" | tee -a "$LOG"
}

log "START — 주간 OSS README 갱신 제안"

"$NODE" "$JARVIS_HOME/scripts/oss-manager.mjs" --mode docs >> "$LOG" 2>&1
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    log "SUCCESS"
else
    log "ERROR — exit $EXIT_CODE"
    exit $EXIT_CODE
fi
