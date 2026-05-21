#!/usr/bin/env bash
# oauth-refresh-watchdog.sh — 자동갱신 사이클 실패 감지 워치독
#
# 2026-05-20 신설: oauth-refresh cron이 사일런트 실패할 경우 (호스트 오타·네트워크 끊김 등)
# 주인님이 또 /login 강제 당하기 전에 사전 감지. credentials.json + ledger 양쪽 교차 검증.
#
# 동작:
# - credentials.json의 만료까지 잔여 시간이 4h 이내인데, ledger에 최근 2h 내 success가 없으면 alert
# - ledger의 가장 최근 record가 success가 아니면 alert (rate_limit 영구화 조기 감지)
# - 매시간 실행 (cron 0 * * * *)

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
CRED="${HOME}/.claude/.credentials.json"
LEDGER="${BOT_HOME}/ledger/oauth-refresh-ledger.jsonl"
LOG="${BOT_HOME}/logs/oauth-refresh-watchdog.log"

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

if [[ ! -f "$CRED" ]]; then
    log "ERROR: credentials.json 없음"
    exit 1
fi

# 잔여 시간 (초)
REMAIN_SECS=$(python3 -c "
import json, time
d = json.load(open('$CRED'))
exp = d['claudeAiOauth'].get('expiresAt', 0) / 1000
print(int(exp - time.time()))
")

# ledger 최근 record (없으면 'none')
LAST_RESULT=$(tail -1 "$LEDGER" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    print(d.get('result','unknown'))
except:
    print('none')
")

# 최근 6h 내 success 여부 (2026-05-21: 2h→6h — 갱신 사이클 최대 5h이므로 2h window는 정상 사이클도 오발)
RECENT_SUCCESS_COUNT=$(python3 << 'PYEOF'
import json, time, os
ledger = os.path.expanduser('~/jarvis/runtime/ledger/oauth-refresh-ledger.jsonl')
cutoff = time.time() - 6*3600
count = 0
try:
    for line in open(ledger):
        try:
            d = json.loads(line)
            if d.get('result') == 'success':
                ts = d.get('ts','')
                if ts:
                    import datetime
                    t = datetime.datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
                    if t > cutoff:
                        count += 1
        except: pass
except FileNotFoundError: pass
print(count)
PYEOF
)

log "remain=${REMAIN_SECS}s last_ledger=${LAST_RESULT} recent_2h_success=${RECENT_SUCCESS_COUNT}"

# Alert 조건
ALERT_REASON=""
if (( REMAIN_SECS < 14400 )) && (( RECENT_SUCCESS_COUNT == 0 )); then
    ALERT_REASON="만료 ${REMAIN_SECS}초 남았는데 최근 2h 내 갱신 success 0건"
elif [[ "$LAST_RESULT" == "fail" ]]; then
    ALERT_REASON="ledger 최근 record가 fail — 자동갱신 사이클 단절 가능성"
fi

if [[ -n "$ALERT_REASON" ]]; then
    log "🚨 ALERT: $ALERT_REASON"
    COOLDOWN_FILE="/tmp/jarvis-oauth-watchdog.cooldown"
    NOW=$(date +%s)
    LAST=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo "0")
    if (( NOW - LAST > 3600 )); then
        echo "$NOW" > "$COOLDOWN_FILE"
        if [[ -x "${BOT_HOME}/scripts/alert.sh" ]]; then
            bash "${BOT_HOME}/scripts/alert.sh" \
                critical \
                "🚨 OAuth 자동갱신 워치독 경보" \
                "$ALERT_REASON. 즉시 진단 필요: \`tail -20 ${LOG}\` + \`tail -5 ${LEDGER}\`. 주인님 /login 안 하셔도 됨 — 자비스 자동 복구 시도가 우선." \
                2>/dev/null || log "alert.sh 호출 실패"
        fi
        # 자동 복구 시도: --force로 즉시 갱신 한 번
        log "자동 복구 시도 — oauth-refresh.sh --force"
        bash "${BOT_HOME}/../infra/scripts/oauth-refresh.sh" --force >> "$LOG" 2>&1 || \
            bash "${HOME}/jarvis/infra/scripts/oauth-refresh.sh" --force >> "$LOG" 2>&1 || true
    fi
    exit 1
fi

exit 0
