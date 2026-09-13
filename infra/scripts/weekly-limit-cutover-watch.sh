#!/usr/bin/env bash
set -euo pipefail

# weekly-limit-cutover-watch.sh
# 2026-09-14 Claude Code 주간 한도 정책 전환(임시 50%→영구 25%, 실질 17% 감소) 대응 임시 감시.
# 기존 daily-usage-report.sh(매일 05:55, jarvis-lite)보다 낮은 임계값으로,
# jarvis-system 채널에 능동 경보한다. 전환 안정화 후(예: 2026-09-21) 비활성화 검토.
#
# 실행 예: BOT_HOME=/Users/ramsbaby/.openclaw-data/runtime /bin/bash \
#   /Users/ramsbaby/.openclaw-data/runtime/scripts/weekly-limit-cutover-watch.sh

CACHE="${HOME}/.claude/usage-cache.json"
COOLDOWN_FILE="${HOME}/.openclaw-data/runtime/state/weekly-limit-cutover-watch.last-alert"
COOLDOWN_SEC=10800  # 3시간 — 동일 경보 중복 발송 방지
THRESHOLD=65        # 9/14 이후 여유 감소를 감안해 daily report(80%)보다 낮게 설정

if [[ ! -f "${CACHE}" ]]; then
    echo "usage-cache.json 없음: ${CACHE}"
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq 없음 — 검사 불가"
    exit 0
fi

OK=$(jq -r '.ok // false' "${CACHE}" 2>/dev/null || echo "false")

_should_alert() {
    local now last
    now=$(date +%s)
    last=$(cat "${COOLDOWN_FILE}" 2>/dev/null || echo "0")
    [[ $(( now - last )) -ge ${COOLDOWN_SEC} ]]
}

_mark_alerted() {
    date +%s > "${COOLDOWN_FILE}" 2>/dev/null || true
}

source "${HOME}/projects/jarvis/infra/lib/discord-route.sh"

if [[ "${OK}" != "true" ]]; then
    REASON=$(jq -r '.reason // "unknown"' "${CACHE}" 2>/dev/null || echo "unknown")
    echo "usage-cache 갱신 실패 (reason=${REASON}) — 주간 한도 실측 불가"
    if _should_alert; then
        discord_route critical "주간 한도 감시 중단" "reason=${REASON},cache=${CACHE}"
        _mark_alerted
    fi
    exit 0
fi

SEVEN_D=$(jq -r '.sevenD.pct // 0' "${CACHE}" 2>/dev/null || echo 0)
SONNET_7D=$(jq -r '.sonnet.pct // 0' "${CACHE}" 2>/dev/null || echo 0)

echo "7일 사용률: ${SEVEN_D}% / Sonnet 7일: ${SONNET_7D}% (경보 임계 ${THRESHOLD}%)"

if (( SEVEN_D >= THRESHOLD || SONNET_7D >= THRESHOLD )); then
    if _should_alert; then
        discord_route critical "주간 한도 임계 근접 (9/14 전환 대비)" \
            "7일=${SEVEN_D}%,Sonnet7일=${SONNET_7D}%,임계=${THRESHOLD}%"
        _mark_alerted
    else
        echo "임계 초과했으나 쿨다운 중 — 발송 생략"
    fi
fi

exit 0
