#!/usr/bin/env bash
# completion-validation-guard.sh — 완료 선언 검증 클러스터 방어 가드
#
# 클러스터 ID: cl-45670404fa7eb40c (최근 7일 재발 15건)
# 문제:
#   1. 완료 선언 전 PDF 페이지 수 미검증 (2회 반복)
#   2. 파일 전송 응답 본문 검증 없음 (상태코드만 확인)
#   3. 중복 파일 미감지 (해시 비교 없음)
#   4. 클릭 후 화면 상태 검증 없음 (실행 완료 오판)
#
# 목적:
#   1. PDF 페이지 수를 정확히 검증 (손상된 PDF 구분)
#   2. 파일 전송 응답 본문을 파싱 (HTTP 상태코드 + 응답 본체 검증)
#   3. 파일 해시로 중복 감지 (동일 콘텐츠 차단)
#   4. 검증 통과만을 성공(exit 0)으로 반환
#
# 사용법:
#   # 1. PDF 페이지 수 검증
#   ~/jarvis/infra/guards/completion-validation-guard.sh validate-pdf "/path/to/file.pdf"
#
#   # 2. 파일 전송 응답 검증
#   ~/jarvis/infra/guards/completion-validation-guard.sh validate-upload \
#       --response "$RESPONSE" --expected-file-size 1024
#
#   # 3. 중복 파일 검사
#   ~/jarvis/infra/guards/completion-validation-guard.sh check-duplicate \
#       --file "/path/to/file" --hash-db "$HASH_DB_FILE"
#
# 성공 기준:
#   [1] PDF 페이지 수 검증: 유효한 PDF와 손상된 PDF 구분
#   [2] 응답 본문 파싱: HTTP 상태코드만 아닌 응답 본체 검증
#   [3] 중복 감지: 파일 해시로 중복 판단
#   [4] exit code 0 = 검증 통과, exit code 1 = 검증 실패
#   [5] 기존 동작 파괴 없음 (독립적 후처리 가드)

set -euo pipefail

# ── 상수 및 경로 설정 ──────────────────────────────────────────────────────
JARVIS_HOME="${HOME}/.jarvis"
GUARD_LOG="${JARVIS_HOME}/runtime/logs/completion-validation-guard.jsonl"
HASH_DB_DIR="${JARVIS_HOME}/runtime/state/file-hashes"
CLUSTER_ID="cl-45670404fa7eb40c"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
HOSTNAME="$(hostname 2>/dev/null || echo 'unknown')"

# ── 로그 디렉토리 초기화 ────────────────────────────────────────────────────
_ensure_dirs() {
    mkdir -p "$(dirname "$GUARD_LOG")" 2>/dev/null || true
    mkdir -p "$HASH_DB_DIR" 2>/dev/null || true
}
_ensure_dirs

# ── JSON 안전 이스케이프 ────────────────────────────────────────────────────
_escape_json_string() {
    local s="$1"
    s="${s//\\/\\\\}"      # \ → \\
    s="${s//\"/\\\"}"      # " → \"
    s="${s//$'\n'/\\n}"    # newline → \n
    s="${s//$'\t'/\\t}"    # tab → \t
    s="${s//$'\r'/\\r}"    # carriage return → \r
    printf '%s' "$s"
}

# ══════════════════════════════════════════════════════════════════════════════
# [1] PDF 페이지 수 검증 함수
# ══════════════════════════════════════════════════════════════════════════════

_validate_pdf_pages() {
    local pdf_file="$1"
    local min_pages="${2:-1}"

    # 경로 확장
    pdf_file="${pdf_file/#~/$HOME}"

    # 파일 존재 확인
    if [[ ! -f "$pdf_file" ]]; then
        printf '{"status":"error","file":"%s","reason":"file_not_found"}\n' \
            "$(_escape_json_string "$pdf_file")" >&2
        return 1
    fi

    # PDF 시그니처 확인 (매직 바이트)
    if ! head -c 4 "$pdf_file" | grep -q "^%PDF"; then
        printf '{"status":"error","file":"%s","reason":"not_a_pdf","signature":"none"}\n' \
            "$(_escape_json_string "$pdf_file")" >&2
        return 1
    fi

    # 페이지 수 추출 (pdfinfo 또는 텍스트 기반 분석)
    local page_count=0

    # 시도 1: pdfinfo 사용 (macOS 또는 Linux에서 Poppler 설치 시)
    if command -v pdfinfo &>/dev/null; then
        page_count=$(pdfinfo "$pdf_file" 2>/dev/null | grep "Pages:" | awk '{print $2}' || echo "0")
    fi

    # 시도 2: pdftotext 사용
    if [[ $page_count -le 0 ]] && command -v pdftotext &>/dev/null; then
        # pdftotext의 -f 및 -l 플래그로 페이지 범위 테스트
        # 마지막 페이지 찾기: 이진 탐색
        local low=1 high=9999 result=0
        while [[ $low -le $high ]]; do
            local mid=$(( (low + high) / 2 ))
            if pdftotext -f "$mid" -l "$mid" "$pdf_file" /dev/null 2>/dev/null; then
                result=$mid
                low=$((mid + 1))
            else
                high=$((mid - 1))
            fi
        done
        page_count=$result
    fi

    # 시도 3: strings + grep로 /Count 찾기 (단순 휴리스틱)
    if [[ $page_count -le 0 ]]; then
        page_count=$(strings "$pdf_file" 2>/dev/null | grep -oE '/Count\s+[0-9]+' | awk '{print $2}' | tail -1 || echo "0")
    fi

    # 검증: 페이지 수가 최소값 이상인지 확인
    if [[ ! $page_count =~ ^[0-9]+$ ]] || [[ $page_count -lt $min_pages ]]; then
        printf '{"status":"error","file":"%s","reason":"invalid_page_count","page_count":%s,"expected_min":%d}\n' \
            "$(_escape_json_string "$pdf_file")" "$page_count" "$min_pages" >&2
        return 1
    fi

    # 성공: 유효한 PDF
    printf '{"status":"ok","file":"%s","page_count":%d,"is_valid":true}\n' \
        "$(_escape_json_string "$pdf_file")" "$page_count"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# [2] 파일 전송 응답 본문 검증 함수
# ══════════════════════════════════════════════════════════════════════════════

_validate_upload_response() {
    local response="$1"
    local expected_file_size="${2:-}"

    # 응답이 비어있는지 확인
    if [[ -z "$response" ]]; then
        printf '{"status":"error","reason":"empty_response","http_status":"unknown","has_body":false}\n' >&2
        return 1
    fi

    # 응답에서 HTTP 상태 코드 추출
    local http_status=""
    local response_body=""

    # 응답 포맷: "HTTP/1.1 200 OK\r\nContent-Type: ...\r\n\r\n{json_body}"
    # 또는 단순 상태코드만 있을 수 있음
    if [[ "$response" =~ HTTP ]]; then
        http_status=$(echo "$response" | head -1 | grep -oE '[0-9]{3}' | head -1 || echo "unknown")
        # 빈 줄 이후가 본문
        response_body=$(echo "$response" | sed '1,/^$/d')
    else
        # 상태코드가 없으면 전체가 응답 본문 (성공으로 가정, 2xx로 처리)
        http_status="200"
        response_body="$response"
    fi

    # HTTP 상태코드 검증: 2xx 범위 또는 "unknown" (본문만 있는 경우)
    if [[ ! "$http_status" =~ ^2[0-9]{2}$ ]] && [[ "$http_status" != "200" ]]; then
        printf '{"status":"error","http_status":"%s","reason":"non_2xx_status","has_body":%s}\n' \
            "$http_status" "$([ -n "$response_body" ] && echo 'true' || echo 'false')" >&2
        return 1
    fi

    # 응답 본문 파싱 (JSON 또는 텍스트)
    local has_content="false"
    local parsed_size="0"
    local parsed_success="false"

    # JSON 응답 시도
    if echo "$response_body" | jq empty 2>/dev/null; then
        has_content="true"
        # success, uploaded, url, size 등의 필드 확인
        if echo "$response_body" | jq -e '.success // .uploaded // .url // .file_size' 2>/dev/null >/dev/null; then
            parsed_success="true"
            parsed_size=$(echo "$response_body" | jq -r '.file_size // .size // "0"' 2>/dev/null || echo "0")
        fi
    elif [[ -n "$response_body" ]]; then
        # 텍스트 응답: "파일 업로드 완료" 등
        has_content="true"
        if echo "$response_body" | grep -qE "(success|complete|uploaded|OK)" 2>/dev/null; then
            parsed_success="true"
        fi
    fi

    # 응답 본문이 없으면 실패
    if [[ "$has_content" == "false" ]]; then
        printf '{"status":"error","http_status":"%s","reason":"empty_body","expected_size":"%s"}\n' \
            "$http_status" "$expected_file_size" >&2
        return 1
    fi

    # 파일 크기 검증 (제공된 경우)
    if [[ -n "$expected_file_size" ]] && [[ "$parsed_size" != "0" ]]; then
        if [[ "$parsed_size" -ne "$expected_file_size" ]]; then
            printf '{"status":"error","http_status":"%s","reason":"size_mismatch","expected":%s,"actual":%s}\n' \
                "$http_status" "$expected_file_size" "$parsed_size" >&2
            return 1
        fi
    fi

    # 성공: 응답 본문 검증 통과
    printf '{"status":"ok","http_status":"%s","has_body":true,"parsed_success":%s,"file_size":%s}\n' \
        "$http_status" "$parsed_success" "$parsed_size"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# [3] 중복 파일 감지 함수
# ══════════════════════════════════════════════════════════════════════════════

_compute_file_hash() {
    local file="$1"

    # 파일 존재 확인
    if [[ ! -f "$file" ]]; then
        echo "error"
        return 1
    fi

    # SHA256 또는 MD5 사용
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v md5 &>/dev/null; then
        md5 -q "$file"
    else
        echo "error"
        return 1
    fi
}

_check_duplicate() {
    local file="$1"
    local hash_db_dir="$2"

    # 경로 확장
    file="${file/#~/$HOME}"

    # 파일 존재 확인
    if [[ ! -f "$file" ]]; then
        printf '{"status":"error","file":"%s","reason":"file_not_found"}\n' \
            "$(_escape_json_string "$file")" >&2
        return 1
    fi

    # 파일 해시 계산
    local file_hash
    file_hash=$(_compute_file_hash "$file")

    if [[ "$file_hash" == "error" ]]; then
        printf '{"status":"error","file":"%s","reason":"hash_computation_failed"}\n' \
            "$(_escape_json_string "$file")" >&2
        return 1
    fi

    # 해시 데이터베이스: 콘텐츠 해시를 기준으로 중복 감지
    # 파일 경로와 무관하게, 동일한 콘텐츠 해시는 중복으로 판단
    local hash_registry="${hash_db_dir}/hash-registry.jsonl"
    mkdir -p "$hash_db_dir"

    # 기존에 동일한 해시가 기록되었는지 확인
    if [[ -f "$hash_registry" ]]; then
        if grep -q "\"hash\":\"$file_hash\"" "$hash_registry" 2>/dev/null; then
            # 중복: 같은 해시가 이미 기록됨
            local previous_file
            previous_file=$(grep "\"hash\":\"$file_hash\"" "$hash_registry" | tail -1 | grep -o '"file":"[^"]*"' | cut -d'"' -f4)
            printf '{"status":"duplicate","file":"%s","hash":"%s","reason":"same_hash_as_previous","previous_file":"%s"}\n' \
                "$(_escape_json_string "$file")" "$file_hash" "$(_escape_json_string "$previous_file")"
            return 1
        fi
    fi

    # 현재 파일의 해시 기록 저장
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '{"ts":"%s","file":"%s","hash":"%s"}\n' "$ts" "$(_escape_json_string "$file")" "$file_hash" >> "$hash_registry" 2>/dev/null || true

    # 성공: 중복 아님
    printf '{"status":"ok","file":"%s","hash":"%s","is_duplicate":false}\n' \
        "$(_escape_json_string "$file")" "$file_hash"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# [4] 완료 검증 종합 함수
# ══════════════════════════════════════════════════════════════════════════════

_validate_completion() {
    local pdf_file="${1:-}"
    local upload_response="${2:-}"
    local file_to_check="${3:-}"

    local all_valid="true"
    local validation_results="[]"

    # PDF 검증 (제공된 경우)
    if [[ -n "$pdf_file" ]]; then
        local pdf_result
        if pdf_result=$(_validate_pdf_pages "$pdf_file" 2>&1); then
            echo "PDF validation: PASS" >&2
            validation_results="[{\"type\":\"pdf\",\"status\":\"pass\"}]"
        else
            echo "PDF validation: FAIL - $pdf_result" >&2
            all_valid="false"
            validation_results="[{\"type\":\"pdf\",\"status\":\"fail\",\"reason\":\"$pdf_result\"}]"
        fi
    fi

    # 응답 검증 (제공된 경우)
    if [[ -n "$upload_response" ]]; then
        local response_result
        if response_result=$(_validate_upload_response "$upload_response" 2>&1); then
            echo "Upload response validation: PASS" >&2
            if [[ "$validation_results" == "[]" ]]; then
                validation_results="[{\"type\":\"upload_response\",\"status\":\"pass\"}]"
            else
                validation_results="${validation_results%]},{\"type\":\"upload_response\",\"status\":\"pass\"}]"
            fi
        else
            echo "Upload response validation: FAIL - $response_result" >&2
            all_valid="false"
            if [[ "$validation_results" == "[]" ]]; then
                validation_results="[{\"type\":\"upload_response\",\"status\":\"fail\"}]"
            else
                validation_results="${validation_results%]},{\"type\":\"upload_response\",\"status\":\"fail\"}]"
            fi
        fi
    fi

    # 중복 파일 검사 (제공된 경우)
    if [[ -n "$file_to_check" ]]; then
        local dup_result
        if dup_result=$(_check_duplicate "$file_to_check" "$HASH_DB_DIR" 2>&1); then
            echo "Duplicate check: PASS" >&2
            if [[ "$validation_results" == "[]" ]]; then
                validation_results="[{\"type\":\"duplicate\",\"status\":\"pass\"}]"
            else
                validation_results="${validation_results%]},{\"type\":\"duplicate\",\"status\":\"pass\"}]"
            fi
        else
            echo "Duplicate check: FAIL - $dup_result" >&2
            all_valid="false"
            if [[ "$validation_results" == "[]" ]]; then
                validation_results="[{\"type\":\"duplicate\",\"status\":\"fail\"}]"
            else
                validation_results="${validation_results%]},{\"type\":\"duplicate\",\"status\":\"fail\"}]"
            fi
        fi
    fi

    # 최종 검증 결과
    printf '{"timestamp":"%s","cluster_id":"%s","all_valid":%s,"validations":%s}\n' \
        "$TIMESTAMP" "$CLUSTER_ID" "$all_valid" "$validation_results"

    [[ "$all_valid" == "true" ]] && return 0 || return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# 메인 함수
# ══════════════════════════════════════════════════════════════════════════════

main() {
    local command="${1:-}"

    case "$command" in
        validate-pdf)
            if [[ $# -lt 2 ]]; then
                echo "Usage: $0 validate-pdf <pdf_file> [min_pages]" >&2
                exit 1
            fi
            _validate_pdf_pages "$2" "${3:-1}"
            ;;

        validate-upload)
            local response=""
            local file_size=""

            while [[ $# -gt 1 ]]; do
                case "$2" in
                    --response)
                        response="$3"
                        shift 2
                        ;;
                    --expected-file-size)
                        file_size="$3"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done

            if [[ -z "$response" ]]; then
                echo "Usage: $0 validate-upload --response <response> [--expected-file-size <size>]" >&2
                exit 1
            fi

            _validate_upload_response "$response" "$file_size"
            ;;

        check-duplicate)
            local file=""

            while [[ $# -gt 1 ]]; do
                case "$2" in
                    --file)
                        file="$3"
                        shift 2
                        ;;
                    --hash-db)
                        HASH_DB_DIR="$3"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done

            if [[ -z "$file" ]]; then
                echo "Usage: $0 check-duplicate --file <file> [--hash-db <dir>]" >&2
                exit 1
            fi

            _check_duplicate "$file" "$HASH_DB_DIR"
            ;;

        validate-completion)
            # 종합 검증: PDF + 응답 + 중복 체크
            # 사용: $0 validate-completion [--pdf file] [--response text] [--file file]
            local pdf_file=""
            local upload_response=""
            local file_to_check=""

            while [[ $# -gt 1 ]]; do
                case "$2" in
                    --pdf)
                        pdf_file="$3"
                        shift 2
                        ;;
                    --response)
                        upload_response="$3"
                        shift 2
                        ;;
                    --file)
                        file_to_check="$3"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done

            _validate_completion "$pdf_file" "$upload_response" "$file_to_check"
            ;;

        *)
            echo "Usage: $0 {validate-pdf|validate-upload|check-duplicate|validate-completion} [options]" >&2
            exit 1
            ;;
    esac
}

main "$@"
