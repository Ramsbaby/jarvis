#!/usr/bin/env bash
# cluster-guard-cl-45670404fa7eb40c.sh — 완료 선언 검증 클러스터 방어 가드
#
# 클러스터 ID: cl-45670404fa7eb40c (최근 7일 재발 15건)
# 반복 실수: 완료 선언 전 PDF 페이지 수 미검증, 파일 전송 응답 본문 미검증, 중복 파일 미감지
#
# 통합 위치: ask-claude.sh의 "Cluster guard integration" 섹션
# 호출 방식: source cluster-guard-cl-45670404fa7eb40c.sh "$RAW_OUTPUT" "$TASK_ID" 2>/dev/null
#
# 검증 로직:
#   1. 결과에서 PDF 경로 추출 → PDF 페이지 수 검증
#   2. 결과에서 파일 업로드 응답 추출 → 응답 본문 검증
#   3. 생성된 파일 목록 추출 → 중복 파일 감지
#   4. 검증 실패 시 경고 로그 기록, exit 코드 NOT 변경 (호출자가 판단)

set -uo pipefail

readonly CLUSTER_ID="cl-45670404fa7eb40c"
readonly GUARD_SCRIPT="${HOME}/.jarvis/infra/guards/completion-validation-guard.sh"
readonly LOG_FILE="${HOME}/jarvis/runtime/logs/cluster-guard-cl-45670404fa7eb40c.jsonl"

# ── 초기화 ────────────────────────────────────────────────────────────────────
_ensure_log_dir() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
}
_ensure_log_dir

# ── JSON 안전 이스케이프 ────────────────────────────────────────────────────
_escape_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# ── 로그 기록 ────────────────────────────────────────────────────────────────
_log_guard_event() {
    local task_id="$1"
    local event_type="$2"  # check_passed, check_failed, check_skipped
    local check_name="$3"  # pdf, upload_response, duplicate
    local details="${4:-}"

    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local entry="{\"ts\":\"$ts\",\"cluster\":\"$CLUSTER_ID\",\"task\":\"$task_id\",\"event\":\"$event_type\",\"check\":\"$check_name\""
    if [[ -n "$details" ]]; then
        entry="$entry,\"details\":\"$(_escape_json "$details")\""
    fi
    entry="$entry}"

    echo "$entry" >> "$LOG_FILE" 2>/dev/null || true
}

# ── 결과에서 PDF 경로 추출 ────────────────────────────────────────────────────
_extract_pdf_paths() {
    local result="$1"
    # 패턴: "파일: /path/to/file.pdf" 또는 "PDF: /path/file.pdf" 또는 "/path/file.pdf"
    echo "$result" | grep -oE '/[^[:space:]]*\.pdf' 2>/dev/null || true
}

# ── 결과에서 파일 업로드 응답 추출 ────────────────────────────────────────────
_extract_upload_response() {
    local result="$1"
    # 패턴: HTTP 응답이나 upload/response 키워드 근처의 JSON
    # 간단한 휴리스틱: {.*} 형태의 JSON 블록 찾기
    echo "$result" | grep -oE '\{[^{}]*"(success|uploaded|url|file|response|status)"[^{}]*\}' | head -1 || true
}

# ── 결과에서 생성된 파일 목록 추출 ────────────────────────────────────────────
_extract_saved_files() {
    local result="$1"
    # 패턴: "저장했습니다", "생성했습니다" 또는 "Saved to" 근처의 경로
    echo "$result" | grep -oE '([^[:space:]]*\.pdf|[^[:space:]]*\.docx|[^[:space:]]*\.xlsx|[^[:space:]]*\.json)' 2>/dev/null || true
}

# ── 메인 검증 로직 ────────────────────────────────────────────────────────────
main() {
    local raw_output="${1:-}"
    local task_id="${2:-unknown}"

    if [[ -z "$raw_output" ]]; then
        return 0  # 출력이 없으면 검증 스킵
    fi

    # 결과 추출
    local result=""
    if echo "$raw_output" | jq empty 2>/dev/null; then
        result=$(echo "$raw_output" | jq -r '.result // ""' 2>/dev/null || echo "$raw_output")
    else
        result="$raw_output"
    fi

    # [1] PDF 검증
    local pdf_count=0
    local pdf_failed=0
    while IFS= read -r pdf_path; do
        if [[ -z "$pdf_path" ]]; then
            continue
        fi
        pdf_count=$((pdf_count + 1))

        if "$GUARD_SCRIPT" validate-pdf "$pdf_path" >/dev/null 2>&1; then
            _log_guard_event "$task_id" "check_passed" "pdf" "Path: $pdf_path"
        else
            _log_guard_event "$task_id" "check_failed" "pdf" "Path: $pdf_path — page count validation failed"
            pdf_failed=$((pdf_failed + 1))
        fi
    done < <(_extract_pdf_paths "$result")

    # [2] 파일 업로드 응답 검증
    local upload_response=""
    upload_response=$(_extract_upload_response "$result")

    if [[ -n "$upload_response" ]]; then
        if "$GUARD_SCRIPT" validate-upload --response "$upload_response" >/dev/null 2>&1; then
            _log_guard_event "$task_id" "check_passed" "upload_response"
        else
            _log_guard_event "$task_id" "check_failed" "upload_response" "Response validation failed"
        fi
    fi

    # [3] 중복 파일 감지
    local dup_count=0
    local dup_failed=0
    while IFS= read -r file_path; do
        if [[ -z "$file_path" ]] || [[ ! -f "$file_path" ]]; then
            continue
        fi
        dup_count=$((dup_count + 1))

        if "$GUARD_SCRIPT" check-duplicate --file "$file_path" >/dev/null 2>&1; then
            _log_guard_event "$task_id" "check_passed" "duplicate" "Path: $file_path"
        else
            _log_guard_event "$task_id" "check_failed" "duplicate" "Path: $file_path — duplicate detected"
            dup_failed=$((dup_failed + 1))
        fi
    done < <(_extract_saved_files "$result")

    # 요약 로그
    local summary="pdf_checked=$pdf_count,pdf_failed=$pdf_failed,files_checked=$dup_count,files_failed=$dup_failed"
    _log_guard_event "$task_id" "check_summary" "all" "$summary"

    # 기존 호출자의 exit code NOT 변경 (log만 기록)
    return 0
}

# 진입점: ask-claude.sh에서 source로 호출
main "$@"
