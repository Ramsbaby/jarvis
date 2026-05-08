#!/usr/bin/env bash
# self-monitor-snapshot.sh — 매주 월 09:35 KST: 자비스 자체 성능 점검
# 3-in-1: hot path (token-ledger 함수별 빈도) / 적응형 임계값 (heartbeat 30일 평균) / stale 인용 (RAG 6개월↑)

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
LOG_FILE="$JARVIS_HOME/runtime/logs/self-monitor.log"
DISCORD_VISUAL="$HOME/jarvis/runtime/scripts/discord-visual.mjs"
LEDGER="$JARVIS_HOME/runtime/state/token-ledger.jsonl"
THRESHOLD_FILE="$JARVIS_HOME/runtime/state/adaptive-thresholds.json"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$THRESHOLD_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Single-instance lock
# shellcheck source=/dev/null
[ -f "$JARVIS_HOME/infra/lib/single-instance.sh" ] && source "$JARVIS_HOME/infra/lib/single-instance.sh" && single_instance "self-monitor-snapshot"

# ── 1. Hot path — top 5 task by 빈도 (지난 7일) ──────────────────────
TOP_TASKS="(없음)"
if [ -f "$LEDGER" ]; then
    CUTOFF=$(date -v-7d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '-7 days' +%Y-%m-%dT%H:%M:%S)
    TOP_TASKS=$(jq -s --arg c "$CUTOFF" \
        '[.[] | select(.ts > $c) | .task] | group_by(.) | map({task:.[0], n:length}) | sort_by(-.n) | .[0:5] | map("\(.task):\(.n)") | join(" | ")' \
        "$LEDGER" 2>/dev/null | tr -d '"' || echo "(분석실패)")
fi

# ── 2. 적응형 임계값 — heartbeat / RAG 30일 평균 ─────────────────────
LEDGER_SUPERVISOR="$JARVIS_HOME/runtime/state/supervisor-tick-ledger.jsonl"
HEARTBEAT_AVG="N/A"
RAG_AVG="N/A"
if [ -f "$LEDGER_SUPERVISOR" ]; then
    CUTOFF_30=$(date -v-30d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '-30 days' +%Y-%m-%dT%H:%M:%S)
    HEARTBEAT_AVG=$(jq -s --arg c "$CUTOFF_30" \
        '[.[] | select(.ts > $c) | .snapshot.heartbeat_age // 0] | (add/length) // 0 | floor' \
        "$LEDGER_SUPERVISOR" 2>/dev/null)
    RAG_AVG=$(jq -s --arg c "$CUTOFF_30" \
        '[.[] | select(.ts > $c) | .snapshot.rag_age_min // 0] | (add/length) // 0 | floor' \
        "$LEDGER_SUPERVISOR" 2>/dev/null)
fi
# 적응형 임계값: 평균 + 표준편차 가정. 단순 = 평균 × 3 (튀면 알림)
HEARTBEAT_THRESHOLD=$((HEARTBEAT_AVG * 3))
RAG_THRESHOLD=$((RAG_AVG * 3))
echo "{\"heartbeat\": $HEARTBEAT_THRESHOLD, \"rag_min\": $RAG_THRESHOLD, \"updated\": \"$(date -u +%FT%TZ)\"}" > "$THRESHOLD_FILE"

# ── 3. Stale 인용 — RAG 인덱싱 문서 중 6개월↑ 비율 ───────────────────
RAG_DOCS_DIR="$JARVIS_HOME/runtime/rag"
STALE_RATIO="N/A"
if [ -d "$RAG_DOCS_DIR" ]; then
    TOTAL=$(find "$RAG_DOCS_DIR" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    STALE=$(find "$RAG_DOCS_DIR" -name "*.md" -type f -mtime +180 2>/dev/null | wc -l | tr -d ' ')
    if [ "$TOTAL" -gt 0 ]; then
        STALE_RATIO=$(awk -v s="$STALE" -v t="$TOTAL" 'BEGIN{printf "%.0f%% (%d/%d)", (s/t)*100, s, t}')
    fi
fi

_log "hot=$TOP_TASKS / heartbeat_avg=${HEARTBEAT_AVG}s thr=${HEARTBEAT_THRESHOLD}s / rag_avg=${RAG_AVG}m thr=${RAG_THRESHOLD}m / stale=$STALE_RATIO"

if [ -f "$DISCORD_VISUAL" ]; then
    PAYLOAD=$(jq -nc \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        --arg hot "$TOP_TASKS" \
        --arg hb "${HEARTBEAT_AVG}s 평균 / 임계 ${HEARTBEAT_THRESHOLD}s" \
        --arg rag "${RAG_AVG}분 평균 / 임계 ${RAG_THRESHOLD}분" \
        --arg stale "$STALE_RATIO" \
        '{title:"🔍 자비스 자가 성능 점검", data:{"Hot path Top5":$hot,"Heartbeat 적응형 임계":$hb,"RAG 적응형 임계":$rag,"Stale 인용":$stale}, timestamp:$ts}')
    discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 0
