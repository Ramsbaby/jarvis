#!/usr/bin/env bash
# prompt-ab-analyzer.sh — Analyze task outcomes from SQLite kpi channel
# Usage: prompt-ab-analyzer.sh [--task TASK_ID] [--days N] [--report] [--discord]
# Part of Phase 4-1: Prompt A/B test framework (data collection layer)

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
MESSAGES_DB="${BOT_HOME}/state/messages.db"
DAYS=7
FILTER_TASK=""
SEND_DISCORD=false

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            FILTER_TASK="${2:?--task requires a TASK_ID argument}"
            shift 2
            ;;
        --days)
            DAYS="${2:?--days requires a number}"
            shift 2
            ;;
        --report)
            shift
            ;;
        --discord)
            SEND_DISCORD=true
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--task TASK_ID] [--days N] [--report] [--discord]" >&2
            exit 1
            ;;
    esac
done

# --- Dependency check ---
if [[ ! -f "$MESSAGES_DB" ]]; then
    echo "ERROR: messages.db not found at $MESSAGES_DB" >&2
    exit 1
fi
command -v sqlite3 >/dev/null 2>&1 || { echo "ERROR: sqlite3 not found" >&2; exit 1; }

# --- Build optional task filter (sanitize to prevent SQL injection) ---
TASK_WHERE=""
if [[ -n "$FILTER_TASK" ]]; then
    # 허용: 영문, 숫자, 하이픈, 언더스코어만 (task ID 형식)
    SAFE_TASK=$(echo "$FILTER_TASK" | sed 's/[^a-zA-Z0-9_-]//g')
    TASK_WHERE="AND json_extract(payload, '$.taskId') = '${SAFE_TASK}'"
fi

# --- Query outcomes from kpi channel ---
results=$(sqlite3 "$MESSAGES_DB" "
  SELECT
    json_extract(payload, '$.taskId') as task_id,
    COUNT(*) as total,
    SUM(CASE WHEN json_extract(payload, '$.success') = 1 THEN 1 ELSE 0 END) as success_count,
    CAST(AVG(json_extract(payload, '$.durationMs')) AS INTEGER) as avg_duration_ms,
    ROUND(SUM(json_extract(payload, '$.cost')), 4) as total_cost
  FROM messages
  WHERE channel = 'kpi'
    AND sender LIKE 'cron:%'
    AND created_at >= datetime('now', '-${DAYS} days')
    AND status != 'failed'
    ${TASK_WHERE}
  GROUP BY task_id
  HAVING total >= 3
  ORDER BY (success_count * 100 / total) ASC
;" 2>/dev/null) || results=""

# --- Build report ---
CRITICAL_LINES=""
WARNING_LINES=""
OK_LINES=""
TOTAL_TASKS=0
TOTAL_RUNS=0
TOTAL_SUCCESSES=0

if [[ -n "$results" ]]; then
    while IFS="|" read -r task_id total success_count avg_ms total_cost; do
        if [[ -z "$task_id" ]]; then continue; fi
        TOTAL_TASKS=$(( TOTAL_TASKS + 1 ))
        TOTAL_RUNS=$(( TOTAL_RUNS + total ))
        TOTAL_SUCCESSES=$(( TOTAL_SUCCESSES + success_count ))
        pct=$(( success_count * 100 / total ))
        entry="${task_id} ${pct}% (${success_count}/${total}, avg ${avg_ms}ms, cost \$${total_cost})"
        if [[ $pct -lt 70 ]]; then
            if [[ -n "$CRITICAL_LINES" ]]; then
                CRITICAL_LINES="${CRITICAL_LINES}, ${entry}"
            else
                CRITICAL_LINES="$entry"
            fi
        elif [[ $pct -lt 85 ]]; then
            if [[ -n "$WARNING_LINES" ]]; then
                WARNING_LINES="${WARNING_LINES}, ${entry}"
            else
                WARNING_LINES="$entry"
            fi
        else
            if [[ -n "$OK_LINES" ]]; then
                OK_LINES="${OK_LINES}, ${entry}"
            else
                OK_LINES="$entry"
            fi
        fi
    done <<< "$results"
fi

# --- Format report ---
REPORT="=== Prompt A/B Analysis (${DAYS} days) ==="
if [[ $TOTAL_TASKS -eq 0 ]]; then
    REPORT="${REPORT}
No data yet (need >= 3 runs per task in messages.db kpi channel).
Instrumentation active — data will accumulate from next cron cycle."
else
    OVERALL_PCT=$(( TOTAL_SUCCESSES * 100 / TOTAL_RUNS ))
    REPORT="${REPORT}
Tasks tracked: ${TOTAL_TASKS} | Total runs: ${TOTAL_RUNS} | Overall success: ${OVERALL_PCT}%"
    if [[ -n "$CRITICAL_LINES" ]]; then
        REPORT="${REPORT}
CRITICAL (<70%): ${CRITICAL_LINES}"
    fi
    if [[ -n "$WARNING_LINES" ]]; then
        REPORT="${REPORT}
WARNING (70-85%): ${WARNING_LINES}"
    fi
    if [[ -n "$OK_LINES" ]]; then
        REPORT="${REPORT}
OK (>85%): ${OK_LINES}"
    fi
    if [[ -z "$CRITICAL_LINES" ]] && [[ -z "$WARNING_LINES" ]]; then
        REPORT="${REPORT}
All tasks above 85% threshold."
    fi
fi

echo "$REPORT"

# --- Optional Discord send ---
if [[ "$SEND_DISCORD" == "true" ]]; then
    MONITORING_JSON="${BOT_HOME}/config/monitoring.json"
    WEBHOOK=""
    if [[ -f "$MONITORING_JSON" ]] && command -v jq >/dev/null 2>&1; then
        WEBHOOK=$(jq -r '.webhooks.system // .webhooks.jarvis // ""' "$MONITORING_JSON" 2>/dev/null) || WEBHOOK=""
    fi
    if [[ -n "$WEBHOOK" ]]; then
        PAYLOAD=$(python3 -c "
import json, sys
content = sys.argv[1][:1990]
print(json.dumps({'content': '\`\`\`\n' + content + '\n\`\`\`'}))
" "$REPORT" 2>/dev/null) || PAYLOAD=""
        if [[ -n "$PAYLOAD" ]]; then
            curl -s -X POST -H "Content-Type: application/json" \
                -d "$PAYLOAD" "$WEBHOOK" >/dev/null 2>&1 || true
        fi
    else
        echo "[discord] No webhook configured in monitoring.json" >&2
    fi
fi