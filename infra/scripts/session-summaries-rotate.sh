#!/usr/bin/env bash
set -uo pipefail

# session-summaries-rotate.sh — Rotate session summaries to prevent AUP refusal repetition
#
# Purpose: Prevent accumulated injectedSummary bloat by:
#   - Removing summaries older than 7 days
#   - Truncating individual summaries to 8KB max
#
# Background: Session summaries (in $BOT_HOME/state/session-summaries/*.md) are
# injected into Claude prompts to provide context on resume. Over time, accumulated
# summaries can cause AUP refusal loops (Anthropic treats long context as trying to
# bypass safety guidelines).
#
# Schedule: Daily at 03:30 KST (matches cron-catalog.md)
# Exit code: 0 (always succeeds, errors logged but non-fatal)

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
BOT_HOME="${BOT_HOME:-${HOME}/.openclaw-data/runtime}"
SUMMARIES_DIR="$BOT_HOME/state/session-summaries"
LOG_FILE="$BOT_HOME/logs/session-summaries-rotate.log"
STATE_FILE="$BOT_HOME/state/session-summaries-rotate.state.json"

mkdir -p "$(dirname "$LOG_FILE")"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(timestamp)] $1" >> "$LOG_FILE"; }

log "START: session-summaries rotation"

# Initialize state if missing
if [[ ! -f "$STATE_FILE" ]]; then
  cat > "$STATE_FILE" <<'EOF'
{
  "rotated_count": 0,
  "truncated_count": 0,
  "removed_count": 0,
  "last_run": 0
}
EOF
fi

ROTATED=0
TRUNCATED=0
REMOVED=0

# ──────────────────────────────────────────────────────────────
# 1. TTL rotation: Remove summaries older than 7 days
# ──────────────────────────────────────────────────────────────

TTL_DAYS=7
TTL_SECONDS=$((TTL_DAYS * 86400))
NOW=$(date +%s)

if [[ -d "$SUMMARIES_DIR" ]]; then
  while IFS= read -r -d '' file; do
    [[ -z "$file" ]] && continue

    # Get file modification time
    mtime=$(stat -f%m "$file" 2>/dev/null || stat -c%Y "$file" 2>/dev/null || echo "0")
    age=$((NOW - mtime))

    if [[ $age -gt $TTL_SECONDS ]]; then
      log "REMOVE: $(basename "$file") — age ${age}s > TTL ${TTL_SECONDS}s"
      rm -f "$file" 2>/dev/null && ((REMOVED++)) || log "WARN: Failed to remove $(basename "$file")"
    fi
  done < <(find "$SUMMARIES_DIR" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)
fi

# ──────────────────────────────────────────────────────────────
# 2. Size cap: Truncate summaries larger than 8KB
# ──────────────────────────────────────────────────────────────

MAX_SIZE_KB=8
MAX_SIZE_BYTES=$((MAX_SIZE_KB * 1024))

if [[ -d "$SUMMARIES_DIR" ]]; then
  while IFS= read -r -d '' file; do
    [[ -z "$file" ]] && continue

    # Get file size
    size=$(wc -c < "$file" 2>/dev/null || echo 0)

    if [[ $size -gt $MAX_SIZE_BYTES ]]; then
      # Truncate to 80% of max size to leave headroom
      target_size=$((MAX_SIZE_BYTES * 80 / 100))

      # Truncate and try to preserve structure (end at nearest newline)
      content=$(head -c "$target_size" "$file")
      last_newline="${content%$'\n'*}"

      if [[ -n "$last_newline" ]]; then
        echo "$last_newline" > "$file"
      else
        # If no newline found, just truncate to target
        head -c "$target_size" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
      fi

      log "TRUNCATE: $(basename "$file") — ${size}B → $(wc -c < "$file" 2>/dev/null || echo 0)B"
      ((TRUNCATED++)) || true
    fi
  done < <(find "$SUMMARIES_DIR" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null)
fi

# ──────────────────────────────────────────────────────────────
# 3. Update state
# ──────────────────────────────────────────────────────────────

cat > "$STATE_FILE" <<EOF
{
  "rotated_count": $ROTATED,
  "truncated_count": $TRUNCATED,
  "removed_count": $REMOVED,
  "last_run": $(date +%s),
  "last_run_date": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

log "DONE: removed=$REMOVED, truncated=$TRUNCATED"
log "Summary: TTL=${TTL_DAYS}d, MaxSize=${MAX_SIZE_KB}KB"

exit 0
