#!/usr/bin/env bash
# skill-dryrun-auto-activate.sh — 1주 시뮬 결과 OK면 SKILL_EXTRACT_DRYRUN=0 자동 활성화
# 매주 일 21:00 KST (weekly-self-retro 22:00 1시간 전)
#
# 활성화 기준:
#   - 7일 ledger에 dryrun-skip 항목 ≥ 5건 (충분한 시뮬)
#   - 에러(parse fail / fatal) 0건

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LEDGER="$JARVIS_HOME/runtime/state/skill-extractor-ledger.jsonl"
LOG_FILE="$JARVIS_HOME/runtime/logs/skill-dryrun-auto-activate.log"
ACTIVATION_MARKER="$JARVIS_HOME/runtime/state/skill-extract-production-active"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"

mkdir -p "$(dirname "$LOG_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

if [ -f "$ACTIVATION_MARKER" ]; then
    _log "이미 production 활성 — skip"
    exit 0
fi

[ -f "$LEDGER" ] || { _log "ledger 없음 — 시뮬 데이터 부족"; exit 0; }

CUTOFF=$(date -v-7d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '-7 days' +%Y-%m-%dT%H:%M:%S)
DRYRUN_COUNT=$(jq -s --arg c "$CUTOFF" '[.[] | select(.ts > $c) | select(.action == "dryrun-skip")] | length' "$LEDGER" 2>/dev/null)
ERROR_COUNT=$(jq -s --arg c "$CUTOFF" '[.[] | select(.ts > $c) | select(.action == "llm-fail" or .action == "parse-fail")] | length' "$LEDGER" 2>/dev/null)

_log "7d: dryrun=$DRYRUN_COUNT error=$ERROR_COUNT"

if [ "$DRYRUN_COUNT" -lt 5 ]; then
    _log "시뮬 부족 (need ≥5) — 다음 주 재평가"
    exit 0
fi
if [ "$ERROR_COUNT" -gt 0 ]; then
    _log "에러 발견 — 자동 활성화 차단. 사람 결재 필요."
    [ -f "$DISCORD_VISUAL" ] && node "$DISCORD_VISUAL" --type stats --data \
        "$(jq -nc --arg ts "$(date '+%Y-%m-%d %H:%M KST')" --arg e "$ERROR_COUNT" \
            '{title:"🟡 Skill DRYRUN 자동 활성화 차단", data:{"에러 건수":$e,"조치":"수동 검토 필요"}, timestamp:$ts}')" \
        --channel jarvis-system 2>&1 | tee -a "$LOG_FILE" || true
    exit 0
fi

# 활성화: marker 생성. transition() 함수가 이걸 보고 환경변수 우선 적용
touch "$ACTIVATION_MARKER"
_log "✅ Skill production 활성화 — 다음 task done부터 실제 LLM 호출"

if [ -f "$DISCORD_VISUAL" ]; then
    PAYLOAD=$(jq -nc --arg ts "$(date '+%Y-%m-%d %H:%M KST')" --arg d "$DRYRUN_COUNT" \
        '{title:"🟢 Skill 시스템 production 활성화", data:{"7일 시뮬 건수":$d,"에러":"0","상태":"production 활성"}, timestamp:$ts}')
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
