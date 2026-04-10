#!/usr/bin/env bash
# Cross-platform compat
source "${JARVIS_HOME:-${BOT_HOME:-${HOME}/.local/share/jarvis}}/lib/compat.sh" 2>/dev/null || true
set -uo pipefail
# jarvis-auditor.sh - Autonomous code quality auditor
# set -e 없음: 감지 실패는 정상 흐름 (e2e-test.sh와 동일 패턴)
#
# Usage: jarvis-auditor.sh [--dry-run] [--incremental]
# Cron: 45 4 * * * (e2e-cron 30분 후, standup 전)

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export HOME="${HOME:-/Users/$(id -un)}"

BOT_HOME="${BOT_HOME:-${HOME}/.local/share/jarvis}"
CONFIG_DIR="$BOT_HOME/config"
STATE_DIR="$BOT_HOME/state"
RESULTS_DIR="$BOT_HOME/results/auditor"
LOG_FILE="$BOT_HOME/logs/auditor.log"
ANTI_PATTERNS="$CONFIG_DIR/anti-patterns.json"
LAST_RUN_FILE="$STATE_DIR/auditor-last-run.json"
REPORT_FILE="$RESULTS_DIR/$(date +%Y-%m-%d).md"
SCAN_DIRS=("$BOT_HOME/bin" "$BOT_HOME/scripts" "$BOT_HOME/discord" "$BOT_HOME/lib")

DRY_RUN=false
INCREMENTAL=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --incremental) INCREMENTAL=true ;;
    esac
done

COOLDOWN_HOURS=20
MAX_AUTO_FIXES=5

# 보호 파일 (자동수정 금지)
PROTECTED_FILES="discord-bot.js monitoring.json tasks.json company-dna.md autonomy-levels.md .env rag-engine.mjs rag-index.mjs effective-tasks.json calendar.json social.json system.json secrets.json"

# Counters
TOTAL_ISSUES=0
WARN_ISSUES=0  # warning 이상만 (alert 판단용)
TIER1_FIXED=0
TIER2_ESCALATED=0
SKIPPED=0
AUTO_FIX_COUNT=0
FIXED_FILES_JSON=""

mkdir -p "$RESULTS_DIR" "$STATE_DIR" "$STATE_DIR/l3-requests" "$(dirname "$LOG_FILE")"

# Cleanup stale backup files from previous crashes
find "$BOT_HOME" -name '*.auditor-bak' -mmin +120 -delete 2>/dev/null || true

# ============================================================================
# Utility
# ============================================================================

log() { echo "[$(date '+%F %T')] [auditor] $*" >> "$LOG_FILE"; }

is_protected() {
    local file="$1"
    local bn
    bn=$(basename "$file")
    for p in $PROTECTED_FILES; do
        if [[ "$bn" == "$p" ]]; then
            return 0
        fi
    done
    return 1
}

is_in_cooldown() {
    local file="$1"
    if [[ ! -f "$LAST_RUN_FILE" ]]; then
        return 1
    fi
    local last_fixed
    last_fixed=$(jq -r --arg f "$file" '.fixed_files[$f] // 0' "$LAST_RUN_FILE" 2>/dev/null || echo "0")
    if [[ "$last_fixed" == "0" || "$last_fixed" == "null" ]]; then
        return 1
    fi
    local now elapsed
    now=$(date +%s)
    elapsed=$(( now - last_fixed ))
    if [[ $elapsed -lt $(( COOLDOWN_HOURS * 3600 )) ]]; then
        return 0
    fi
    return 1
}

# Incremental: build -newer flag if applicable
NEWER_FLAG=()
if [[ "$INCREMENTAL" == true && -f "$LAST_RUN_FILE" ]]; then
    NEWER_FLAG=(-newer "$LAST_RUN_FILE")
    log "Incremental mode: scanning files newer than $LAST_RUN_FILE"
fi

# Expand brace globs (e.g., *.{js,mjs} -> *.js *.mjs)
expand_glob() {
    local glob="$1"
    if [[ "$glob" == *"{"*"}"* ]]; then
        local prefix="${glob%%\{*}"
        local rest="${glob#*\{}"
        local alts="${rest%%\}*}"
        local suffix="${rest#*\}}"
        IFS=',' read -ra parts <<< "$alts"
        for part in "${parts[@]}"; do
            echo "${prefix}${part}${suffix}"
        done
    else
        echo "$glob"
    fi
}

# Report accumulator
REPORT_BODY=""
report() {
    REPORT_BODY+="$1"$'\n'
}

# ============================================================================
# Tier 1 Auto-Fix
# ============================================================================

try_tier1_fix() {
    local file="$1"
    local fix_type="$2"
    local sed_pattern="${3:-}"

    if [[ "$DRY_RUN" == true ]]; then return 1; fi
    if [[ $AUTO_FIX_COUNT -ge $MAX_AUTO_FIXES ]]; then
        log "MAX_AUTO_FIXES ($MAX_AUTO_FIXES) reached, skipping: $file"
        return 1
    fi
    if is_protected "$file"; then
        log "Protected file, skipping: $file"
        ((SKIPPED++))
        return 1
    fi
    if is_in_cooldown "$file"; then
        log "In cooldown, skipping: $file"
        ((SKIPPED++))
        return 1
    fi

    cp "$file" "${file}.auditor-bak"
    local applied=false

    case "$fix_type" in
        shellcheck-diff)
            local diff_out
            diff_out=$(shellcheck --format=diff "$file" 2>/dev/null || true)
            if [[ -n "$diff_out" ]]; then
                # patch -p1 strips the a/ prefix from shellcheck diff output
                if echo "$diff_out" | patch -p1 --no-backup-if-mismatch -s 2>/dev/null; then
                    applied=true
                fi
            fi
            ;;
        sed)
            if [[ -n "$sed_pattern" ]]; then
                local sed_ok=false
                if ${IS_MACOS:-false}; then
                    sed -i '' "$sed_pattern" "$file" 2>/dev/null && sed_ok=true
                else
                    sed -i "$sed_pattern" "$file" 2>/dev/null && sed_ok=true
                fi
                if [[ "$sed_ok" == true ]]; then
                    applied=true
                fi
            fi
            ;;
    esac

    if [[ "$applied" == true ]]; then
        # Verify: file must have changed AND pass syntax check
        if diff -q "$file" "${file}.auditor-bak" &>/dev/null; then
            # No actual change
            rm -f "${file}.auditor-bak"
            return 1
        fi
        local ext="${file##*.}"
        local verify_ok=true
        case "$ext" in
            sh|bash) bash -n "$file" 2>/dev/null || verify_ok=false ;;
            js|mjs)  node --check "$file" 2>/dev/null || verify_ok=false ;;
        esac
        if [[ "$verify_ok" == true ]]; then
            rm -f "${file}.auditor-bak"
            ((AUTO_FIX_COUNT++))
            ((TIER1_FIXED++))
            local rel="${file#"$BOT_HOME"/}"
            FIXED_FILES_JSON="${FIXED_FILES_JSON},\"${rel}\":$(date +%s)"
            log "Tier 1 fixed ($fix_type): $rel"
            report "  - **AUTO-FIXED**: \`$rel\`"
            return 0
        fi
    fi

    # Restore on any failure
    mv "${file}.auditor-bak" "$file"
    return 1
}

# Create L3 request (with idempotency: skip if same category exists within 24h)
create_l3_request() {
    local category="$1"
    local description="$2"
    local fix_hint="${3:-manual}"
    local extra_json="${4:-}"

    if [[ "$DRY_RUN" == true ]]; then return; fi

    # Idempotency: skip if same category request created within last 24h
    local existing
    existing=$(find "$STATE_DIR/l3-requests" -name "auditor-${category}-*" -mmin -1440 2>/dev/null | head -1)
    if [[ -n "$existing" ]]; then
        log "L3 request already exists for $category ($(basename "$existing")), skipping"
        return
    fi

    local ts
    ts=$(date +%s)
    cat > "$STATE_DIR/l3-requests/auditor-${category}-${ts}.json" <<EOJSON
{
  "type": "auditor-fix",
  "category": "$category",
  "description": "$description",
  "fix_hint": "$fix_hint",
  "action": "l3-action",
  "created": $ts${extra_json:+,
  $extra_json}
}
EOJSON
    ((TIER2_ESCALATED++))
}

# Enqueue an issue to tasks.db via task-store.mjs enqueue CLI
# jarvis-coder.sh는 tasks.db를 소비하므로 dev-queue.json 방식은 사용하지 않음
enqueue_to_devqueue() {
    local title="$1"
    local priority="${2:-medium}"
    local context="${3:-}"

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY-RUN enqueue: $title (priority=$priority)"
        return 0
    fi

    # ID: title을 slug화 (중복 방지용)
    local slug
    slug="code-fix-$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40 | sed 's/-*$//')-$(date +%s)"

    local prompt_text="다음 Jarvis 코드 이슈를 분석하고 수정하라.

문제: ${title}
상세: ${context}

수정 시 기존 동작 파괴 금지. 수정 후 Discord #jarvis-system에 결과 보고."

    local result
    result=$(node "${BOT_HOME}/lib/task-store.mjs" enqueue \
        --id "$slug" \
        --title "$title" \
        --prompt "$prompt_text" \
        --priority "$priority" \
        --source "jarvis-auditor" \
        --type "code-fix" 2>/dev/null) || { log "WARN: dev-queue 적재 실패 (non-fatal)"; return 0; }

    local action
    action=$(echo "$result" | node -e "const d=require('fs').readFileSync(0,'utf8'); try{console.log(JSON.parse(d).action)}catch{console.log('?')}" 2>/dev/null || echo "?")
    if [[ "$action" == "skip" ]]; then
        log "SKIP enqueue (already pending): $title"
    else
        log "ENQUEUED to tasks.db: $title (priority=$priority, id=$slug)"
    fi
}

# ============================================================================
# Audit Functions
# ============================================================================

# 1. ShellCheck audit
run_shellcheck_audit() {
    log "Starting shellcheck audit"
    report "### ShellCheck"
    report ""

    if ! command -v shellcheck &>/dev/null; then
        report "- SKIP: shellcheck not installed"
        log "shellcheck not found, skipping"
        return
    fi

    local found=0
    while IFS= read -r -d '' sh_file; do
        local result
        result=$(shellcheck --format=json "$sh_file" 2>/dev/null || true)
        if [[ -z "$result" || "$result" == "[]" ]]; then
            continue
        fi

        local count high_count
        count=$(echo "$result" | jq 'length')
        if [[ "$count" -gt 0 ]]; then
            local warn_count
            warn_count=$(echo "$result" | jq '[.[] | select(.level == "error" or .level == "warning")] | length')
            high_count=$(echo "$result" | jq '[.[] | select(.level == "error" or .code == 2086 or .code == 2046)] | length')
            local rel_path="${sh_file#"$BOT_HOME"/}"
            report "- \`$rel_path\`: $count issues (${high_count} high-priority)"
            found=$(( found + count ))
            ((TOTAL_ISSUES += count))
            ((WARN_ISSUES += warn_count))

            # Tier 1: try auto-fix for quoting issues
            if [[ $high_count -gt 0 ]]; then
                try_tier1_fix "$sh_file" "shellcheck-diff" || true
            fi
        fi
    done < <(find "${SCAN_DIRS[@]}" -not -path '*/node_modules/*' -name '*.sh' -type f "${NEWER_FLAG[@]+"${NEWER_FLAG[@]}"}" -print0 2>/dev/null)

    if [[ $found -eq 0 ]]; then
        report "- OK: No shellcheck issues"
    fi
    report ""
}

# 2. Node syntax audit (fixed: find operator precedence with parentheses)
run_node_syntax_audit() {
    log "Starting node syntax audit"
    report "### Node.js Syntax"
    report ""

    local found=0
    while IFS= read -r -d '' js_file; do
        if ! node --check "$js_file" 2>/dev/null; then
            local rel_path="${js_file#"$BOT_HOME"/}"
            report "- FAIL: \`$rel_path\` — syntax error"
            found=$(( found + 1 ))
            ((TOTAL_ISSUES++))
            ((WARN_ISSUES++))

            create_l3_request "node-syntax" "Node.js syntax error in $rel_path" "manual" \
                "\"file\": \"$rel_path\""
            enqueue_to_devqueue "코드 이상: $rel_path — Node.js 문법 오류" "high" "node --check 실패: $rel_path"
        fi
    done < <(find "$BOT_HOME/discord" "$BOT_HOME/lib" "$BOT_HOME/bin" \
        -not -path '*/node_modules/*' \
        \( -name '*.js' -o -name '*.mjs' \) -type f "${NEWER_FLAG[@]+"${NEWER_FLAG[@]}"}" -print0 2>/dev/null)

    if [[ $found -eq 0 ]]; then
        report "- OK: All JS/MJS files pass syntax check"
    fi
    report ""
}

# 3. Anti-pattern audit (optimized: batch jq, brace expansion, context check)
run_antipattern_audit() {
    log "Starting anti-pattern audit"
    report "### Anti-Patterns"
    report ""

    if [[ ! -f "$ANTI_PATTERNS" ]]; then
        report "- SKIP: anti-patterns.json not found"
        return
    fi

    # Parse all non-shellcheck patterns at once (1 jq call instead of N*8)
    local patterns_json
    patterns_json=$(jq -c '.patterns[] | select(.tool != "shellcheck")' "$ANTI_PATTERNS" 2>/dev/null) || {
        report "- SKIP: Failed to parse anti-patterns.json"
        return
    }

    local antipattern_found=0

    while IFS= read -r pjson; do
        if [[ -z "$pjson" ]]; then continue; fi

        # Parse all scalar fields in 1 jq call using SOH delimiter
        local fields
        fields=$(echo "$pjson" | jq -r '[.id, (.tier|tostring), .severity, .grep_pattern, .file_glob, (.sed_fix // ""), (.description // ""), (.fix_hint // ""), (.context_check // ""), (.auto_fix_script // "")] | join("\u0001")')
        local id tier severity grep_pattern file_glob sed_fix description fix_hint context_check auto_fix_script
        IFS=$'\x01' read -r id tier severity grep_pattern file_glob sed_fix description fix_hint context_check auto_fix_script <<< "$fields"

        # Parse exclude_lines (1 more jq call per pattern)
        local -a exclude_arr=()
        while IFS= read -r excl; do
            if [[ -n "$excl" ]]; then exclude_arr+=("$excl"); fi
        done < <(echo "$pjson" | jq -r '.exclude_lines[]? // empty' 2>/dev/null)

        # Expand brace globs for grep --include (*.{js,mjs} -> --include=*.js --include=*.mjs)
        local -a glob_args=()
        while IFS= read -r g; do
            glob_args+=(--include="$g")
        done < <(expand_glob "$file_glob")

        local matches=""
        for dir in "${SCAN_DIRS[@]}"; do
            [[ -d "$dir" ]] || continue
            local result
            result=$(grep -rnE --exclude-dir=node_modules "$grep_pattern" "${glob_args[@]}" "$dir" 2>/dev/null || true)
            if [[ -n "$result" ]]; then
                # Apply exclude_lines filter
                local filtered="$result"
                for excl in "${exclude_arr[@]}"; do
                    filtered=$(echo "$filtered" | grep -v "^[^:]*:[0-9]*:[[:space:]]*${excl}" || true)
                done

                # Context check: only flag in files containing a specific pattern
                # e.g., set-e-and-cmd only matters in files with set -e
                if [[ -n "$context_check" && -n "$filtered" ]]; then
                    local ctx_filtered=""
                    local prev_file=""
                    local file_has_context=false
                    while IFS= read -r match_line; do
                        if [[ -z "$match_line" ]]; then continue; fi
                        local match_file="${match_line%%:*}"
                        if [[ "$match_file" != "$prev_file" ]]; then
                            prev_file="$match_file"
                            if grep -qE "$context_check" "$match_file" 2>/dev/null; then
                                file_has_context=true
                            else
                                file_has_context=false
                            fi
                        fi
                        if [[ "$file_has_context" == true ]]; then
                            ctx_filtered+="$match_line"$'\n'
                        fi
                    done <<< "$filtered"
                    filtered="$ctx_filtered"
                fi

                if [[ -n "$filtered" ]]; then
                    matches+="$filtered"
                fi
            fi
        done

        if [[ -n "$matches" ]]; then
            local match_count
            match_count=$(echo "$matches" | grep -c . || true)
            report "#### [$id] (tier $tier, $severity)"
            report ""

            local shown=0
            local pattern_found=0
            while IFS= read -r line; do
                if [[ -z "$line" ]]; then continue; fi
                local rel_line="${line#"$BOT_HOME"/}"
                report "- \`$rel_line\`"
                pattern_found=$(( pattern_found + 1 ))
                shown=$(( shown + 1 ))
                if [[ $shown -ge 10 ]]; then
                    local remaining=$(( match_count - 10 ))
                    if [[ $remaining -gt 0 ]]; then
                        report "- ... and $remaining more"
                    fi
                    break
                fi
            done <<< "$matches"
            report ""

            ((TOTAL_ISSUES += pattern_found))
            ((antipattern_found += pattern_found))
            if [[ "$severity" != "low" ]]; then
                ((WARN_ISSUES += pattern_found))
            fi

            # Tier 1: try auto-fix with sed_fix
            if [[ "$tier" == "1" && -n "$sed_fix" ]]; then
                # Collect unique files for fixing
                local -a fix_files=()
                while IFS= read -r line; do
                    if [[ -z "$line" ]]; then continue; fi
                    local f="${line%%:*}"
                    local already=false
                    for existing in "${fix_files[@]+"${fix_files[@]}"}"; do
                        if [[ "$existing" == "$f" ]]; then
                            already=true
                            break
                        fi
                    done
                    if [[ "$already" == false ]]; then
                        fix_files+=("$f")
                    fi
                done <<< "$matches"
                for f in "${fix_files[@]+"${fix_files[@]}"}"; do
                    try_tier1_fix "$f" "sed" "$sed_fix" || true
                done
            fi

            # Tier 1: try per-line fix via auto_fix_script (e.g. set-e-and-cmd)
            if [[ "$tier" == "1" && -n "$auto_fix_script" && "$DRY_RUN" == false ]]; then
                local script_path="$BOT_HOME/$auto_fix_script"
                if [[ -x "$script_path" ]]; then
                    while IFS= read -r mline; do
                        if [[ -z "$mline" ]]; then continue; fi
                        local mfile="${mline%%:*}"
                        local mnum="${mline#*:}"; mnum="${mnum%%:*}"
                        if ! [[ "$mnum" =~ ^[0-9]+$ ]]; then continue; fi
                        if is_protected "$mfile"; then continue; fi
                        if is_in_cooldown "$mfile"; then continue; fi
                        if [[ $AUTO_FIX_COUNT -ge $MAX_AUTO_FIXES ]]; then break; fi
                        local mrel="${mfile#"$BOT_HOME"/}"
                        if BOT_HOME="$BOT_HOME" IS_MACOS="$IS_MACOS" \
                           bash "$script_path" "$mfile" "$mnum" >>"$LOG_FILE" 2>&1; then
                            ((AUTO_FIX_COUNT++)) || true
                            ((TIER1_FIXED++)) || true
                            FIXED_FILES_JSON="${FIXED_FILES_JSON},\"${mrel}\":$(date +%s)"
                            report "  - **AUTO-FIXED**: \`${mrel}\` L${mnum}"
                            log "auto_fix_script fixed: $mrel L$mnum"
                        else
                            log "WARN: auto_fix_script failed: $mrel L$mnum"
                        fi
                    done <<< "$matches"
                else
                    log "WARN: auto_fix_script not executable: $script_path"
                fi
            fi

            # Tier 2: escalate
            if [[ "$tier" == "2" && "$DRY_RUN" == false ]]; then
                create_l3_request "$id" "$description ($pattern_found matches)" "$fix_hint" \
                    "\"match_count\": $pattern_found"
            fi
        fi
    done <<< "$patterns_json"

    if [[ $antipattern_found -eq 0 ]]; then
        report "- OK: No anti-patterns detected"
    fi
    report ""
}

# 4. LaunchAgent audit (with race condition protection)
run_launchagent_audit() {
    $IS_MACOS || { report "### LaunchAgent Status"; report ""; report "- SKIP: non-macOS"; report ""; return 0; }
    log "Starting LaunchAgent audit"
    report "### LaunchAgent Status"
    report ""

    local services=("ai.jarvis.discord-bot" "ai.jarvis.watchdog" )
    local uid
    uid=$(id -u)
    local found=0

    for svc in "${services[@]}"; do
        # Retry mechanism for race condition protection
        local print_success=false
        local retry_count=0
        while [[ $retry_count -lt 3 ]]; do
            if launchctl print "gui/${uid}/${svc}" &>/dev/null; then
                print_success=true
                break
            fi
            sleep 0.5
            ((retry_count++))
        done

        if [[ "$print_success" == false ]]; then
            report "- WARN: \`$svc\` not loaded (after 3 retries)"
            found=$(( found + 1 ))
            ((TOTAL_ISSUES++))
            ((WARN_ISSUES++))
            enqueue_to_devqueue "LaunchAgent 미로드: $svc" "high" "launchctl print gui/${uid}/${svc} 3회 재시도 후 실패 — 서비스 미등록 또는 크래시"
        else
            local pid
            pid=$(launchctl list "$svc" 2>/dev/null | awk 'NR==2{print $1}' || echo "-")
            if [[ "$pid" == "-" || -z "$pid" ]]; then
                report "- WARN: \`$svc\` loaded but no PID"
                found=$(( found + 1 ))
                ((TOTAL_ISSUES++))
                ((WARN_ISSUES++))
                enqueue_to_devqueue "LaunchAgent PID 없음: $svc" "medium" "launchctl list 결과 PID 없음 — 서비스 중단 가능성"
            fi
        fi
    done

    if [[ $found -eq 0 ]]; then
        report "- OK: All LaunchAgents running"
    fi
    report ""
}

# 5. Health freshness audit (threshold adjusted for */31 cron interval)
run_health_freshness_audit() {
    log "Starting health freshness audit"
    report "### Health Freshness"
    report ""

    local health_file="$STATE_DIR/health.json"
    if [[ ! -f "$health_file" ]]; then
        report "- WARN: health.json not found"
        ((TOTAL_ISSUES++))
        ((WARN_ISSUES++))
        report ""
        return
    fi

    local last_check
    last_check=$(jq -r '.last_check // .timestamp // 0' "$health_file" 2>/dev/null || echo "0")

    if [[ "$last_check" == "0" || "$last_check" == "null" ]]; then
        report "- WARN: No last_check timestamp in health.json"
        ((TOTAL_ISSUES++))
    else
        local now
        now=$(date +%s)
        # system-health runs at */31 intervals -> threshold must exceed that
        local stale_threshold=2400  # 40 minutes (> 31min cron + execution time)

        local check_epoch
        if [[ "$last_check" =~ ^[0-9]+$ ]]; then
            check_epoch="$last_check"
        else
            # Strip trailing Z (UTC marker) and milliseconds before parsing
            # Must use TZ=UTC since watchdog.sh writes timestamps with date -u
            local ts_clean="${last_check%Z}"
            ts_clean="${ts_clean%%.*}"
            check_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$ts_clean" +%s 2>/dev/null \
                || TZ=UTC date -d "$ts_clean" +%s 2>/dev/null \
                || echo "0")
        fi

        local age=$(( now - check_epoch ))
        if [[ $age -gt $stale_threshold ]]; then
            report "- WARN: health.json stale ($(( age / 60 ))m old, threshold $(( stale_threshold / 60 ))m)"
            ((TOTAL_ISSUES++))
            ((WARN_ISSUES++))
            enqueue_to_devqueue "헬스체크 STALE: health.json $(( age / 60 ))분 미갱신" "medium" "system-health 크론 미실행 또는 실패 의심 — stale threshold $(( stale_threshold / 60 ))m 초과"
        else
            report "- OK: health.json fresh ($(( age / 60 ))m ago)"
        fi
    fi
    report ""
}

# 6. E2E audit (reads result files directly, not log)
run_e2e_audit() {
    log "Starting e2e audit"
    report "### E2E Test Results"
    report ""

    # Use result file (more reliable than parsing log)
    local today_result
    today_result="$BOT_HOME/results/e2e-health/$(date +%F).txt"
    local result_file=""

    if [[ -f "$today_result" ]]; then
        result_file="$today_result"
    else
        # Fallback: most recent result file
        result_file=$(find "$BOT_HOME/results/e2e-health" -name '*.txt' -type f 2>/dev/null | sort -r | head -1)
    fi

    if [[ -z "$result_file" || ! -f "$result_file" ]]; then
        report "- SKIP: No e2e result files found"
        report ""
        return
    fi

    local fails
    fails=$(grep "FAIL" "$result_file" 2>/dev/null | grep -v "^#" || true)

    if [[ -n "$fails" ]]; then
        local fail_count
        fail_count=$(echo "$fails" | grep -c . || true)
        local result_date
        result_date=$(basename "$result_file" .txt)
        report "- $fail_count FAIL items (from $result_date):"
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                report "  - $line"
            fi
        done <<< "$fails"
        ((TOTAL_ISSUES += fail_count))
        ((WARN_ISSUES += fail_count))
        enqueue_to_devqueue "E2E 테스트 실패: $fail_count건 ($result_date)" "high" "e2e-health 결과 파일에서 FAIL 항목 $fail_count건 감지"
    else
        report "- OK: No e2e failures detected"
    fi
    report ""
}

# ============================================================================
# Main
# ============================================================================

log "=== Auditor run started (dry_run=$DRY_RUN, incremental=$INCREMENTAL) ==="

# Build report header
report "# Jarvis Auditor Report"
report ""
report "**Date**: $(date '+%Y-%m-%d %H:%M:%S')"
if [[ "$DRY_RUN" == true ]]; then
    report "**Mode**: Dry Run"
elif [[ "$INCREMENTAL" == true ]]; then
    report "**Mode**: Incremental"
else
    report "**Mode**: Full"
fi
report ""
report "---"
report ""
report "## Audit Results"
report ""

# Run all audits
run_shellcheck_audit
run_node_syntax_audit
run_antipattern_audit
run_launchagent_audit
run_health_freshness_audit
run_e2e_audit

# Summary
report "---"
report ""
report "## Summary"
report ""
report "| Metric | Count |"
report "|--------|-------|"
report "| Total issues | $TOTAL_ISSUES |"
report "| Tier 1 auto-fixed | $TIER1_FIXED |"
report "| Tier 2 escalated | $TIER2_ESCALATED |"
report "| Skipped | $SKIPPED |"
report ""

# Write report
echo "$REPORT_BODY" > "$REPORT_FILE"
log "Report written to $REPORT_FILE"

# Write state (with fixed_files for cooldown tracking)
cat > "$LAST_RUN_FILE" <<EOJSON
{
  "timestamp": $(date +%s),
  "date": "$(date '+%F %T')",
  "total_issues": $TOTAL_ISSUES,
  "tier1_fixed": $TIER1_FIXED,
  "tier2_escalated": $TIER2_ESCALATED,
  "skipped": $SKIPPED,
  "dry_run": $DRY_RUN,
  "incremental": $INCREMENTAL,
  "fixed_files": {${FIXED_FILES_JSON#,}}
}
EOJSON

# Tier 1 수정분 자동 커밋 — auditor가 직접 수정한 파일만 스테이징 (git add -A 금지)
if [[ $TIER1_FIXED -gt 0 && "$DRY_RUN" == false ]]; then
    # FIXED_FILES_JSON에서 실제 수정된 파일 경로만 추출해 개별 add
    STAGED_COUNT=0
    if [[ -n "$FIXED_FILES_JSON" ]]; then
        while IFS= read -r rel_path; do
            [[ -z "$rel_path" ]] && continue
            git -C "$BOT_HOME" add -- "$BOT_HOME/$rel_path" 2>/dev/null && ((STAGED_COUNT++)) || true
        done < <(echo "{${FIXED_FILES_JSON#,}}" | jq -r 'keys[]' 2>/dev/null)
    fi
    if [[ $STAGED_COUNT -gt 0 ]]; then
        git -C "$BOT_HOME" commit -m "fix(auditor): auto-fix ${TIER1_FIXED} anti-pattern(s) [T1]" \
            >>"$LOG_FILE" 2>&1 || log "WARN: git commit failed (non-fatal)"
        log "Committed $STAGED_COUNT auditor-fixed file(s) (targeted add, not add -A)"
    else
        log "WARN: TIER1_FIXED=$TIER1_FIXED but no files staged — FIXED_FILES_JSON may be empty"
    fi
fi

# Discord notification
if [[ "$DRY_RUN" == false ]]; then
    local_summary="[Auditor] $(date +%F): $TOTAL_ISSUES issues (T1:$TIER1_FIXED fixed, T2:$TIER2_ESCALATED escalated)"

    # T1(자동수정) 또는 T2(에스컬레이션)가 있을 때만 Discord 알림.
    # WARN_ISSUES만 있고 T1/T2가 0인 경우(ShellCheck 스타일 경고 등)는 묵음 — 노이즈 방지.
    if [[ $TIER1_FIXED -gt 0 || $TIER2_ESCALATED -gt 0 ]]; then
        "$BOT_HOME/bin/route-result.sh" discord "code-auditor" "$local_summary" "jarvis-system" 2>/dev/null || true
        "$BOT_HOME/scripts/alert.sh" warning "Auditor Alert" "[Auditor] T1:$TIER1_FIXED fixed, T2:$TIER2_ESCALATED escalated — review $REPORT_FILE" 2>/dev/null || true
    fi
fi

log "=== Auditor run completed: $TOTAL_ISSUES issues (T1:$TIER1_FIXED, T2:$TIER2_ESCALATED) ==="

echo "[auditor] $TOTAL_ISSUES issues found (T1:$TIER1_FIXED fixed, T2:$TIER2_ESCALATED escalated). Report: $REPORT_FILE"
exit 0
