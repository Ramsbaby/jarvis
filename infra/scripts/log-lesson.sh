#!/usr/bin/env bash
set -euo pipefail
# log-lesson.sh "category" "message"
# Appends a lesson to lessons-learned.md with date headers

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LESSONS_FILE="$BOT_HOME/context/lessons-learned.md"
LOCK_FILE="$BOT_HOME/state/lessons.lock"
CATEGORY="${1:-general}"
MESSAGE="${2:-}"

if [[ -z "$MESSAGE" ]]; then
    echo "Usage: log-lesson.sh <category> <message>" >&2
    exit 1
fi

TODAY=$(date '+%Y-%m-%d')
ENTRY="- [$CATEGORY] $(date '+%H:%M') $MESSAGE"

mkdir -p "$(dirname "$LESSONS_FILE")" "$BOT_HOME/state"

(
    flock -x 200
    # Add date header if not present
    if ! grep -q "^## $TODAY" "$LESSONS_FILE" 2>/dev/null; then
        echo -e "\n## $TODAY" >> "$LESSONS_FILE"
    fi
    echo "$ENTRY" >> "$LESSONS_FILE"
) 200>"$LOCK_FILE"