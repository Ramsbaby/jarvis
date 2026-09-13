#!/usr/bin/env bash
# task-completion-validator.sh — 작업 완료 선언 시 산출물 자동 검증
#
# 역할:
#   - 완료 주장 시 실제 산출물(파일 존재, 크기, 품질) 검증
#   - 불완전/비어있는 산출물 감지 및 차단
#   - 도구 통과와 실제 산출물 불일치 방지
#
# 사용:
#   source ~/projects/jarvis/infra/guards/task-completion-validator.sh
#   validate_task_completion "file" "/path/to/output.txt"
#   validate_task_completion "response" "응답 텍스트 길이 최소 100자"
#   validate_task_completion "text" "생성된 문장" "min_chars=50"

set -o pipefail

# 함수: 파일 산출물 검증
_validate_file_artifact() {
    local file_path="$1"
    local min_size="${2:-1}"  # 기본 1바이트 이상

    [[ -z "$file_path" ]] && { echo "ERROR: file_path required" >&2; return 2; }

    # 파일 존재 확인
    if [[ ! -f "$file_path" ]]; then
        echo "FAIL: 파일 미존재 — $file_path" >&2
        return 1
    fi

    # 파일 크기 확인 (빈 파일 감지)
    local file_size
    file_size=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null || echo "0")

    if [[ "$file_size" -lt "$min_size" ]]; then
        echo "FAIL: 파일 크기 부족 — $file_path ($file_size bytes, 최소: $min_size bytes)" >&2
        return 1
    fi

    # 읽기 가능 확인
    if [[ ! -r "$file_path" ]]; then
        echo "FAIL: 파일 읽기 불가 — $file_path" >&2
        return 1
    fi

    # 실제 콘텐츠 존재 확인 (완전히 비어있지 않은지)
    local line_count
    line_count=$(wc -l < "$file_path" 2>/dev/null || echo "0")

    if [[ "$line_count" -eq 0 ]] && [[ "$file_size" -lt 10 ]]; then
        echo "WARN: 파일이 매우 작습니다 — $file_path ($file_size bytes, 라인 수: 0)" >&2
        # 일부 파일은 한 줄만 있을 수 있으므로 FAIL이 아님
    fi

    echo "OK: 파일 산출물 검증 성공 — $file_path ($file_size bytes)" >&2
    return 0
}

# 함수: 텍스트 응답 검증 (1글자 응답 방지)
_validate_text_response() {
    local response="$1"
    local min_chars="${2:-1}"

    [[ -z "$response" ]] && { echo "FAIL: 응답이 비어있습니다" >&2; return 1; }

    # 실제 길이 계산 (공백 제거 후)
    local trimmed="${response#"${response%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    local response_len=${#trimmed}

    if [[ "$response_len" -lt "$min_chars" ]]; then
        echo "FAIL: 응답이 너무 짧습니다 — 현재: $response_len 글자, 최소: $min_chars 글자" >&2
        echo "응답 내용: \"$response\"" >&2
        return 1
    fi

    if [[ "$response_len" -lt 10 ]]; then
        echo "WARN: 응답이 매우 짧습니다 — $response_len 글자" >&2
        # 대답이 짧을 수도 있으니 완전히 FAIL은 아님
    fi

    echo "OK: 텍스트 응답 검증 성공 — $response_len 글자" >&2
    return 0
}

# 함수: HTTP 산출물 검증
_validate_http_artifact() {
    local url="$1"
    local expected_status="${2:-200}"
    local min_size="${3:-10}"

    [[ -z "$url" ]] && { echo "ERROR: url required" >&2; return 2; }

    # HTTP 상태 코드 확인
    local http_status
    http_status=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")

    if [[ "$http_status" != "$expected_status" ]]; then
        echo "FAIL: HTTP 상태 코드 오류 — $url (현재: $http_status, 예상: $expected_status)" >&2
        return 1
    fi

    # 응답 크기 확인
    local response_size
    response_size=$(curl -s -m 5 -w "%{size_download}" -o /dev/null "$url" 2>/dev/null || echo "0")

    if [[ "$response_size" -lt "$min_size" ]]; then
        echo "FAIL: HTTP 응답이 너무 작습니다 — $url ($response_size bytes, 최소: $min_size bytes)" >&2
        return 1
    fi

    echo "OK: HTTP 산출물 검증 성공 — $url (상태: $http_status, 크기: $response_size bytes)" >&2
    return 0
}

# 함수: JSON 산출물 검증
_validate_json_artifact() {
    local json_file="$1"
    local min_size="${2:-10}"

    [[ -z "$json_file" ]] && { echo "ERROR: json_file required" >&2; return 2; }

    # 파일 존재 확인
    [[ ! -f "$json_file" ]] && { echo "FAIL: JSON 파일 미존재 — $json_file" >&2; return 1; }

    # 파일 크기 확인
    local file_size
    file_size=$(stat -f%z "$json_file" 2>/dev/null || stat -c%s "$json_file" 2>/dev/null)

    if [[ "$file_size" -lt "$min_size" ]]; then
        echo "FAIL: JSON 파일이 너무 작습니다 — $json_file ($file_size bytes)" >&2
        return 1
    fi

    # JSON 구문 검증
    if ! jq empty "$json_file" 2>/dev/null; then
        echo "FAIL: 유효하지 않은 JSON — $json_file" >&2
        return 1
    fi

    # 빈 객체/배열 감지
    local json_content
    json_content=$(cat "$json_file")

    if [[ "$json_content" == "{}" ]] || [[ "$json_content" == "[]" ]] || [[ "$json_content" == "null" ]]; then
        echo "WARN: JSON이 비어있습니다 — $json_file" >&2
        # 일부 케이스는 빈 객체가 정상일 수 있으므로 FAIL이 아님
    fi

    echo "OK: JSON 산출물 검증 성공 — $json_file ($file_size bytes)" >&2
    return 0
}

# 함수: PDF 산출물 검증
_validate_pdf_artifact() {
    local pdf_file="$1"
    local min_size="${2:-1000}"  # PDF는 최소 1KB 정도

    [[ -z "$pdf_file" ]] && { echo "ERROR: pdf_file required" >&2; return 2; }

    # 파일 존재 확인
    [[ ! -f "$pdf_file" ]] && { echo "FAIL: PDF 파일 미존재 — $pdf_file" >&2; return 1; }

    # 파일 크기 확인
    local file_size
    file_size=$(stat -f%z "$pdf_file" 2>/dev/null || stat -c%s "$pdf_file" 2>/dev/null)

    if [[ "$file_size" -lt "$min_size" ]]; then
        echo "FAIL: PDF 파일이 너무 작습니다 — $pdf_file ($file_size bytes, 최소: $min_size bytes)" >&2
        return 1
    fi

    # PDF 헤더 확인
    if ! head -c 4 "$pdf_file" | grep -q '%PDF'; then
        echo "FAIL: 유효하지 않은 PDF 헤더 — $pdf_file" >&2
        return 1
    fi

    echo "OK: PDF 산출물 검증 성공 — $pdf_file ($file_size bytes)" >&2
    return 0
}

# 메인 검증 함수
validate_task_completion() {
    local artifact_type="$1"
    local artifact_path="$2"
    local options="$3"

    [[ -z "$artifact_type" || -z "$artifact_path" ]] && {
        echo "ERROR: artifact_type and artifact_path required" >&2
        return 2
    }

    case "$artifact_type" in
        file)
            local min_size=1
            if [[ -n "$options" ]]; then
                min_size=$(echo "$options" | sed -n 's/.*min_size=\([0-9]\+\).*/\1/p' || echo "1")
            fi
            _validate_file_artifact "$artifact_path" "$min_size"
            ;;
        text|response)
            local min_chars=1
            if [[ -n "$options" ]]; then
                min_chars=$(echo "$options" | sed -n 's/.*min_chars=\([0-9]\+\).*/\1/p' || echo "1")
            fi
            _validate_text_response "$artifact_path" "$min_chars"
            ;;
        http|url)
            local expected_status=200 min_size=10
            if [[ -n "$options" ]]; then
                expected_status=$(echo "$options" | sed -n 's/.*status=\([0-9]\+\).*/\1/p' || echo "200")
                min_size=$(echo "$options" | sed -n 's/.*min_size=\([0-9]\+\).*/\1/p' || echo "10")
            fi
            _validate_http_artifact "$artifact_path" "$expected_status" "$min_size"
            ;;
        json)
            local min_size=10
            if [[ -n "$options" ]]; then
                min_size=$(echo "$options" | sed -n 's/.*min_size=\([0-9]\+\).*/\1/p' || echo "10")
            fi
            _validate_json_artifact "$artifact_path" "$min_size"
            ;;
        pdf)
            local min_size=1000
            if [[ -n "$options" ]]; then
                min_size=$(echo "$options" | sed -n 's/.*min_size=\([0-9]\+\).*/\1/p' || echo "1000")
            fi
            _validate_pdf_artifact "$artifact_path" "$min_size"
            ;;
        *)
            echo "ERROR: Unknown artifact type — $artifact_type" >&2
            echo "Supported types: file, text, response, http, url, json, pdf" >&2
            return 2
            ;;
    esac
}

# 함수: 다중 산출물 검증 (모두 성공해야 함)
validate_task_completion_batch() {
    local -n artifacts_ref="$1"  # 연관 배열: type → path
    local all_pass=0

    for artifact_type in "${!artifacts_ref[@]}"; do
        local artifact_path="${artifacts_ref[$artifact_type]}"
        echo "Validating: $artifact_type → $artifact_path" >&2

        if ! validate_task_completion "$artifact_type" "$artifact_path"; then
            all_pass=1
        fi
    done

    return "$all_pass"
}

# 함수: 완료 레포트 생성 (JSON)
report_completion_validation() {
    local task_id="$1"
    local artifact_type="$2"
    local artifact_path="$3"
    local validation_result="$4"  # "pass" or "fail"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    [[ -z "$task_id" ]] && task_id="unknown"
    [[ -z "$validation_result" ]] && validation_result="unknown"

    cat <<EOF
{
  "timestamp": "$timestamp",
  "cluster": "cl-41697ce934383874",
  "guard": "task-completion-validator",
  "task_id": "$task_id",
  "artifact_type": "$artifact_type",
  "artifact_path": "$artifact_path",
  "validation_result": "$validation_result"
}
EOF
}

# Test mode
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Testing task-completion-validator.sh..."

    # 테스트 1: 파일 검증 (성공)
    echo ""
    echo "Test 1: 파일 검증 (성공)"
    echo "test content" > /tmp/test_output.txt
    validate_task_completion "file" "/tmp/test_output.txt"

    # 테스트 2: 파일 검증 (실패 - 빈 파일)
    echo ""
    echo "Test 2: 파일 검증 (실패 - 빈 파일)"
    touch /tmp/empty_output.txt
    validate_task_completion "file" "/tmp/empty_output.txt" "min_size=10" || true

    # 테스트 3: 텍스트 응답 검증 (성공)
    echo ""
    echo "Test 3: 텍스트 응답 검증 (성공)"
    validate_task_completion "text" "이것은 충분히 긴 응답입니다" "min_chars=10"

    # 테스트 4: 텍스트 응답 검증 (실패 - 너무 짧음)
    echo ""
    echo "Test 4: 텍스트 응답 검증 (실패 - 너무 짧음)"
    validate_task_completion "text" "a" "min_chars=10" || true

    # 정리
    rm -f /tmp/test_output.txt /tmp/empty_output.txt
fi
