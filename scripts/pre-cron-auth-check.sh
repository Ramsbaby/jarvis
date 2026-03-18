#!/usr/bin/env bash
# pre-cron-auth-check.sh — 아침 크론 클러스터 시작 전 Claude 인증 사전 확인
# 크론: 0 7 * * * (news-briefing 07:50 / morning-standup 09:15 전에 실행)
# 실패 시 ntfy + Discord 즉시 알림 → 수동 재로그인 유도

set -euo pipefail

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_FILE="${BOT_HOME}/logs/pre-cron-auth-check.log"
MONITORING_CONFIG="${BOT_HOME}/config/monitoring.json"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# ntfy 알림
send_ntfy() {
    local title="$1" msg="$2" priority="${3:-high}"
    local topic
    topic=$(jq -r '.ntfy.topic // empty' "$MONITORING_CONFIG" 2>/dev/null || echo "")
    if [[ -z "$topic" ]]; then return; fi
    curl -s --max-time 10 \
        -H "Title: $title" -H "Priority: $priority" -H "Tags: warning" \
        -d "$msg" "https://ntfy.sh/${topic}" >/dev/null 2>&1 || true
}

# Discord 웹훅 알림
send_discord() {
    local msg="$1"
    local webhook payload
    webhook=$(jq -r '.webhooks["jarvis-system"] // empty' "$MONITORING_CONFIG" 2>/dev/null || echo "")
    if [[ -z "$webhook" ]]; then return; fi
    # jq로 직렬화 — msg에 ", \, 개행 포함돼도 안전
    payload=$(jq -cn --arg content "$msg" '{"content":$content}' 2>/dev/null) || return
    curl -s --max-time 10 -H "Content-Type: application/json" \
        -d "$payload" "$webhook" >/dev/null 2>&1 || true
}

# 현재 로그인 계정 tier 확인
get_account_info() {
    local cred_file="${HOME}/.claude/.credentials.json"
    if [[ ! -f "$cred_file" ]]; then echo "credentials 없음"; return; fi
    python3 -c "
import json, datetime, sys
d = json.load(open('$cred_file'))
for k, v in d.items():
    if isinstance(v, dict) and 'accessToken' in v:
        tier = v.get('rateLimitTier','?')
        sub = v.get('subscriptionType','?')
        exp = v.get('expiresAt', 0)
        exp_str = datetime.datetime.fromtimestamp(exp/1000).strftime('%H:%M') if exp else '?'
        print(f'{sub}({tier}) 만료:{exp_str}')
" 2>/dev/null || echo "파싱 실패"
}

# 쿨다운: 1시간에 1번만 알림 (계정 전환 후 반복 알림 방지)
COOLDOWN_FILE="${BOT_HOME}/state/pre-cron-auth-alerted.ts"
if [[ -f "$COOLDOWN_FILE" ]]; then
    last_alert=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo "0")
    now=$(date +%s)
    if (( now - last_alert < 3600 )); then
        log "쿨다운 중 — 이미 최근 알림 발송됨, 스킵"
        exit 0
    fi
fi

log "Claude 인증 사전 확인 시작"

# PATH 설정 (크론 환경)
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS

_TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || echo "")

# claude -p 인증 테스트 (30초 타임아웃)
AUTH_RESULT=""
AUTH_EXIT=0
if [[ -n "${_TIMEOUT_CMD:-}" ]]; then
    AUTH_RESULT=$(${_TIMEOUT_CMD} 30 claude -p "ok" --output-format json 2>&1) || AUTH_EXIT=$?
else
    AUTH_RESULT=$(claude -p "ok" --output-format json 2>&1) || AUTH_EXIT=$?
fi

ACCOUNT_INFO=$(get_account_info)

if echo "$AUTH_RESULT" | grep -q "Not logged in"; then
    log "인증 실패: Not logged in (계정: $ACCOUNT_INFO)"
    echo "$(date +%s)" > "$COOLDOWN_FILE"
    MSG="🔴 [pre-cron-auth] Claude 로그인 필요\n계정: $ACCOUNT_INFO\n→ SSH 접속 후 \`claude login\` 실행\n아침 크론 07:50~09:15 실패 예정"
    send_ntfy "Jarvis 인증 만료" "$MSG" "urgent"
    send_discord "🔴 **[pre-cron-auth]** Claude 로그인 필요. 계정: \`$ACCOUNT_INFO\`\n아침 크론(news-briefing·morning-standup·board-meeting) 실패 예정. \`claude login\` 실행 필요."
    exit 1

elif (( AUTH_EXIT == 124 )); then
    log "인증 타임아웃 (30s) — 네트워크 또는 클로드 서비스 이상"
    echo "$(date +%s)" > "$COOLDOWN_FILE"
    send_ntfy "Jarvis Claude 타임아웃" "⚠️ claude -p 15초 타임아웃. 네트워크 확인 필요. 계정: $ACCOUNT_INFO" "high"
    exit 1

elif (( AUTH_EXIT != 0 )); then
    log "인증 응답 이상 (exit $AUTH_EXIT): ${AUTH_RESULT:0:100}"
    # 일시적 오류일 수 있으므로 critical 알림은 안 보냄
    exit 0

else
    log "인증 정상 (계정: $ACCOUNT_INFO)"
    rm -f "$COOLDOWN_FILE"

    # 만료 임박 경고: 3시간 이내 만료 예정이면 선제 알림
    EXPIRE_SOON=$(python3 -c "
import json, time, sys
cred = '${HOME}/.claude/.credentials.json'
try:
    d = json.load(open(cred))
    for v in d.values():
        if isinstance(v, dict) and 'expiresAt' in v:
            exp_ms = v.get('expiresAt', 0)
            remaining_min = (exp_ms/1000 - time.time()) / 60
            if 0 < remaining_min < 180:
                print(f'{int(remaining_min)}')
                sys.exit(0)
except Exception:
    pass
sys.exit(1)
" 2>/dev/null || echo "")

    if [[ -n "$EXPIRE_SOON" ]]; then
        log "⚠️ 토큰 만료 임박: ${EXPIRE_SOON}분 후 (계정: $ACCOUNT_INFO)"
        echo "$(date +%s)" > "$COOLDOWN_FILE"
        send_ntfy "Jarvis 토큰 만료 임박" "⚠️ Claude 토큰 ${EXPIRE_SOON}분 후 만료. 계정: $ACCOUNT_INFO → 지금 claude login 필요" "high"
        send_discord "⚠️ **[pre-cron-auth]** 토큰 **${EXPIRE_SOON}분 후 만료** 예정. 계정: \`$ACCOUNT_INFO\`\n지금 \`claude login\` 실행하지 않으면 오전 크론 401 발생합니다."
    fi

    exit 0
fi
