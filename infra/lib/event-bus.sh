#!/usr/bin/env bash
# event-bus.sh — Jarvis Loop 이벤트 버스
#
# Usage (sourced):
#   source "$BOT_HOME/lib/event-bus.sh"
#   emit_event "disk.threshold_exceeded" '{"pct":"92%"}'
#
# 생성 파일: $BOT_HOME/state/events/<safe_name>-<timestamp>-<uuid>.json
# 형식: { "event": "...", "payload": {...}, "ts": "...", "emitter": "..." }
#
# rag-watch.mjs (ai.jarvis.rag-watcher LaunchAgent)가 state/events/를 감시하여
# whitelisted 이벤트에 대해 bot-cron.sh를 spawn함.

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"

emit_event() {
    local event_name="${1:?emit_event requires event_name}"
    local payload_json="${2}"
    [[ -z "$payload_json" ]] && payload_json="{}"
    local emitter="${3:-${BASH_SOURCE[1]:-unknown}}"

    local events_dir="${BOT_HOME}/state/events"
    mkdir -p "$events_dir"

    # 파일명 안전 처리: 영숫자+하이픈만 허용
    local safe_name
    safe_name=$(echo "$event_name" | tr -cs 'A-Za-z0-9' '-' | tr -s '-' | sed 's/-$//')

    # macOS date는 %N 미지원 → date +%s + uuidgen 조합으로 충돌 방지
    local ts_sec uuid_part
    ts_sec=$(date +%s)
    uuid_part=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '-' || printf '%s%s' "$ts_sec" "$$")

    local filename="${safe_name}-${ts_sec}-${uuid_part}.json"
    local filepath="${events_dir}/${filename}"

    local iso_ts
    iso_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # 이벤트 파일 원자적 쓰기 (tmp → rename)
    # python3가 JSON 유효성 처리: json.loads 실패 시 raw 문자열로 래핑
    local tmp_file="${filepath}.tmp.$$"
    python3 -c "
import json, sys
event = sys.argv[1]
try:
    payload = json.loads(sys.argv[2])
except Exception:
    payload = {'raw': sys.argv[2]}
out = {
    'event': event,
    'payload': payload,
    'ts': sys.argv[3],
    'emitter': sys.argv[4]
}
print(json.dumps(out))
" "$event_name" "$payload_json" "$iso_ts" "$emitter" > "$tmp_file" 2>/dev/null || {
        # python3 실패 시 최소 JSON 직접 쓰기
        printf '{"event":"%s","payload":{},"ts":"%s","emitter":"%s"}\n' \
            "$event_name" "$iso_ts" "$emitter" > "$tmp_file"
    }

    mv "$tmp_file" "$filepath"
    return 0
}

# 7일 이상 된 이벤트 파일 정리 (memory-cleanup 크론에서 호출)
cleanup_old_events() {
    local days="${1:-7}"
    local events_dir="${BOT_HOME}/state/events"
    [[ -d "$events_dir" ]] || return 0
    find "$events_dir" -maxdepth 1 -name "*.json" -mtime +"$days" -exec rm -f {} \;
}