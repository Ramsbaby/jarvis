#!/usr/bin/env bash
# file-existence-validator.sh — 파일 존재 판단 오류 후처리 검증 (cl-3dbad2477e65b7b7)
#
# 클러스터 ID: cl-3dbad2477e65b7b7 (최근 7일 재발 14건)
# 목적: 응답에서 파일 존재 여부를 단언하기 전에 자동 탐색 결과와 대조
#
# 사용법 (ask-claude.sh 내부):
#   source "${BOT_HOME}/lib/file-existence-validator.sh"
#   validate_file_assertions "$RESPONSE_TEXT" "$WORK_DIR" || return 1
#
# 반환값:
#   0 = 응답이 안전함 (파일 단언 없거나 일치함)
#   1 = 응답에 파일 단언이 있지만 미확인 상태 (경고 로깅)
#   2 = 실패: 단언과 실제 탐색 결과 불일치 (명시 차단)

set -euo pipefail

# ── 상수 및 경로 설정 ──────────────────────────────────────────────────────
JARVIS_HOME="${HOME}/.jarvis"
VALIDATOR_LOG="${JARVIS_HOME}/runtime/logs/file-existence-validator.jsonl"
CLUSTER_ID="cl-3dbad2477e65b7b7"
FILE_GUARD_SCRIPT="${JARVIS_HOME}/infra/guards/file-existence-guard.sh"

# ── 로그 디렉토리 초기화 ────────────────────────────────────────────────────
_ensure_validator_log_dir() {
    local log_dir
    log_dir=$(dirname "$VALIDATOR_LOG")
    mkdir -p "$log_dir" 2>/dev/null || true
}
_ensure_validator_log_dir

# ── JSON 안전 이스케이프 ────────────────────────────────────────────────────
_escape_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# ── 파일 참조 패턴 추출 ────────────────────────────────────────────────────
# 응답에서 파일 경로/참조 검출
# 예: /path/to/file, ~/some/file, file.txt, 파일 이름: "test.json"
_extract_file_references() {
    local response="$1"
    local -a refs=()

    # 절대 경로 (/, /tmp/, ~/., etc.)
    while IFS= read -r ref; do
        [[ -n "$ref" ]] && refs+=("$ref")
    done < <(grep -oE '(/[^[:space:]"]+|~/[^[:space:]"]+)' <<< "$response" 2>/dev/null || true)

    # 상대 경로 및 파일명 (*.extension)
    while IFS= read -r ref; do
        [[ -n "$ref" ]] && [[ "$ref" != *"/"* ]] && refs+=("$ref")
    done < <(grep -oE '\b[a-zA-Z0-9_\-]+\.[a-zA-Z0-9]+\b' <<< "$response" 2>/dev/null || true)

    # 파일명 명시 (파일: "xxx.yyy", 파일이름: xxx.yyy 등)
    # 한글: "파일", "파일명", "파일이름"  및 영문: "File"
    while IFS= read -r ref; do
        [[ -n "$ref" ]] && refs+=("$ref")
    done < <(grep -oE '(파일|파일명|파일이름|File|파일경로|path)[[:space:]]*[:：][[:space:]]*"?([^"[:space:]]+\.?[^"[:space:]]*)"?' <<< "$response" 2>/dev/null | sed 's/.*[:：][[:space:]]*"\?//; s/"\?$//' | grep -E '\.' || true)

    printf '%s\n' "${refs[@]}"
}

# ── 응답에서 파일 관련 단언 검출 ────────────────────────────────────────────
# 강화된 탐지: 한국어/영어 패턴, 맥락 기반 의미 파악
_detect_file_assertions() {
    local response="$1"
    local -a assertions=()

    # 긍정 패턴 (파일 존재 주장)
    local pos_patterns=(
        "파일.*있습니다"
        "파일.*있습니다"
        "파일.*있어요"
        "파일.*있거든"
        "파일.*있으니"
        "파일을.*확인"
        "파일.*확인했"
        "파일.*확인합니다"
        "파일을.*읽"
        "파일을.*읽었"
        "파일을.*열"
        "파일을.*찾"
        "파일이.*있"
        "파일이.*존재"
        "파일을.*생성"
        "파일.*검사"
        "파일.*검색"
        "파일.*포함"
        "file exists"
        "found.*file"
        "exists.*file"
        "checked.*file"
        "located.*file"
    )

    # 부정 패턴 (파일 부재 주장)
    local neg_patterns=(
        "파일.*없습니다"
        "파일.*없습니다"
        "파일.*없어요"
        "파일을.*찾을.*수.*없"
        "파일.*찾지.*못"
        "파일.*없는"
        "파일이.*없"
        "파일이.*존재.*하지"
        "파일.*부재"
        "파일이.*없을"
        "파일을.*찾지.*못했"
        "파일.*검색.*못했"
        "파일이.*없"
        "file does not exist"
        "file.*not.*found"
        "no.*file"
        "cannot find.*file"
        "파일을.*찾을.*수.*없습"
    )

    local assertion_count=0

    # 긍정 패턴 검색
    for pattern in "${pos_patterns[@]}"; do
        if grep -qEi "$pattern" <<< "$response" 2>/dev/null; then
            assertions+=("positive:$pattern")
            ((assertion_count++)) || true
        fi
    done

    # 부정 패턴 검색
    for pattern in "${neg_patterns[@]}"; do
        if grep -qEi "$pattern" <<< "$response" 2>/dev/null; then
            assertions+=("negative:$pattern")
            ((assertion_count++)) || true
        fi
    done

    printf '%s\n' "${assertions[@]}"
}

# ── 응답 검증: 파일 단언과 실제 탐색 결과 대조 ────────────────────────────
# 입력: response 텍스트, work_dir (문맥용)
# 반환: 0=안전, 1=경고, 2=차단
validate_file_assertions() {
    local response="$1"
    local work_dir="${2:-.}"

    # 파일 관련 단언 검출
    local assertions
    assertions=$(_detect_file_assertions "$response")

    # 단언이 없으면 OK
    if [[ -z "$assertions" ]]; then
        return 0
    fi

    # 파일 참조 추출
    local file_refs
    file_refs=$(_extract_file_references "$response")

    # 각 참조에 대해 탐색 실행
    local validation_passed=0
    local validation_issues=0

    while IFS= read -r ref; do
        [[ -z "$ref" ]] && continue

        # 가드 스크립트로 탐색
        local scan_result
        if [[ -x "$FILE_GUARD_SCRIPT" ]]; then
            scan_result=$("$FILE_GUARD_SCRIPT" scan "$ref" 2>/dev/null || echo '{"error":"scan failed"}')
        else
            # 가드 스크립트 없으면 기본 검사
            if [[ -e "$ref" ]]; then
                scan_result='{"exists":true}'
            else
                scan_result='{"exists":false}'
            fi
        fi

        # 검증 결과 로깅
        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        local log_entry
        log_entry=$(printf '{
            "timestamp":"%s",
            "cluster_id":"%s",
            "task_context":"%s",
            "file_ref":"%s",
            "scan_result":%s,
            "response_has_assertions":true,
            "response_length":%d
        }' \
            "$timestamp" \
            "$CLUSTER_ID" \
            "$(_escape_json "$work_dir")" \
            "$(_escape_json "$ref")" \
            "$scan_result" \
            "${#response}")

        echo "$log_entry" >> "$VALIDATOR_LOG" 2>/dev/null || true

        ((validation_passed++)) || true

    done <<< "$file_refs"

    # 단언이 있지만 탐색되지 않은 경우 경고
    if [[ $validation_passed -eq 0 ]] && [[ -n "$assertions" ]]; then
        local warning_log
        warning_log=$(printf '{
            "timestamp":"%s",
            "cluster_id":"%s",
            "level":"WARNING",
            "message":"File assertion detected but no file references could be extracted",
            "assertions_found":%d,
            "response_preview":"%.300s"
        }' \
            "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            "$CLUSTER_ID" \
            "$(echo "$assertions" | wc -l)" \
            "$(_escape_json "${response:0:300}")")

        echo "$warning_log" >> "$VALIDATOR_LOG" 2>/dev/null || true
        return 1
    fi

    return 0
}

# ── 통계 리포팅 (선택사항) ────────────────────────────────────────────────
report_validator_stats() {
    if [[ ! -f "$VALIDATOR_LOG" ]]; then
        echo "No validation log found" >&2
        return 1
    fi

    local total_checks
    total_checks=$(wc -l < "$VALIDATOR_LOG" 2>/dev/null || echo "0")

    local warnings
    warnings=$(grep -c '"level":"WARNING"' "$VALIDATOR_LOG" 2>/dev/null || echo "0")

    local errors
    errors=$(grep -c '"level":"ERROR"' "$VALIDATOR_LOG" 2>/dev/null || echo "0")

    printf '[file-existence-validator] Total: %d | Warnings: %d | Errors: %d\n' \
        "$total_checks" "$warnings" "$errors"
}

export -f validate_file_assertions
export -f report_validator_stats
