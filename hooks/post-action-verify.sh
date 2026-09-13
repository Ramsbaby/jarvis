#!/bin/bash
################################################################################
# Post-Action Completion Verification Hook
#
# Purpose:
#   - Automatically verify completion declarations before they take effect
#   - Block false completion claims that would reach the user
#   - Ensure actual artifacts exist and are valid
#
# Usage:
#   source ~/projects/jarvis/hooks/post-action-verify.sh
#   post_action_verify_completion "task_id" "response_text" [output_file] [html_file]
#
# Exit codes:
#   0 = Completion verified and allowed
#   1 = Completion blocked (verification failed)
#   2 = Invalid arguments or configuration
################################################################################

set -o pipefail

# Configuration
GUARD_CLUSTER_ID="cl-41697ce934383874"
HOOK_STATE_DIR="${HOME}/.jarvis/state/post-action-hooks"
HOOK_LOG_DIR="${HOME}/.jarvis/logs/post-action-verify"

# Dependency scripts
CLUSTER_GUARD="${HOME}/.jarvis/infra/lib/cluster-guard-cl-41697ce934383874.sh"
RESPONSE_VALIDATOR="${HOME}/.jarvis/infra/lib/response-completion-validator.sh"
ARTIFACT_VALIDATOR="${HOME}/.jarvis/infra/lib/artifact-validation-gate.sh"
IMPOSSIBLE_TASKS_REGISTRY="${HOME}/.jarvis/infra/lib/impossible-tasks-registry.json"

# ============================================================================
# INITIALIZATION
# ============================================================================

hook_init() {
    mkdir -p "$HOOK_STATE_DIR"
    mkdir -p "$HOOK_LOG_DIR"

    # Verify dependencies
    if [[ ! -f "$CLUSTER_GUARD" ]]; then
        echo "ERROR: Cluster guard not found: $CLUSTER_GUARD" >&2
        return 2
    fi

    if [[ ! -f "$RESPONSE_VALIDATOR" ]]; then
        echo "ERROR: Response validator not found: $RESPONSE_VALIDATOR" >&2
        return 2
    fi

    if [[ ! -f "$ARTIFACT_VALIDATOR" ]]; then
        echo "ERROR: Artifact validator not found: $ARTIFACT_VALIDATOR" >&2
        return 2
    fi

    if [[ ! -f "$IMPOSSIBLE_TASKS_REGISTRY" ]]; then
        echo "ERROR: Impossible tasks registry not found: $IMPOSSIBLE_TASKS_REGISTRY" >&2
        return 2
    fi

    # Source dependencies
    source "$CLUSTER_GUARD" 2>/dev/null || {
        echo "ERROR: Failed to source cluster guard" >&2
        return 2
    }

    source "$RESPONSE_VALIDATOR" 2>/dev/null || {
        echo "ERROR: Failed to source response validator" >&2
        return 2
    }

    source "$ARTIFACT_VALIDATOR" 2>/dev/null || {
        echo "ERROR: Failed to source artifact validator" >&2
        return 2
    }
}

# ============================================================================
# MAIN VERIFICATION LOGIC
# ============================================================================

post_action_verify_completion() {
    local task_id="$1"
    local response_text="$2"
    local output_file="${3:-}"
    local html_file="${4:-}"

    [[ -z "$task_id" ]] && {
        echo "ERROR: task_id required" >&2
        return 2
    }

    [[ -z "$response_text" ]] && {
        echo "ERROR: response_text required" >&2
        return 2
    }

    # Setup logging
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local log_file="$HOOK_LOG_DIR/${task_id}.log"

    {
        echo "================================================================================"
        echo "POST-ACTION COMPLETION VERIFICATION"
        echo "================================================================================"
        echo "Task ID: $task_id"
        echo "Timestamp: $timestamp"
        echo "Response Length: ${#response_text} chars"
        echo "Output File: ${output_file:-(not provided)}"
        echo "HTML File: ${html_file:-(not provided)}"
        echo ""

        # Phase 1: Detect completion claim
        echo "PHASE 1: Completion Claim Detection"
        echo "---"

        if echo "$response_text" | grep -qiE '완료했|완료되었|작업.*완료|완료.*선언|✅|✓'; then
            echo "✓ Completion claim detected"
            echo ""
        else
            echo "✓ No completion claim found (conservative response)"
            echo "RESULT: PASSED (no action needed)"
            echo "Exit Code: 0"
            return 0
        fi

        # Phase 2: Detect impossible tasks
        echo "PHASE 2: Impossible Task Detection"
        echo "---"

        local impossible_found=0
        if guard_detect_impossible_task "$response_text" >>"$log_file" 2>&1; then
            echo "✓ No impossible tasks detected"
        else
            echo "✗ BLOCKED: Impossible task detected"
            impossible_found=1
        fi
        echo ""

        if [[ $impossible_found -eq 1 ]]; then
            echo "RESULT: FAILED (impossible task)"
            echo "Exit Code: 1"
            return 1
        fi

        # Phase 3: Validate response completion
        echo "PHASE 3: Response Completion Validation"
        echo "---"

        if validate_response_completion "$response_text" "$output_file" >>"$log_file" 2>&1; then
            echo "✓ Response appears complete"
        else
            case $? in
                1)
                    echo "✗ WARNING: Response may be truncated"
                    ;;
                2)
                    echo "✗ WARNING: Output file not verified"
                    ;;
            esac
        fi
        echo ""

        # Phase 4: Validate artifact existence (if provided)
        echo "PHASE 4: Artifact Validation"
        echo "---"

        local artifact_valid=0

        if [[ -n "$output_file" ]]; then
            if [[ ! -f "$output_file" ]]; then
                echo "✗ BLOCKED: Output file does not exist: $output_file"
                artifact_valid=1
            elif [[ ! -s "$output_file" ]]; then
                echo "✗ BLOCKED: Output file is empty: $output_file"
                artifact_valid=1
            else
                local fsize=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null)
                echo "✓ Output file exists and is valid: $output_file ($fsize bytes)"
            fi
        else
            echo "⊘ No output file specified (skipped)"
        fi

        echo ""

        if [[ $artifact_valid -eq 1 ]]; then
            echo "RESULT: FAILED (false completion claim)"
            echo "Exit Code: 1"
            return 1
        fi

        # Phase 5: Feature consistency validation (if HTML file provided)
        echo "PHASE 5: Feature Consistency (HTML)"
        echo "---"

        if [[ -n "$html_file" ]] && [[ -f "$html_file" ]]; then

            local has_description=0
            if grep -qE 'description|설명|explanation' "$html_file"; then
                has_description=1
            fi

            if [[ $has_description -eq 1 ]]; then
                if grep -qE 'onclick|addEventListener|<script' "$html_file"; then
                    echo "✓ Description added with interactive features intact"
                else
                    echo "⚠ Description added but interactive features may be incomplete"
                fi
            else
                echo "⊘ No description section found (expected if not applicable)"
            fi
        else
            echo "⊘ HTML file not provided (skipped)"
        fi

        echo ""
        echo "================================================================================"
        echo "RESULT: PASSED (all verifications completed successfully)"
        echo "Exit Code: 0"
        echo "================================================================================"

    } | tee "$log_file"

    return 0
}

# ============================================================================
# CLI INTERFACE
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    hook_init || exit $?

    case "${1:-help}" in
        verify)
            shift
            post_action_verify_completion "$@"
            exit $?
            ;;
        init)
            hook_init
            exit $?
            ;;
        help)
            cat <<'EOF'
usage: post-action-verify.sh <command> [options]

Commands:
  verify <task_id> <response_text> [output_file] [html_file]
    Execute post-action completion verification

  init
    Initialize hook dependencies

  help
    Show this message

Examples:
  # Verify completion with artifact
  ./post-action-verify.sh verify "task-001" "작업을 완료했습니다." "/tmp/output.txt"

  # Verify completion with HTML file
  ./post-action-verify.sh verify "task-002" "완료했습니다." "/tmp/output.pdf" "/tmp/page.html"

Exit codes:
  0 - Verification passed, completion allowed
  1 - Verification failed, completion blocked
  2 - Configuration error or invalid arguments
EOF
            exit 0
            ;;
        *)
            echo "ERROR: Unknown command: $1" >&2
            exit 2
            ;;
    esac
fi

# Export functions
export -f post_action_verify_completion
