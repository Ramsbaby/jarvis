#!/usr/bin/env bash
set -euo pipefail

# calendar-alert.sh - Google Calendar 이벤트 선제 알림 (30분 전)
# cron: */5 * * * *
# 25~35분 사이 시작 이벤트를 감지하여 Discord 알림 전송

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
STATE_DIR="$BOT_HOME/state"
ALERTED_FILE="$STATE_DIR/alerted-events.json"
WEBHOOK_CONFIG="$BOT_HOME/config/monitoring.json"
LOG="$BOT_HOME/logs/calendar-alert.log"
GOOGLE_ACCOUNT="yuiopnm1931@gmail.com"
ALERT_WINDOW_MIN=25
ALERT_WINDOW_MAX=35

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# gog 없으면 조용히 종료
if ! command -v gog &>/dev/null; then
    exit 0
fi

# python3 필요
if ! command -v python3 &>/dev/null; then
    log "ERROR: python3 not found"
    exit 0
fi

# 알림 상태 파일 초기화
if [[ ! -f "$ALERTED_FILE" ]]; then
    echo '[]' > "$ALERTED_FILE"
fi

# 시간 윈도우 계산 (macOS date -v)
WINDOW_FROM="$(date -v+"${ALERT_WINDOW_MIN}"M '+%Y-%m-%dT%H:%M:%S')"
WINDOW_TO="$(date -v+"${ALERT_WINDOW_MAX}"M '+%Y-%m-%dT%H:%M:%S')"
FROM_DATE="$(date -v+"${ALERT_WINDOW_MIN}"M '+%Y-%m-%d')"
TO_DATE="$(date -v+"${ALERT_WINDOW_MAX}"M '+%Y-%m-%d %H:%M')"

# Google Calendar에서 이벤트 조회
CALENDAR_OUTPUT="$(gog calendar list \
    --from "$FROM_DATE" \
    --to "$TO_DATE" \
    --account "$GOOGLE_ACCOUNT" \
    --json 2>/dev/null || echo '{"events":[]}')"

# Webhook URL 가져오기
WEBHOOK_URL="$(python3 -c "import json; print(json.load(open('${WEBHOOK_CONFIG}'))['webhook']['url'])")"

# 이벤트 처리: 필터링 + 중복 체크 + 알림 전송 + 정리
python3 - "$CALENDAR_OUTPUT" "$ALERTED_FILE" "$WEBHOOK_URL" "$WINDOW_FROM" "$WINDOW_TO" "$LOG" << 'PYEOF'
import json
import sys
import subprocess
from datetime import datetime, timedelta

cal_json_str = sys.argv[1]
alerted_file = sys.argv[2]
webhook_url = sys.argv[3]
window_from_str = sys.argv[4]
window_to_str = sys.argv[5]
log_file = sys.argv[6]


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(log_file, "a") as f:
        f.write(f"[{ts}] {msg}\n")


def send_discord(content):
    payload = json.dumps({"content": content}, ensure_ascii=False)
    result = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
         "-H", "Content-Type: application/json",
         "-d", payload, webhook_url],
        capture_output=True, text=True, timeout=30
    )
    return result.stdout.strip()


def parse_event_time(dt_str):
    """Parse ISO datetime with timezone offset like +09:00."""
    if len(dt_str) >= 6 and dt_str[-3] == ':' and dt_str[-6] in ('+', '-'):
        dt_str = dt_str[:-3] + dt_str[-2:]
    try:
        return datetime.strptime(dt_str, "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return datetime.strptime(dt_str[:19], "%Y-%m-%dT%H:%M:%S")


# Load calendar data
try:
    cal_data = json.loads(cal_json_str)
except json.JSONDecodeError:
    log("ERROR: Failed to parse calendar JSON")
    sys.exit(0)

events = cal_data.get("events", [])

# Load alerted events
try:
    with open(alerted_file, "r") as f:
        alerted = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    alerted = []

alerted_ids = {e.get("id") for e in alerted}

# Parse window boundaries (local time, naive)
window_from = datetime.strptime(window_from_str, "%Y-%m-%dT%H:%M:%S")
window_to = datetime.strptime(window_to_str, "%Y-%m-%dT%H:%M:%S")

new_alerts = []

for event in events:
    event_id = event.get("id", "")
    summary = event.get("summary", "(제목 없음)")

    if event_id in alerted_ids:
        continue

    start = event.get("start", {})
    start_dt_str = start.get("dateTime", "")

    # Skip all-day events (no dateTime, only date)
    if not start_dt_str:
        continue

    start_dt = parse_event_time(start_dt_str)
    start_local = start_dt.replace(tzinfo=None)

    if window_from <= start_local <= window_to:
        time_str = start_local.strftime("%H:%M")
        message = "\U0001f4c5 **30\ubd84 \ud6c4 \uc77c\uc815**\n**{}** \u2014 {}".format(
            summary, time_str
        )

        http_code = send_discord(message)
        if http_code.startswith("2"):
            log("ALERT SENT: {} at {} (id={})".format(summary, time_str, event_id))
            new_alerts.append({
                "id": event_id,
                "summary": summary,
                "ts": datetime.now().isoformat()
            })
        else:
            log("ERROR: Discord send failed (HTTP {}) for {}".format(
                http_code, summary))

# Update alerted file
if new_alerts:
    alerted.extend(new_alerts)

# Prune entries older than 24 hours
cutoff = (datetime.now() - timedelta(hours=24)).isoformat()
alerted = [e for e in alerted if e.get("ts", "") > cutoff]

with open(alerted_file, "w") as f:
    json.dump(alerted, f, ensure_ascii=False, indent=2)

if new_alerts:
    log("Total alerts sent: {}".format(len(new_alerts)))
elif not events:
    pass  # No events, silent exit
else:
    log("No new events to alert (all already notified or outside window)")
PYEOF
