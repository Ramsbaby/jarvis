#!/usr/bin/env bash
set -euo pipefail

# github-monitor-gate.sh — Hash-based cache gate for github-monitor task
#
# Purpose: Eliminate LLM re-invocation when GitHub notifications haven't changed.
# Previously github-monitor ran hourly and produced identical "GitHub: 알림 없음"
# output ~95% of the time. This gate fetches notifications directly, hashes them,
# and skips the LLM call entirely on cache hit.
#
# Pattern: Script gatekeeper → LLM formatting only on cache miss.
# Compatible with bot-cron.sh script dispatch (line 380+).
#
# Output: Writes result to stdout (captured by bot-cron.sh as RESULT).
# Exit codes: 0 success (cache hit or miss), non-zero on ask-claude.sh failure.

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
TASK_ID="github-monitor"
HASH_FILE="${BOT_HOME}/state/github-monitor-last.hash"
CACHE_RESULT_FILE="${BOT_HOME}/state/github-monitor-last-result.md"
RESULTS_DIR="${BOT_HOME}/results/github-monitor"
LEDGER_FILE="${BOT_HOME}/state/token-ledger.jsonl"

mkdir -p "$(dirname "$HASH_FILE")" "$RESULTS_DIR" 2>/dev/null || true

log() { printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TASK_ID" "$*" >&2; }

# --- 1. Fetch notifications directly (no LLM, no Bash tool) ---
notifications=""
if command -v gh >/dev/null 2>&1; then
    # gh api may fail on auth issues — fall through to LLM path with empty
    if notifications=$(gh api notifications --jq '.[] | .subject.title' 2>/dev/null); then
        :
    else
        log "WARN: gh api notifications failed — falling through to LLM with empty list"
        notifications=""
    fi
else
    log "WARN: gh CLI not found — falling through to LLM with empty list"
fi

# --- 2. Compute hash of notification list ---
current_hash=$(printf '%s' "$notifications" | shasum -a 256 2>/dev/null | cut -c1-16 || echo "nohash")
prev_hash=""
if [[ -f "$HASH_FILE" ]]; then
    prev_hash=$(cat "$HASH_FILE" 2>/dev/null || echo "")
fi

# --- 3. Cache hit path: same notifications as last run + have cached result ---
if [[ -n "$prev_hash" && "$current_hash" == "$prev_hash" && -s "$CACHE_RESULT_FILE" ]]; then
    log "CACHE_HIT hash=$current_hash — skipping LLM"

    # Write the cached result as this run's output file (for retention/observability)
    result_file="${RESULTS_DIR}/$(date +%F_%H%M%S).md"
    cp "$CACHE_RESULT_FILE" "$result_file" 2>/dev/null || true

    # Rotate old results (same policy as ask-claude.sh)
    find "$RESULTS_DIR" -name "*.md" -mtime +1 -delete 2>/dev/null || true

    # --- Ledger entry: cache hit = zero cost, zero tokens ---
    if command -v jq >/dev/null 2>&1; then
        ledger_bytes=$(wc -c < "$CACHE_RESULT_FILE" 2>/dev/null | tr -d ' ' || echo 0)
        jq -cn --arg ts "$(date -u +%FT%TZ)" \
               --arg task "$TASK_ID" \
               --arg model "cache" \
               --arg status "cache_hit" \
               --arg result_hash "$current_hash" \
               --argjson input 0 \
               --argjson output 0 \
               --argjson cost_usd 0 \
               --argjson duration_ms 0 \
               --argjson result_bytes "${ledger_bytes:-0}" \
               --argjson max_budget_usd 0 \
            '{ts:$ts, task:$task, model:$model, status:$status, input:$input, output:$output, cost_usd:$cost_usd, duration_ms:$duration_ms, result_bytes:$result_bytes, result_hash:$result_hash, max_budget_usd:$max_budget_usd}' \
          >> "$LEDGER_FILE" 2>/dev/null || true
    fi

    # Emit cached result to stdout so bot-cron.sh can route it
    cat "$CACHE_RESULT_FILE"
    exit 0
fi

# --- 4. Cache miss path: notifications changed, LLM formatting needed ---
log "CACHE_MISS prev=${prev_hash:-none} curr=$current_hash — invoking LLM"

# Update hash file first (so even if LLM fails we don't loop)
printf '%s' "$current_hash" > "$HASH_FILE"

# Build a self-contained prompt that doesn't need Bash tool
if [[ -z "$notifications" ]]; then
    prompt='GitHub 알림이 없거나 API 호출에 실패했습니다. 아래 한 줄만 그대로 출력:

GitHub: 알림 없음'
else
    # Limit to first 30 notifications to keep prompt bounded
    notif_data=$(printf '%s' "$notifications" | head -30)
    prompt="GitHub 알림 목록이 아래와 같다. 한국어로 간결하게 요약하라 (5줄 이내, 우선순위 높은 것 먼저).

제목:
\`\`\`
${notif_data}
\`\`\`

출력 형식:
첫 줄: **GitHub: N건 알림** (N은 총 개수)
다음 줄부터: 각 알림 1줄 요약 (최대 5개)
나머지는 생략."
fi

# Find ask-claude.sh — prefer BOT_HOME/bin, fall back to repo path
ASK_CLAUDE=""
for candidate in \
    "${BOT_HOME}/bin/ask-claude.sh" \
    "${HOME}/jarvis/infra/bin/ask-claude.sh" \
    "$(dirname "$0")/../bin/ask-claude.sh"; do
    if [[ -x "$candidate" ]]; then
        ASK_CLAUDE="$candidate"
        break
    fi
done

if [[ -z "$ASK_CLAUDE" ]]; then
    log "ERROR: ask-claude.sh not found"
    # Fall back: emit raw notifications as result
    if [[ -n "$notifications" ]]; then
        printf '# Task: %s\nDate: %s\n\n## Result\nGitHub: %d건 알림 (formatter unavailable)\n%s\n' \
            "$TASK_ID" "$(date -u +%Y-%m-%d)" \
            "$(printf '%s\n' "$notifications" | wc -l | tr -d ' ')" \
            "$notifications"
    else
        printf '# Task: %s\nDate: %s\n\n## Result\nGitHub: 알림 없음\n' \
            "$TASK_ID" "$(date -u +%Y-%m-%d)"
    fi
    exit 1
fi

# Call ask-claude.sh with Read tool only (no Bash needed since data is in prompt)
# Timeout 60s, inherit MAX_BUDGET from env or default 0.10
max_budget="${MAX_BUDGET:-0.10}"
if result=$(bash "$ASK_CLAUDE" "$TASK_ID" "$prompt" "Read" 60 "$max_budget" 2>&1); then
    # Cache the formatted result for next cache-hit
    printf '%s' "$result" > "$CACHE_RESULT_FILE"
    printf '%s' "$result"
    exit 0
else
    exit_code=$?
    log "ERROR: ask-claude.sh failed exit=$exit_code"
    printf '%s' "$result" >&2
    exit "$exit_code"
fi