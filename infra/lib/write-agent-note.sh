#!/usr/bin/env bash
# write-agent-note.sh — 에이전트 Self-Note 저장 헬퍼
#
# Usage:
#   write-agent-note.sh TASK_ID AGENT NOTE_JSON
#
# NOTE_JSON은 schema.json 기준 부분 객체여도 됨.
# task_id, agent, timestamp는 자동 주입되므로 생략 가능.
#
# 연동:
#   - ask-claude.sh 성공 완료 후 호출 (log_jsonl "success" 이후)
#   - council-insight-3-agent.sh verify 단계 완료 후 호출
#   - context-bus.md에 context_bus_update 필드가 있으면 자동 append
#
# 저장 위치:
#   ~/jarvis/runtime/agent-notes/{TASK_ID}/{ISO8601_timestamp}.json
#   ~/jarvis/runtime/agent-notes/{TASK_ID}/latest.json  (덮어씀)
#   ~/jarvis/runtime/agent-notes/_index.jsonl           (append)

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
NOTES_DIR="${BOT_HOME}/agent-notes"
CONTEXT_BUS="${BOT_HOME}/state/context-bus.md"

TASK_ID="${1:?Usage: write-agent-note.sh TASK_ID AGENT NOTE_JSON}"
AGENT="${2:?Usage: write-agent-note.sh TASK_ID AGENT NOTE_JSON}"
NOTE_JSON="${3:?Usage: write-agent-note.sh TASK_ID AGENT NOTE_JSON}"

TS="$(date -u +%FT%TZ)"
TASK_DIR="${NOTES_DIR}/${TASK_ID}"
NOTE_FILE="${TASK_DIR}/${TS//:/}.json"
LATEST_FILE="${TASK_DIR}/latest.json"
INDEX_FILE="${NOTES_DIR}/_index.jsonl"

mkdir -p "$TASK_DIR"

# task_id / agent / timestamp 자동 보강
FULL_NOTE=$(echo "$NOTE_JSON" | jq \
    --arg tid "$TASK_ID" \
    --arg agt "$AGENT" \
    --arg ts  "$TS" \
    '. + {task_id: $tid, agent: $agt, timestamp: $ts}
     | .patterns    //= []
     | .mistakes    //= []
     | .suggestions //= []')

# 개별 노트 저장
echo "$FULL_NOTE" > "$NOTE_FILE"

# latest.json 덮어쓰기
cp "$NOTE_FILE" "$LATEST_FILE"

# 인덱스 append (task_id + timestamp + 파일 경로만 기록)
jq -cn \
    --arg tid  "$TASK_ID" \
    --arg agt  "$AGENT" \
    --arg ts   "$TS" \
    --arg path "$NOTE_FILE" \
    '{task_id:$tid, agent:$agt, timestamp:$ts, path:$path}' \
    >> "$INDEX_FILE"

# context-bus.md 업데이트 (context_bus_update 필드가 비어있지 않으면)
CB_UPDATE=$(echo "$FULL_NOTE" | jq -r '.context_bus_update // empty' 2>/dev/null || true)
if [[ -n "${CB_UPDATE:-}" && -f "$CONTEXT_BUS" ]]; then
    printf '\n<!-- agent-note:%s:%s -->\n%s\n' "$TASK_ID" "$TS" "$CB_UPDATE" >> "$CONTEXT_BUS"
fi

# 30일 초과 오래된 노트 정리
find "$TASK_DIR" -name "*.json" -not -name "latest.json" -mtime +30 -delete 2>/dev/null || true

printf '[write-agent-note] saved: %s\n' "$NOTE_FILE" >&2
