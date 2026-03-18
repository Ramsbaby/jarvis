#!/usr/bin/env bash
# tqqq-alert.sh - Proactive TQQQ alert checker
#
# Reads latest tqqq-monitor result file, parses TQQQ price/change,
# sends Discord webhook to jarvis-market if CRITICAL or WARNING conditions met.
# No claude -p needed — pure bash, runs in <1s.
#
# Thresholds:
#   CRITICAL: TQQQ price < STOP_LOSS (손절선, 기본값 $47 — TQQQ_STOP_LOSS 환경변수로 변경 가능)
#   WARNING:  TQQQ daily change <= -5%
# Cooldown: 60 min per level to avoid spam
# Quiet hours: 23:00-08:00 (CRITICAL only, per DNA-C002)

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
NODE="${NODE:-$(command -v node 2>/dev/null || echo /opt/homebrew/bin/node)}"
export HOME="${HOME:-/Users/$(id -un)}"  # macOS default; Linux: /home/$(id -un)

JARVIS_HOME="$HOME/.jarvis"

# ── 0. Market holiday / weekend guard ────────────────────────────────────────
if ! /bin/bash "$JARVIS_HOME/scripts/market-holiday-guard.sh" > /dev/null 2>&1; then
    echo "[$(date '+%F %T')] [tqqq-alert] Market closed today — skipping" >> "$JARVIS_HOME/logs/cron.log"
    exit 0
fi
RESULTS_DIR="$JARVIS_HOME/results/tqqq-monitor"
STATE_FILE="$JARVIS_HOME/state/tqqq-alert-state.json"
MONITORING_CONFIG="$JARVIS_HOME/config/monitoring.json"
CRON_LOG="$JARVIS_HOME/logs/cron.log"

STOP_LOSS="${TQQQ_STOP_LOSS:-47}"
WARN_PCT=5
COOLDOWN=3600   # 1 hour per alert level
STALE_SECS=1500 # ignore result files older than 25 min

log() { echo "[$(date '+%F %T')] [tqqq-alert] $1" >> "$CRON_LOG"; }

# ── 1. Load webhook URL ──────────────────────────────────────────────────────
WEBHOOK_URL=$(jq -r '.webhooks["jarvis-market"]' "$MONITORING_CONFIG")
if [[ -z "$WEBHOOK_URL" || "$WEBHOOK_URL" == "null" ]]; then
    log "ERROR: jarvis-market webhook not found in monitoring.json"
    exit 1
fi

# ── 2. Find latest result file ───────────────────────────────────────────────
LATEST=$(find "$RESULTS_DIR" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1 || true)
if [[ -z "$LATEST" ]]; then exit 0; fi

FILE_AGE=$(( $(date +%s) - $(stat -f %m "$LATEST" 2>/dev/null || stat -c '%Y' "$LATEST" 2>/dev/null || echo "$(date +%s)") ))
if [[ $FILE_AGE -gt $STALE_SECS ]]; then exit 0; fi  # stale — tqqq-monitor hasn't run recently

# ── 3. Parse TQQQ line ───────────────────────────────────────────────────────
# Format: **TQQQ: $49.52 (▼1.06%, -$0.53)**
TQQQ_LINE=$(grep -o '\*\*TQQQ: \$[0-9.]*[^*]*\*\*' "$LATEST" | head -1 || true)
if [[ -z "$TQQQ_LINE" ]]; then exit 0; fi

# Price: $49.52 → 49.52
PRICE=$(printf '%s' "$TQQQ_LINE" | grep -oE '\$[0-9]+\.[0-9]+' | head -1 | tr -d '$')
if [[ -z "$PRICE" ]]; then exit 0; fi

# Change direction and magnitude: ▼1.06% → IS_DOWN=true, PCT=1.06
CHANGE_RAW=$(printf '%s' "$TQQQ_LINE" | grep -oE '[▲▼][0-9]+\.[0-9]+%' | head -1 || true)
IS_DOWN=false
PCT="0"
if [[ -n "$CHANGE_RAW" ]]; then
    PCT=$(printf '%s' "$CHANGE_RAW" | grep -oE '[0-9]+\.[0-9]+')
    if printf '%s' "$CHANGE_RAW" | grep -q '▼'; then IS_DOWN=true; fi
fi

# ── 4. Determine alert level ─────────────────────────────────────────────────
ALERT_LEVEL="none"
ALERT_MSG=""

TS=$(date '+%H:%M')
if (( $(echo "$PRICE < $STOP_LOSS" | bc -l) )); then
    ALERT_LEVEL="critical"
    GAP=$(echo "$STOP_LOSS - $PRICE" | bc)
    ALERT_MSG="🚨 **TQQQ 손절선 하회** [${TS}]
현재 ${PRICE}달러 — 손절선 ${STOP_LOSS}달러 대비 -${GAP}달러
즉시 포지션 확인 필요!"

elif $IS_DOWN && (( $(echo "$PCT >= $WARN_PCT" | bc -l) )); then
    ALERT_LEVEL="warning"
    GAP=$(echo "scale=2; $PRICE - $STOP_LOSS" | bc)
    ALERT_MSG="⚠️ **TQQQ ${PCT}% 급락** [${TS}]
현재 ${PRICE}달러 — 손절선까지 여유 ${GAP}달러
포지션 모니터링 필요"
fi

if [[ "$ALERT_LEVEL" == "none" ]]; then exit 0; fi

# ── 5. Quiet hours check (DNA-C002: 23:00-08:00, CRITICAL 제외) ──────────────
HOUR=$(date +%-H)
if [[ $HOUR -ge 23 || $HOUR -lt 8 ]]; then
    if [[ "$ALERT_LEVEL" != "critical" ]]; then exit 0; fi
fi

# ── 6. Cooldown check ────────────────────────────────────────────────────────
mkdir -p "$(dirname "$STATE_FILE")"
if [[ ! -f "$STATE_FILE" ]]; then echo '{}' > "$STATE_FILE"; fi

LAST=$(jq -r --arg l "$ALERT_LEVEL" '.[$l] // 0' "$STATE_FILE")
NOW=$(date +%s)
if (( NOW - LAST < COOLDOWN )); then
    exit 0  # same level already alerted within cooldown window
fi

# ── 7. Send Discord webhook ──────────────────────────────────────────────────
PAYLOAD=$(jq -n --arg msg "$ALERT_MSG" '{content: $msg}')

if curl -sS -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    -w '\n%{http_code}' | tail -1 | grep -qE '^2'; then
    # Update cooldown state
    jq --arg l "$ALERT_LEVEL" --argjson now "$NOW" '.[$l] = $now' \
        "$STATE_FILE" > "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
    log "ALERT sent: $ALERT_LEVEL — TQQQ=\$$PRICE (${PCT}%)"

    # 이벤트 드리븐: TQQQ 이벤트 발생 시 관련 팀 자동 활성화
    COMPANY_AGENT="$JARVIS_HOME/discord/lib/company-agent.mjs"
    if [[ -f "$COMPANY_AGENT" ]]; then
        EVENT_DATA=$(jq -n --arg price "$PRICE" --arg change "${PCT}%" --arg level "$ALERT_LEVEL" \
            '{price: $price, change: $change, level: $level}')
        log "Event dispatch: tqqq-critical → company-agent"
        "${NODE}" "$COMPANY_AGENT" --event tqqq-critical --data "$EVENT_DATA" \
            >> "$JARVIS_HOME/logs/company-agent.log" 2>&1 &
    fi
else
    log "ALERT send failed: $ALERT_LEVEL — TQQQ=\$$PRICE"
fi
