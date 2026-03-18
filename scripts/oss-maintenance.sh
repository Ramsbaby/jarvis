#!/usr/bin/env bash
# oss-maintenance.sh — OSS 일간 유지보수 래퍼
# 모드: maintenance (이슈 자동 라벨 + Stale PR 감지 + Discord 리포트)
# 크론: 15 9 * * *  (매일 09:15 — oss-maintenance 크론)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

JARVIS_HOME="${JARVIS_HOME:-$HOME/.jarvis}"
LOG="$JARVIS_HOME/logs/oss-manager.log"
NODE="${NODE:-$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)}"

log() {
    echo "[$(date '+%F %T')] [oss-maintenance] $1" | tee -a "$LOG"
}

log "START — 일간 OSS 유지보수"

"$NODE" "$JARVIS_HOME/scripts/oss-manager.mjs" --mode maintenance >> "$LOG" 2>&1
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    log "SUCCESS"
else
    log "ERROR — exit $EXIT_CODE"
    exit $EXIT_CODE
fi
