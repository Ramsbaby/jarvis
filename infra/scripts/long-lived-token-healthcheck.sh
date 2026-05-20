#!/usr/bin/env bash
# long-lived-token-healthcheck.sh — long-lived OAuth token 헬스 체크
#
# 2026-05-20 도입: short-lived OAuth (`oauth-refresh.sh`)를 long-lived token으로 대체한 후,
# 토큰이 어느 날 invalid 되어도 자비스가 모르고 모든 크론이 동시 사망하는 blast radius를 막기 위함.
#
# 동작:
# - 1회 가벼운 API ping (Bearer + oauth-2025-04-20 beta) → HTTP 200 확인
# - 401/403 발생 시 Discord critical 알림 + ledger 기록
# - 통과 시 ledger에 success 기록 (주간 통계용)
#
# 호출: LaunchAgent 매 6시간 (cron 부담 최소화)

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
CRED="${HOME}/.claude/.credentials.json"
LEDGER="${BOT_HOME}/ledger/long-lived-token-healthcheck.jsonl"
LOG="${BOT_HOME}/logs/long-lived-token-healthcheck.log"

mkdir -p "$(dirname "$LEDGER")" "$(dirname "$LOG")"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

if [[ ! -f "$CRED" ]]; then
    log "ERROR: credentials.json 없음 — $CRED"
    exit 1
fi

# accessToken 추출 (Iron Law 4: 응답·로그에 평문 노출 금지)
TOKEN=$(python3 -c "import json; print(json.load(open('$CRED'))['claudeAiOauth']['accessToken'])" 2>/dev/null || echo "")

if [[ -z "$TOKEN" ]]; then
    log "ERROR: accessToken 추출 실패"
    exit 1
fi

# Anthropic API ping (가장 저렴한 호출 — haiku, 1 token output)
HTTP_CODE=$(curl -sS -o /tmp/lltkn-resp.$$ -w "%{http_code}" -X POST https://api.anthropic.com/v1/messages \
    -H "authorization: Bearer $TOKEN" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -H "content-type: application/json" \
    --data '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"."}]}' \
    2>/dev/null || echo "000")
RESP=$(cat /tmp/lltkn-resp.$$ 2>/dev/null || echo "")
rm -f /tmp/lltkn-resp.$$

if [[ "$HTTP_CODE" == "200" ]]; then
    log "✅ token healthy (HTTP 200)"
    printf '{"ts":"%s","result":"ok","http":200}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LEDGER"
    exit 0
fi

# 401/403/기타 — invalid 가능성
ERR_TYPE=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',{}).get('type','unknown'))" 2>/dev/null || echo "parse_error")
log "❌ token UNHEALTHY (HTTP $HTTP_CODE, err=$ERR_TYPE)"
printf '{"ts":"%s","result":"fail","http":%s,"err_type":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HTTP_CODE" "$ERR_TYPE" >> "$LEDGER"

# Discord critical 알림 — 쿨다운 6시간 (헬스체크 주기와 동일)
COOLDOWN_FILE="/tmp/jarvis-lltkn-alert.cooldown"
NOW=$(date +%s)
LAST=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo "0")
if (( NOW - LAST > 21600 )); then
    echo "$NOW" > "$COOLDOWN_FILE"
    if [[ -x "${BOT_HOME}/scripts/alert.sh" ]]; then
        bash "${BOT_HOME}/scripts/alert.sh" \
            critical \
            "🛑 Long-lived OAuth token UNHEALTHY" \
            "HTTP $HTTP_CODE / err=$ERR_TYPE — 모든 자비스 크론이 곧 실패할 가능성. 주인님 수동 조치 필요: \`claude auth logout && claude setup-token\` 후 토큰 갱신." \
            2>/dev/null || log "alert.sh 호출 실패"
    fi
fi

exit 1
