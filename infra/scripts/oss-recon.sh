#!/usr/bin/env bash
# oss-recon.sh — OSS 경쟁자 분석 래퍼
# 모드: recon (경쟁자 비교 + 기능 갭 리포트 + Discord 전송)
# 크론: 30 10 * * 1  (매주 월요일 10:30 — oss-recon 크론)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

JARVIS_HOME="${JARVIS_HOME:-${HOME}/jarvis/runtime}"
LOG="$JARVIS_HOME/logs/oss-manager.log"
NODE="${NODE:-$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)}"

log() {
    echo "[$(date '+%F %T')] [oss-recon] $1" | tee -a "$LOG"
}

log "DEPRECATED — recon 모드는 2026-04-21 oss-manager.mjs에서 제거됨"
log "주간 OSS 경쟁자 분석은 recon-weekly LA (com.jarvis.recon-weekly, 월 09:00)가 담당합니다"
log "이 LA(com.jarvis.oss-recon)는 제거 또는 비활성화를 권고합니다. exit 0으로 정상 종료"
exit 0