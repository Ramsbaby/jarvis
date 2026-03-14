#!/usr/bin/env bash
set -euo pipefail

# auditor-fix-set-e-and.sh - Fix [[ ]] && cmd pattern in set -e scripts
# Usage: auditor-fix-set-e-and.sh <file> <line_number>
# Called by L3 approval system

FILE="${1:?Usage: auditor-fix-set-e-and.sh <file> <line_number>}"
LINE_NUM="${2:?Usage: auditor-fix-set-e-and.sh <file> <line_number>}"
BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if [[ ! -f "$FILE" ]]; then
    echo "ERROR: File not found: $FILE" >&2
    exit 1
fi

if ! [[ "$LINE_NUM" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Line number must be numeric: $LINE_NUM" >&2
    exit 1
fi

# Backup
cp "$FILE" "${FILE}.bak"

# Read the target line
TARGET_LINE=$(sed -n "${LINE_NUM}p" "$FILE")

# Verify line matches pattern
if ! echo "$TARGET_LINE" | grep -qE '\[\[.*\]\]\s*&&\s*'; then
    rm -f "${FILE}.bak"
    echo "WARN: Line $LINE_NUM does not match [[ ]] && pattern" >&2
    exit 0
fi

# Extract condition and command
# Pattern: [[ cond ]] && cmd  →  if [[ cond ]]; then cmd; fi
# Preserve leading whitespace
INDENT=$(echo "$TARGET_LINE" | sed -E 's/^([[:space:]]*).*/\1/')
COND=$(echo "$TARGET_LINE" | sed -E 's/^[[:space:]]*(\[\[.*\]\])\s*&&\s*.*/\1/')
CMD=$(echo "$TARGET_LINE" | sed -E 's/^[[:space:]]*\[\[.*\]\]\s*&&\s*(.*)/\1/')

# Build replacement
REPLACEMENT="${INDENT}if ${COND}; then ${CMD}; fi"

# Apply fix using sed with line number
if ${IS_MACOS:-false}; then
    sed -i '' "${LINE_NUM}s|.*|${REPLACEMENT}|" "$FILE"
else
    sed -i "${LINE_NUM}s|.*|${REPLACEMENT}|" "$FILE"
fi

# Verify syntax
if bash -n "$FILE" 2>/dev/null; then
    rm -f "${FILE}.bak"
    echo "OK: Fixed line $LINE_NUM in $FILE"
    echo "  Before: $TARGET_LINE"
    echo "  After:  $REPLACEMENT"
    exit 0
else
    # Restore from backup
    mv "${FILE}.bak" "$FILE"
    echo "ERROR: Syntax check failed after fix, restored backup" >&2
    exit 1
fi
