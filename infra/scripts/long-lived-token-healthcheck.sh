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

# 2026-05-30 폐기 (claude 먹통 사고): claude 바이너리 래퍼 자동 재설치 블록 영구 제거.
# 근본원인: cp가 ~/.local/bin/claude 심링크를 따라가 versions/<ver> 진짜 바이너리(215MB)를
#   2KB 래퍼로 덮어씀 → 래퍼 _REAL=자기자신 → 무한재귀 → claude 전면 먹통.
#   이 블록이 30분 주기로 진짜 바이너리를 반복 파괴 = 5/30 "하루종일 로그인 풀림"의 근본원인
#   (21:04 healthcheck 실행이 2.1.157 바이너리를 래퍼로 덮은 것을 실측 확인).
# 대체: 봇 격리는 봇 plist의 CLAUDE_CODE_OAUTH_TOKEN env로 충분 — claude 바이너리를 건드릴 필요 없음.
# 래퍼 소스 폐기됨: ~/.local/bin/claude-iso-wrapper.sh.DEPRECATED-* + infra/scripts/claude-iso-wrapper.sh.DEPRECATED-*
# 절대 복원 금지. 봇 격리가 필요하면 env 또는 CLAUDE_CONFIG_DIR 방식만 사용할 것.

if [[ ! -f "$CRED" ]]; then
    log "ERROR: credentials.json 없음 — $CRED"
    exit 1
fi

# accessToken + expiresAt 추출 (Iron Law 4: 응답·로그에 평문 노출 금지)
# 2026-05-30: 봇·크론이 실제 쓰는 격리 long-lived 토큰(~/.claude-bot/.long-lived-token)을 우선 감시.
# (감사 지적: 기존엔 메인 ~/.claude creds를 봄 = 봇 실제 인증 경로 미감시. 격리 토큰이 8h 가설로
#  오늘 밤 죽을 수 있으므로 이 토큰을 감시해 즉시 알림 = 안전망.)
_ISO_TOKEN_FILE="${HOME}/.claude-bot/.long-lived-token"
if [[ -r "$_ISO_TOKEN_FILE" ]]; then
    TOKEN="$(cat "$_ISO_TOKEN_FILE")"
    EXPIRES_AT_MS=0   # 격리 토큰은 raw bearer(메타 없음) → HTTP 200 여부로만 판정
    _TOKEN_SRC="isolated-bot"
else
    TOKEN=$(python3 -c "import json; print(json.load(open('$CRED'))['claudeAiOauth']['accessToken'])" 2>/dev/null || echo "")
    EXPIRES_AT_MS=$(python3 -c "import json; print(json.load(open('$CRED'))['claudeAiOauth'].get('expiresAt',0))" 2>/dev/null || echo "0")
    _TOKEN_SRC="main"
fi

if [[ -z "$TOKEN" ]]; then
    log "ERROR: accessToken 추출 실패"
    exit 1
fi

# 2026-06-10 추가: 메인 토큰 독립 감시 — 격리 토큰 감시 중에도 메인 credentials.json 만료를 별도 확인.
# 사고: 6/10 메인 토큰 10:10 KST 만료 → statusline 사용량 4시간+ 침묵 401. 격리 토큰만 감시해 사각지대.
# 영향 범위: statusline(update-usage-cache.py) 등 메인 토큰 legacy 소비자. 봇·크론(격리 토큰)은 무관.
MAIN_EXP_MS=$(python3 -c "import json; print(json.load(open('$CRED'))['claudeAiOauth'].get('expiresAt',0))" 2>/dev/null || echo "0")
NOW_MS_CHK=$(date +%s000)
if (( MAIN_EXP_MS > 0 )); then
    MAIN_REMAIN=$(( (MAIN_EXP_MS - NOW_MS_CHK) / 1000 ))
    if (( MAIN_REMAIN < 3600 )); then
        MAIN_CD_FILE="/tmp/jarvis-main-token-expire.cooldown"
        NOW_S2=$(date +%s)
        LAST_S2=$(cat "$MAIN_CD_FILE" 2>/dev/null || echo "0")
        if (( NOW_S2 - LAST_S2 > 21600 )); then  # 6시간 쿨다운
            echo "$NOW_S2" > "$MAIN_CD_FILE"
            if (( MAIN_REMAIN < 0 )); then
                MAIN_MSG="이미 만료 ($(( -MAIN_REMAIN / 60 ))분 경과)"
            else
                MAIN_MSG="${MAIN_REMAIN}초 후 만료"
            fi
            log "🔑 메인 토큰(credentials.json) ${MAIN_MSG} — statusline 등 legacy 소비자 영향"
            printf '{"ts":"%s","result":"main-token-stale","remainSecs":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MAIN_REMAIN" >> "$LEDGER"
            if [[ -x "${BOT_HOME}/scripts/alert.sh" ]]; then
                bash "${BOT_HOME}/scripts/alert.sh" \
                    info \
                    "🔑 메인 OAuth 토큰 ${MAIN_MSG}" \
                    "봇·크론(격리 토큰)은 정상. statusline 사용량 표시 등 메인 토큰 소비자만 영향. 복구: 새 터미널 또는 현재 세션에서 \`claude /login\`." \
                    2>/dev/null || log "alert.sh 호출 실패"
            fi
        fi
    fi
fi

# 2026-05-20 추가: 만료 임박 사전 경보 (401 사후 적발 대신 T-60분 사전 알림)
# 사고: 5/20 18:24 만료를 21:17 healthcheck가 사후 적발 → 22:03 주인님이 /login 수동 복구.
#       이제 expiresAt이 60분 이내면 즉시 critical 알림.
NOW_MS=$(date +%s000)
REMAIN_SECS=$(( (EXPIRES_AT_MS - NOW_MS) / 1000 ))
if (( EXPIRES_AT_MS > 0 && REMAIN_SECS > 0 && REMAIN_SECS < 3600 )); then
    EXPIRE_COOLDOWN_FILE="/tmp/jarvis-lltkn-expire-soon.cooldown"
    NOW_S=$(date +%s)
    LAST_S=$(cat "$EXPIRE_COOLDOWN_FILE" 2>/dev/null || echo "0")
    if (( NOW_S - LAST_S > 1800 )); then  # 30분 쿨다운
        echo "$NOW_S" > "$EXPIRE_COOLDOWN_FILE"
        log "⏰ 토큰 만료 임박 — ${REMAIN_SECS}초 남음"
        if [[ -x "${BOT_HOME}/scripts/alert.sh" ]]; then
            bash "${BOT_HOME}/scripts/alert.sh" \
                critical \
                "⏰ Claude OAuth 토큰 ${REMAIN_SECS}초 후 만료" \
                "401 사후 적발이 아닌 T-${REMAIN_SECS}s 사전 알림. 즉시 \`claude /login\` 또는 \`claude setup-token\` 후 자비스 정상 작동 보장." \
                2>/dev/null || log "alert.sh 호출 실패"
        fi
    fi
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
    # 2026-05-30: 생존 플래그 갱신 — claude 바이너리 래퍼(~/.local/bin/claude)가 이 플래그(40분 신선도)로
    # 격리 토큰 주입 여부를 결정. 토큰 살아있으면 touch → 래퍼가 격리 토큰 주입. 죽으면 아래서 rm → 메인 폴백.
    if [[ "${_TOKEN_SRC:-}" == "isolated-bot" ]]; then touch "${HOME}/.claude-bot/.token-alive" 2>/dev/null || true; fi
    exit 0
fi

# 401/403/기타 — invalid 가능성
ERR_TYPE=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',{}).get('type','unknown'))" 2>/dev/null || echo "parse_error")
log "❌ token UNHEALTHY (HTTP $HTTP_CODE, err=$ERR_TYPE)"
printf '{"ts":"%s","result":"fail","http":%s,"err_type":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HTTP_CODE" "$ERR_TYPE" >> "$LEDGER"
# 2026-05-30: 격리 토큰 죽음 → 생존 플래그 제거. 래퍼가 40분 내 메인 폴백으로 자동 전환(자가복구).
if [[ "${_TOKEN_SRC:-}" == "isolated-bot" ]]; then rm -f "${HOME}/.claude-bot/.token-alive" 2>/dev/null || true; fi

# 2026-05-30: 401 시 자동 --force 제거 (refresh_token reuse race 차단).
# --force가 캐시된 refresh_token을 stale로 만들어 다음 SDK 갱신이 reuse detection →
# 토큰 패밀리 revoke (05-30 13:01 회전 → 13:52 사망 실측). 또한 401 = 패밀리가 이미 revoke된
# 상태면 --force로 복구 불가(수동 /login 필요). → 감지·알림 전용으로 강등.
if [[ "$HTTP_CODE" == "401" ]]; then
    log "🔴 401 감지 — 자동 --force 비활성화 (reuse race 차단). 알림만 발송"
fi

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
