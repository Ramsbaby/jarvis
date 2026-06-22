#!/usr/bin/env bash
# pre-service-stop-check.sh — Service stop pre-flight check for auto-recovery mechanisms
#
# Cluster: cl-81d765eefdc6ec7f
# Seed issue: LaunchAgent bootout without predicting watchdog auto-recovery
#
# Purpose:
#   Before running bootout/kill/stop commands, perform unified checks on:
#   1. LaunchAgent activation status (via launchctl list)
#   2. crontab registration status (via crontab -l)
#   3. watchdog process status (via pgrep)
#
#   Output each mechanism state and warn if auto-recovery is possible.
#
# Usage:
#   source pre-service-stop-check.sh
#   pre_service_stop_check [service-pattern]
#     → exit 0: check complete, warnings/info displayed
#     → exit 1: error during check
#
#   Standalone:
#   ./pre-service-stop-check.sh [service-pattern]
#   ./pre-service-stop-check.sh --test     (self-test mode)
#   ./pre-service-stop-check.sh --verbose  (detailed mode)

set -euo pipefail

readonly GUARD_VERSION="1.0.0"
readonly GUARD_CLUSTER="cl-81d765eefdc6ec7f"
readonly GUARD_NAME="pre-service-stop-check"
readonly GUARD_LOG_DIR="${HOME}/jarvis/runtime/logs"
readonly GUARD_LOG_FILE="${GUARD_LOG_DIR}/${GUARD_NAME}.jsonl"

# Recovery mechanism keywords
declare -a RECOVERY_MECHANISMS=(
    "ai.jarvis.watchdog"
    "com.jarvis"
    "ai.jarvis"
)

_guard_log() {
    local level="$1"
    local message="$2"
    mkdir -p "$GUARD_LOG_DIR"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '{"ts":"%s","level":"%s","guard":"%s","cluster":"%s","msg":"%s"}\n' \
        "$ts" "$level" "$GUARD_NAME" "$GUARD_CLUSTER" \
        "$(printf '%s' "$message" | sed 's/"/\\"/g')" >> "$GUARD_LOG_FILE" 2>/dev/null || true
}

_print_header() {
    printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    printf '[%s] Service Stop Pre-Flight Check (v%s, cluster=%s)\n' \
        "$GUARD_NAME" "$GUARD_VERSION" "$GUARD_CLUSTER"
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
}

_print_section() {
    printf '\n[●] %s\n' "$1"
    printf '─────────────────────────────────────────────────────────\n'
}

_print_success() {
    printf '  ✓ %s\n' "$1"
}

_print_warning() {
    printf '  ⚠ %s\n' "$1"
}

_print_info() {
    printf '  ℹ %s\n' "$1"
}

# Check LaunchAgent status
check_launchagent_status() {
    local service_pattern="${1:-}"
    local verbose="${2:-0}"

    _print_section "LaunchAgent Activation Status"

    if ! command -v launchctl &>/dev/null; then
        _print_warning "launchctl not found (macOS only)"
        _guard_log "warn" "launchctl not found"
        return 0
    fi

    # Query all LaunchAgents
    if ! launchctl list > /tmp/launchctl_list.txt 2>/dev/null; then
        _print_warning "launchctl list failed"
        _guard_log "error" "launchctl list failed"
        rm -f /tmp/launchctl_list.txt
        return 1
    fi

    local active_count=0
    local inactive_count=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local pid label is_recovery
        pid=$(echo "$line" | awk '{print $1}')
        label=$(echo "$line" | awk '{$1=""; print $0}' | xargs)

        # Check if this is a recovery mechanism
        is_recovery=0
        for mechanism in "${RECOVERY_MECHANISMS[@]}"; do
            if [[ "$label" == *"$mechanism"* ]]; then
                is_recovery=1
                break
            fi
        done

        if [[ $is_recovery -eq 1 ]]; then
            if [[ "$pid" != "-" ]] && [[ "$pid" != "0" ]]; then
                (( active_count++ )) || true
                if [[ $verbose -eq 1 ]]; then
                    _print_success "Active: $label (PID=$pid)"
                fi
            else
                (( inactive_count++ )) || true
                if [[ $verbose -eq 1 ]]; then
                    _print_info "Inactive: $label"
                fi
            fi
        fi
    done < /tmp/launchctl_list.txt

    rm -f /tmp/launchctl_list.txt

    local total_agents=$((active_count + inactive_count))
    _print_success "Recovery agents found: $total_agents"
    _print_info "  Active: $active_count | Inactive: $inactive_count"

    if [[ $active_count -gt 0 ]]; then
        _print_warning "Active LaunchAgents detected - bootout may trigger auto-recovery"
    fi

    _guard_log "info" "LaunchAgent check completed" 
    return 0
}

# Check crontab status
check_crontab_status() {
    local verbose="${1:-0}"

    _print_section "crontab Registration Status"

    local crontab_entries
    if ! crontab_entries=$(crontab -l 2>/dev/null); then
        _print_info "No crontab entries or read failed"
        _guard_log "info" "No crontab entries"
        return 0
    fi

    local task_count=0
    local recovery_count=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        (( task_count++ )) || true

        if [[ "$line" == *"watchdog"* ]] || \
           [[ "$line" == *"guardian"* ]] || \
           [[ "$line" == *"orchestrator"* ]] || \
           [[ "$line" == *"recovery"* ]] || \
           [[ "$line" == *"bot-" ]]; then
            (( recovery_count++ )) || true
            if [[ $verbose -eq 1 ]]; then
                _print_success "Recovery task: $(echo "$line" | cut -c1-60)..."
            fi
        fi
    done <<< "$crontab_entries"

    _print_success "crontab entries found: $task_count"
    _print_info "  Recovery tasks: $recovery_count"

    if [[ $recovery_count -gt 0 ]]; then
        _print_warning "crontab has recovery tasks registered - periodic restart may occur"
    fi

    _guard_log "info" "crontab check completed"
    return 0
}

# Check watchdog process
check_watchdog_process() {
    local verbose="${1:-0}"

    _print_section "watchdog Process Status"

    local watchdog_pids
    watchdog_pids=$(pgrep -f "watchdog|guardian|bot-watchdog" 2>/dev/null || true)

    if [[ -z "$watchdog_pids" ]]; then
        _print_info "No watchdog processes running"
        _guard_log "info" "No watchdog processes"
        return 0
    fi

    local count=0
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        (( count++ )) || true
        if [[ $verbose -eq 1 ]]; then
            _print_success "Running: PID=$pid"
        fi
    done <<< "$watchdog_pids"

    _print_success "watchdog processes running: $count"
    if [[ $count -gt 0 ]]; then
        _print_warning "watchdog is active - stopped services will be auto-recovered"
    fi

    _guard_log "info" "watchdog check completed"
    return 0
}

# Risk analysis
_analyze_recovery_risk() {
    _print_section "Auto-Recovery Risk Analysis"

    local has_launchagent=0
    local has_crontab=0
    local has_watchdog=0

    [[ -n "$(launchctl list 2>/dev/null | grep -E "$RECOVERY_MECHANISMS" || true)" ]] && has_launchagent=1
    [[ -n "$(crontab -l 2>/dev/null | grep -E "watchdog|guardian|bot-" || true)" ]] && has_crontab=1
    pgrep -f "watchdog|guardian" >/dev/null 2>&1 && has_watchdog=1

    local risk_level="LOW"
    local risk_count=$((has_launchagent + has_crontab + has_watchdog))

    if [[ $risk_count -eq 3 ]]; then
        risk_level="CRITICAL"
    elif [[ $risk_count -eq 2 ]]; then
        risk_level="HIGH"
    elif [[ $risk_count -eq 1 ]]; then
        risk_level="MEDIUM"
    fi

    printf '\n'
    printf '  Risk Level: [%s]\n' "$risk_level"
    printf '  Active Recovery Mechanisms:\n'
    [[ $has_launchagent -eq 1 ]] && _print_warning "    LaunchAgent (PID-based monitoring)"
    [[ $has_crontab -eq 1 ]] && _print_warning "    crontab (periodic monitoring)"
    [[ $has_watchdog -eq 1 ]] && _print_warning "    watchdog process (realtime monitoring)"

    if [[ $risk_count -gt 0 ]]; then
        printf '\n  Recommendations:\n'
        printf '    1. Disable the above mechanisms before stopping services\n'
        printf '    2. Multiple recovery layers exist - stopping one is not enough\n'
        printf '    3. Establish clear disable/stop sequence\n'
    fi

    _guard_log "info" "Risk analysis completed"
    return 0
}

# Main check function
pre_service_stop_check() {
    local service_pattern="${1:-}"
    local verbose="${2:-0}"

    _print_header

    check_launchagent_status "$service_pattern" "$verbose" || return 1
    check_crontab_status "$verbose" || return 1
    check_watchdog_process "$verbose" || return 1
    _analyze_recovery_risk

    printf '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
    printf '[Complete] Review information above before stopping services\n'
    printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'

    return 0
}

# Self-test mode
_run_self_test() {
    local pass=0
    local fail=0

    printf '[%s] Self-test (v%s, cluster=%s)\n' \
        "$GUARD_NAME" "$GUARD_VERSION" "$GUARD_CLUSTER"
    printf '─────────────────────────────────────────────────────────\n'

    if command -v launchctl &>/dev/null; then
        printf '[T1] PASS: launchctl available\n'
        (( pass++ )) || true
    else
        printf '[T1] SKIP: launchctl not available\n'
    fi

    if crontab -l &>/dev/null 2>&1 || true; then
        printf '[T2] PASS: crontab queryable\n'
        (( pass++ )) || true
    fi

    if command -v pgrep &>/dev/null; then
        printf '[T3] PASS: pgrep available\n'
        (( pass++ )) || true
    else
        printf '[T3] FAIL: pgrep not found\n'
        (( fail++ )) || true
    fi

    if declare -f pre_service_stop_check >/dev/null 2>&1; then
        printf '[T4] PASS: function defined\n'
        (( pass++ )) || true
    else
        printf '[T4] FAIL: function error\n'
        (( fail++ )) || true
    fi

    printf '─────────────────────────────────────────────────────────\n'
    printf 'Result: %d pass\n' "$pass"

    if (( fail == 0 )); then
        printf '[%s] Self-test PASSED\n' "$GUARD_NAME"
        return 0
    else
        return 1
    fi
}

# Standalone execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --test)
            _run_self_test
            exit $?
            ;;
        --verbose)
            pre_service_stop_check "${2:-}" 1
            exit $?
            ;;
        --version)
            printf '%s v%s (cluster=%s)\n' "$GUARD_NAME" "$GUARD_VERSION" "$GUARD_CLUSTER"
            exit 0
            ;;
        --help)
            printf 'Usage: %s [--test|--verbose|--version|--help]\n' "$(basename "$0")" >&2
            exit 0
            ;;
        "")
            pre_service_stop_check "" 0
            exit $?
            ;;
        *)
            pre_service_stop_check "$1" 0
            exit $?
            ;;
    esac
fi
