#!/usr/bin/env bash
# proactive-engine-v2.sh — 자비스 선제 발화 데몬 v2 (영화 JARVIS 5패턴)
#
# 2026-05-14 — 1주 풀스택 Day 1 골격
# 스펙: ~/jarvis/runtime/specs/proactive-jarvis-v2-2026-05-14.md
# 결정: ~/jarvis/runtime/ledger/deep-interview-2026-05-14.jsonl
#
# Day 1: KeepAlive 데몬 + 시간대 + critical 예외 + 빈도 가드 (방법 1)
# Day 2-3: Mail/Cal event hook 통합 예정
# Day 4: 자가 후퇴 방법 2+3 통합 예정
# Day 5: 반응 학습 ledger 시작 예정
# Day 6: 도메인 알림 + 위트 통합 예정
# Day 7: 회고 인터뷰

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG="${BOT_HOME}/logs/proactive-engine-v2.log"
STATE_DIR="${BOT_HOME}/state"
FREQ_LEDGER="${STATE_DIR}/proactive-frequency.jsonl"
EVENT_QUEUE="${STATE_DIR}/proactive-event-queue.jsonl"
POLL_INTERVAL=300  # 5분

mkdir -p "$(dirname "$LOG")" "$STATE_DIR"

# 라이브러리 — discord 발화 (어제 추가한 discord_notify 래퍼 활용)
# shellcheck disable=SC1091
source "${BOT_HOME}/lib/discord-notify-bash.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [proactive-v2] $*" | tee -a "$LOG"; }

# ─── CPU 가드 (2026-05-11 오답노트 영구 등재) ──────────────────────
# 데몬 자신 CPU 폭주 시 자동 종료 → launchd가 재시작 → ThrottleInterval로 폭주 방지
_cpu_guard() {
    local own_cpu
    own_cpu=$(ps -o %cpu= -p $$ 2>/dev/null | tr -d ' ' | awk -F. '{print $1}')
    if [[ -z "$own_cpu" ]]; then
        return 0
    fi
    if (( own_cpu > 50 )); then
        log "🔴 CPU guard: self ${own_cpu}% > 50% — exit (launchd restart)"
        exit 1
    fi
}

# ─── 시간대 정책 (스펙 §5) ─────────────────────────────────────
# 반환: silent | critical_only | normal
get_time_mode() {
    local h
    h=$(date '+%-H')
    if (( h >= 0 && h < 7 )); then
        echo "silent"           # 00~07 수면
    elif (( h >= 7 && h < 9 )); then
        echo "critical_only"    # 07~09 출근 준비
    elif (( h >= 9 && h < 22 )); then
        echo "normal"           # 09~22 정상
    else
        echo "critical_only"    # 22~24 휴식
    fi
}

# ─── critical 예외 (스펙 §3 — 항상 통과 5개) ───────────────────
is_critical() {
    case "$1" in
        token_bot_failure|family_message|calendar_5min|card_anomaly|interview_notice)
            return 0 ;;
        *) return 1 ;;
    esac
}

# ─── 빈도 가드 (방법 1 — 스펙 §3.1) ────────────────────────────
# 1시간 내 3회+ 발화 누적 시 후퇴 (critical 제외는 emit 함수에서)
check_frequency_guard() {
    local cutoff
    cutoff=$(($(date +%s) - 3600))
    local recent=0
    if [[ -f "$FREQ_LEDGER" ]]; then
        recent=$(awk -v cut="$cutoff" '$1 > cut {c++} END {print c+0}' "$FREQ_LEDGER")
    fi
    (( recent < 3 ))
}

# ─── 발화 함수 (공통 게이트) ───────────────────────────────────
# arg1: 카테고리 (critical 예외 판정용)
# arg2: webhook 키 (jarvis-system 등)
# arg3: 메시지
emit() {
    local category="$1" webhook_key="$2" msg="$3"
    local mode
    mode=$(get_time_mode)

    # 게이트 1 — 시간대 정책 (critical 5개는 silent 시간에도 항상 통과 — 스펙 §3)
    # 2026-05-14 /verify BLOCKER 수정: silent 분기에 is_critical 예외 추가
    # 어제 토큰 사고가 새벽에 발생했으면 차단됐을 회로 → 패치
    if [[ "$mode" == "silent" ]] && ! is_critical "$category"; then
        log "🔇 [silent] $category 차단 (수면 시간)"
        return 0
    fi
    if [[ "$mode" == "critical_only" ]] && ! is_critical "$category"; then
        log "🔇 [critical_only] $category 차단 (출근/휴식 시간)"
        return 0
    fi

    # 게이트 2 — 빈도 가드 (critical 우회)
    if ! is_critical "$category" && ! check_frequency_guard; then
        log "🔇 [freq] $category 차단 (1시간 3회+ 누적)"
        return 0
    fi

    # 발화
    if discord_notify "$webhook_key" "$msg"; then
        log "📢 [$category → $webhook_key] $(echo "$msg" | head -c 80)"
        echo "$(date +%s) $category $webhook_key" >> "$FREQ_LEDGER"
    else
        log "❌ discord_notify 실패 — $category"
    fi
}

# ─── 이벤트 큐 처리 (Day 2~5에 추가될 hook 출력 수신) ─────────
process_event_queue() {
    if [[ ! -f "$EVENT_QUEUE" ]]; then
        return 0
    fi
    if [[ ! -s "$EVENT_QUEUE" ]]; then
        return 0
    fi

    local tmp="${EVENT_QUEUE}.processing.$$"
    mv "$EVENT_QUEUE" "$tmp" 2>/dev/null || return 0
    touch "$EVENT_QUEUE"

    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            continue
        fi
        local category webhook msg
        category=$(echo "$line" | jq -r '.category // "unknown"' 2>/dev/null)
        webhook=$(echo "$line" | jq -r '.webhook // "jarvis-system"' 2>/dev/null)
        msg=$(echo "$line" | jq -r '.message // ""' 2>/dev/null)
        if [[ -z "$msg" ]]; then
            continue
        fi
        emit "$category" "$webhook" "$msg"
    done < "$tmp"
    rm -f "$tmp"
}

# ─── 메인 루프 ─────────────────────────────────────────────────
log "=== proactive-engine v2 시작 (mode=$(get_time_mode), poll=${POLL_INTERVAL}s) ==="

# 2026-05-14 /verify 추가: heartbeat 카운터 — 1시간 1회 가시성 로그
_heartbeat_cnt=0
_HEARTBEAT_EVERY=12  # 12 * 5min = 60min

while true; do
    _cpu_guard
    process_event_queue

    # 가시성 — 빈 큐 사이클에도 데몬 살아있다는 흔적
    if (( _heartbeat_cnt % _HEARTBEAT_EVERY == 0 )); then
        log "💓 heartbeat (mode=$(get_time_mode), uptime_cycles=${_heartbeat_cnt})"
    fi
    _heartbeat_cnt=$((_heartbeat_cnt + 1))

    # Day 2~6에 추가될 직접 체크들:
    # - mail-event-hook.sh 큐 (Day 2)
    # - calendar-event-hook.sh 큐 (Day 3)
    # - 반응 학습 (Day 5)
    # - 도메인 알림 (Day 6)
    sleep "$POLL_INTERVAL"
done
