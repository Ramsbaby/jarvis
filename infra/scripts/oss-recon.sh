#!/usr/bin/env bash
# oss-recon.sh — OSS 경쟁자 분석 래퍼
# 모드: recon (경쟁자 비교 + 기능 갭 리포트 + Discord 전송)
# 크론: 30 10 * * 1  (매주 월요일 10:30 — oss-recon 크론)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

JARVIS_HOME="${JARVIS_HOME:-${HOME}/.jarvis}"
LOG="$JARVIS_HOME/logs/oss-manager.log"
NODE="${NODE:-$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)}"

log() {
    echo "[$(date '+%F %T')] [oss-recon] $1" | tee -a "$LOG"
}

log "START — 주간 OSS 경쟁자 분석"

"$NODE" "$JARVIS_HOME/scripts/oss-manager.mjs" --mode recon >> "$LOG" 2>&1
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    log "SUCCESS"
else
    log "ERROR — exit $EXIT_CODE"
    exit $EXIT_CODE
fi
