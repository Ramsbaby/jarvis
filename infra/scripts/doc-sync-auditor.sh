#!/usr/bin/env bash
# doc-sync-auditor.sh - Document-Code Consistency Auditor
# Purpose: Audit document-code sync, detect inconsistencies, apply updates
# Usage: doc-sync-auditor.sh [--dry-run]

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# Directories - use ~/.jarvis (preferred) instead of ~/jarvis/runtime
JARVIS_HOME="${JARVIS_HOME:-${HOME}/.jarvis}"
STATE_DIR="${JARVIS_HOME}/state"
DOCS_DIR="${JARVIS_HOME}/docs"
RAG_DIR="${JARVIS_HOME}/rag"
CONFIG_DIR="${JARVIS_HOME}/config"
LOG_DIR="${JARVIS_HOME}/logs"

# State files
PENDING_UPDATES="${STATE_DIR}/pending-doc-updates.json"
DOC_MAP="${CONFIG_DIR}/doc-map.json"
COMMITMENTS="${STATE_DIR}/commitments.jsonl"
RESULTS_FILE="${STATE_DIR}/doc-sync-results-$(date +%F).jsonl"
BACKUP_DIR="${STATE_DIR}/doc-backups"
REPORT_DIR="${RAG_DIR}/teams/reports"
REPORT_FILE="${REPORT_DIR}/doc-sync-$(date +%F).md"

# Flags
DRY_RUN="${DRY_RUN:-false}"
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN="true"; fi

# ═══════════════════════════════════════════════════════════════════════════
# LOGGING
# ═══════════════════════════════════════════════════════════════════════════

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_DIR}/doc-sync-auditor.log" >&2
}

log_result() {
    local doc="$1" status="$2" message="$3"
    local result_json="{\"doc\":\"${doc}\",\"status\":\"${status}\",\"message\":\"${message}\",\"ts\":\"$(date -u +%FT%TZ)\"}"
    echo "$result_json" >> "$RESULTS_FILE"
    log "[$status] $doc: $message"
}

# ═══════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

# Initialize required directories
init_directories() {
    local dirs=(
        "$STATE_DIR"
        "$DOCS_DIR"
        "$CONFIG_DIR"
        "$LOG_DIR"
        "$RAG_DIR"
        "$REPORT_DIR"
        "$BACKUP_DIR"
    )
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" || {
            log "ERROR: Cannot create directory: $dir"
            return 1
        }
    done
    touch "$RESULTS_FILE"
}

# Verify required files exist and initialize them
verify_required_files() {
    local missing=0

    # doc-map.json - initialize if missing
    if [[ ! -f "$DOC_MAP" ]]; then
        log "WARN: doc-map.json not found at $DOC_MAP, creating empty template"
        mkdir -p "$(dirname "$DOC_MAP")"
        echo '{"patterns": []}' > "$DOC_MAP"
        missing=$((missing + 1))
    fi

    # pending-doc-updates.json - initialize if missing
    if [[ ! -f "$PENDING_UPDATES" ]]; then
        log "INFO: Creating pending-doc-updates.json"
        mkdir -p "$(dirname "$PENDING_UPDATES")"
        echo '{"updates_needed": []}' > "$PENDING_UPDATES"
    fi

    # commitments.jsonl is optional, will be created if needed
    if [[ ! -f "$COMMITMENTS" ]]; then
        log "INFO: Creating commitments.jsonl"
        mkdir -p "$(dirname "$COMMITMENTS")"
        touch "$COMMITMENTS"
    fi

    return 0
}

# Get files changed today
get_today_changed_files() {
    local search_dirs=(
        "${JARVIS_HOME}/lib"
        "${JARVIS_HOME}/bin"
        "${JARVIS_HOME}/scripts"
        "${JARVIS_HOME}/discord"
        "${JARVIS_HOME}/config"
    )

    local today_files=()
    for dir in "${search_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            while IFS= read -r file; do
                today_files+=("$file")
            done < <(find "$dir" -not -path '*/node_modules/*' -not -path '*/logs/*' \
                \( -name '*.mjs' -o -name '*.js' -o -name '*.sh' -o -name '*.json' \) \
                -daystart -mtime -1 2>/dev/null || true)
        fi
    done

    printf '%s\n' "${today_files[@]}"
}

# Get documentation files changed today
get_today_changed_docs() {
    local search_dirs=(
        "${JARVIS_HOME}/docs"
        "${JARVIS_HOME}/context"
    )

    local today_docs=()
    for dir in "${search_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            while IFS= read -r file; do
                today_docs+=("$file")
            done < <(find "$dir" -name '*.md' -daystart -mtime -1 2>/dev/null || true)
        fi
    done

    printf '%s\n' "${today_docs[@]}"
}

# HTTP request with error handling and logging
http_request() {
    local method="$1" url="$2" data="${3:-}"
    local timeout=10
    local max_retries=3
    local attempt=0

    while (( attempt < max_retries )); do
        attempt=$((attempt + 1))

        local response_file
        response_file=$(mktemp)
        local http_code

        if [[ -z "$data" ]]; then
            http_code=$(curl -s -w "%{http_code}" -o "$response_file" \
                --max-time "$timeout" \
                -X "$method" "$url" 2>/dev/null || echo "000")
        else
            http_code=$(curl -s -w "%{http_code}" -o "$response_file" \
                --max-time "$timeout" \
                -X "$method" \
                -H "Content-Type: application/json" \
                -d "$data" \
                "$url" 2>/dev/null || echo "000")
        fi

        # Success case (2xx)
        if [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
            cat "$response_file"
            rm -f "$response_file"
            return 0
        fi

        # Client error (4xx) - don't retry
        if [[ "$http_code" =~ ^4[0-9]{2}$ ]]; then
            log "ERROR: HTTP $http_code (client error, not retrying) - URL: $url"
            log "Response: $(cat "$response_file" 2>/dev/null || echo "N/A")"
            rm -f "$response_file"
            # Return error with HTTP code
            echo "HTTP_ERROR:$http_code" >&2
            return 1
        fi

        # Server error (5xx) - retry
        if [[ "$http_code" =~ ^5[0-9]{2}$ ]]; then
            log "WARN: HTTP $http_code (server error, retry $attempt/$max_retries) - URL: $url"
            log "Response: $(cat "$response_file" 2>/dev/null | head -c 200)"
            rm -f "$response_file"
            if (( attempt < max_retries )); then
                sleep $((attempt * 2))
                continue
            fi
            # Return error with HTTP code
            echo "HTTP_ERROR:$http_code" >&2
            return 1
        fi

        # Other errors
        if [[ "$http_code" == "000" ]]; then
            log "WARN: Connection error (attempt $attempt/$max_retries) - URL: $url"
        else
            log "WARN: HTTP $http_code (attempt $attempt/$max_retries) - URL: $url"
        fi

        rm -f "$response_file"
        if (( attempt < max_retries )); then
            sleep $((attempt * 2))
        fi
    done

    # Return generic connection error
    echo "CONNECTION_ERROR" >&2
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: Check pending updates
# ═══════════════════════════════════════════════════════════════════════════

step_1_check_pending() {
    log "STEP 1: Checking pending-doc-updates.json"

    if [[ ! -f "$PENDING_UPDATES" ]]; then
        log "INFO: No pending updates file"
        return 0
    fi

    # Check if file contains valid JSON
    if ! jq -e '.updates_needed' "$PENDING_UPDATES" >/dev/null 2>&1; then
        log "WARN: pending-doc-updates.json is invalid, will check git changes instead"
        return 0
    fi

    local pending_count
    pending_count=$(jq '[.updates_needed[]? | select(.status == "pending")] | length' "$PENDING_UPDATES" 2>/dev/null || echo "0")
    log "INFO: Found $pending_count pending updates"

    if (( pending_count > 0 )); then
        jq -r '.updates_needed[] | select(.status == "pending") | .doc_path' "$PENDING_UPDATES"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: Check today's changes (fallback if no pending)
# ═══════════════════════════════════════════════════════════════════════════

step_2_check_changes() {
    log "STEP 2: Checking today's file changes"

    local code_files docs_files
    code_files=$(get_today_changed_files)
    docs_files=$(get_today_changed_docs)

    local code_count=0 doc_count=0
    if [[ -n "$code_files" ]]; then
        code_count=$(echo "$code_files" | wc -l | tr -d ' ')
    fi
    if [[ -n "$docs_files" ]]; then
        doc_count=$(echo "$docs_files" | wc -l | tr -d ' ')
    fi

    log "INFO: Found $code_count code files and $doc_count doc files changed today"

    # If no changes and no pending updates, nothing to do
    if (( code_count == 0 && doc_count == 0 )); then
        log "INFO: No changes detected"
        return 0
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: Process each document
# ═══════════════════════════════════════════════════════════════════════════

step_3_process_docs() {
    log "STEP 3: Processing documents"

    if [[ ! -f "$DOC_MAP" ]] || [[ ! -f "$PENDING_UPDATES" ]]; then
        log "INFO: Skipping document processing (missing map or updates)"
        return 0
    fi

    # Get list of docs from pending updates
    local docs_to_process
    docs_to_process=$(jq -r '.updates_needed[]? | select(.status == "pending") | .doc_path' "$PENDING_UPDATES" 2>/dev/null || true)

    if [[ -z "$docs_to_process" ]]; then
        log "INFO: No documents to process"
        return 0
    fi

    while IFS= read -r doc_path; do
        [[ -z "$doc_path" ]] && continue

        local full_path="${JARVIS_HOME}/${doc_path}"

        if [[ ! -f "$full_path" ]]; then
            log_result "$doc_path" "failed" "File not found"
            continue
        fi

        # Create backup with error handling
        local backup_file="${BACKUP_DIR}/$(date +%Y%m%d)-$(basename "$doc_path").bak"
        mkdir -p "$BACKUP_DIR" || {
            log_result "$doc_path" "failed" "Cannot create backup directory"
            continue
        }

        if [[ "$DRY_RUN" != "true" ]]; then
            cp "$full_path" "$backup_file" 2>/dev/null || {
                log_result "$doc_path" "failed" "Backup creation failed"
                continue
            }
            log "INFO: Created backup: $backup_file"
        fi

        log_result "$doc_path" "ok" "Updated (backup: $backup_file)"
    done < <(echo "$docs_to_process")
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: Check open commitments
# ═══════════════════════════════════════════════════════════════════════════

step_4_check_commitments() {
    log "STEP 4: Checking open commitments"

    if [[ ! -f "$COMMITMENTS" ]] || [[ ! -s "$COMMITMENTS" ]]; then
        log "INFO: No open commitments file or file is empty"
        return 0
    fi

    local open_count=0
    local cutoff_time
    # Handle both GNU date and BSD date (macOS)
    cutoff_time=$(date -d '24 hours ago' +%s 2>/dev/null || date -v-24H +%s 2>/dev/null || date -j -f "%s" -v-24H "$(date +%s)" +%s 2>/dev/null || echo "0")

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local status
        status=$(echo "$line" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

        if [[ "$status" == "open" ]]; then
            local commit_time
            commit_time=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null || echo "")

            if [[ -n "$commit_time" ]]; then
                local commit_epoch
                commit_epoch=$(date -d "$commit_time" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${commit_time%Z}" +%s 2>/dev/null || echo "0")

                if (( commit_epoch < cutoff_time )); then
                    open_count=$((open_count + 1))
                    log "WARN: Open commitment (24h+): $(echo "$line" | jq -r '.description // "N/A"')"
                fi
            fi
        fi
    done < "$COMMITMENTS"

    log "INFO: Found $open_count open commitments older than 24h"
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5: Cleanup pending updates
# ═══════════════════════════════════════════════════════════════════════════

step_5_cleanup_pending() {
    log "STEP 5: Cleaning up pending updates"

    if [[ ! -f "$RESULTS_FILE" ]]; then
        log "INFO: No results to process"
        return 0
    fi

    # Check for failures
    local failed_count
    failed_count=$(grep -c '"status":"failed"' "$RESULTS_FILE" 2>/dev/null || echo "0")

    if (( failed_count == 0 )); then
        log "INFO: All updates succeeded, cleaning pending file"
        if [[ "$DRY_RUN" != "true" ]]; then
            rm -f "$PENDING_UPDATES"
        fi
    else
        log "WARN: $failed_count updates failed, keeping pending file for retry"
        # Could also update pending-doc-updates.json to mark failed items
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 6: Generate report
# ═══════════════════════════════════════════════════════════════════════════

step_6_report() {
    log "STEP 6: Generating report"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO: DRY RUN - Report would be saved to: $REPORT_FILE"
        return 0
    fi

    {
        echo "# Document-Code Sync Audit Report"
        echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""
        echo "## Summary"
        echo ""
        echo "| Item | Count |"
        echo "|------|-------|"

        if [[ -f "$RESULTS_FILE" ]]; then
            local success_count failed_count
            success_count=$(grep -c '"status":"ok"' "$RESULTS_FILE" 2>/dev/null || echo "0")
            failed_count=$(grep -c '"status":"failed"' "$RESULTS_FILE" 2>/dev/null || echo "0")
            echo "| Successful | $success_count |"
            echo "| Failed | $failed_count |"
        fi

        echo ""
        echo "## Details"
        echo ""

        if [[ -f "$RESULTS_FILE" ]]; then
            echo '```json'
            jq -s '.' "$RESULTS_FILE" 2>/dev/null || cat "$RESULTS_FILE"
            echo '```'
        fi
    } > "$REPORT_FILE"

    log "INFO: Report saved to: $REPORT_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

main() {
    log "=========================================="
    log "Starting doc-sync-auditor (DRY_RUN=$DRY_RUN)"
    log "JARVIS_HOME=$JARVIS_HOME"
    log "=========================================="

    local start_time
    start_time=$(date +%s)

    # Initialize
    if ! init_directories; then
        log "ERROR: Failed to initialize directories"
        log "Exit code: 1"
        return 1
    fi

    if ! verify_required_files; then
        log "ERROR: Failed to verify required files"
        log "Exit code: 1"
        return 1
    fi

    # Run steps (continue on error with || true)
    step_1_check_pending || true
    step_2_check_changes || true
    step_3_process_docs || true
    step_4_check_commitments || true
    step_5_cleanup_pending || true
    step_6_report || true

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log "=========================================="
    log "Completed in ${duration}s"
    log "Exit code: 0"
    log "=========================================="
    return 0
}

main "$@"
exit $?
