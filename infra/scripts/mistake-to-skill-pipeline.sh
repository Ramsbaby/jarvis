#!/usr/bin/env bash
# mistake-to-skill-pipeline.sh — learned-mistakes.md 새 항목 → skill 자동 추출 (DRYRUN)
# 매일 00:30 KST 실행. 어제 신규 추가된 ## 헤더 발견 시 skill-extractor 발화.

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
MISTAKES="$JARVIS_HOME/runtime/wiki/meta/learned-mistakes.md"
STATE_FILE="$JARVIS_HOME/runtime/state/mistake-to-skill-state.json"
LOG_FILE="$JARVIS_HOME/runtime/logs/mistake-to-skill.log"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$STATE_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

[ -f "$MISTAKES" ] || { _log "learned-mistakes 없음"; exit 0; }

# 현재 ## 헤더 (실수 항목) 카운트
CURRENT=$(grep "^## 2026-" "$MISTAKES" 2>/dev/null | wc -l | tr -d ' \n')

# 첫 실행: baseline만 등록 (모든 기존 항목 skip)
if [ ! -f "$STATE_FILE" ]; then
    echo "{\"lastCount\": $CURRENT, \"lastRun\": \"$(date -u +%FT%TZ)\", \"baselined\": true}" > "$STATE_FILE"
    _log "첫 실행 — baseline 등록 ($CURRENT건). 다음 실행부터 신규 항목만 추출."
    exit 0
fi

LAST=$(jq -r '.lastCount // 0' "$STATE_FILE" 2>/dev/null || echo 0)

if [ "$CURRENT" -le "$LAST" ]; then
    _log "신규 항목 없음 (current=$CURRENT, last=$LAST)"
    exit 0
fi

NEW_COUNT=$((CURRENT - LAST))
# 안전 가드: 한 번에 5건 이상 신규 추가 시 비정상 — chunk 처리 (5건만)
# B fix (verify 잔여): state 보존 → 다음 실행 시 나머지 처리. 영구 정지 차단.
CHUNK_SIZE=5
if [ "$NEW_COUNT" -gt "$CHUNK_SIZE" ]; then
    _log "신규 ${NEW_COUNT}건 — chunk 처리 (이번 실행: ${CHUNK_SIZE}건만, 나머지 다음 실행)"
    NEW_COUNT="$CHUNK_SIZE"
    # state는 이번 chunk만큼 진전 (LAST + CHUNK_SIZE)
    UPDATED_LAST=$((LAST + CHUNK_SIZE))
    # 끝에 echo로 state 업데이트하므로 일단 처리 후 LAST=$UPDATED_LAST 사용
    CURRENT_FOR_STATE="$UPDATED_LAST"
    # Discord 알림: chunk 처리 중
    if [ -f "$HOME/jarvis/runtime/scripts/discord-visual.mjs" ]; then
        node "$HOME/jarvis/runtime/scripts/discord-visual.mjs" --type stats --data \
            "$(jq -nc --arg ts "$(date '+%Y-%m-%d %H:%M KST')" --arg n "$((CURRENT - LAST))" --arg c "$CHUNK_SIZE" \
                '{title:"📚 사고→skill chunk 처리", data:{"신규 사고 총":$n,"이번 chunk":$c,"나머지":"내일 처리"}, timestamp:$ts}')" \
            --channel jarvis-system 2>&1 | tee -a "$LOG_FILE" || true
    fi
else
    CURRENT_FOR_STATE="$CURRENT"
fi

_log "신규 ${NEW_COUNT}건 발견 (current=$CURRENT, last=$LAST)"

# 가장 최근 추가된 N개 항목 추출 (## 2026- 으로 시작)
NEW_TITLES=$(grep "^## 2026-" "$MISTAKES" | head -"$NEW_COUNT")

# skill-extractor 발화 (DRYRUN 모드 자동 호출 — 비용 안전)
# meta source: learned-mistakes:auto-extract
COUNT=0
while IFS= read -r title; do
    [ -z "$title" ] && continue
    SLUG=$(echo "$title" | sed -E 's/## 2026-[0-9-]+ — //; s/[^a-zA-Z0-9가-힣]/-/g; s/--+/-/g' | head -c 60)
    SKILL_TASK_ID="mistake-${SLUG}"
    _log "[trigger] $SKILL_TASK_ID"
    # DRYRUN 모드 — extractor가 알아서 LLM 호출 X (현재 default)
    SKILL_EXTRACT_DRYRUN=1 node "$JARVIS_HOME/infra/lib/skill-extractor.mjs" \
        --task-id "$SKILL_TASK_ID" --dry-run >>"$LOG_FILE" 2>&1 || true
    COUNT=$((COUNT + 1))
done <<< "$NEW_TITLES"

# state 업데이트 (chunk 처리 시 LAST + CHUNK_SIZE만큼만 진전)
STATE_COUNT="${CURRENT_FOR_STATE:-$CURRENT}"
echo "{\"lastCount\": $STATE_COUNT, \"lastRun\": \"$(date -u +%FT%TZ)\"}" > "$STATE_FILE"
_log "처리: $COUNT건 (state lastCount: $STATE_COUNT)"

exit 0
