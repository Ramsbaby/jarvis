#!/usr/bin/env bash
# boot-auth-check.sh — 부팅 후 Claude 인증 상태 검증 + 실패 시 ntfy 알림
# LaunchAgent: ai.jarvis.boot-auth-check (RunAtLoad, 1회 실행)

set -euo pipefail

BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BOT_HOME}/lib/log-utils.sh" 2>/dev/null || true

LOG_FILE="${BOT_HOME}/logs/boot-auth-check.log"
MONITORING_CONFIG="${BOT_HOME}/config/monitoring.json"
BOOT_WAIT_SECONDS=120

log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"; }
log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"; }

send_ntfy_alert() {
    local msg="$1"
    local topic
    topic=$(jq -r '.ntfy.topic // empty' "$MONITORING_CONFIG" 2>/dev/null || echo "")
    if [[ -z "$topic" ]]; then return; fi
    curl -s --max-time 10 \
        -H "Title: Jarvis 인증 경고" \
        -H "Priority: high" \
        -H "Tags: warning,lock" \
        -d "$msg" \
        "https://ntfy.sh/${topic}" >/dev/null 2>&1 || true
}

send_discord_alert() {
    local msg="$1"
    local webhook_url
    webhook_url=$(jq -r '.webhook.url // empty' "$MONITORING_CONFIG" 2>/dev/null || echo "")
    if [[ -z "$webhook_url" ]]; then return; fi
    curl -s --max-time 10 \
        -H "Content-Type: application/json" \
        -d "{\"content\": \"$msg\"}" \
        "$webhook_url" >/dev/null 2>&1 || true
}

main() {
    log_info "부팅 후 인증 검증 시작 — ${BOOT_WAIT_SECONDS}초 대기 중..."
    sleep "$BOOT_WAIT_SECONDS"

    # 네트워크 연결 확인 (macOS 네이티브 네트워크 상태 — 외부 ping 불필요)
    local retry=0
    local max_retries=60  # 5초×60회 = 최대 5분
    while ! scutil --nwi 2>/dev/null | grep -q "Network reachable"; do
        retry=$((retry + 1))
        if [[ $retry -ge $max_retries ]]; then
            log_error "네트워크 연결 실패 (5초×${max_retries}회). 알림 전송."
            send_ntfy_alert "🔴 맥미니 부팅 후 네트워크 연결 실패. 확인 필요."
            send_discord_alert "🔴 **[boot-auth-check]** 부팅 후 네트워크 연결 실패."
            exit 1
        fi
        log_warn "네트워크 대기 중... (${retry}/${max_retries})"
        sleep 5
    done
    log_info "네트워크 정상"

    # Claude 인증 확인 (간단한 프롬프트 테스트)
    local auth_result
    auth_result=$(timeout 30 claude -p "ping" --output-format json 2>&1 || true)

    if echo "$auth_result" | grep -q "Not logged in"; then
        log_error "Claude 인증 만료 감지"
        local msg="⚠️ 맥미니 재부팅 후 Claude 로그인 필요. SSH 접속 후 \`claude /login\` 실행 필요."
        send_ntfy_alert "$msg"
        send_discord_alert "⚠️ **[boot-auth-check]** Claude 인증 만료. \`claude /login\` 필요."
        exit 1
    elif echo "$auth_result" | grep -qiE "error|fail|refused"; then
        log_warn "Claude 응답 이상: ${auth_result:0:100}"
        send_ntfy_alert "⚠️ 맥미니 부팅 후 Claude 상태 이상. 확인 권장."
        exit 0
    else
        log_info "Claude 인증 정상"
        exit 0
    fi
}

main "$@"
