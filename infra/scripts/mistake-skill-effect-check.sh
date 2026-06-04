#!/usr/bin/env bash
set -uo pipefail

SKILLS_DIR="$HOME/jarvis/runtime/skills"
LOG="$HOME/jarvis/runtime/logs/mistake-skill-effect-check.log"
_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

_log "=== mistake-skill 효과 측정 시작 ==="

# 5/28 이후 생성된 자동 추출 스킬 카운트
NEW_SKILLS=$(find "$SKILLS_DIR" -name "skill-*.md" -newermt "2026-05-28" 2>/dev/null | xargs grep -l "auto-extracted-from-task:mistake-" 2>/dev/null | wc -l | tr -d ' ')

# 가장 최근 5개 스킬명
RECENT=$(find "$SKILLS_DIR" -name "skill-*.md" -newermt "2026-05-28" 2>/dev/null | xargs grep -l "auto-extracted-from-task:mistake-" 2>/dev/null | head -5 | xargs -I{} basename {} .md | tr '\n' ',' | sed 's/,$//')

_log "신규 자동 추출 스킬: ${NEW_SKILLS}개"
_log "최근 5개: ${RECENT}"

# Discord 알림
if [ -f "$HOME/jarvis/runtime/scripts/discord-visual.mjs" ]; then
    node "$HOME/jarvis/runtime/scripts/discord-visual.mjs" --type stats --data \
        "$(jq -nc --arg ts "$(date '+%Y-%m-%d %H:%M KST')" --arg n "$NEW_SKILLS" --arg r "${RECENT:-없음}" \
            '{title:"🎯 자가발전 1주 효과 측정", data:{"신규 변환 스킬":$n,"최근 5개":$r,"다음 결정":"백필 진행 여부"}, timestamp:$ts}')" \
        --channel jarvis-system 2>&1 | tee -a "$LOG" || true
fi

# 1회 실행 후 자동 unload
launchctl unload "$HOME/Library/LaunchAgents/ai.jarvis.mistake-skill-effect-check.plist" 2>/dev/null
_log "=== 측정 완료, LaunchAgent unload ==="
