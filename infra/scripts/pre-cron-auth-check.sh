#!/usr/bin/env bash
# pre-cron-auth-check.sh — Claude 인증 상시 감시 (30분 주기)
# 크론: */30 * * * *
# 토큰 만료 4h 전 선제 경고 / 만료 즉시 ntfy 긴급 발송 → 수동 재로그인 유도

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG_FILE="${BOT_HOME}/logs/pre-cron-auth-check.log"
MONITORING_CONFIG="${BOT_HOME}/config/monitoring.json"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Shared libraries
source "${BOT_HOME}/lib/ntfy-notify.sh"
WEBHOOK="jarvis-system"
source "${BOT_HOME}/lib/discord-notify-bash.sh"

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

# 쿨다운 파일 (종류별 분리)
COOLDOWN_EXPIRED="${BOT_HOME}/state/auth-alerted-expired.ts"   # 만료 감지: 30분 쿨다운
COOLDOWN_WARNING="${BOT_HOME}/state/auth-alerted-warning.ts"   # 임박 경고: 4시간 쿨다운

_check_cooldown() {
    local file="$1" seconds="$2"
    [[ -f "$file" ]] || return 1
    local last now
    last=$(cat "$file" 2>/dev/null || echo "0")
    now=$(date +%s)
    (( now - last < seconds ))
}

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

# ── 인증 실패 분류 ─────────────────────────────────────────────────────────
_is_real_auth_failure() {
    # is_error:true + duration_api_ms:0 → API 호출조차 못한 실제 인증 실패
    # "Not logged in" 문자열도 동일 처리
    echo "$AUTH_RESULT" | grep -q "Not logged in" && return 0
    echo "$AUTH_RESULT" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    if d.get('is_error') and d.get('duration_api_ms', 1) == 0:
        sys.exit(0)
except: pass
sys.exit(1)" 2>/dev/null && return 0
    return 1
}

if (( AUTH_EXIT == 124 )); then
    log "인증 타임아웃 (30s) — 네트워크 또는 클로드 서비스 이상"
    if ! _check_cooldown "$COOLDOWN_EXPIRED" 1800; then
        date +%s > "$COOLDOWN_EXPIRED"
        send_ntfy "Jarvis Claude 타임아웃" "⚠️ claude -p 30s 타임아웃. 네트워크 확인 필요. 계정: $ACCOUNT_INFO" "high"
    fi
    exit 1

elif (( AUTH_EXIT != 0 )); then
    if _is_real_auth_failure; then
        log "🔴 인증 만료 감지 (exit $AUTH_EXIT) — 계정: $ACCOUNT_INFO"
        if ! _check_cooldown "$COOLDOWN_EXPIRED" 1800; then  # 30분 쿨다운
            date +%s > "$COOLDOWN_EXPIRED"
            send_ntfy "Jarvis 토큰 만료" "🔴 Claude 토큰 만료. 모든 크론 AUTH_ERROR 상태.\n계정: $ACCOUNT_INFO\n→ claude login 실행 필요" "urgent"
            send_discord "🔴 **[auth-watch]** Claude 토큰 만료 감지 ($(date '+%H:%M'))\n계정: \`$ACCOUNT_INFO\`\n모든 \`claude -p\` 태스크 실패 중 → **\`claude login\`** 실행 필요"
        fi
        exit 1
    else
        # 진짜 일시적 오류 (Claude 서비스 불안정 등)
        log "인증 응답 이상 (exit $AUTH_EXIT, 일시적): ${AUTH_RESULT:0:120}"
        exit 0
    fi

else
    log "인증 정상 (계정: $ACCOUNT_INFO)"
    rm -f "$COOLDOWN_EXPIRED"

    # 만료 임박 경고: 4시간 이내 만료 예정이면 선제 알림 (4h 쿨다운)
    EXPIRE_SOON=$(python3 -c "
import json, time, sys
cred = '${HOME}/.claude/.credentials.json'
try:
    d = json.load(open(cred))
    for v in d.values():
        if isinstance(v, dict) and 'expiresAt' in v:
            remaining_min = (v.get('expiresAt',0)/1000 - time.time()) / 60
            if 0 < remaining_min < 240:
                print(int(remaining_min))
                sys.exit(0)
except: pass
sys.exit(1)
" 2>/dev/null || echo "")

    if [[ -n "$EXPIRE_SOON" ]]; then
        log "⚠️ 토큰 만료 임박: ${EXPIRE_SOON}분 후 (계정: $ACCOUNT_INFO) — oauth-refresh.sh --force 호출"
        OAUTH_SCRIPT="${BOT_HOME}/infra/scripts/oauth-refresh.sh"

        # 갱신 전 expiresAt 기록 (false success 감지용)
        BEFORE_EXP=$(python3 -c "
import json
d=json.load(open('${HOME}/.claude/.credentials.json'))
v=d.get('claudeAiOauth',{})
print(int(v.get('expiresAt',0)))
" 2>/dev/null || echo "0")

        REFRESH_RESULT=""
        if [[ -x "$OAUTH_SCRIPT" ]]; then
            REFRESH_RESULT=$(bash "$OAUTH_SCRIPT" --force 2>&1) && REFRESH_OK=true || REFRESH_OK=false
        else
            log "❌ oauth-refresh.sh 없음: $OAUTH_SCRIPT"
            REFRESH_OK=false
        fi

        # 갱신 후 expiresAt 재확인 (exit 0이어도 실제 갱신 여부 검증)
        AFTER_EXP=$(python3 -c "
import json,datetime
d=json.load(open('${HOME}/.claude/.credentials.json'))
v=d.get('claudeAiOauth',{})
ts=int(v.get('expiresAt',0))
print(ts)
" 2>/dev/null || echo "0")

        if [[ "$REFRESH_OK" == true ]] && [[ "$AFTER_EXP" -gt "$BEFORE_EXP" ]]; then
            NEW_EXP=$(python3 -c "
import json,datetime
d=json.load(open('${HOME}/.claude/.credentials.json'))
v=d.get('claudeAiOauth',{})
ts=int(v.get('expiresAt',0))
print(datetime.datetime.fromtimestamp(ts/1000).strftime('%H:%M'))
" 2>/dev/null || echo "?")
            log "✅ 자동 갱신 성공 — 새 만료: ${NEW_EXP} (이전: $(python3 -c "import datetime; print(datetime.datetime.fromtimestamp(${BEFORE_EXP}/1000).strftime('%H:%M'))" 2>/dev/null))"
            ACCOUNT_INFO=$(get_account_info)
            rm -f "$COOLDOWN_WARNING"
            send_discord "✅ **[auth-watch]** 토큰 자동 갱신 완료 (→ ${NEW_EXP}) · 계정: \`$ACCOUNT_INFO\`"
        else
            # false success 또는 실제 실패 — 만료시각 변동 없음
            local_exp=$(python3 -c "
import json,datetime
d=json.load(open('${HOME}/.claude/.credentials.json'))
v=d.get('claudeAiOauth',{})
ts=int(v.get('expiresAt',0))
print(datetime.datetime.fromtimestamp(ts/1000).strftime('%H:%M'))
" 2>/dev/null || echo "?")
            log "❌ 자동 갱신 실패 (exit=${REFRESH_OK}, expiresAt 변동 없음) — ${REFRESH_RESULT:0:100}"
            if ! _check_cooldown "$COOLDOWN_WARNING" 14400; then
                date +%s > "$COOLDOWN_WARNING"
                send_ntfy "Jarvis 토큰 갱신 실패" "⚠️ ${EXPIRE_SOON}분 후 만료 (${local_exp})\noauth-refresh.sh 실패 → 수동 claude setup 필요\n계정: $ACCOUNT_INFO" "high"
                send_discord "⚠️ **[auth-watch]** 토큰 자동 갱신 실패. **${EXPIRE_SOON}분 후 만료** (${local_exp})\n계정: \`$ACCOUNT_INFO\` — 갱신 재시도 중 (다음 30분 체크 시 재시도)"
            fi
        fi
    else
        rm -f "$COOLDOWN_WARNING"
    fi

    exit 0
fi