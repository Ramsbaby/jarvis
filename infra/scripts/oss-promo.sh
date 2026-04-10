#!/usr/bin/env bash
# oss-promo.sh — OSS 주간 홍보 초안 생성 래퍼
# 모드: promo (릴리즈 노트 + Twitter/X + Reddit 홍보 초안 → Discord)
# 크론: 0 17 * * 5  (매주 금요일 17:00 — oss-promo 크론)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

JARVIS_HOME="${JARVIS_HOME:-${HOME}/.local/share/jarvis}"
LOG="$JARVIS_HOME/logs/oss-manager.log"
NODE="${NODE:-$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)}"

log() {
    echo "[$(date '+%F %T')] [oss-promo] $1" | tee -a "$LOG"
}

log "START — 주간 OSS 홍보 초안 생성"

"$NODE" "$JARVIS_HOME/scripts/oss-manager.mjs" --mode promo >> "$LOG" 2>&1
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    log "SUCCESS"
else
    log "ERROR — exit $EXIT_CODE"
    exit $EXIT_CODE
fi
