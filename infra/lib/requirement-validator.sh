#!/usr/bin/env bash
# requirement-validator.sh - Validate that generated output meets extracted requirements
# 클러스터 cl-28e5202af0584c23 방어: 생성 결과물 검증

set -u

# Main validation function
validate_requirements() {
    local result_file="${1:?Usage: validate_requirements RESULT_FILE REQUIREMENTS_JSON}"
    local requirements_json="${2:?Usage: validate_requirements RESULT_FILE REQUIREMENTS_JSON}"
    local task_id="${3:-unknown}"

    if [[ ! -f "$result_file" ]]; then
        echo '{"status":"error","message":"Result file not found","file":"'"$result_file"'"}'
        return 1
    fi

    if [[ ! -s "$result_file" ]]; then
        echo '{"status":"error","message":"Result file is empty","file":"'"$result_file"'"}'
        return 1
    fi

    declare -a validation_errors=()
    declare -a validation_warnings=()

    # [1] Extract and validate sections from requirements
    # Check for common section indicators in result
    if echo "$requirements_json" | grep -q '"요약본"'; then
        if ! grep -qi "요약" "$result_file" 2>/dev/null; then
            validation_errors+=("missing_section:요약본")
        fi
    fi

    if echo "$requirements_json" | grep -q '"숙제"'; then
        if ! grep -qi "숙제\|homework" "$result_file" 2>/dev/null; then
            validation_errors+=("missing_section:숙제")
        fi
    fi

    if echo "$requirements_json" | grep -q '"정답지"'; then
        if ! grep -qi "정답\|answer" "$result_file" 2>/dev/null; then
            validation_errors+=("missing_section:정답지")
        fi
    fi

    if echo "$requirements_json" | grep -q '"수업교재"'; then
        if ! grep -qi "수업\|lesson\|교재" "$result_file" 2>/dev/null; then
            validation_errors+=("missing_section:수업교재")
        fi
    fi

    # [2] Validate bilingual requirement
    if echo "$requirements_json" | grep -q '"bilingual": true'; then
        local has_korean=false
        local has_english=false

        grep -q '[가-힣]' "$result_file" 2>/dev/null && has_korean=true
        grep -q '[a-zA-Z]' "$result_file" 2>/dev/null && has_english=true

        if [[ "$has_korean" != "true" || "$has_english" != "true" ]]; then
            validation_errors+=("missing_bilingual_content")
        fi
    fi

    # [3] Completeness check
    if echo "$requirements_json" | grep -q '"completeness": "full"'; then
        local result_lines=$(wc -l < "$result_file" 2>/dev/null || echo 0)
        if (( result_lines < 10 )); then
            validation_warnings+=("potentially_incomplete_content")
        fi
    fi

    # [4] File integrity check
    if [[ "$result_file" =~ \.(pdf|html|docx)$ ]]; then
        local file_size
        file_size=$(stat -f%z "$result_file" 2>/dev/null || stat -c%s "$result_file" 2>/dev/null || echo 0)
        if (( file_size < 100 )); then
            validation_errors+=("file_too_small")
        fi
    fi

    # Build validation report
    local validation_status="pass"
    [[ ${#validation_errors[@]} -gt 0 ]] && validation_status="fail"
    [[ ${#validation_warnings[@]} -gt 0 && "$validation_status" == "pass" ]] && validation_status="warn"

    # Extract requirement hash
    local req_hash
    req_hash=$(echo "$requirements_json" | grep -o '"requirement_hash": "[^"]*"' | cut -d'"' -f4 || echo "")

    printf '{
  "task_id": "%s",
  "status": "%s",
  "result_file": "%s",
  "file_size_bytes": %d,
  "file_lines": %d,
  "validation_errors": [%s],
  "validation_warnings": [%s],
  "requirement_hash": "%s",
  "timestamp": "%s"
}' \
        "$task_id" \
        "$validation_status" \
        "$result_file" \
        "$(stat -f%z "$result_file" 2>/dev/null || stat -c%s "$result_file" 2>/dev/null || echo 0)" \
        "$(wc -l < "$result_file" 2>/dev/null || echo 0)" \
        "$(printf '"%s",' "${validation_errors[@]}" | sed 's/,$//')" \
        "$(printf '"%s",' "${validation_warnings[@]}" | sed 's/,$//')" \
        "$req_hash" \
        "$(date -u +%FT%TZ)"

    [[ "$validation_status" == "fail" ]] && return 1
    return 0
}

export -f validate_requirements
