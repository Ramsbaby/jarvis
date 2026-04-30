#!/usr/bin/env bash
# memory-cleanup.sh — Direct Bash implementation of Jarvis memory cleanup
# Purpose: Clean up stale runtime files/sessions without Claude API
# Exit codes: 0 = success, 1 = error

set -euo pipefail

# Configuration
RUNTIME_HOME="${HOME}/jarvis/runtime"
RESULTS_DIR="${RUNTIME_HOME}/results"
SESSIONS_FILE="${RUNTIME_HOME}/state/sessions.json"
EVENTS_DIR="${RUNTIME_HOME}/state/events"
ACTIVE_TASKS_DIR="${RUNTIME_HOME}/state/active-tasks"
STALE_DAYS=7
SENTINEL_HOURS=1

# Cleanup tracking
RESULTS_CLEANED=0
SESSIONS_CLEANED=0
EVENTS_CLEANED=0
SENTINELS_CLEANED=0

# Ensure directories exist
mkdir -p "$RESULTS_DIR" "$EVENTS_DIR" "$ACTIVE_TASKS_DIR"

# === 1. Clean up old files in ~/jarvis/runtime/results/ ===
if [[ -d "$RESULTS_DIR" ]]; then
    while IFS= read -r -d '' file; do
        rm -f "$file"
        ((RESULTS_CLEANED++))
    done < <(find "$RESULTS_DIR" -type f -mtime +$STALE_DAYS -print0 2>/dev/null)
fi

# === 2. Clean up stale sessions in ~/jarvis/runtime/state/sessions.json ===
if [[ -f "$SESSIONS_FILE" ]]; then
    CUTOFF_EPOCH=$(($(date +%s) - (STALE_DAYS * 86400)))

    # Check if sessions.json is valid JSON before processing
    if jq empty "$SESSIONS_FILE" 2>/dev/null; then
        # Create temp file for cleaned sessions
        TEMP_FILE="${SESSIONS_FILE}.tmp.$$"

        # Filter out sessions older than STALE_DAYS
        if jq --arg cutoff "$CUTOFF_EPOCH" '[.sessions[] | select(.timestamp > ($cutoff | tonumber))] | {sessions: .}' "$SESSIONS_FILE" > "$TEMP_FILE" 2>/dev/null; then
            # Count removed sessions
            BEFORE=$(jq '.sessions | length' "$SESSIONS_FILE" 2>/dev/null || echo 0)
            AFTER=$(jq '.sessions | length' "$TEMP_FILE" 2>/dev/null || echo 0)
            SESSIONS_CLEANED=$((BEFORE - AFTER))

            # Replace original with cleaned version
            if [[ $AFTER -ge 0 ]]; then
                mv "$TEMP_FILE" "$SESSIONS_FILE"
            else
                rm -f "$TEMP_FILE"
            fi
        else
            rm -f "$TEMP_FILE"
        fi
    fi
fi

# === 3. Clean up old event files in ~/jarvis/runtime/state/events/ ===
if [[ -d "$EVENTS_DIR" ]]; then
    while IFS= read -r -d '' file; do
        rm -f "$file"
        ((EVENTS_CLEANED++))
    done < <(find "$EVENTS_DIR" -type f -name "*.json" -mtime +$STALE_DAYS -print0 2>/dev/null)
fi

# === 4. Clean up old sentinel files in ~/jarvis/runtime/state/active-tasks/ ===
if [[ -d "$ACTIVE_TASKS_DIR" ]]; then
    CUTOFF_MINUTES=$((SENTINEL_HOURS * 60))
    while IFS= read -r -d '' file; do
        rm -f "$file"
        ((SENTINELS_CLEANED++))
    done < <(find "$ACTIVE_TASKS_DIR" -type d -mmin +$CUTOFF_MINUTES -print0 2>/dev/null)
fi

# === 5. Generate summary output ===
cat << EOF
## ✅ Jarvis 런타임 메모리 정리 완료

| 항목 | 정리됨 |
|------|--------|
| **결과 파일** (~/jarvis/runtime/results) | $RESULTS_CLEANED |
| **세션 항목** (sessions.json) | $SESSIONS_CLEANED |
| **이벤트 파일** (~/jarvis/runtime/state/events) | $EVENTS_CLEANED |
| **Sentinel 파일** (~/jarvis/runtime/state/active-tasks) | $SENTINELS_CLEANED |

**총 정리된 항목**: $((RESULTS_CLEANED + SESSIONS_CLEANED + EVENTS_CLEANED + SENTINELS_CLEANED))개
EOF

exit 0
