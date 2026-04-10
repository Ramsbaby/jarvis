#!/usr/bin/env bash
# langfuse-trace.sh — Fire-and-forget Langfuse HTTP ingestion for bash scripts
#
# Source this file; do NOT execute directly.
#
# Usage (in llm-gateway.sh or any bash script):
#   source "$BOT_HOME/lib/langfuse-trace.sh"
#
#   # Before LLM call:
#   lf_start_timer                        # sets _LF_CALL_START_MS
#
#   # After successful LLM call:
#   lf_trace_generation \
#     --task-id   "morning-standup" \
#     --name      "standup-draft" \
#     --model     "claude-opus-4-20250514" \
#     --provider  "claude-cli" \
#     --output    "/tmp/llm-out.json"     # output file from llm_call()
#
# Required env vars (load from discord/.env or .env):
#   LANGFUSE_PUBLIC_KEY   e.g. lf-pub-xxxx
#   LANGFUSE_SECRET_KEY   e.g. lf-sk-xxxx
#   LANGFUSE_BASE_URL     default: http://localhost:3200

LANGFUSE_TRACE_VERSION="1.0.0"

# Millisecond timestamp
_lf_now_ms() {
  python3 -c "import time; print(int(time.time()*1000))"
}

# ISO-8601 timestamp from milliseconds
_lf_ms_to_iso() {
  local ms="${1:-0}"
  python3 -c "
import datetime
ms = int('${ms}')
dt = datetime.datetime.fromtimestamp(ms/1000.0, datetime.timezone.utc)
print(dt.strftime('%Y-%m-%dT%H:%M:%S.') + f'{ms%1000:03d}Z')
"
}

# Start timer — call before provider chain
lf_start_timer() {
  _LF_CALL_START_MS=$(_lf_now_ms)
  export _LF_CALL_START_MS
}

# Post to Langfuse ingestion API (background, non-blocking)
_lf_post_ingestion() {
  local body="$1"
  local base_url="${LANGFUSE_BASE_URL:-http://localhost:3200}"
  local pub="${LANGFUSE_PUBLIC_KEY:-}"
  local sec="${LANGFUSE_SECRET_KEY:-}"

  if [[ -z "$pub" || -z "$sec" ]]; then
    return 0  # tracing disabled — no keys configured
  fi

  curl -sf -X POST "${base_url}/api/public/ingestion" \
    -u "${pub}:${sec}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    --max-time 5 \
    -o /dev/null \
    2>/dev/null &
  disown
}

# Main tracing function — call after successful llm_call()
# Args: --task-id --name --model --provider --output [--metadata-json]
lf_trace_generation() {
  local task_id="" name="" model="" provider="" output_file="" extra_meta="{}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id)       task_id="$2";       shift 2 ;;
      --name)          name="$2";          shift 2 ;;
      --model)         model="$2";         shift 2 ;;
      --provider)      provider="$2";      shift 2 ;;
      --output)        output_file="$2";   shift 2 ;;
      --metadata-json) extra_meta="$2";    shift 2 ;;
      *) shift ;;
    esac
  done

  # Skip if keys not configured
  [[ -z "${LANGFUSE_PUBLIC_KEY:-}" ]] && return 0

  local end_ms start_ms
  end_ms=$(_lf_now_ms)
  start_ms="${_LF_CALL_START_MS:-$end_ms}"

  # Extract usage from output file
  local input_tokens=0 output_tokens=0 cost_usd=0 result_preview=""
  if [[ -f "$output_file" ]]; then
    input_tokens=$(jq -r '.usage.input_tokens // 0' "$output_file" 2>/dev/null || echo 0)
    output_tokens=$(jq -r '.usage.output_tokens // 0' "$output_file" 2>/dev/null || echo 0)
    cost_usd=$(jq -r '.cost_usd // 0' "$output_file" 2>/dev/null || echo 0)
    result_preview=$(jq -r '.result // ""' "$output_file" 2>/dev/null | head -c 200 | tr '\n' ' ' || echo "")
  fi

  local start_iso end_iso trace_id gen_id event_id
  start_iso=$(_lf_ms_to_iso "$start_ms")
  end_iso=$(_lf_ms_to_iso "$end_ms")
  trace_id="jarvis-$(date +%Y%m%d)-${task_id:-unknown}-$$"
  gen_id="${trace_id}-gen"
  event_id="$(date +%s%N)"

  # Escape for JSON
  local safe_name safe_task safe_preview safe_model safe_provider
  safe_name=$(echo "${name:-$task_id}" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")
  safe_task=$(echo "${task_id}" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")
  safe_preview=$(echo "${result_preview}" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")
  safe_model=$(echo "${model}" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")
  safe_provider=$(echo "${provider}" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")

  local body
  body=$(cat <<JSON
{
  "batch": [
    {
      "id": "ev-trace-${event_id}",
      "type": "trace-create",
      "timestamp": "${start_iso}",
      "body": {
        "id": "${trace_id}",
        "name": ${safe_name},
        "metadata": {
          "task_id": ${safe_task},
          "provider": ${safe_provider}
        },
        "tags": ["jarvis", "bot-cron", ${safe_provider}]
      }
    },
    {
      "id": "ev-gen-${event_id}",
      "type": "generation-create",
      "timestamp": "${start_iso}",
      "body": {
        "id": "${gen_id}",
        "traceId": "${trace_id}",
        "name": ${safe_name},
        "model": ${safe_model},
        "startTime": "${start_iso}",
        "endTime": "${end_iso}",
        "usage": {
          "input": ${input_tokens},
          "output": ${output_tokens},
          "unit": "TOKENS"
        },
        "output": ${safe_preview},
        "metadata": {
          "task_id": ${safe_task},
          "provider": ${safe_provider},
          "cost_usd": ${cost_usd},
          "duration_ms": $((end_ms - start_ms))
        }
      }
    }
  ]
}
JSON
)

  _lf_post_ingestion "$body"
}

# Convenience: trace a failed generation
lf_trace_generation_error() {
  local task_id="" name="" model="" provider="" error_msg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id) task_id="$2"; shift 2 ;;
      --name)    name="$2";    shift 2 ;;
      --model)   model="$2";   shift 2 ;;
      --provider) provider="$2"; shift 2 ;;
      --error)   error_msg="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  [[ -z "${LANGFUSE_PUBLIC_KEY:-}" ]] && return 0

  local end_ms start_ms end_iso start_iso trace_id gen_id event_id
  end_ms=$(_lf_now_ms)
  start_ms="${_LF_CALL_START_MS:-$end_ms}"
  end_iso=$(_lf_ms_to_iso "$end_ms")
  start_iso=$(_lf_ms_to_iso "$start_ms")
  trace_id="jarvis-$(date +%Y%m%d)-${task_id:-unknown}-$$-err"
  gen_id="${trace_id}-gen"
  event_id="$(date +%s%N)"

  local safe_name safe_error safe_model safe_provider
  safe_name=$(echo "${name:-$task_id}" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")
  safe_error=$(echo "${error_msg}" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")
  safe_model=$(echo "${model:-unknown}" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")
  safe_provider=$(echo "${provider:-unknown}" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")

  local body
  body=$(cat <<JSON
{
  "batch": [
    {
      "id": "ev-trace-${event_id}",
      "type": "trace-create",
      "timestamp": "${start_iso}",
      "body": {
        "id": "${trace_id}",
        "name": ${safe_name},
        "metadata": {"task_id": "${task_id}", "provider": ${safe_provider}},
        "tags": ["jarvis", "error", ${safe_provider}]
      }
    },
    {
      "id": "ev-gen-${event_id}",
      "type": "generation-create",
      "timestamp": "${start_iso}",
      "body": {
        "id": "${gen_id}",
        "traceId": "${trace_id}",
        "name": ${safe_name},
        "model": ${safe_model},
        "startTime": "${start_iso}",
        "endTime": "${end_iso}",
        "level": "ERROR",
        "statusMessage": ${safe_error},
        "metadata": {"task_id": "${task_id}", "provider": ${safe_provider}}
      }
    }
  ]
}
JSON
)

  _lf_post_ingestion "$body"
}
