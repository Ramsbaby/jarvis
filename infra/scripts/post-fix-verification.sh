#!/usr/bin/env bash
# post-fix-verification.sh — 수정 작업 완료 후 /verify 자동 강제 실행 파이프라인 훅
#
# 역할: jarvis-auditor.sh 또는 개발자 fix 후 자동으로 /verify 단계 실행
#       감사관 출력을 검증하고, cross-validator와 연계하여 재검증 확인
#
# 호출: post-fix-verification.sh [--audit-log <log_file>] [--fix-files <csv>] [--target-cluster <id>]
#
# 환경:
#   BOT_HOME: Jarvis 홈 (기본값: ~/jarvis/runtime)
#   DRY_RUN: true면 실제 수정하지 않고 리포트만 생성

export JARVIS_HOME="${JARVIS_HOME:-${HOME}/jarvis/runtime}"
source "${JARVIS_HOME}/lib/compat.sh" || {
  echo "ERROR: Failed to source compat.sh from $JARVIS_HOME" >&2
  exit 1
}
set -uo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG_FILE="$BOT_HOME/logs/post-fix-verification.log"
VERIFICATION_REPORT="$BOT_HOME/results/verifications/$(date +%Y-%m-%d_%H%M%S)_verify.md"
CROSS_VALIDATOR="$BOT_HOME/bin/auditor-cross-validator.mjs"
STATE_DIR="$BOT_HOME/state"
METRICS_FILE="$STATE_DIR/verification-metrics.json"

DRY_RUN="${DRY_RUN:-false}"
AUDIT_LOG=""
FIX_FILES=""
TARGET_CLUSTER=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --audit-log) AUDIT_LOG="$2"; shift 2 ;;
        --fix-files) FIX_FILES="$2"; shift 2 ;;
        --target-cluster) TARGET_CLUSTER="$2"; shift 2 ;;
        *) shift ;;
    esac
done

log() { echo "[$(date '+%F %T')] [post-fix-verify] $*" >> "$LOG_FILE"; }
report() { REPORT_BODY+="$1"$'\n'; }

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$VERIFICATION_REPORT")" "$STATE_DIR"

log "=== Post-Fix Verification started (dry_run=$DRY_RUN) ==="
log "audit_log=$AUDIT_LOG, fix_files=$FIX_FILES, target_cluster=$TARGET_CLUSTER"

REPORT_BODY=""
report "# Post-Fix Verification Report"
report ""
report "**Timestamp**: $(date '+%Y-%m-%d %H:%M:%S KST')"
report "**Target Cluster**: ${TARGET_CLUSTER:-N/A}"
report ""
report "---"
report ""

# ============================================================================
# Phase 1: Fixed Files Syntax Validation
# ============================================================================

report "## Phase 1: Syntax Validation (Fixed Files)"
report ""

SYNTAX_PASS=0
SYNTAX_FAIL=0

if [[ -n "$FIX_FILES" ]]; then
    IFS=',' read -ra FILES <<< "$FIX_FILES"
    for file in "${FILES[@]}"; do
        file="${file#"$BOT_HOME"/}"  # Normalize path
        local full_path="$BOT_HOME/$file"

        if [[ ! -f "$full_path" ]]; then
            report "- ⚠️  **SKIP**: \`$file\` not found"
            continue
        fi

        local ext="${file##*.}"
        local verify_ok=true
        local error_msg=""

        case "$ext" in
            sh|bash)
                if ! error_msg=$(bash -n "$full_path" 2>&1); then
                    verify_ok=false
                fi
                ;;
            js|mjs)
                if ! error_msg=$(node --check "$full_path" 2>&1); then
                    verify_ok=false
                fi
                ;;
            json)
                if ! error_msg=$(jq empty "$full_path" 2>&1); then
                    verify_ok=false
                fi
                ;;
            *)
                report "- ℹ️  **SKIP**: \`$file\` (unsupported extension)"
                continue
                ;;
        esac

        if [[ "$verify_ok" == true ]]; then
            report "- ✅ **PASS**: \`$file\` ($ext syntax OK)"
            ((SYNTAX_PASS++))
        else
            report "- ❌ **FAIL**: \`$file\` — $error_msg"
            ((SYNTAX_FAIL++))
        fi
    done
else
    report "- ℹ️  No fix_files provided, skipping syntax validation"
fi

report ""
report "| Metric | Count |"
report "|--------|-------|"
report "| Syntax Pass | $SYNTAX_PASS |"
report "| Syntax Fail | $SYNTAX_FAIL |"
report ""

# ============================================================================
# Phase 2: Cross-Validator Invocation
# ============================================================================

report "## Phase 2: Cross-Validation (Auditor Output Check)"
report ""

CROSS_VALIDATE_OK=true
CROSS_VALIDATE_MSG=""

if [[ -f "$CROSS_VALIDATOR" && -n "$AUDIT_LOG" && -f "$AUDIT_LOG" ]]; then
    log "Invoking cross-validator with audit_log=$AUDIT_LOG"

    if CV_OUT=$(node "$CROSS_VALIDATOR" --log "$AUDIT_LOG" 2>&1); then
        report "- ✅ **CROSS-VALIDATOR PASS**"
        report ""
        report "**Output:**"
        report "\`\`\`"
        report "$CV_OUT"
        report "\`\`\`"
        report ""
    else
        CROSS_VALIDATE_OK=false
        CROSS_VALIDATE_MSG="$CV_OUT"
        report "- ❌ **CROSS-VALIDATOR ISSUE DETECTED**"
        report ""
        report "**Output:**"
        report "\`\`\`"
        report "$CROSS_VALIDATE_MSG"
        report "\`\`\`"
        report ""
    fi
else
    report "- ℹ️  Cross-validator unavailable or no audit_log provided"
    report ""
fi

# ============================================================================
# Phase 3: Cluster-Specific Guard Check
# ============================================================================

report "## Phase 3: Cluster-Specific Guard"
report ""

if [[ -n "$TARGET_CLUSTER" ]]; then
    # Check if this cluster has known repeat patterns
    local cluster_guard_file="$STATE_DIR/cluster-guards/$TARGET_CLUSTER.json"

    if [[ -f "$cluster_guard_file" ]]; then
        report "- ℹ️  Cluster guard found: \`$TARGET_CLUSTER\`"

        # Validate that guard logic was applied during fix
        local guard_state
        guard_state=$(jq -r '.guard_status // "unknown"' "$cluster_guard_file" 2>/dev/null || echo "unknown")

        if [[ "$guard_state" == "applied" ]]; then
            report "- ✅ **Guard Applied**: Repeat pattern mitigation confirmed"
        else
            report "- ⚠️  **Guard Status Unknown**: \`$guard_state\`"
        fi
    else
        report "- ℹ️  No cluster-specific guard configured for \`$TARGET_CLUSTER\`"
    fi
else
    report "- ℹ️  No target cluster specified"
fi

report ""

# ============================================================================
# Phase 4: Metrics & Summary
# ============================================================================

report "## Summary"
report ""

local OVERALL_STATUS="PASS"
if [[ $SYNTAX_FAIL -gt 0 || "$CROSS_VALIDATE_OK" == false ]]; then
    OVERALL_STATUS="FAIL"
fi

report "| Status | Value |"
report "|--------|-------|"
report "| Overall | **$OVERALL_STATUS** |"
report "| Syntax Validation | $SYNTAX_PASS pass, $SYNTAX_FAIL fail |"
report "| Cross-Validation | $([ "$CROSS_VALIDATE_OK" == true ] && echo "✅ PASS" || echo "❌ ISSUE") |"
report ""

report "---"
report ""
report "*Generated by post-fix-verification.sh*"

# Write report
echo "$REPORT_BODY" > "$VERIFICATION_REPORT"
log "Verification report written to $VERIFICATION_REPORT"

# ============================================================================
# Persistence: Write metrics JSON
# ============================================================================

mkdir -p "$(dirname "$METRICS_FILE")"
cat > "$METRICS_FILE" <<EOJSON
{
  "timestamp": $(date +%s),
  "cluster": "${TARGET_CLUSTER:-N/A}",
  "syntax_pass": $SYNTAX_PASS,
  "syntax_fail": $SYNTAX_FAIL,
  "cross_validation_ok": $([ "$CROSS_VALIDATE_OK" == true ] && echo "true" || echo "false"),
  "overall_status": "$OVERALL_STATUS",
  "report_path": "$VERIFICATION_REPORT"
}
EOJSON

log "Metrics written to $METRICS_FILE"

# ============================================================================
# Exit Code
# ============================================================================

if [[ "$OVERALL_STATUS" == "FAIL" ]]; then
    log "=== Post-Fix Verification FAILED ==="
    exit 1
else
    log "=== Post-Fix Verification PASSED ==="
    exit 0
fi
