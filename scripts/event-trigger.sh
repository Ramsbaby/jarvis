#!/usr/bin/env bash
set -euo pipefail

# event-trigger.sh - 조건 기반 이벤트 트리거 (3분 간격)
# 조건 충족 시에만 Discord 알림 발송
# Triggers: TQQQ 가격, 디스크 용량, Claude 동시 실행 과부하

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
TRIGGER_DIR="$BOT_HOME/state/triggers"
WEBHOOK_CONFIG="$BOT_HOME/config/monitoring.json"
LOG="$BOT_HOME/logs/event-trigger.log"

mkdir -p "$TRIGGER_DIR" "$(dirname "$LOG")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# --- 쿨다운 헬퍼 ---
is_in_cooldown() {
    local key="$1" cooldown_sec="$2"
    local f="$TRIGGER_DIR/${key}.last"
    if [[ ! -f "$f" ]]; then
        return 1
    fi
    local last_ts
    last_ts=$(cat "$f")
    local now_ts
    now_ts=$(date +%s)
    local elapsed=$(( now_ts - last_ts ))
    if (( elapsed < cooldown_sec )); then
        return 0
    fi
    return 1
}

mark_triggered() {
    date +%s > "$TRIGGER_DIR/${1}.last"
}

# --- Discord 전송 ---
send_discord() {
    local msg="$1"
    local webhook_url
    webhook_url=$(python3 -c "
import json, sys
try:
    cfg = json.load(open('$WEBHOOK_CONFIG'))
    print(cfg.get('webhook', {}).get('url', ''))
except Exception:
    print('')
" 2>/dev/null || true)
    if [[ -z "$webhook_url" ]]; then
        log "WARN: webhook URL not found in $WEBHOOK_CONFIG"
        return 0
    fi
    local json_payload
    json_payload=$(python3 -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$msg")
    if curl -sf -o /dev/null -X POST "$webhook_url" \
        -H "Content-Type: application/json" \
        -d "$json_payload"; then
        log "Discord 전송 성공: ${msg:0:80}..."
    else
        log "Discord 전송 실패"
    fi
}

# --- Trigger 1: TQQQ Price Alert ---
check_tqqq() {
    # 평일 장중만 체크 (KST 기준 월-금 09:30-16:00 → UTC 00:30-07:00)
    # macOS date: day of week (1=Mon, 7=Sun)
    local dow hour min
    dow=$(date +%u)
    hour=$(date +%-H)
    min=$(date +%-M)

    # 주말이면 스킵
    if (( dow > 5 )); then
        return 0
    fi

    # KST 23:30~06:00 (장전/장후) 스킵 — 실질 US 장중 시간
    # US ET 09:30~16:00 = KST 23:30~06:00 (서머타임)  or KST 00:30~07:00 (겨울)
    # 간단히: KST 기준 hour 체크 대신 로컬(KST) 시간 기반
    # macOS 로컬 = KST이므로:
    #   US 장중(서머타임) = KST 22:30 ~ 05:00 다음날
    #   US 장중(겨울) = KST 23:30 ~ 06:00 다음날
    # 넓게 잡아 KST 22:00~07:00 사이만 실행
    if (( hour >= 7 && hour < 22 )); then
        return 0
    fi

    if is_in_cooldown "tqqq-price" 14400; then
        return 0
    fi

    local price
    price=$(python3 -c "
import urllib.request, json, sys
try:
    url = 'https://query1.finance.yahoo.com/v8/finance/chart/TQQQ?interval=1m&range=1d'
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    data = json.load(urllib.request.urlopen(req, timeout=10))
    p = data['chart']['result'][0]['meta']['regularMarketPrice']
    print(f'{p:.2f}')
except Exception:
    print('')
" 2>/dev/null || true)

    if [[ -z "$price" ]]; then
        log "TQQQ: 가격 조회 실패 (네트워크 또는 API 오류)"
        return 0
    fi

    local alert_msg=""
    # python3 float 비교
    local should_alert
    should_alert=$(python3 -c "
p = float('$price')
if p <= 47.0:
    print('stop_loss')
elif p >= 80.0:
    print('take_profit')
else:
    print('none')
" 2>/dev/null || echo "none")

    if [[ "$should_alert" == "stop_loss" ]]; then
        alert_msg="⚠️ **TQQQ 손절선 도달** 현재가: \$${price} (손절선: \$47.00)"
    elif [[ "$should_alert" == "take_profit" ]]; then
        alert_msg="📈 **TQQQ 익절 검토** 현재가: \$${price}"
    fi

    if [[ -n "$alert_msg" ]]; then
        send_discord "$alert_msg"
        mark_triggered "tqqq-price"
        log "TQQQ 트리거: $should_alert (가격: \$$price)"
    fi
}

# --- Trigger 2: Disk Space Alert ---
check_disk() {
    if is_in_cooldown "disk-space" 86400; then
        return 0
    fi

    local usage
    usage=$(df -h / | awk 'NR==2{print $5}' | tr -d '%')

    if [[ -z "$usage" ]]; then
        log "DISK: 용량 조회 실패"
        return 0
    fi

    if (( usage > 85 )); then
        send_discord "💾 **디스크 용량 경고** 사용률: ${usage}%"
        mark_triggered "disk-space"
        log "디스크 트리거: ${usage}%"
    fi
}

# --- Trigger 3: Claude Concurrency Alert ---
check_claude_load() {
    if is_in_cooldown "claude-load" 1800; then
        return 0
    fi

    local count_file="$BOT_HOME/state/claude-global.count"
    if [[ ! -f "$count_file" ]]; then
        return 0
    fi

    local count
    count=$(cat "$count_file" 2>/dev/null || echo "0")
    # 숫자가 아니면 스킵
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        return 0
    fi

    if (( count >= 3 )); then
        send_discord "🔥 **Claude 고부하** 동시 실행: ${count}/4"
        mark_triggered "claude-load"
        log "Claude 부하 트리거: ${count}/4"
    fi
}

# --- Main ---
log "이벤트 트리거 체크 시작"
check_tqqq
check_disk
check_claude_load
log "이벤트 트리거 체크 완료"
