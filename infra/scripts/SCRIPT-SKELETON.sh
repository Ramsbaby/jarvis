#!/usr/bin/env bash
# {SCRIPT_NAME}.sh — {ONE_LINE_PURPOSE}
# 매{frequency} {time} KST
#
# DRYRUN 의무 (자비스 자동화 표준):
#   {SCRIPT_NAME}_DRYRUN=1 default → 실제 액션 X, ledger만
#   {SCRIPT_NAME}_DRYRUN=0 → production
#
# 첫 1주 시뮬 후 dryrun-auto-activate가 결과 OK 시 0으로 전환.

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LOG_FILE="$JARVIS_HOME/runtime/logs/{SCRIPT_NAME}.log"
LEDGER="$JARVIS_HOME/runtime/state/{SCRIPT_NAME}-ledger.jsonl"

# discord-route 사용 (채널 분산 wrapper)
# shellcheck source=/dev/null
source "$JARVIS_HOME/infra/lib/discord-route.sh"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$LEDGER")"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# DRYRUN 가드
DRYRUN="${SCRIPT_NAME_DRYRUN:-1}"

# === 1. 데이터 수집 ===
# (구현)

# === 2. 분석 ===
# (구현)

# === 3. 액션 (DRYRUN 가드) ===
if [ "$DRYRUN" = "0" ]; then
    # 실제 액션
    _log "production action"
    echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"action\":\"executed\"}" >> "$LEDGER"
else
    _log "DRYRUN — action skipped"
    echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"action\":\"dryrun-skip\"}" >> "$LEDGER"
fi

# === 4. Discord 알림 (severity 분류) ===
# discord_route critical "Critical 발견" "건수=1,상세=..."
# discord_route info "주간 리포트" "metric=val"
# discord_route retro "자가 회고" "..."

exit 0
