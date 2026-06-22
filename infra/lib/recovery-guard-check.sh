#!/bin/bash
#
# Recovery Guard Check Script (cl-81d765eefdc6ec7f)
#
# Purpose: Inspect auto-recovery layers before issuing service disruption commands
# (bootout, kill, etc.). Detects LaunchAgent registrations, crontab entries, and
# watchdog process activation state.
#

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script metadata
CLUSTER_ID="cl-81d765eefdc6ec7f"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Configuration
JARVIS_HOME="${JARVIS_HOME:-${HOME}/.jarvis}"
RUNTIME_HOME="${RUNTIME_HOME:-${HOME}/jarvis/runtime}"

# Counter for recovery layers
RECOVERY_LAYER_COUNT=0

# ==============================================================================
# Helper Functions
# ==============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} Recovery Guard Check - Cluster $CLUSTER_ID"
    echo -e "${BLUE}║${NC} Timestamp: $TIMESTAMP"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    local title="$1"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}▶${NC} $title"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_warning() {
    local msg="$1"
    echo -e "${RED}⚠ WARNING${NC}: $msg"
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}✓${NC} $msg"
}

print_info() {
    local msg="$1"
    echo -e "${BLUE}ℹ${NC} $msg"
}

# ==============================================================================
# [2] LaunchAgent Activation Status Check
# ==============================================================================

check_launchagent_status() {
    print_section "LaunchAgent Activation Status"

    launchctl list 2>/dev/null | grep 'ai\.jarvis' | while read -r line; do
        local pid=$(echo "$line" | awk '{print $1}')
        local label=$(echo "$line" | awk '{print $NF}')

        if [ "$pid" != "-" ] && [ ! -z "$pid" ] && [ "$pid" != "0" ]; then
            if [ "$pid" -gt 0 ] 2>/dev/null; then
                echo -e "${GREEN}✓ ACTIVE${NC}   [PID: $pid] $label"
            else
                echo -e "${YELLOW}○ INACTIVE${NC} $label"
            fi
        else
            echo -e "${YELLOW}○ INACTIVE${NC} $label"
        fi
    done

    echo ""
    print_info "Total ai.jarvis agents registered: $(launchctl list 2>/dev/null | grep -c 'ai\.jarvis')"

    local active_count=$(launchctl list 2>/dev/null | grep 'ai\.jarvis' | awk '$1 ~ /^[0-9]+$/ && $1 > 0 {count++} END {print count+0}')
    print_info "Active agents (running): $active_count"

    if [ "$active_count" -gt 0 ]; then
        print_warning "LaunchAgent auto-recovery layer is ACTIVE ($active_count agents)"
        RECOVERY_LAYER_COUNT=$((RECOVERY_LAYER_COUNT + 1))
    else
        print_success "No active LaunchAgent recovery layer"
    fi

    echo ""
}

# ==============================================================================
# [3] Crontab Registration State Check
# ==============================================================================

check_crontab_status() {
    print_section "Crontab Registration Status"

    local crontab_content=$(crontab -l 2>/dev/null || true)

    if [ -z "$crontab_content" ]; then
        echo -e "${YELLOW}No crontab entries found${NC}"
        echo ""
        return
    fi

    # Show entries
    echo "$crontab_content" | grep -v '^#' | grep -v '^[[:space:]]*$' | while read -r entry; do
        if echo "$entry" | grep -qE 'jarvis|watchdog|launchd-guardian|bot-watchdog'; then
            echo -e "${GREEN}✓${NC} $entry"
        else
            echo -e "${BLUE}•${NC} $entry"
        fi
    done

    echo ""

    # Count entries
    local jarvis_count=$(echo "$crontab_content" | grep -v '^#' | grep -v '^[[:space:]]*$' | grep -cE 'jarvis|watchdog|launchd-guardian|bot-watchdog' || echo 0)
    local total_count=$(echo "$crontab_content" | grep -v '^#' | grep -v '^[[:space:]]*$' | wc -l)

    print_info "Total crontab entries: $total_count"
    print_info "Jarvis/Watchdog cron tasks: $jarvis_count"

    if [ "$jarvis_count" -gt 0 ]; then
        print_warning "Crontab auto-recovery layer is REGISTERED ($jarvis_count entries)"
        RECOVERY_LAYER_COUNT=$((RECOVERY_LAYER_COUNT + 1))
    else
        print_success "No crontab recovery layer detected"
    fi

    echo ""
}

# ==============================================================================
# [4] Watchdog Process Activation Status Check
# ==============================================================================

check_watchdog_process() {
    print_section "Watchdog Process Activation Status"

    local watchdog_proc=$(ps aux 2>/dev/null | grep -E '\bwatchdog\.sh\b' | grep -v grep || true)

    if [ -z "$watchdog_proc" ]; then
        print_success "No active watchdog process detected"
        echo ""
        return
    fi

    local pid=$(echo "$watchdog_proc" | awk '{print $2}')
    local user=$(echo "$watchdog_proc" | awk '{print $1}')
    local cpu=$(echo "$watchdog_proc" | awk '{print $3}')
    local mem=$(echo "$watchdog_proc" | awk '{print $4}')

    print_warning "Watchdog process is ACTIVE"
    echo ""
    echo "  User:     $user"
    echo "  PID:      $pid"
    echo "  CPU:      $cpu%"
    echo "  Memory:   $mem%"
    echo "  Script:   $RUNTIME_HOME/scripts/watchdog.sh"
    echo ""

    RECOVERY_LAYER_COUNT=$((RECOVERY_LAYER_COUNT + 1))
    echo ""
}

# ==============================================================================
# Launchd Guardian Status Check
# ==============================================================================

check_launchd_guardian() {
    print_section "Launchd Guardian Status"

    local guardian_proc=$(ps aux 2>/dev/null | grep -E 'launchd-guardian' | grep -v grep || true)

    if [ -z "$guardian_proc" ]; then
        print_success "No launchd-guardian process detected"
        echo ""
        return
    fi

    local pid=$(echo "$guardian_proc" | awk '{print $2}')
    print_warning "Launchd guardian process is ACTIVE (PID: $pid)"
    print_info "Guardian monitors and restarts LaunchAgents"
    RECOVERY_LAYER_COUNT=$((RECOVERY_LAYER_COUNT + 1))
    echo ""
}

# ==============================================================================
# Recovery Summary
# ==============================================================================

check_recovery_summary() {
    print_section "Auto-Recovery Layers Summary"

    echo ""
    echo "Total active recovery layers detected: $RECOVERY_LAYER_COUNT"
    echo ""

    if [ "$RECOVERY_LAYER_COUNT" -eq 0 ]; then
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✓ NO AUTO-RECOVERY LAYERS DETECTED${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "Safe to issue service disruption commands (bootout, kill, etc.)"
        echo ""
    else
        echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}⚠ $RECOVERY_LAYER_COUNT AUTO-RECOVERY LAYER(S) DETECTED${NC}"
        echo -e "${RED}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo "RECOMMENDED ACTIONS:"
        echo ""
        echo "  1. Boot out LaunchAgents BEFORE issuing service disruption:"
        echo "     launchctl bootout system/ai.jarvis.watchdog"
        echo "     launchctl bootout system/ai.jarvis.orchestrator"
        echo "     launchctl bootout system/ai.jarvis.event-watcher"
        echo ""
        echo "  2. Disable crontab entries (comment out or remove)"
        echo ""
        echo "  3. Kill watchdog and guardian processes:"
        echo "     pkill -f 'watchdog\.sh'"
        echo "     pkill -f 'launchd-guardian\.sh'"
        echo ""
        echo "  4. Verify all layers are disabled BEFORE proceeding"
        echo ""
    fi

    echo ""
}

# ==============================================================================
# Main Execution
# ==============================================================================

print_header
check_launchagent_status
check_crontab_status
check_watchdog_process
check_launchd_guardian
check_recovery_summary

# Exit with status code based on recovery layer count
if [ "$RECOVERY_LAYER_COUNT" -gt 0 ]; then
    exit 1
else
    exit 0
fi
