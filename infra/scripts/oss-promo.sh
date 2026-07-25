#!/usr/bin/env bash
# oss-promo.sh — OSS 주간 홍보 초안 생성 래퍼
# 모드: promo (릴리즈 노트 + Twitter/X + Reddit 홍보 초안 → Discord)
# 크론: 0 17 * * 5  (매주 금요일 17:00 — oss-promo 크론)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

JARVIS_HOME="${JARVIS_HOME:-${HOME}/jarvis/runtime}"
LOG="$JARVIS_HOME/logs/oss-manager.log"
NODE="${NODE:-$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)}"

log() {
    echo "[$(date '+%F %T')] [oss-promo] $1" | tee -a "$LOG"
}

log "DEPRECATED — promo 모드는 2026-04-21 oss-manager.mjs에서 제거됨"
log "OSS 홍보 초안 생성 기능은 현재 구현 없음. 필요 시 /git-open-up step-7 스킬 참조"
log "이 LA(com.jarvis.oss-promo)는 제거 또는 비활성화를 권고합니다. exit 0으로 정상 종료"
exit 0