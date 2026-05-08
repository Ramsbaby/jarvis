#!/usr/bin/env bash
# external-detect.sh — 매일 03:00 KST: 신모델 + dependency 자동 감지
# 2-in-1: Anthropic 모델 카탈로그 / npm + pip outdated

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LOG_FILE="$JARVIS_HOME/runtime/logs/external-detect.log"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"
MODEL_KNOWN_FILE="$JARVIS_HOME/runtime/state/known-claude-models.json"
DEP_LAST_FILE="$JARVIS_HOME/runtime/state/dependency-snapshot.json"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$MODEL_KNOWN_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ── 1. Anthropic 신모델 감지 ─────────────────────────────────────────
# 2026-05-08 OAuth 전용 정책 적용 — ANTHROPIC_API_KEY 미사용 (jarvis-ethos.md Iron Law 4 4.1)
# 신모델 감지는 비활성. 필요 시 향후 OAuth 토큰으로 대체 구현 (참조: 2026-05-08 SSoT 등재).
NEW_MODELS="(모델 감지 비활성 — OAuth 전용 정책)"

# ── 2. npm + pip outdated (자비스 본체) ──────────────────────────────
NPM_OUTDATED=0
if [ -f "$JARVIS_HOME/package.json" ]; then
    NPM_OUTDATED=$(cd "$JARVIS_HOME" && npm outdated --json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
fi
PIP_OUTDATED=0
if [ -d "$JARVIS_HOME/jarvis-voice/.venv" ]; then
    PIP_OUTDATED=$("$JARVIS_HOME/jarvis-voice/.venv/bin/pip" list --outdated --format=json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
fi

LAST_NPM=$(jq -r '.npm // 0' "$DEP_LAST_FILE" 2>/dev/null || echo 0)
LAST_PIP=$(jq -r '.pip // 0' "$DEP_LAST_FILE" 2>/dev/null || echo 0)
echo "{\"npm\": $NPM_OUTDATED, \"pip\": $PIP_OUTDATED, \"updated\": \"$(date -u +%FT%TZ)\"}" > "$DEP_LAST_FILE"

NPM_DELTA=$((NPM_OUTDATED - LAST_NPM))
PIP_DELTA=$((PIP_OUTDATED - LAST_PIP))

_log "models: $NEW_MODELS / npm outdated: $NPM_OUTDATED (Δ$NPM_DELTA) / pip outdated: $PIP_OUTDATED (Δ$PIP_DELTA)"

# Discord 알림 (변화 또는 신모델 발견 시)
NEED_ALERT=false
[ "$NEW_MODELS" != "(변경 없음)" ] && NEED_ALERT=true
[ "$NPM_DELTA" -gt 5 ] || [ "$PIP_DELTA" -gt 5 ] && NEED_ALERT=true

if [ "$NEED_ALERT" = "true" ] && [ -f "$DISCORD_VISUAL" ]; then
    PAYLOAD=$(jq -nc \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        --arg m "$NEW_MODELS" \
        --arg n "$NPM_OUTDATED ($NPM_DELTA 변화)" \
        --arg p "$PIP_OUTDATED ($PIP_DELTA 변화)" \
        '{title:"🔭 외부 변화 감지", data:{"Anthropic 모델":$m,"npm outdated":$n,"pip outdated":$p,"권고":"마이그 검토"}, timestamp:$ts}')
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
