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
# 호출: LaunchAgent 매 30분 (StartInterval=1800 — 2026-06-12 주석 실측 정정, 구 "매 6시간"은 stale)

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
    _TOKEN_SRC="isolated-bot"
else
    TOKEN=$(python3 -c "import json; print(json.load(open('$CRED'))['claudeAiOauth']['accessToken'])" 2>/dev/null || echo "")
    _TOKEN_SRC="main"
fi

if [[ -z "$TOKEN" ]]; then
    log "ERROR: accessToken 추출 실패"
    exit 1
fi

# 2026-06-12 재설계: 메인 토큰 감시를 "시간 예측"에서 "검증된 실패 시그니처"로 전환.
# 실측(06-12): CLI는 만료 후 첫 거부 시점에 지연 갱신함 (만료 09:40 → 갱신 09:51).
#   만료 임박·직후 수 분~수 시간 stale은 정상 창 → 알림 대상 아님 (기존 T-60분 예고가 하루 2~3회 오경보).
# 실패 시그니처 2종만 알림 (독립 감사 반영):
#   (1) 폐기 의심: expiresAt이 미래(5분+)인데 API 401 — 유효 중 패밀리 폐기 (5/29형) → critical. 5초 후 재검 1회로 오탐 차단.
#   (2) 장기 미갱신: 만료 후 12시간+ 파일 그대로 — CLI 장기 미사용(정상 가능) 또는 갱신 불능 → info (24h 1회)
# 커버리지 한계 (정직 명시 — 독립 감사 C-2): 6/11형(만료 후 갱신 시도 중 패밀리 사망)은 expiresAt이 과거라
#   (1)에 안 걸리고, 외부에서 refresh를 시험하는 것은 금지라 실시간 탐지 불가. 원인 차단은 llm-gateway
#   격리 토큰 주입(v4)이 담당, 여기서는 (2)가 늦은 안전망 + llm-gateway 401 critical 알림이 즉시 경보.
#   "CLI 활동 흔적" 휴리스틱은 06-12 실측 결과 야간 크론 transcript가 ~/.claude/projects를 오염시켜
#   (매일 밤 오탐 확정) 채택 불가 판정.
# 갱신 메커니즘 자체는 불간섭 — refresh 엔드포인트 호출 영구 금지 (~/CLAUDE.md 0순위). 검사는 읽기 전용 /v1/models만.
MAIN_EXP_MS=$(python3 -c "import json; print(json.load(open('$CRED'))['claudeAiOauth'].get('expiresAt',0))" 2>/dev/null || echo "0")
NOW_MS_CHK=$(date +%s000)
# 읽기 전용 /v1/models 검사 — 401이면 성공(0) 리턴, 에러 종류를 MAIN_ERR_TYPE에 기록 (refresh 비호출)
_main_token_401() {
    local tk resp http
    tk=$(python3 -c "import json; print(json.load(open('$CRED'))['claudeAiOauth']['accessToken'])" 2>/dev/null || echo "")
    [[ -n "$tk" ]] || return 1
    resp="/tmp/lltkn-main-resp.$$"
    http=$(curl -sS -o "$resp" -w "%{http_code}" --max-time 10 https://api.anthropic.com/v1/models \
        -H "authorization: Bearer $tk" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null || true)
    http="${http:0:3}"   # curl 부분 실패 시 이중 출력("401000" 등) 정규화 — 독립 감사 M-2
    MAIN_ERR_TYPE=$(python3 -c "import json; print(json.load(open('$resp')).get('error',{}).get('type','unknown'))" 2>/dev/null || echo "unknown")
    rm -f "$resp"
    [[ "$http" == "401" ]]
}
if (( MAIN_EXP_MS > 0 )); then
    MAIN_REMAIN=$(( (MAIN_EXP_MS - NOW_MS_CHK) / 1000 ))
    if (( MAIN_REMAIN > 300 )); then
        # (1) 폐기 시그니처 — 만료 5분+ 전(시계 오차 마진)인데 401이면 비정상
        MAIN_ERR_TYPE="unknown"
        if _main_token_401; then
            sleep 5   # /login·갱신 직후 파일 교체 창의 1회성 오탐 차단 — 재독 + 재검 (독립 감사 M-3)
            if _main_token_401; then
                REVOKE_CD_FILE="/tmp/jarvis-main-token-revoked.cooldown"
                NOW_S2=$(date +%s)
                LAST_S2=$(cat "$REVOKE_CD_FILE" 2>/dev/null || echo "0")
                [[ "$LAST_S2" =~ ^[0-9]+$ ]] || LAST_S2=0   # 쿨다운 파일 오염 시 즉사 방지 — 독립 감사 M-1
                if (( NOW_S2 - LAST_S2 > 1500 )); then  # 실행 주기 1800s와 경계 충돌 방지 — 독립 감사 M-4
                    echo "$NOW_S2" > "$REVOKE_CD_FILE"
                    log "🛑 메인 토큰 폐기 의심 — 만료 ${MAIN_REMAIN}초 전인데 HTTP 401 (err=${MAIN_ERR_TYPE}, 재검 포함 2회)"
                    printf '{"ts":"%s","result":"main-token-revoked-suspect","remainSecs":%s,"err_type":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MAIN_REMAIN" "$MAIN_ERR_TYPE" >> "$LEDGER"
                    if [[ -x "${BOT_HOME}/scripts/alert.sh" ]]; then
                        bash "${BOT_HOME}/scripts/alert.sh" \
                            critical \
                            "🛑 메인 OAuth 토큰 폐기 의심 (만료 전 401)" \
                            "만료 시각이 아직 미래인데 API가 거부 (err=${MAIN_ERR_TYPE}, 5초 간격 2회 확인) = 갱신 키 패밀리 폐기 시그니처 (5/29 사고 패턴). 봇·크론(격리 토큰)은 무관. 조치: \`claude /login\` 재로그인." \
                            2>/dev/null || log "alert.sh 호출 실패"
                    fi
                fi
            fi
        fi
    elif (( MAIN_REMAIN < -43200 )); then
        # (2) 만료 후 12시간+ 미갱신 — 지연 갱신 정상 창(분~수 시간)과 야간 공백(~10h)은 침묵
        STALE_CD_FILE="/tmp/jarvis-main-token-stale12h.cooldown"
        NOW_S2=$(date +%s)
        LAST_S2=$(cat "$STALE_CD_FILE" 2>/dev/null || echo "0")
        [[ "$LAST_S2" =~ ^[0-9]+$ ]] || LAST_S2=0   # 쿨다운 파일 오염 시 즉사 방지 — 독립 감사 M-1
        if (( NOW_S2 - LAST_S2 > 86400 )); then  # 24시간 쿨다운
            echo "$NOW_S2" > "$STALE_CD_FILE"
            log "🔑 메인 토큰 만료 후 $(( -MAIN_REMAIN / 3600 ))시간 미갱신"
            printf '{"ts":"%s","result":"main-token-stale-12h","remainSecs":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MAIN_REMAIN" >> "$LEDGER"
            if [[ -x "${BOT_HOME}/scripts/alert.sh" ]]; then
                bash "${BOT_HOME}/scripts/alert.sh" \
                    info \
                    "🔑 메인 OAuth 토큰 만료 후 12시간+ 미갱신" \
                    "CLI 장기 미사용이면 정상 (다음 사용 시 자동 갱신). CLI를 쓰는데도 이 알림이 반복되면 갱신 실패 — \`claude /login\` 점검. 봇·크론(격리 토큰)은 무관." \
                    2>/dev/null || log "alert.sh 호출 실패"
            fi
        fi
    fi
fi

# 2026-06-12 폐지 (독립 감사 C-1): 구 "T-60분 만료 임박" critical 예측 경보 블록 제거.
# 사유: 격리 토큰 존재 시 휴면(dead code)이었으나, 격리 토큰 파일 소실 폴백 경로에서 부활해
#   "시간 예측 알림 폐지" 재설계와 모순 — lazy 갱신이 정상 동작이므로 만료 임박은 사고가 아님.
#   메인 토큰 감시는 위 시그니처 블록(폐기 의심·장기 미갱신)이 전담.

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
[[ "$LAST" =~ ^[0-9]+$ ]] || LAST=0   # 쿨다운 파일 오염 시 즉사 방지 — 독립 감사 M-1
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
