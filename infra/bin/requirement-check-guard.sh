#!/usr/bin/env bash
# requirement-check-guard.sh
# Cluster cl-28e5202af0584c23: 요청사항 추출 & 검증 가드
#
# 용도:
#   - ask-claude.sh에서 pre/post hook으로 호출
#   - 프롬프트의 요청사항 추출 → 결과물 대조 → 누락 감지
#   - 누락이 있으면 경고 발생 & 제출 차단
#
# 환경변수:
#   CHECK_REQUIREMENTS_ENABLED=1 (기본값, 활성화하려면 명시)
#   REQUIREMENTS_STRICT=1 (엄격 모드: 누락 시 exit code 1)
#
# 함수:
#   check_requirements_pre()  - 실행 전: 요청사항 추출
#   check_requirements_post() - 실행 후: 결과물 검증

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
REQUIREMENT_LEDGER="${BOT_HOME}/ledger/requirement-check.jsonl"
EXTRACTOR="${BOT_HOME}/bin/requirement-extractor.mjs"
LOG_FILE="${BOT_HOME}/logs/requirement-check-guard.log"

mkdir -p "$(dirname "$REQUIREMENT_LEDGER")" "$(dirname "$LOG_FILE")"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }

log_guard() {
    local severity="$1" message="$2" task_id="${3:-unknown}" extra="${4:-}"
    local log_msg="[$(ts)] [$severity] [$task_id] $message"
    [[ -n "$extra" ]] && log_msg="$log_msg | $extra"
    echo "$log_msg" | tee -a "$LOG_FILE" >&2
    return 0
}

log_ledger() {
    local task_id="$1" status="$2" reqs="$3" missing="${4:-}" extra="${5:-}"
    local ledger_entry="{\"ts\":\"$(date -u +%FT%TZ)\",\"task\":\"$task_id\",\"status\":\"$status\""
    [[ -n "$reqs" ]] && ledger_entry+=",\"requirements\":$reqs"
    [[ -n "$missing" ]] && ledger_entry+=",\"missing\":[$missing]"
    [[ -n "$extra" ]] && ledger_entry+=",\"extra\":\"$extra\""
    ledger_entry+="}"
    echo "$ledger_entry" >> "$REQUIREMENT_LEDGER"
}

# Pre-execution: 프롬프트에서 요청사항 추출
check_requirements_pre() {
    local task_id="${1:-unknown}"
    local prompt="${2:-}"

    # Guard: 환경변수 미설정 시 조용히 skip
    if [[ "${CHECK_REQUIREMENTS_ENABLED:-1}" != "1" ]]; then
        return 0
    fi

    # Guard: 프롬프트가 없으면 skip
    if [[ -z "$prompt" ]]; then
        log_guard "WARN" "Empty prompt, skipping requirement extraction" "$task_id"
        return 0
    fi

    # Guard: extractor 없으면 skip (선택적 통합)
    if [[ ! -f "$EXTRACTOR" ]]; then
        log_guard "WARN" "Extractor not found, requirement check disabled" "$task_id" "$EXTRACTOR"
        return 0
    fi

    # Extract
    local req_json
    if ! req_json=$(node "$EXTRACTOR" "$prompt" 2>/dev/null); then
        log_guard "WARN" "Failed to extract requirements" "$task_id"
        return 0
    fi

    # Empty result
    if [[ "$req_json" == "{}" ]]; then
        log_ledger "$task_id" "no_requirements_detected" "{}" "" ""
        return 0
    fi

    # Store in temp for post-check
    local req_cache="${BOT_HOME}/state/.req-${task_id}-$$.json"
    mkdir -p "$(dirname "$req_cache")"
    echo "$req_json" > "$req_cache"

    log_guard "INFO" "Requirements extracted" "$task_id" "fields=$(echo "$req_json" | jq 'keys | length')"
    log_ledger "$task_id" "extracted" "$req_json" "" ""

    return 0
}

# Post-execution: 결과물 검증
check_requirements_post() {
    local task_id="${1:-unknown}"
    local result_file="${2:-}"

    if [[ "${CHECK_REQUIREMENTS_ENABLED:-1}" != "1" ]]; then
        return 0
    fi

    if [[ -z "$result_file" ]] || [[ ! -f "$result_file" ]]; then
        log_guard "WARN" "Result file not provided or not found" "$task_id" "$result_file"
        return 0
    fi

    # Load cached requirements
    local req_cache="${BOT_HOME}/state/.req-${task_id}-$$.json"
    if [[ ! -f "$req_cache" ]]; then
        log_guard "DEBUG" "No requirement cache found, skipping post-check" "$task_id"
        return 0
    fi

    local requirements
    requirements=$(cat "$req_cache")
    rm -f "$req_cache"

    # 검증 로직
    local missing=()
    local result_content
    result_content=$(cat "$result_file" | tr '[:upper:]' '[:lower:]')

    # 1. format 검증 (결과 파일 확장자)
    local expected_format=""
    if expected_format=$(echo "$requirements" | jq -r '.format // empty'); then
        if [[ -n "$expected_format" ]]; then
            local file_ext="${result_file##*.}"
            file_ext="${file_ext,,}"

            # Normalize format names
            local norm_ext="$file_ext"
            case "$expected_format" in
                md|markdown) expected_format="md" ;;
                txt|text) expected_format="txt" ;;
                html) expected_format="html" ;;
                pdf) expected_format="pdf" ;;
                json) expected_format="json" ;;
            esac

            case "$norm_ext" in
                md|markdown) norm_ext="md" ;;
                txt|text) norm_ext="txt" ;;
                html) norm_ext="html" ;;
                pdf) norm_ext="pdf" ;;
                json) norm_ext="json" ;;
            esac

            if [[ "$norm_ext" != "$expected_format" ]]; then
                missing+=("format:expected=$expected_format,got=$norm_ext")
            fi
        fi
    fi

    # 2. sections 검증
    local section_list
    if section_list=$(echo "$requirements" | jq -r '.sections[]? // empty'); then
        while IFS= read -r section; do
            [[ -z "$section" ]] && continue
            local section_lower="${section,,}"
            if ! grep -qi "$section_lower" "$result_file" 2>/dev/null; then
                missing+=("section:$section")
            fi
        done <<< "$section_list"
    fi

    # 3. bilingual 검증
    if echo "$requirements" | jq -e '.bilingual' >/dev/null 2>&1; then
        # Check if both Korean and English are present
        if ! grep -qE '[가-힣]' "$result_file" 2>/dev/null; then
            missing+=("bilingual:korean_missing")
        fi
        if ! grep -qE '[a-zA-Z]' "$result_file" 2>/dev/null; then
            missing+=("bilingual:english_missing")
        fi
    fi

    # 4. scope 검증
    local expected_scope
    if expected_scope=$(echo "$requirements" | jq -r '.scope // empty'); then
        if [[ -n "$expected_scope" ]]; then
            case "$expected_scope" in
                all)
                    # Check if "전체" 또는 "all" 적용 표시가 있는지
                    if ! grep -qi "전체\|all" "$result_file" 2>/dev/null; then
                        missing+=("scope:full_application_unclear")
                    fi
                    ;;
                partial)
                    # Check for partial markers
                    if ! grep -qi "부분\|partial\|일부" "$result_file" 2>/dev/null; then
                        missing+=("scope:partial_markers_missing")
                    fi
                    ;;
            esac
        fi
    fi

    # 5. completeness_check 검증
    if echo "$requirements" | jq -e '.completeness_check' >/dev/null 2>&1; then
        # Verify there's some explicit completeness marking
        local completeness_markers=0
        completeness_markers=$(grep -c -E '✓|✅|완료|confirmed|verified|checked' "$result_file" 2>/dev/null || echo 0)
        if (( completeness_markers == 0 )); then
            missing+=("completeness:no_verification_markers")
        fi
    fi

    # Report
    local status="pass"
    local missing_str=""
    if (( ${#missing[@]} > 0 )); then
        status="fail"
        missing_str="\"$(IFS=, ; echo "${missing[*]}")\""

        log_guard "ERROR" "Requirement check FAILED" "$task_id" "missing=(${missing[*]})"

        # Show warnings
        echo "" >&2
        echo "⚠️  REQUIREMENT CHECK FAILED" >&2
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
        echo "Task: $task_id" >&2
        echo "Missing/Incomplete:" >&2
        for item in "${missing[@]}"; do
            echo "  ✗ $item" >&2
        done
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
        echo "" >&2

        # Strict mode: exit 1
        if [[ "${REQUIREMENTS_STRICT:-0}" == "1" ]]; then
            log_guard "FATAL" "Strict mode enabled, blocking submission" "$task_id"
            log_ledger "$task_id" "validation_failed_strict" "$requirements" "$missing_str" ""
            return 1
        else
            log_ledger "$task_id" "validation_failed_warn" "$requirements" "$missing_str" ""
            return 0
        fi
    else
        log_guard "INFO" "All requirements validated" "$task_id"
        log_ledger "$task_id" "validation_passed" "$requirements" "" ""
        return 0
    fi
}

# Helper: 요청사항 조회
get_requirements() {
    local task_id="$1"
    local req_cache="${BOT_HOME}/state/.req-${task_id}-$$.json"
    if [[ -f "$req_cache" ]]; then
        cat "$req_cache"
    else
        echo "{}"
    fi
}

# Helper: 검증 결과 조회
get_validation_status() {
    local task_id="$1"
    grep "\"task\":\"$task_id\"" "$REQUIREMENT_LEDGER" 2>/dev/null | tail -1 | jq '.status' 2>/dev/null || echo "unknown"
}

# Export functions
export -f check_requirements_pre
export -f check_requirements_post
export -f get_requirements
export -f get_validation_status
