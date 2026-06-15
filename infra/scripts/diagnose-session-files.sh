#!/bin/bash

##############################################################################
# diagnose-session-files.sh
# Purpose: Diagnose and document session file structure, size, and load order
#
# Session Files Concept Definition:
# ├─ Session File: Persistent context storage (markdown/json files) in
# │  ~/.jarvis/context/. Stores user profile, coding mode, preferences.
# │  Each file = one "session context". Not related to API tokens.
# │
# ├─ Context Token: Ephemeral LLM context within a single API call.
# │  Counted by Claude API toward usage. Different from "session file".
# │  Size: varies, regenerated per call. NOT stored permanently.
# │
# └─ Credit: API usage billing unit. Consumed by context tokens.
#    Unit: measured in token counts. Independent of session files.
#
# DO NOT confuse:
# - "Session file" (persistent file on disk)
# - "Context tokens" (ephemeral API input)
# - "Credits" (billing units consumed per API call)
#
##############################################################################

set -e

# Configuration
JARVIS_HOME="${HOME}/.jarvis"
SESSION_DIRS=(
    "context"
    "context/claude-code-sessions"
    "context/claude-memory"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Report file
REPORT_FILE="${JARVIS_HOME}/reports/session-diagnosis-$(date +%Y%m%d-%H%M%S).txt"

# Ensure reports directory exists
mkdir -p "${JARVIS_HOME}/reports"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Session File Diagnosis Report${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

{
    echo "════════════════════════════════════════════════════════════════"
    echo "SESSION FILE DIAGNOSTIC REPORT"
    echo "Generated: $(date)"
    echo "════════════════════════════════════════════════════════════════"
    echo ""

    echo "[SECTION 1] CONCEPT DEFINITIONS"
    echo "────────────────────────────────────────────────────────────────"
    echo ""
    echo "1. SESSION FILE (Persistent on Disk)"
    echo "   Location: ~/.jarvis/context/*.md or *.json"
    echo "   Purpose: Store user profile, preferences, context between sessions"
    echo "   Lifetime: Persistent (survives app restart)"
    echo "   Examples:"
    echo "     - user-profile.md (main user context)"
    echo "     - coding-test-mode.md (coding mode preferences)"
    echo "     - career-daily.md (daily career notes)"
    echo "   NOT related to: API tokens, context token budget, billing"
    echo ""

    echo "2. CONTEXT TOKEN (Ephemeral, API-Level)"
    echo "   Location: Live Claude API calls only (not stored permanently)"
    echo "   Purpose: Represents input to LLM model"
    echo "   Lifetime: Duration of single API call only"
    echo "   Size: Counted by Claude API tokenizer"
    echo "   Cost: Consumed from billing credits per API call"
    echo "   NOT stored in: ~/.jarvis/context/"
    echo ""

    echo "3. CREDIT (Billing Unit)"
    echo "   Measurement: Token count → dollar cost"
    echo "   Source: Claude API usage meter"
    echo "   Independent of: session files, session file size, disk usage"
    echo ""

    echo "[COMMON CONFUSION POINTS] ⚠️"
    echo "────────────────────────────────────────────────────────────────"
    echo "WRONG: 'Session file size → context token budget'"
    echo "RIGHT: Session files are metadata only. Context tokens are"
    echo "       ephemeral API input, counted separately by Claude API."
    echo ""
    echo "WRONG: 'Deleting session files saves context tokens'"
    echo "RIGHT: Session files don't consume API tokens. Deleting them"
    echo "       only frees disk space in ~/.jarvis/."
    echo ""
    echo "WRONG: 'Large session file = expensive API call'"
    echo "RIGHT: Context token cost is determined by what's actually"
    echo "       sent in the API call, not by session file size."
    echo ""
    echo ""

    echo "[SECTION 2] SESSION FILE DIRECTORY STRUCTURE"
    echo "────────────────────────────────────────────────────────────────"
    echo ""

    # Scan all session directories
    for dir in "${SESSION_DIRS[@]}"; do
        full_path="${JARVIS_HOME}/${dir}"

        if [ -d "${full_path}" ]; then
            echo "Directory: ${full_path}"
            echo "  Size: $(du -sh "${full_path}" 2>/dev/null | awk '{print $1}')"
            echo "  File Count: $(find "${full_path}" -type f 2>/dev/null | wc -l)"
            echo ""

            # List top-level files with sizes
            echo "  Contents (Top Level):"
            ls -lh "${full_path}" 2>/dev/null | grep -v "^total" | grep -v "^d" | \
            awk '{printf "    %-40s %6s\n", $9, $5}' | head -20

            # List subdirectories with sizes
            if [ "$(find "${full_path}" -maxdepth 1 -type d | wc -l)" -gt 1 ]; then
                echo ""
                echo "  Subdirectories:"
                find "${full_path}" -maxdepth 1 -type d ! -name "." 2>/dev/null | sort | while read subdir; do
                    size=$(du -sh "${subdir}" 2>/dev/null | awk '{print $1}')
                    count=$(find "${subdir}" -type f 2>/dev/null | wc -l)
                    name=$(basename "${subdir}")
                    printf "    %-40s %6s (%4d files)\n" "${name}" "${size}" "${count}"
                done | head -20
            fi
        else
            echo "Directory: ${full_path} (NOT FOUND)"
        fi

        echo ""
    done

    echo "[SECTION 3] CRITICAL SESSION FILES (Load Order)"
    echo "────────────────────────────────────────────────────────────────"
    echo ""
    echo "Session files are loaded in the following priority order:"
    echo ""

    # Define critical files with expected path and purpose
    declare -a CRITICAL_FILES=(
        "context/user-profile.md:User profile and system context"
        "context/coding-test-mode.md:Coding mode preferences"
        "context/coding-coach-mode.md:Coaching mode settings"
        "context/coding-deep-mode.md:Deep work mode settings"
        "context/ssot-registry.json:Single source of truth registry"
        "context/injection-watch.json:Injection monitoring config"
    )

    priority=1
    for file_entry in "${CRITICAL_FILES[@]}"; do
        IFS=':' read -r filepath description <<< "${file_entry}"
        full_path="${JARVIS_HOME}/${filepath}"

        if [ -f "${full_path}" ]; then
            size=$(stat -f%z "${full_path}" 2>/dev/null | numfmt --to=iec-i --suffix=B 2>/dev/null || stat -c%s "${full_path}" 2>/dev/null | numfmt --to=iec-i --suffix=B 2>/dev/null || du -h "${full_path}" | awk '{print $1}')
            modified=$(stat -f%Sm -t "%Y-%m-%d %H:%M:%S" "${full_path}" 2>/dev/null || stat --format=%y "${full_path}" 2>/dev/null | cut -d' ' -f1-2)

            printf "%d. %-35s [%8s] Last: %s\n" \
                "${priority}" "${filepath}" "${size}" "${modified}"
            echo "   Purpose: ${description}"
        else
            printf "%d. %-35s [MISSING]\n" "${priority}" "${filepath}"
            echo "   Purpose: ${description}"
        fi
        ((priority++))
    done

    echo ""
    echo "[SECTION 4] SESSION DIRECTORY SIZE ANALYSIS"
    echo "────────────────────────────────────────────────────────────────"
    echo ""

    # Analyze by file type
    echo "File Types in Session Directories:"
    find "${JARVIS_HOME}/context" -type f 2>/dev/null | sed 's/.*\.//' | sort | uniq -c | sort -rn | while read count ext; do
        printf "  .%-10s: %4d files\n" "${ext}" "${count}"
    done

    echo ""
    echo "Largest Session Files:"
    find "${JARVIS_HOME}/context" -type f 2>/dev/null -exec du -h {} \; | sort -rh | head -10 | awk '{printf "  %8s: %s\n", $1, $2}'

    echo ""
    echo "[SECTION 5] DISK USAGE BREAKDOWN"
    echo "────────────────────────────────────────────────────────────────"
    echo ""

    total_session_size=$(du -sh "${JARVIS_HOME}/context" 2>/dev/null | awk '{print $1}')
    total_jarvis_size=$(du -sh "${JARVIS_HOME}" 2>/dev/null | awk '{print $1}')

    echo "Session context directory size: ${total_session_size}"
    echo "Total ~/.jarvis size:           ${total_jarvis_size}"

    echo ""
    echo "[SECTION 6] DIAGNOSTIC CHECKS"
    echo "────────────────────────────────────────────────────────────────"
    echo ""

    # Check for missing critical files
    missing_count=0
    for file_entry in "${CRITICAL_FILES[@]}"; do
        IFS=':' read -r filepath description <<< "${file_entry}"
        full_path="${JARVIS_HOME}/${filepath}"

        if [ ! -f "${full_path}" ]; then
            echo "⚠️  MISSING: ${filepath}"
            ((missing_count++))
        fi
    done

    if [ ${missing_count} -eq 0 ]; then
        echo "✓ All critical session files present"
    else
        echo "⚠️  ${missing_count} critical session files missing"
    fi

    echo ""

    # Check for corrupt/empty files
    empty_count=0
    find "${JARVIS_HOME}/context" -type f -size 0 2>/dev/null | while read empty_file; do
        echo "⚠️  EMPTY: ${empty_file}"
        ((empty_count++))
    done

    if [ ${empty_count} -eq 0 ]; then
        echo "✓ No empty session files detected"
    fi

    echo ""
    echo "[SECTION 7] CLAUDE CODE SESSIONS METADATA"
    echo "────────────────────────────────────────────────────────────────"
    echo ""

    session_count=$(find "${JARVIS_HOME}/context/claude-code-sessions" -maxdepth 1 -type d ! -name "claude-code-sessions" 2>/dev/null | wc -l)
    echo "Total Claude Code sessions: ${session_count}"

    echo ""
    echo "Recent sessions (last 5):"
    find "${JARVIS_HOME}/context/claude-code-sessions" -maxdepth 1 -type d ! -name "claude-code-sessions" 2>/dev/null | \
    xargs -I {} stat -f "%Sm %N" -t "%Y-%m-%d %H:%M:%S" {} 2>/dev/null | sort -r | head -5 | \
    awk '{printf "  [%s] %s\n", $1 " " $2, $NF}'

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "End of Report"
    echo "════════════════════════════════════════════════════════════════"

} | tee "${REPORT_FILE}"

echo ""
echo -e "${GREEN}✓ Report saved to: ${REPORT_FILE}${NC}"
echo ""
