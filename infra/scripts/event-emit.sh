#!/usr/bin/env bash
set -euo pipefail

# emit-event.sh — 이벤트 발생 헬퍼
# 사용: emit-event.sh <event_name> [payload]
# 예)   emit-event.sh github.push
#       emit-event.sh disk.threshold_exceeded '{"usage":92}'
#       emit-event.sh task.failed '{"task_id":"morning-standup"}'
#
# → ~/jarvis/runtime/state/events/<event_name>.trigger 파일 생성
# → event-watcher.sh 데몬이 30초 내에 감지하여 매칭 태스크 실행

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
EVENTS_DIR="${BOT_HOME}/state/events"
LOG="${BOT_HOME}/logs/event-watcher.log"

# --- 인자 검증 ---
if [[ $# -lt 1 ]]; then
    echo "Usage: emit-event.sh <event_name> [json_payload]" >&2
    echo ""                                                  >&2
    echo "Available event names (from tasks.json):"         >&2
    python3 -c "
import json
try:
    import os
    bot_home = os.environ.get('BOT_HOME', os.path.expanduser('~/jarvis/runtime'))
    for cfg in [bot_home+'/config/effective-tasks.json', bot_home+'/config/tasks.json']:
        try:
            with open(cfg) as f:
                data = json.load(f)
            for t in data.get('tasks', []):
                et = t.get('event_trigger')
                if et:
                    print(f'  {et:35s} → {t[\"id\"]} (debounce={t.get(\"event_trigger_debounce_s\",0)}s)')
            break
        except FileNotFoundError:
            continue
except Exception as e:
    print(f'  (tasks.json 파싱 실패: {e})')
" 2>/dev/null >&2 || true
    exit 1
fi

EVENT_NAME="$1"
PAYLOAD="${2:-{}}"

# event_name 유효성: 영문자, 숫자, . _ - 만 허용
if [[ ! "$EVENT_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: invalid event_name '${EVENT_NAME}' — 영문자/숫자/점/언더스코어/하이픈만 허용" >&2
    exit 1
fi

mkdir -p "$EVENTS_DIR"

TRIGGER_FILE="${EVENTS_DIR}/${EVENT_NAME}.trigger"
TIMESTAMP=$(date +%s)
HUMAN_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# trigger 파일 생성 (이미 있어도 덮어씀 — 더 최신 이벤트 우선)
printf '{"event":"%s","ts":%d,"emitted_at":"%s","payload":%s}\n' \
    "$EVENT_NAME" "$TIMESTAMP" "$HUMAN_TIME" "$PAYLOAD" \
    > "$TRIGGER_FILE"

# 로그 기록
LOG_MSG="[${HUMAN_TIME}] [emit-event] EMITTED event=${EVENT_NAME} payload=${PAYLOAD}"
echo "$LOG_MSG" >> "$LOG" 2>/dev/null || true

echo "OK: event '${EVENT_NAME}' triggered → ${TRIGGER_FILE}"
echo "    event-watcher.sh가 30초 내에 감지하여 매칭 태스크를 실행합니다."