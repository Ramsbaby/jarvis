#!/usr/bin/env bash
# token-health-check.sh — Anthropic 토큰 헬스체크
# 2026-05-04 신설: long-lived token (sk-ant-oat01-) 사용 환경에서 인증 헬스 모니터링
#
# 역할:
#   - 매시간 claude -p로 인증 검증
#   - 실패 시 jarvis-system 디스코드 알림 + 봇 재시작
#   - 성공 시 헬스 로그만 기록 (조용히)
#
# crontab: 0 * * * * /bin/bash ~/.jarvis/scripts/token-health-check.sh  # ALLOW-DOTJARVIS

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
# OAuth 모드 (2026-05-06 A안): long-lived API key 의존 제거. credentials.json만 검증.
unset ANTHROPIC_API_KEY

BOT_HOME="${HOME}/.jarvis"
LOG="${BOT_HOME}/logs/token-health.log"
COOLDOWN="${BOT_HOME}/state/token-health-alert.ts"  # 중복 알림 차단 (1시간 쿨다운)
CREDENTIALS_FILE="${HOME}/.claude/.credentials.json"
mkdir -p "$(dirname "$LOG")" "$(dirname "$COOLDOWN")"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

# OAuth credentials.json 존재 + 만료 검증
if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
    log "🔴 credentials.json 없음 — /login 필요"
    # 알림으로 fall-through (아래 실패 처리 분기)
    RESULT='{"is_error":true,"error":"no_credentials"}'
fi

# 인증 테스트 (60s timeout — 첫 호출은 CLAUDE.md 로딩 등으로 느림)
# 2026-05-04: python3 json.loads는 응답 텍스트의 제어 문자에 약함. grep 단순 매칭이 robust.
set +e  # timeout 124 등 비정상 종료에도 RESULT 할당 보장
RESULT=$(timeout 60 claude -p "ok" --output-format json 2>&1)
RC=$?
set -e
if [[ $RC -ne 0 && -z "$RESULT" ]]; then
    RESULT='{"is_error":true,"error":"timeout_or_crash","exit_code":'"$RC"'}'
fi

# is_error:false 매칭 (인증·실행 모두 성공)
if echo "$RESULT" | grep -q '"is_error":false'; then
    log "✅ 토큰 헬스 OK (key prefix: ${ANTHROPIC_API_KEY:0:18}...)"
    exit 0
fi

# 401 명시적 감지 (디버깅용)
if echo "$RESULT" | grep -qiE "Invalid API key|401|authentication_error|Failed to authenticate"; then
    log "🔴 명시적 인증 실패 감지: 401 / Invalid API key"
fi

# 실패 — 쿨다운 체크 (1시간)
NOW=$(date +%s)
LAST=0
[[ -f "$COOLDOWN" ]] && LAST=$(cat "$COOLDOWN" 2>/dev/null || echo 0)
if (( NOW - LAST < 3600 )); then
    log "⚠️ 토큰 헬스 실패 (쿨다운 중 — 1시간 내 알림 발송됨, 무시)"
    exit 1
fi

log "❌ 토큰 헬스 실패 — 즉시 알림 발송"
echo "$NOW" > "$COOLDOWN"

# Discord 알림 (jarvis-system) — 2026-05-06 fallback chain 강화
# 주 경로 실패 시 자동 fallback (24시간 무시 사고 방지)
ALERT_MSG="🔴 **토큰 헬스체크 실패** ($(TZ=Asia/Seoul date '+%H:%M KST'))
OAuth credentials.json 인증 실패. 즉시 조치: \`/login\` (Claude Code)"

NOTIFY_OK=false
if [[ -f "${HOME}/jarvis/runtime/lib/discord-notify-bash.sh" ]]; then
    if source "${HOME}/jarvis/runtime/lib/discord-notify-bash.sh" 2>/dev/null \
       && discord_notify "jarvis-system" "$ALERT_MSG" 2>/dev/null; then
        NOTIFY_OK=true
    else
        log "discord-notify-bash 실패 → alert.sh fallback"
    fi
fi
if ! $NOTIFY_OK && [[ -f "${BOT_HOME}/scripts/alert.sh" ]]; then
    if bash "${BOT_HOME}/scripts/alert.sh" critical "토큰 헬스체크 실패" "$ALERT_MSG" 2>/dev/null; then
        NOTIFY_OK=true
    else
        log "alert.sh 실패"
    fi
fi
if ! $NOTIFY_OK; then
    # 최종 fallback: macOS notification + ntfy (있으면)
    osascript -e "display notification \"$ALERT_MSG\" with title \"토큰 헬스 실패\"" 2>/dev/null || true
    if [[ -n "${NTFY_TOPIC:-}" ]]; then
        curl -s -X POST "${NTFY_SERVER:-https://ntfy.sh}/${NTFY_TOPIC}" -d "$ALERT_MSG" >/dev/null 2>&1 || true
    fi
    log "🚨 모든 Discord 알림 경로 실패 — macOS notification만 발송"
fi

exit 1
