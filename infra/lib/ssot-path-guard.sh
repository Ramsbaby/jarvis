#!/usr/bin/env bash
# ssot-path-guard.sh — SSoT multi-repo path validation (cl-1a81b2956a7f0cc9)
#
# Detects when a file being edited is part of a multi-repo SSoT, warns about:
# - Duplicate SSoT paths across repositories
# - Mismatched paths (same logical file in different locations)
# - Missing synchronization points
#
# Usage:
#   ssot-path-guard.sh /path/to/file        # Check single file
#   ssot-path-guard.sh /path/to/file --sync # Check and show sync points
#   ssot-path-guard.sh --validate-config    # Validate config file
#   ssot-path-guard.sh --list-ssot           # List all known SSoT paths

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────

readonly SSOT_CONFIG="${HOME}/projects/jarvis/infra/config/ssot-paths.json"
readonly GUARD_NAME="ssot-path-guard"
readonly GUARD_VERSION="1.0"
readonly GUARD_CLUSTER="cl-1a81b2956a7f0cc9"

# Color output
readonly C_RED='\033[0;31m'
readonly C_YELLOW='\033[1;33m'
readonly C_GREEN='\033[0;32m'
readonly C_BLUE='\033[0;34m'
readonly C_RESET='\033[0m'

# Logging levels
log_error() { printf "${C_RED}[ERROR]${C_RESET} %s\n" "$1" >&2; }
log_warn() { printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$1" >&2; }
log_info() { printf "${C_BLUE}[INFO]${C_RESET} %s\n" "$1" >&2; }
log_ok() { printf "${C_GREEN}[OK]${C_RESET} %s\n" "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# Configuration Validation
# ─────────────────────────────────────────────────────────────────────────────

validate_config() {
    if [[ ! -f "$SSOT_CONFIG" ]]; then
        log_error "SSoT config not found: $SSOT_CONFIG"
        return 1
    fi

    if ! jq empty "$SSOT_CONFIG" 2>/dev/null; then
        log_error "SSoT config is invalid JSON"
        return 1
    fi

    # Verify required sections
    for section in repositories ssot_mappings rules; do
        if ! jq -e ".$section" "$SSOT_CONFIG" > /dev/null 2>&1; then
            log_error "Missing required section: .$section"
            return 1
        fi
    done

    log_ok "Configuration valid"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# SSoT Path Discovery
# ─────────────────────────────────────────────────────────────────────────────

# Get all known SSoT paths from config
get_all_ssot_paths() {
    jq -r '.ssot_mappings[].primary_paths[]' "$SSOT_CONFIG" 2>/dev/null | sort -u
}

# Get repository for a given file path
get_repo_for_path() {
    local file_path="$1"
    jq -r --arg path "$file_path" \
        '.repositories[] | select(.patterns[] as $p | ($path | test($p))) | .id' \
        "$SSOT_CONFIG" 2>/dev/null | head -1
}

# Get all SSoT mappings that include the given file
get_ssot_mapping_for_file() {
    local file_path="$1"
    jq -r --arg path "$file_path" \
        '.ssot_mappings | to_entries[] | select(.value.primary_paths[] == $path) | .key' \
        "$SSOT_CONFIG" 2>/dev/null
}

# Get all related paths for a given SSoT mapping
get_related_paths() {
    local mapping_name="$1"
    jq -r --arg name "$mapping_name" \
        '.ssot_mappings[$name].primary_paths[]' \
        "$SSOT_CONFIG" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# File Validation
# ─────────────────────────────────────────────────────────────────────────────

# Check if a file is part of any SSoT mapping
check_file_is_ssot() {
    local file_path="$1"
    local mapping
    mapping=$(get_ssot_mapping_for_file "$file_path")
    if [[ -n "$mapping" ]]; then
        return 0  # is SSoT
    fi
    return 1  # not SSoT
}

# Check for duplicate or related SSoT files
check_related_files() {
    local file_path="$1"
    local mapping
    mapping=$(get_ssot_mapping_for_file "$file_path")

    if [[ -z "$mapping" ]]; then
        return 0  # No SSoT mapping found
    fi

    local related_paths
    related_paths=$(get_related_paths "$mapping")

    if [[ -z "$related_paths" ]]; then
        return 0  # Single path mapping
    fi

    # Check which related paths exist
    local existing_count=0
    local missing_count=0
    local paths_list=""

    while IFS= read -r path; do
        if [[ "$path" != "$file_path" ]]; then
            if [[ -f "$path" ]]; then
                ((existing_count++))
                paths_list+="  ✓ EXISTS: $path\n"
            else
                ((missing_count++))
                paths_list+="  ✗ MISSING: $path\n"
            fi
        fi
    done <<< "$related_paths"

    # Report findings
    if [[ $existing_count -gt 0 ]]; then
        log_warn "This file is part of SSoT mapping: $mapping"
        log_warn "Found $existing_count related file(s) that MUST be synchronized:"
        printf "$paths_list"

        # Determine criticality
        local is_critical
        is_critical=$(jq -r --arg name "$mapping" \
            '.ssot_mappings[$name].critical // false' \
            "$SSOT_CONFIG" 2>/dev/null)

        if [[ "$is_critical" == "true" ]]; then
            log_error "*** CRITICAL: This is a CRITICAL SSoT mapping ***"
            log_error "After editing this file, you MUST synchronize:"
            log_error "  1. Review all related files listed above"
            log_error "  2. Apply the same changes to each copy"
            log_error "  3. Verify consistency before committing"
            return 2  # Critical warning
        fi
        return 1  # Warning
    fi

    if [[ $missing_count -gt 0 ]]; then
        log_warn "Expected related SSoT files are MISSING:"
        printf "$paths_list"
        log_warn "This may indicate an incomplete setup or missing repository."
        return 1  # Warning
    fi

    return 0  # OK
}

# Check for file path misspellings or repository confusion
check_path_consistency() {
    local file_path="$1"
    local repo
    repo=$(get_repo_for_path "$file_path")

    if [[ -z "$repo" ]]; then
        # File not in known repository - might indicate misconfiguration
        log_warn "File is not in any known SSoT repository: $file_path"
        return 1
    fi

    log_info "File belongs to repository: $repo"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Validation
# ─────────────────────────────────────────────────────────────────────────────

check_file() {
    local file_path="$1"
    local show_sync="${2:-}"

    # Resolve to absolute path
    if [[ ! "$file_path" = /* ]]; then
        file_path="$(cd "$(dirname "$file_path")" && pwd)/$(basename "$file_path")"
    fi

    log_info "Checking SSoT status for: $file_path"
    echo ""

    # Check 1: Path consistency
    check_path_consistency "$file_path"
    local path_check=$?

    echo ""

    # Check 2: Related files (SSoT mapping)
    local ssot_check=0
    if check_file_is_ssot "$file_path"; then
        check_related_files "$file_path"
        ssot_check=$?
    else
        log_ok "File is not part of any known SSoT mapping"
    fi

    echo ""

    # Sync details if requested
    if [[ "$show_sync" == "--sync" ]] && [[ $ssot_check -ne 0 ]]; then
        local mapping
        mapping=$(get_ssot_mapping_for_file "$file_path")
        if [[ -n "$mapping" ]]; then
            log_info "Sync points for mapping '$mapping':"
            get_related_paths "$mapping" | while read -r path; do
                if [[ -f "$path" ]]; then
                    printf "  → %s\n" "$path"
                fi
            done
            echo ""
        fi
    fi

    # Return highest severity
    return "$ssot_check"
}

# ─────────────────────────────────────────────────────────────────────────────
# CLI Interface
# ─────────────────────────────────────────────────────────────────────────────

list_ssot_mappings() {
    log_info "All SSoT mappings:"
    jq -r '.ssot_mappings | keys[]' "$SSOT_CONFIG" 2>/dev/null | while read -r mapping; do
        local critical
        critical=$(jq -r --arg name "$mapping" \
            '.ssot_mappings[$name].critical // false' \
            "$SSOT_CONFIG")
        local desc
        desc=$(jq -r --arg name "$mapping" \
            '.ssot_mappings[$name].description' \
            "$SSOT_CONFIG")
        local criticality=""
        if [[ "$critical" == "true" ]]; then
            criticality="[CRITICAL]"
        fi
        printf "  %s %-20s %s\n" "$criticality" "$mapping" "$desc"
    done
}

list_all_paths() {
    log_info "All known SSoT paths:"
    get_all_ssot_paths | while read -r path; do
        local exists_indicator="✗"
        if [[ -f "$path" ]]; then
            exists_indicator="✓"
        fi
        printf "  %s %s\n" "$exists_indicator" "$path"
    done
}

show_help() {
    cat << EOF
${C_BLUE}ssot-path-guard.sh${C_RESET} v${GUARD_VERSION}
SSoT multi-repository path validation and consistency checker

${C_BLUE}Usage:${C_RESET}
  ssot-path-guard.sh <file>              Check file for SSoT violations
  ssot-path-guard.sh <file> --sync       Check file and show sync points
  ssot-path-guard.sh --validate-config   Validate configuration file
  ssot-path-guard.sh --list-ssot          List all known SSoT mappings
  ssot-path-guard.sh --list-paths         List all known SSoT paths
  ssot-path-guard.sh --help               Show this help message

${C_BLUE}Exit Codes:${C_RESET}
  0 - File is safe to edit (no SSoT issues)
  1 - Warning: File has related SSoT copies (sync required)
  2 - Critical: CRITICAL SSoT file (must sync all copies)
  127 - Configuration error

${C_BLUE}Cluster:${C_RESET}
  $GUARD_CLUSTER

EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry Point
# ─────────────────────────────────────────────────────────────────────────────

main() {
    if [[ $# -eq 0 ]]; then
        show_help
        return 0
    fi

    # Validate config first
    if ! validate_config; then
        return 127
    fi

    case "${1:-}" in
        --help)
            show_help
            return 0
            ;;
        --validate-config)
            return 0  # Already validated above
            ;;
        --list-ssot)
            list_ssot_mappings
            return 0
            ;;
        --list-paths)
            list_all_paths
            return 0
            ;;
        --sync)
            log_error "Invalid usage: --sync must follow a file path"
            log_error "Usage: ssot-path-guard.sh <file> --sync"
            return 1
            ;;
        *)
            # Treat as file path
            check_file "$1" "${2:-}"
            return $?
            ;;
    esac
}

main "$@"
