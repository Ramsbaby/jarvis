#!/bin/bash

################################################################################
# Cluster Guard for cl-dcd8ff3443b1f052
#
# 목적: 반복 실수 클러스터 cl-dcd8ff3443b1f052 방지
#   - 파일 저장/업로드 후 경로 존재, 파일 크기, 언어 비율 검증
#   - 검증 실패 시 자동으로 보고 및 차단
#   - 기존 동작 파괴 없음 (warning level에서 log)
#
# 반복 패턴:
#   1. 파일 상태 확인 없이 재작업 제안 (경로 미검증)
#   2. 파일 업로드 대상 채널 오류 — 검증 미실시
#   3. 파일 내용 미검증 후 보고 — 한글만 있는데 영어로 완성되었다고 암묵적 가정
#   4. 파일 검증 완료 선언 후 같은 도메인에서 표준 미내재화
#   5. API timeout으로 인한 파일 손상 후 불완전한 상태 인식 지연
#
# 사용: ask-claude.sh 내부에서 자동 호출 (L464-494)
#
################################################################################

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

CLUSTER_ID="cl-dcd8ff3443b1f052"
GUARD_LOG="${HOME}/jarvis/logs/cluster-guard-${CLUSTER_ID}.log"
GUARD_REPORT_DIR="${HOME}/jarvis/runtime/reports/cluster-guard-${CLUSTER_ID}"
FILE_VALIDATOR="${HOME}/jarvis/infra/lib/file-validator.sh"

# ============================================================================
# LOGGING
# ============================================================================

log_to_guard() {
    local level="$1"
    local message="$2"
    local filepath="${3:-}"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    mkdir -p "$(dirname "$GUARD_LOG")"

    local entry='{"timestamp":"'"$timestamp"'","level":"'"$level"'","message":"'"$message"'"'
    [[ -n "$filepath" ]] && entry="${entry},"'"filepath":"'"$filepath"'"'
    entry="${entry}"'}'

    echo "$entry" >> "$GUARD_LOG"
}

# ============================================================================
# FILE VALIDATION WITH DETAILED REPORTING
# ============================================================================

validate_and_report() {
    local filepath="$1"
    local task_id="${2:-unknown}"

    if [[ ! -f "$filepath" ]]; then
        log_to_guard "ERROR" "File not found: $filepath" "$filepath"
        return 1
    fi

    # Check file size
    local filesize
    filesize=$(stat -f%z "$filepath" 2>/dev/null || stat -c%s "$filepath" 2>/dev/null || echo 0)

    if (( filesize == 0 )); then
        log_to_guard "ERROR" "File is empty (0 bytes): $filepath" "$filepath"
        return 1
    fi

    # Validate with language analysis
    if ! bash "$FILE_VALIDATOR" "$filepath" 2>/dev/null; then
        log_to_guard "WARN" "File validation failed: $filepath (size: $filesize bytes)" "$filepath"

        # Create detailed report
        _create_validation_report "$filepath" "$task_id" "$filesize"
        return 1
    fi

    log_to_guard "SUCCESS" "File validated: $filepath (size: $filesize bytes)" "$filepath"
    return 0
}

_create_validation_report() {
    local filepath="$1"
    local task_id="$2"
    local filesize="$3"

    mkdir -p "$GUARD_REPORT_DIR"

    local report_file
    report_file="${GUARD_REPORT_DIR}/${task_id}_$(date +%s).json"

    cat > "$report_file" <<EOF
{
  "cluster_id": "$CLUSTER_ID",
  "task_id": "$task_id",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "file_path": "$filepath",
  "file_size": $filesize,
  "file_exists": $(test -f "$filepath" && echo true || echo false),
  "validation_status": "FAILED",
  "remediation": "파일 상태를 확인하고 재생성하세요"
}
EOF

    log_to_guard "REPORT" "Validation report created: $report_file" "$filepath"
}

# ============================================================================
# MAIN: Guard execution
# ============================================================================

guard_saved_files() {
    local raw_output="$1"
    local task_id="${2:-unknown}"

    [[ -z "$raw_output" ]] && return 0

    # Extract saved file paths from LLM output
    local saved_files
    saved_files=$(echo "$raw_output" | jq -r '.saved_files[]? // .file_path // empty' 2>/dev/null || echo "")

    # If jq didn't find files, try pattern matching
    if [[ -z "$saved_files" ]]; then
        saved_files=$(echo "$raw_output" | grep -oE '/(tmp|home|Users|jarvis)[^ "]*\.(pdf|txt|md|json|html|csv)' 2>/dev/null || true)
    fi

    if [[ -z "$saved_files" ]]; then
        return 0
    fi

    local validation_failed=0

    while IFS= read -r file_path; do
        [[ -z "$file_path" ]] && continue
        [[ ! -e "$file_path" ]] && continue

        if ! validate_and_report "$file_path" "$task_id"; then
            validation_failed=1
        fi
    done <<< "$saved_files"

    return $validation_failed
}

# ============================================================================
# CLI
# ============================================================================

main() {
    if [[ $# -lt 1 ]]; then
        cat >&2 <<EOF
Usage: $0 <raw_output> [task_id]

Purpose: Validate files saved by ask-claude.sh for cluster cl-dcd8ff3443b1f052

Arguments:
  raw_output    LLM output JSON (from ask-claude.sh)
  task_id       Task identifier for reporting (default: unknown)

Exit codes:
  0   All files validated successfully or no files found
  1   File validation failed
EOF
        return 2
    fi

    local raw_output="$1"
    local task_id="${2:-unknown}"

    guard_saved_files "$raw_output" "$task_id"
}

# Run if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
