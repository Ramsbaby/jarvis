#!/bin/bash
set -euo pipefail

# Auto-update CLAUDE.md file line-count metadata
# Detects patterns like "filename(NNN줄)" and compares against actual line counts
# Warns if deviation > ±10%, optionally auto-updates

readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_DIR="${JARVIS_RUNTIME_HOME:-$HOME/.openclaw-data/runtime}/logs"
readonly LOG_FILE="$LOG_DIR/update-claude-md-meta.log"
readonly CHANGE_LOG="$LOG_DIR/claude-md-updates.jsonl"

# Mode: "check" (report only) or "update" (auto-fix)
MODE="${1:-check}"

# Threshold for warning/action (in %)
THRESHOLD=10

mkdir -p "$LOG_DIR"

# Logging function
log_msg() {
  local level="$1"
  shift
  local msg="$*"
  printf "[%s] [%s] %s\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$msg" | tee -a "$LOG_FILE"
}

# Resolve file path using multiple strategies
resolve_path() {
  local filename="$1"
  local claude_dir="$2"

  # Strategy 1: If already absolute, use as-is
  if [[ "$filename" == /* ]] && [[ -f "$filename" ]]; then
    echo "$filename"
    return 0
  fi

  # Strategy 2: Relative to CLAUDE.md directory
  if [[ -f "$claude_dir/$filename" ]]; then
    echo "$claude_dir/$filename"
    return 0
  fi

  # Strategy 3: Relative to repo root (parent directory)
  if [[ -f "${claude_dir%/*}/$filename" ]]; then
    echo "${claude_dir%/*}/$filename"
    return 0
  fi

  # Strategy 4: Search in known project roots (bounded depth to avoid slow scans)
  local base_name
  base_name="$(basename "$filename")"
  local found_file
  local known_roots=(
    "$claude_dir"
    "${claude_dir%/*}"
    "$HOME/jarvis-board"
    "$HOME/projects/jarvis"
  )
  for root in "${known_roots[@]}"; do
    if [[ -d "$root" ]]; then
      found_file=$(find "$root" -maxdepth 6 -name "$base_name" -type f 2>/dev/null | head -1)
      if [[ -n "$found_file" ]]; then
        echo "$found_file"
        return 0
      fi
    fi
  done

  # Strategy 5: Broader home search (last resort, depth-limited)
  found_file=$(find "$HOME" -maxdepth 7 -name "$base_name" -type f 2>/dev/null | head -1)
  if [[ -n "$found_file" ]]; then
    echo "$found_file"
    return 0
  fi

  # Not found
  echo ""
}

# Process a single CLAUDE.md file
process_claude_file() {
  local claude_file="$1"
  local claude_dir="$(dirname "$claude_file")"

  log_msg "INFO" "Scanning $claude_file"

  local total=0 updated=0 warned=0 found=0

  # Parse: look for patterns like "filename(NNN,NNN줄)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip lines without line-count pattern
    if ! echo "$line" | grep -qE '\([0-9,]+\s*줄\)'; then
      continue
    fi

    ((found++)) || true

    # Extract recorded count: "VirtualOffice.tsx(2,780줄)" -> 2780
    # Must strip commas from the whole match BEFORE splitting into digit groups
    local recorded
    recorded=$(echo "$line" | grep -oE '\([0-9,]+\s*줄\)' | tr -d ',' | grep -oE '[0-9]+' | head -1)

    if [[ -z "$recorded" ]]; then
      continue
    fi

    # Extract filename (word/dots/slashes before the parenthesis)
    # This matches: "name.tsx(2,780줄)" -> "name.tsx"
    local filename
    filename=$(echo "$line" | grep -oE '[a-zA-Z0-9_./\-]+\.(tsx?|js|mjs|sh|py|md)' | head -1)

    if [[ -z "$filename" ]]; then
      log_msg "WARN" "Could not extract filename from line: $line"
      continue
    fi

    ((total++)) || true

    local full_path
    full_path=$(resolve_path "$filename" "$claude_dir")

    if [[ -z "$full_path" ]]; then
      log_msg "WARN" "File not found: $filename (searched from $claude_dir)"
      continue
    fi

    if [[ ! -f "$full_path" ]]; then
      log_msg "WARN" "Not a file or unreadable: $full_path"
      continue
    fi

    local actual
    actual=$(wc -l < "$full_path")

    # Calculate percentage deviation
    local diff=$((actual - recorded))
    local pct_dev
    if (( recorded == 0 )); then
      pct_dev=0
    else
      pct_dev=$((100 * diff / recorded))
    fi

    # Use absolute value for threshold check
    local abs_pct_dev=${pct_dev#-}

    if (( abs_pct_dev > THRESHOLD )); then
      local msg="STALE: $filename — recorded=$recorded줄, actual=$actual줄, deviation=$pct_dev%"
      log_msg "WARN" "$msg"

      if [[ "$MODE" == "update" ]]; then
        # Create backup with timestamp
        local backup_file="$claude_file.bak.$(date +%s)"
        cp "$claude_file" "$backup_file"
        log_msg "INFO" "Backup: $backup_file"

        # Replace the recorded count with actual count
        # Use a temporary file to avoid issues with sed -i
        sed "s/$(basename "$filename")([0-9,]*\s*줄)/$(basename "$filename")($actual줄)/g" "$claude_file" > "$claude_file.tmp"
        mv "$claude_file.tmp" "$claude_file"

        log_msg "INFO" "UPDATED: $filename ($recorded줄 → $actual줄)"
        ((updated++)) || true

        # Record in JSONL format
        printf '{"timestamp":"%s","file":"%s","recorded":%d,"actual":%d,"deviation_pct":%d,"action":"updated"}\n' \
          "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$filename" "$recorded" "$actual" "$pct_dev" >> "$CHANGE_LOG"
      else
        ((warned++)) || true
        # Record in JSONL format
        printf '{"timestamp":"%s","file":"%s","recorded":%d,"actual":%d,"deviation_pct":%d,"action":"warned"}\n' \
          "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$filename" "$recorded" "$actual" "$pct_dev" >> "$CHANGE_LOG"
      fi
    else
      log_msg "INFO" "OK: $filename ($actual줄, recorded=$recorded줄, deviation=$pct_dev%)"
    fi
  done < "$claude_file"

  if (( found > 0 )); then
    log_msg "INFO" "Summary: found=$found, processed=$total, updated=$updated, warned=$warned"
  else
    log_msg "INFO" "No line-count metadata found"
  fi
}

# Main
main() {
  log_msg "INFO" "Starting CLAUDE.md metadata check (mode=$MODE)"

  # Find all CLAUDE.md files in standard locations
  local claude_files=(
    "$HOME/CLAUDE.md"
    "$HOME/projects/jarvis/CLAUDE.md"
    "$HOME/jarvis-board/CLAUDE.md"
  )

  local total_checked=0
  for file in "${claude_files[@]}"; do
    if [[ -f "$file" ]]; then
      process_claude_file "$file"
      ((total_checked++)) || true
    fi
  done

  if (( total_checked == 0 )); then
    log_msg "WARN" "No CLAUDE.md files found to process"
  fi

  log_msg "INFO" "Metadata check complete"
}

main "$@"
