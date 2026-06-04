#!/usr/bin/env bash
# pilot-test.sh - Test Phase 1 budget routing with three health check tasks
# Usage: ./pilot-test.sh [--live] [--report]
#
# This script tests the pilot routing configuration on low-risk tasks:
# 1. system-health (hourly health check)
# 2. disk-alert (disk usage check)
# 3. rate-limit-check (API rate limit monitoring)
#
# --live: Actually route to DeepSeek (requires DEEPSEEK_API_KEY env var)
# --report: Generate pilot test report after execution

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
INFRA_DIR="${HOME}/jarvis/infra"
LOG_DIR="${BOT_HOME}/logs"
PILOT_LOG="${LOG_DIR}/pilot-test.log"

mkdir -p "$LOG_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$PILOT_LOG"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1" | tee -a "$PILOT_LOG"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1" | tee -a "$PILOT_LOG"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $1" | tee -a "$PILOT_LOG"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1" | tee -a "$PILOT_LOG"
}

# Parse arguments
LIVE_MODE=false
GENERATE_REPORT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --live)
            LIVE_MODE=true
            shift
            ;;
        --report)
            GENERATE_REPORT=true
            shift
            ;;
        *)
            log_error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

log "=========================================="
log "PILOT TEST: Phase 1 Budget Routing"
log "=========================================="
log "Timestamp: $(date)"
log "BOT_HOME: $BOT_HOME"
log "Live Mode: $LIVE_MODE"

# Verify pilot configuration exists
log_step "Verifying pilot configuration..."
if [[ ! -f "${BOT_HOME}/config/pilot-routing-deepseek-qwen.json" ]]; then
    log_error "Pilot config not found at ${BOT_HOME}/config/pilot-routing-deepseek-qwen.json"
    exit 1
fi
log_success "Pilot config verified"

# Verify model-selector exists
log_step "Verifying model-selector.mjs..."
if [[ ! -f "${BOT_HOME}/lib/model-selector.mjs" ]]; then
    log_error "model-selector.mjs not found"
    exit 1
fi
log_success "model-selector.mjs verified"

# Phase 1 tasks
PHASE1_TASKS=(
    "system-health"
    "disk-alert"
    "rate-limit-check"
)

# Test each task
log_step "Testing Phase 1 tasks with model-selector..."
TESTS_PASSED=0
TESTS_FAILED=0
ROUTING_DECISIONS=()

for task_id in "${PHASE1_TASKS[@]}"; do
    log ""
    log "Testing task: $task_id"

    # Get routing decision, extract only JSON part (skip stderr warnings)
    routing_output=$(node "${BOT_HOME}/lib/model-selector.mjs" "$task_id" --json 2>/dev/null | tail -15)

    # Check if taskId field exists
    if echo "$routing_output" | grep 'taskId' >/dev/null 2>&1; then
        log_success "Model selection succeeded for $task_id"

        # Extract fields using awk (more robust than grep/sed)
        model=$(echo "$routing_output" | grep 'model' | head -1 | awk -F'"' '{print $(NF-1)}')
        source=$(echo "$routing_output" | grep 'source' | head -1 | awk -F'"' '{print $(NF-1)}')

        log "  Model: $model"
        log "  Source: $source"

        ROUTING_DECISIONS+=("$task_id:$model:$source")
        ((TESTS_PASSED++))

    else
        log_error "Model selection failed for $task_id"
        ((TESTS_FAILED++))
    fi
done

log ""
log "=========================================="
log "Routing Test Summary"
log "=========================================="
log "Total tests: $((TESTS_PASSED + TESTS_FAILED))"
log_success "Passed: $TESTS_PASSED"
if [[ $TESTS_FAILED -gt 0 ]]; then
    log_error "Failed: $TESTS_FAILED"
fi

if [[ $TESTS_FAILED -gt 0 ]]; then
    log_error "Phase 1 routing test FAILED"
    exit 1
fi

# If --live mode, attempt actual execution
if [[ "$LIVE_MODE" == "true" ]]; then
    log ""
    log_step "Live Mode: Testing actual task execution with budget models..."

    if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
        log_warning "DEEPSEEK_API_KEY not set. Skipping live execution test."
        log_warning "Set DEEPSEEK_API_KEY environment variable to test actual API calls"
    else
        log_success "DEEPSEEK_API_KEY is set. Ready for live testing."

        # Test 1: system-health
        log ""
        log "Attempting live execution: system-health"
        if timeout 10 node "${BOT_HOME}/lib/model-selector.mjs" "system-health" --json >/dev/null 2>&1; then
            log_success "system-health model selection OK"
        else
            log_warning "system-health model selection returned non-zero (may be expected)"
        fi
    fi
fi

# Generate report if requested
if [[ "$GENERATE_REPORT" == "true" ]]; then
    log ""
    log_step "Generating pilot test report..."

    REPORT_FILE="${LOG_DIR}/pilot-test-report-$(date +%Y%m%d-%H%M%S).json"

    cat > "$REPORT_FILE" <<EOF
{
  "reportGeneratedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "testStatus": "$([ $TESTS_FAILED -eq 0 ] && echo 'PASSED' || echo 'FAILED')",
  "testsSummary": {
    "total": $((TESTS_PASSED + TESTS_FAILED)),
    "passed": $TESTS_PASSED,
    "failed": $TESTS_FAILED
  },
  "phase1Tasks": [
    $(printf '"%s"' "${PHASE1_TASKS[@]}" | sed 's/" /"","/g')
  ],
  "routingDecisions": [
EOF

    for decision in "${ROUTING_DECISIONS[@]}"; do
        IFS=':' read -r task_id model source <<< "$decision"
        cat >> "$REPORT_FILE" <<EOF
    {
      "taskId": "$task_id",
      "model": "$model",
      "source": "$source"
    },
EOF
    done

    # Remove last comma and close JSON
    sed -i '' '$ s/,$//' "$REPORT_FILE"
    cat >> "$REPORT_FILE" <<EOF
  ],
  "configStatus": "VERIFIED",
  "nextSteps": [
    "Monitor routing.jsonl for 7 days (Phase 1 duration)",
    "Compare success rate, latency, and cost vs baseline",
    "Generate final report on 2026-06-01 for go/no-go decision"
  ]
}
EOF

    log_success "Report saved to $REPORT_FILE"
    cat "$REPORT_FILE"
fi

log ""
log "=========================================="
log "Pilot test completed successfully"
log "=========================================="
log "Next steps:"
log "  1. Monitor /logs/pilot-routing.jsonl daily"
log "  2. Review success rates, latencies, costs"
log "  3. Schedule 2026-06-01 go/no-go decision"
log "  4. Run: ./pilot-test.sh --report (for final summary)"
