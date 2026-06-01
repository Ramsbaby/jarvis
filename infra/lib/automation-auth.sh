#!/usr/bin/env bash
# automation-auth.sh — 자동화(크론·봇) 전용 인증 주입 [B안: 듀얼 토큰]
#
# 배경 (2026-06-01, "토큰 무한 소멸" 사후 재설계):
#   자비스의 모든 자동화(크론 ~90개 + 봇 SDK 에이전트)가 ~/.claude/.credentials.json
#   하나를 공유하면, short-lived OAuth 토큰 만료 시 여러 프로세스가 동시에 refresh →
#   refresh_token 재사용 → Anthropic이 보안상 revoke → 전원 401(토큰 무한 소멸).
#
# B안 해결:
#   - credentials.json = 주인님 풀스코프 로그인(claude auth login). 원격제어/인터랙티브 전용.
#   - 자동화 = refresh가 "없는" long-lived 토큰(sk-ant-oat01-)을 CLAUDE_CODE_OAUTH_TOKEN으로 주입.
#     long-lived 토큰은 refresh_token이 없으므로 재사용 레이스가 *구조적으로* 불가능하다.
#
# 불변식:
#   1. 이 파일을 source한 프로세스(크론·봇)는 credentials.json을 refresh하지 않는다.
#   2. 자동화 토큰은 단일 파일(LONG_LIVED_TOKEN_FILE)이 SSoT. 회전은 long-lived-token-rotate.sh.
#   3. 이미 CLAUDE_CODE_OAUTH_TOKEN이 설정돼 있으면 존중한다(부모 상속/중첩 호출).
#
# 사용: bot-cron.sh / jarvis-cron.sh / bot-preflight.sh 상단에서 `source` 한다.
#       source "${BOT_HOME}/lib/automation-auth.sh" 2>/dev/null || true

# 멱등 가드 (set -e 안전: && 대신 if 블록 사용)
if [[ -n "${_JARVIS_AUTOMATION_AUTH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_JARVIS_AUTOMATION_AUTH_LOADED=1

_jarvis_inject_automation_token() {
    # 이미 주입돼 있으면(부모 상속 등) 존중하고 종료 — 불변식 3
    if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        return 0
    fi

    local token_file="${LONG_LIVED_TOKEN_FILE:-${HOME}/.claude-bot/.long-lived-token}"
    if [[ -r "$token_file" ]]; then
        local tok
        tok="$(cat "$token_file" 2>/dev/null || true)"
        # long-lived OAuth 토큰 형식 검증 (평문은 로그에 남기지 않음 — Iron Law 4)
        if [[ "$tok" == sk-ant-oat01-* ]]; then
            export CLAUDE_CODE_OAUTH_TOKEN="$tok"
            return 0
        fi
    fi

    # 토큰 없음/형식 오류 — 경고만 (하드 차단은 자동화 전체 중단이라 지양).
    # 이 경우 claude는 credentials.json으로 폴백하지만, long-lived-token-healthcheck(6h)가
    # 토큰 건강을 감시하므로 죽은/없는 토큰은 선제 경보된다.
    # 복구: claude setup-token  →  long-lived-token-rotate.sh '<sk-ant-oat01-...>'
    echo "[automation-auth] ⚠️ long-lived 토큰 없음/형식오류 (${token_file}) — credentials.json 폴백 (레이스 위험: 토큰 회전 필요)" >&2
    return 1
}

_jarvis_inject_automation_token || true
