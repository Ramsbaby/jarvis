#!/usr/bin/env bash
# docs-freshness-audit.sh — 자동 생성 사전 문서 vs 원본 mtime 비교, stale 시 자동 재생성 + 알림
#
# 출처: 주인님 지시 (2026-05-08) "사전 문서 stale 발견 시 알림 + 재생성"
# 매주 월요일 09:10 KST 실행 (ai.jarvis.docs-freshness-audit LaunchAgent)
#
# 비교 매트릭스 (원본 → 생성 문서):
#   runtime/config/tasks.json        → infra/docs/cron-matrix.json + tasks-index.json
#   ~/Library/LaunchAgents/*.plist   → infra/docs/launchagent-catalog.json
#   infra/config/models.json         → infra/docs/discord-channels.json

set -euo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LA_DIR="$HOME/Library/LaunchAgents"
SCRIPTS_DIR="$JARVIS_HOME/infra/scripts"
DOCS_DIR="$JARVIS_HOME/infra/docs"
LOG_FILE="$JARVIS_HOME/runtime/logs/docs-freshness-audit.log"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"

mkdir -p "$(dirname "$LOG_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Single-instance lock
# shellcheck source=/dev/null
[ -f "$JARVIS_HOME/infra/lib/single-instance.sh" ] && source "$JARVIS_HOME/infra/lib/single-instance.sh" && single_instance "docs-freshness-audit"

mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }

# 가장 최근 plist mtime
LA_LATEST=0
for f in "$LA_DIR"/ai.jarvis.*.plist; do
    [ -f "$f" ] || continue
    m=$(mtime "$f")
    [ "$m" -gt "$LA_LATEST" ] && LA_LATEST=$m
done

declare -a STALE
declare -a REGEN_CMDS

check() {
    local source_mtime="$1" doc="$2" regen="$3" label="$4"
    [ -f "$doc" ] || { STALE+=("$label (문서 없음)"); REGEN_CMDS+=("$regen"); return; }
    local doc_mtime; doc_mtime=$(mtime "$doc")
    if [ "$source_mtime" -gt "$doc_mtime" ]; then
        local age_hours=$(( (source_mtime - doc_mtime) / 3600 ))
        STALE+=("$label (${age_hours}h 뒤처짐)")
        REGEN_CMDS+=("$regen")
    fi
}

# 1. cron-matrix
check "$(mtime "$JARVIS_HOME/runtime/config/tasks.json")" \
      "$DOCS_DIR/cron-matrix.json" \
      "node $SCRIPTS_DIR/gen-cron-matrix.mjs" \
      "cron-matrix"

# 2. tasks-index (기존 자동 생성 문서)
check "$(mtime "$JARVIS_HOME/runtime/config/tasks.json")" \
      "$DOCS_DIR/tasks-index.json" \
      "node $SCRIPTS_DIR/gen-tasks-index.mjs" \
      "tasks-index"

# 3. launchagent-catalog
check "$LA_LATEST" \
      "$DOCS_DIR/launchagent-catalog.json" \
      "node $SCRIPTS_DIR/gen-launchagent-catalog.mjs" \
      "launchagent-catalog"

# 4. discord-channels
MODELS_JSON_MTIME=$(mtime "$JARVIS_HOME/infra/config/models.json")
TASKS_JSON_MTIME=$(mtime "$JARVIS_HOME/runtime/config/tasks.json")
NEWER=$MODELS_JSON_MTIME
[ "$TASKS_JSON_MTIME" -gt "$NEWER" ] && NEWER=$TASKS_JSON_MTIME
check "$NEWER" \
      "$DOCS_DIR/discord-channels.json" \
      "node $SCRIPTS_DIR/gen-discord-channels.mjs" \
      "discord-channels"

# ── Cache Content Validation (구멍 3 — 2026-05-08) ─────────────────
# mtime 비교만으로는 gen 스크립트 버그를 못 잡음. 핵심 카운트/분포 정합성 직접 비교.
crosscheck() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        STALE+=("$label (mismatch: 원본=$expected, 사전=$actual)")
        REGEN_CMDS+=("$4")
    fi
}

# C1. tasks.json 총 task 수 vs cron-matrix.json
if [ -f "$DOCS_DIR/cron-matrix.json" ]; then
    SRC_COUNT=$(jq '.tasks | length' "$JARVIS_HOME/runtime/config/tasks.json" 2>/dev/null || echo 0)
    CACHE_COUNT=$(jq '.totalTasks' "$DOCS_DIR/cron-matrix.json" 2>/dev/null || echo -1)
    crosscheck "cron-matrix.totalTasks" "$SRC_COUNT" "$CACHE_COUNT" \
               "node $SCRIPTS_DIR/gen-cron-matrix.mjs"
fi

# C2. plist 수 vs launchagent-catalog.json
if [ -f "$DOCS_DIR/launchagent-catalog.json" ]; then
    SRC_LA=$(ls "$LA_DIR"/ai.jarvis.*.plist 2>/dev/null | wc -l | tr -d ' ')
    CACHE_LA=$(jq '.totalLaunchAgents' "$DOCS_DIR/launchagent-catalog.json" 2>/dev/null || echo -1)
    crosscheck "launchagent-catalog.totalLaunchAgents" "$SRC_LA" "$CACHE_LA" \
               "node $SCRIPTS_DIR/gen-launchagent-catalog.mjs"
fi

# C3. tasks.json discordChannel 고유 수 vs discord-channels.json
if [ -f "$DOCS_DIR/discord-channels.json" ]; then
    SRC_CH=$(jq -r '[.tasks[] | .discordChannel // "<no-channel>"] | unique | length' "$JARVIS_HOME/runtime/config/tasks.json" 2>/dev/null || echo 0)
    CACHE_CH=$(jq '.totalChannels' "$DOCS_DIR/discord-channels.json" 2>/dev/null || echo -1)
    crosscheck "discord-channels.totalChannels" "$SRC_CH" "$CACHE_CH" \
               "node $SCRIPTS_DIR/gen-discord-channels.mjs"
fi

if [ "${#STALE[@]}" -eq 0 ]; then
    _log "PASS: 모든 사전 문서 최신 + 정합성 통과"
    exit 0
fi

_log "STALE: ${#STALE[@]}건 발견 — 자동 재생성"
for s in "${STALE[@]}"; do _log "  - $s"; done

REGEN_OK=0
REGEN_FAIL=0
# bash 3.x 호환: associative array 대신 sort -u로 중복 제거
while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    if eval "$cmd" >>"$LOG_FILE" 2>&1; then
        REGEN_OK=$((REGEN_OK + 1))
    else
        REGEN_FAIL=$((REGEN_FAIL + 1))
    fi
done < <(printf '%s\n' "${REGEN_CMDS[@]}" | sort -u)
_log "재생성: 성공 $REGEN_OK / 실패 $REGEN_FAIL"

# Discord 알림
if [ -f "$DISCORD_VISUAL" ]; then
    TS=$(date +"%Y-%m-%d %H:%M KST")
    STALE_SUMMARY=$(printf '%s\n' "${STALE[@]}" | head -5 | tr '\n' '|' | sed 's/|$//')
    PAYLOAD=$(cat <<EOF
{"title":"📚 사전 문서 갱신","data":{"stale 건수":"${#STALE[@]}","stale":"$STALE_SUMMARY","재생성 성공":"$REGEN_OK","재생성 실패":"$REGEN_FAIL"},"timestamp":"$TS"}
EOF
)
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
