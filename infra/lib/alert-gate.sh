#!/usr/bin/env bash
# alert-gate.sh — 알림 발송 게이트 (2026-07-27 신설)
#
# 목적: "정상을 반복 보고"하는 소음을 구조적으로 차단한다.
#   실측(2026-07-27): 7일 1,110건 = 일평균 158건. 그중 84%가 상태 무변화 반복.
#   원인: 대부분의 발송부가 수준 기반(level-triggered)이라 상태가 그대로여도 매 주기 보낸다.
#
# 원칙: 변화에만 알린다 (edge-triggered).
#   정상→이상  발송      이상→이상  억제(카운트만)
#   이상→정상  발송      정상→정상  침묵
#
# 사용법:
#   source "${BOT_HOME}/lib/alert-gate.sh"
#   if alert_gate "system-doctor" "$warn_count" "$signature"; then
#       ...발송...
#   fi
#   # 억제된 횟수는 alert_gate_suppressed 로 조회 (일일 요약용)
#
# 인자:
#   $1 key        발송처 식별자 (파일명에 쓰이므로 영숫자·하이픈만)
#   $2 severity   0 이면 정상, 1 이상이면 이상 건수
#   $3 signature  (선택) 이상 내용의 지문. 같은 이상이 계속되면 억제된다.
#                 생략 시 severity 만으로 판정한다.
#
# 반환: 0 = 발송하라, 1 = 억제하라
#
# 주의: 이 게이트는 "정상 반복"을 막기 위한 것이다.
#   진짜 실패가 방치되는 것을 숨기지 않도록, 억제된 건수는 반드시 카운트로 남기고
#   주간 감사(token-ledger-audit.sh)가 이를 리포트한다.

_ALERT_GATE_DIR="${BOT_HOME:-${HOME}/jarvis/runtime}/state/alert-gate"

alert_gate() {
    local key="$1" severity="${2:-0}" signature="${3:-}"
    # 키 위생: 경로 조작 방지
    key=$(printf '%s' "$key" | tr -cd 'A-Za-z0-9._-')
    [[ -n "$key" ]] || return 0   # 키가 이상하면 억제하지 않는다(알림 유실 방지)

    mkdir -p "$_ALERT_GATE_DIR" 2>/dev/null || return 0

    local f="${_ALERT_GATE_DIR}/${key}.state"
    local cur prev
    if (( severity > 0 )); then
        cur="ALERT|${signature:-$severity}"
    else
        cur="OK"
    fi
    prev=$(head -1 "$f" 2>/dev/null || echo "")

    if [[ "$cur" == "$prev" ]]; then
        # 상태 무변화 → 억제하고 카운트만 올린다
        local n
        n=$(sed -n '2p' "$f" 2>/dev/null || echo 0)
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        printf '%s\n%s\n%s\n' "$cur" "$((n + 1))" "$(date '+%Y-%m-%d %H:%M:%S')" > "$f"
        return 1
    fi

    # 상태 변화 → 발송 허용, 카운터 리셋
    printf '%s\n0\n%s\n' "$cur" "$(date '+%Y-%m-%d %H:%M:%S')" > "$f"
    return 0
}

# ── 시간 기반 억제 (rate limit) ──────────────────────────────────────────────
# 내용이 매번 달라 상태 비교가 무의미한 알림용. 예: "오답노트 N건 추출"은 매번 N이 다르지만
# 세션마다 받을 필요는 없다(실측: 7일 111회 = 일 16회).
# 첫 발송 후 ttl 초 동안 억제하고 그 사이 발생 건수만 센다.
#
#   if alert_ratelimit "mistake-extract" 86400; then ...발송... fi
#
# 반환: 0 = 발송하라, 1 = 억제하라
alert_ratelimit() {
    local key="$1" ttl="${2:-86400}"
    key=$(printf '%s' "$key" | tr -cd 'A-Za-z0-9._-')
    [[ -n "$key" ]] || return 0
    mkdir -p "$_ALERT_GATE_DIR" 2>/dev/null || return 0

    local f="${_ALERT_GATE_DIR}/${key}.rate"
    local now last n
    now=$(date +%s)
    last=$(head -1 "$f" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0

    if (( now - last < ttl )); then
        n=$(sed -n '2p' "$f" 2>/dev/null || echo 0)
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        printf '%s\n%s\n' "$last" "$((n + 1))" > "$f"
        return 1
    fi
    printf '%s\n0\n' "$now" > "$f"
    return 0
}

# 시간 억제로 눌린 건수 (다음 발송 시 "그 사이 N건 더 있었음"을 붙일 때 쓴다)
alert_ratelimit_pending() {
    local key="$1"
    key=$(printf '%s' "$key" | tr -cd 'A-Za-z0-9._-')
    sed -n '2p' "${_ALERT_GATE_DIR}/${key}.rate" 2>/dev/null || echo 0
}

# 억제된 횟수 조회 (일일/주간 요약에서 "N회 반복 억제됨"을 붙일 때 쓴다)
alert_gate_suppressed() {
    local key="$1"
    key=$(printf '%s' "$key" | tr -cd 'A-Za-z0-9._-')
    sed -n '2p' "${_ALERT_GATE_DIR}/${key}.state" 2>/dev/null || echo 0
}

# 직전 상태가 ALERT였는지 (복구 알림 문구 분기용)
alert_gate_was_alerting() {
    local key="$1"
    key=$(printf '%s' "$key" | tr -cd 'A-Za-z0-9._-')
    head -1 "${_ALERT_GATE_DIR}/${key}.state" 2>/dev/null | grep -q '^ALERT'
}
