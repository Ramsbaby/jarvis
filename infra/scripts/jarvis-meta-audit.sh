#!/usr/bin/env bash
# jarvis-meta-audit.sh — 자비스의 audit-of-audits + dead cron 감지 + 효과 측정 (3-in-1)
#
# 매주 월 09:40 KST (audit-dashboard 09:30 직후)
#
# 1. Meta audit — 모든 ai.jarvis.* LaunchAgent의 last exit 점검 (자비스 자체 cron fail 감지)
# 2. Dead cron — 4주간 0회 발화 또는 PASS만 → 후보 카드
# 3. 효과 측정 — 각 cron의 "방어 카운트" (alerted=true / failed-detected / mismatch-fixed)

set -uo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/.openclaw-data/jarvis}"
LOG_FILE="$JARVIS_HOME/runtime/logs/jarvis-meta-audit.log"
LOGS_DIR="$JARVIS_HOME/runtime/logs"
DISCORD_VISUAL="$HOME/.openclaw-data/jarvis/runtime/scripts/discord-visual.mjs"

mkdir -p "$(dirname "$LOG_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Single-instance lock
# shellcheck source=/dev/null
[ -f "$JARVIS_HOME/infra/lib/single-instance.sh" ] && source "$JARVIS_HOME/infra/lib/single-instance.sh" && single_instance "jarvis-meta-audit"

CUTOFF_4W=$(date -v-28d +%s 2>/dev/null || date -d '-28 days' +%s)

# ── 1. Meta audit — LaunchAgent last exit ────────────────────────────
META_FAILS=()
TOTAL_LA=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    EXIT_CODE=$(echo "$line" | awk '{print $2}')
    LABEL=$(echo "$line" | awk '{print $3}')
    [ -z "$LABEL" ] && continue
    TOTAL_LA=$((TOTAL_LA + 1))
    if [ "$EXIT_CODE" != "0" ] && [ "$EXIT_CODE" != "-" ]; then
        META_FAILS+=("$LABEL (exit=$EXIT_CODE)")
    fi
done < <(launchctl list 2>/dev/null | grep "ai.jarvis." || true)

# ── 2. Dead cron 감지 — 4주간 stdout 로그 발화 0회 ──────────────────
DEAD_CRONS=()
for la in $HOME/Library/LaunchAgents/ai.jarvis.*.plist; do
    [ -f "$la" ] || continue
    LABEL=$(basename "$la" .plist)
    NAME=$(echo "$LABEL" | sed 's/^ai\.jarvis\.//')
    STDOUT_LOG="$LOGS_DIR/${NAME}-stdout.log"
    if [ -f "$STDOUT_LOG" ]; then
        MTIME=$(stat -f %m "$STDOUT_LOG" 2>/dev/null || echo 0)
        if [ "$MTIME" -lt "$CUTOFF_4W" ]; then
            DEAD_CRONS+=("$NAME")
        fi
    fi
done

# ── 3. 효과 측정 — 주요 audit cron의 alerted/FAIL 카운트 (지난 7일) ──
# B3 fix: grep -c || echo 0 → wc -l + tr (정수 안전)
SUPERVISOR_ALERTS=$(awk -v c="$(date -v-7d +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '-7 days' +%Y-%m-%dT%H:%M:%S)" \
    -F'"ts":"' 'NF>1 && $2 > c' "$JARVIS_HOME/runtime/state/supervisor-tick-ledger.jsonl" 2>/dev/null \
    | grep '"alerted":true' | wc -l | tr -d ' \n')
DOCS_REGENS=$(grep "재생성: 성공" "$LOGS_DIR/docs-freshness-audit.log" 2>/dev/null | wc -l | tr -d ' \n')
MODEL_VIOLATIONS=$(grep "FAIL: 모델 정책 위반" "$LOGS_DIR/model-version-audit.log" 2>/dev/null | wc -l | tr -d ' \n')

_log "meta: total=$TOTAL_LA, fails=${#META_FAILS[@]} | dead 4w=${#DEAD_CRONS[@]} | 7d 효과: supervisor_alert=$SUPERVISOR_ALERTS, docs_regen=$DOCS_REGENS, model_fail=$MODEL_VIOLATIONS"

# ── 4. 계측기 생존 + 훅 배선 (2026-08-23 신설) ────────────────────
# 왜 여기인가: 이 크론이 이미 "audit-of-audits + dead cron 감지"다. 감사기가
#   죽었는지 보는 자리와 계측기가 죽었는지 보는 자리는 같아야 한다(DRY).
#
# 무엇을 막는가:
#   2026-08-23 감사에서 계측기 4개가 18~43일째 죽어 있는 것이 발견됐다.
#   가장 나빴던 verification-gate 는 소비자 훅 배선·권한·문법이 전부 정상이라
#   겉보기엔 멀쩡했다. 생산자 훅이 08-04 배선 사고로 빠져 소비자가 매번
#   조용히 exit 0 한 것이었다. **배선 감사로는 못 잡고, 산출물이 안 늘어나는
#   것으로만 잡힌다.** 그래서 둘을 같이 돌린다.
#
#   그리고 hooks-wiring-audit.sh 는 그때까지 **어느 크론도 부르지 않았다** —
#   8/4 에 훅 20개가 한 번에 빠진 것을 19일 동안 아무도 몰랐던 이유다.
INSTRUMENT_SILENT=0
INSTRUMENT_LINE="(점검 안 됨)"
if [ -f "$JARVIS_HOME/infra/scripts/instrument-liveness-audit.mjs" ]; then
    INSTRUMENT_OUT=$(node "$JARVIS_HOME/infra/scripts/instrument-liveness-audit.mjs" 2>&1) || INSTRUMENT_SILENT=1
    echo "$INSTRUMENT_OUT" >> "$LOG_FILE" 2>/dev/null || true
    INSTRUMENT_LINE=$(echo "$INSTRUMENT_OUT" | head -1)
fi

HOOK_ORPHANS=0
HOOK_LINE="(점검 안 됨)"
if [ -f "$JARVIS_HOME/infra/scripts/hooks-wiring-audit.sh" ]; then
    HOOK_OUT=$(bash "$JARVIS_HOME/infra/scripts/hooks-wiring-audit.sh" 2>&1) || true
    echo "$HOOK_OUT" >> "$LOG_FILE" 2>/dev/null || true
    HOOK_LINE=$(echo "$HOOK_OUT" | head -1)
    HOOK_ORPHANS=$(echo "$HOOK_OUT" | grep -oE 'orphan [0-9]+개' | grep -oE '[0-9]+' | head -1)
    HOOK_ORPHANS=${HOOK_ORPHANS:-0}
fi

_log "instrument: silent=$INSTRUMENT_SILENT | hooks: orphan=$HOOK_ORPHANS"

# 계측기가 죽었으면 info 가 아니라 critical 이다 — 계측기가 죽으면 그 뒤의
# 모든 지표가 조용히 거짓이 된다. 오늘 ③ requirement-check 추이가 그렇게 무효가 됐다.
META_SEVERITY=info
[ "$INSTRUMENT_SILENT" -ne 0 ] && META_SEVERITY=critical

# Discord 합본 카드
if [ -f "$DISCORD_VISUAL" ]; then
    META_FAIL_LIST="(없음)"
    [ "${#META_FAILS[@]}" -gt 0 ] && META_FAIL_LIST=$(printf '%s | ' "${META_FAILS[@]}" | head -c 200 | sed 's/ | $//')
    DEAD_LIST="(없음)"
    [ "${#DEAD_CRONS[@]}" -gt 0 ] && DEAD_LIST=$(printf '%s | ' "${DEAD_CRONS[@]}" | head -c 200 | sed 's/ | $//')

    PAYLOAD=$(jq -nc \
        --arg ts "$(date '+%Y-%m-%d %H:%M KST')" \
        --arg total "$TOTAL_LA" \
        --arg fails "${#META_FAILS[@]} ($META_FAIL_LIST)" \
        --arg dead "${#DEAD_CRONS[@]} ($DEAD_LIST)" \
        --arg sup "$SUPERVISOR_ALERTS" \
        --arg docs "$DOCS_REGENS" \
        --arg model "$MODEL_VIOLATIONS" \
        --arg inst "$INSTRUMENT_LINE" \
        --arg hook "$HOOK_LINE" \
        '{title:"🔬 Meta-Audit (자비스 audit-of-audits)", data:{"LaunchAgent 총합":$total,"실패 cron":$fails,"Dead 4주":$dead,"계측기 생존":$inst,"훅 배선":$hook,"7일 supervisor 알림":$sup,"7일 docs 재생성":$docs,"7일 model 위반":$model}, timestamp:$ts}')
    # DRYRUN=1 이면 발송하지 않고 페이로드만 찍는다.
    # ★ 2026-08-23: 이 크론에 DRYRUN 가드가 없어서, 신규 구간을 붙이고도
    #   "즉시 1회 수동 실행"(CRON-INTRODUCTION-CHECKLIST 4️⃣-6)을 못 했다.
    #   검증하려면 오너 채널로 카드가 나가야 하는 구조였기 때문이다.
    #   검증할 수 없는 안전장치는 안전장치가 아니다.
    if [ "${DRYRUN:-0}" = "1" ]; then
        echo "[DRYRUN] severity=$META_SEVERITY 발송 생략" | tee -a "$LOG_FILE"
        echo "$PAYLOAD" | head -c 900 | tee -a "$LOG_FILE"; echo
    else
        discord_route_payload "$META_SEVERITY" "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
    fi
fi

exit 0
