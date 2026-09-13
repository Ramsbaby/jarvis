#!/bin/bash
# artifact-validation-gate.sh — 산출물 자동 검증 게이트
#
# 역할:
#   - 완료 선언 전에 실제 산출물 존재 및 품질 자동 검증
#   - 불완전한 산출물에 대한 거짓 완료 보고 차단
#
# 사용:
#   source ~/.jarvis/infra/lib/artifact-validation-gate.sh
#   validate_artifact "file" "/path/to/output.txt"
#   validate_artifact "http" "https://api.example.com/file"
#   validate_artifact "pdf" "/path/to/document.pdf"
#
# 반환값:
#   0 - 검증 성공
#   1 - 검증 실패
#   2 - 검증 불가능

set -o pipefail

# 산출물 유형별 검증 기준 (주석)
# file: file_exists,size_gt_zero,readable
# http: http_status_ok,response_size_gt_zero
# pdf: file_exists,pdf_valid,size_gt_zero
# html: file_exists,html_structure_valid,size_gt_zero
# json: file_exists,json_valid,size_gt_zero
# image: file_exists,image_valid,size_gt_zero

# 함수: 파일 산출물 검증
validate_file_artifact() {
    local file_path="$1"

    [ -z "$file_path" ] && { echo "ERROR: file_path required" >&2; return 2; }

    if [ ! -f "$file_path" ]; then
        echo "FAIL: 파일 미존재 — $file_path" >&2
        return 1
    fi

    local file_size=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null)
    if [ "$file_size" -eq 0 ]; then
        echo "FAIL: 파일 비어있음 — $file_path (0 bytes)" >&2
        return 1
    fi

    if [ ! -r "$file_path" ]; then
        echo "FAIL: 파일 읽기 불가 — $file_path" >&2
        return 1
    fi

    echo "OK: 파일 산출물 검증 성공 ($file_path, $file_size bytes)"
    return 0
}

# 함수: HTTP 산출물 검증
validate_http_artifact() {
    local url="$1"
    local expected_status="${2:-200}"

    [ -z "$url" ] && { echo "ERROR: url required" >&2; return 2; }

    local http_status=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")

    if [ "$http_status" != "$expected_status" ]; then
        echo "FAIL: HTTP 상태 코드 오류 — $url ($http_status, 예상: $expected_status)" >&2
        return 1
    fi

    local response_size=$(curl -s -w "%{size_download}" -o /dev/null "$url" 2>/dev/null)
    if [ "$response_size" -le 0 ]; then
        echo "FAIL: HTTP 응답 비어있음 — $url ($response_size bytes)" >&2
        return 1
    fi

    echo "OK: HTTP 산출물 검증 성공 ($url, 상태: $http_status, 크기: $response_size bytes)"
    return 0
}

# 함수: PDF 산출물 검증
validate_pdf_artifact() {
    local pdf_path="$1"

    [ -z "$pdf_path" ] && { echo "ERROR: pdf_path required" >&2; return 2; }

    if [ ! -f "$pdf_path" ]; then
        echo "FAIL: PDF 파일 미존재 — $pdf_path" >&2
        return 1
    fi

    local file_size=$(stat -f%z "$pdf_path" 2>/dev/null || stat -c%s "$pdf_path" 2>/dev/null)
    if [ "$file_size" -eq 0 ]; then
        echo "FAIL: PDF 파일 비어있음 — $pdf_path" >&2
        return 1
    fi

    # PDF 헤더 검증
    if ! file "$pdf_path" 2>/dev/null | grep -q "PDF"; then
        echo "FAIL: PDF 형식 오류 또는 손상 — $pdf_path" >&2
        return 1
    fi

    # 페이지 수 확인 (선택)
    local page_count=$(pdfinfo "$pdf_path" 2>/dev/null | grep "Pages:" | awk '{print $2}')
    if [ -z "$page_count" ]; then
        # pdfinfo 없을 수도 있음, 경고만
        echo "WARN: PDF 페이지 수 미확인 (pdfinfo 미설치) — $pdf_path"
    else
        if [ "$page_count" -eq 0 ]; then
            echo "FAIL: PDF 페이지 없음 — $pdf_path" >&2
            return 1
        fi
        echo "OK: PDF 산출물 검증 성공 ($pdf_path, $page_count 페이지, $file_size bytes)"
    fi

    return 0
}

# 함수: HTML 산출물 검증
validate_html_artifact() {
    local html_path="$1"

    [ -z "$html_path" ] && { echo "ERROR: html_path required" >&2; return 2; }

    if [ ! -f "$html_path" ]; then
        echo "FAIL: HTML 파일 미존재 — $html_path" >&2
        return 1
    fi

    local file_size=$(stat -f%z "$html_path" 2>/dev/null || stat -c%s "$html_path" 2>/dev/null)
    if [ "$file_size" -eq 0 ]; then
        echo "FAIL: HTML 파일 비어있음 — $html_path" >&2
        return 1
    fi

    # HTML 구조 검증 (기본 태그 확인)
    if ! grep -q '<html\|<!DOCTYPE' "$html_path"; then
        echo "WARN: HTML 구조 불완전 — $html_path (html/DOCTYPE 태그 미발견)"
        # 경고이지만 파일이 있고 크기가 있으면 일단 통과
        return 0
    fi

    echo "OK: HTML 산출물 검증 성공 ($html_path, $file_size bytes)"
    return 0
}

# 함수: JSON 산출물 검증
validate_json_artifact() {
    local json_path="$1"

    [ -z "$json_path" ] && { echo "ERROR: json_path required" >&2; return 2; }

    if [ ! -f "$json_path" ]; then
        echo "FAIL: JSON 파일 미존재 — $json_path" >&2
        return 1
    fi

    local file_size=$(stat -f%z "$json_path" 2>/dev/null || stat -c%s "$json_path" 2>/dev/null)
    if [ "$file_size" -eq 0 ]; then
        echo "FAIL: JSON 파일 비어있음 — $json_path" >&2
        return 1
    fi

    # JSON 유효성 검증 (jq 사용)
    if ! jq empty "$json_path" 2>/dev/null; then
        echo "FAIL: JSON 형식 오류 — $json_path" >&2
        return 1
    fi

    echo "OK: JSON 산출물 검증 성공 ($json_path, $file_size bytes)"
    return 0
}

# 함수: 이미지 산출물 검증
validate_image_artifact() {
    local image_path="$1"

    [ -z "$image_path" ] && { echo "ERROR: image_path required" >&2; return 2; }

    if [ ! -f "$image_path" ]; then
        echo "FAIL: 이미지 파일 미존재 — $image_path" >&2
        return 1
    fi

    local file_size=$(stat -f%z "$image_path" 2>/dev/null || stat -c%s "$image_path" 2>/dev/null)
    if [ "$file_size" -eq 0 ]; then
        echo "FAIL: 이미지 파일 비어있음 — $image_path" >&2
        return 1
    fi

    # 이미지 형식 검증
    if ! file "$image_path" 2>/dev/null | grep -qE "image|picture"; then
        echo "FAIL: 이미지 형식 오류 또는 손상 — $image_path" >&2
        return 1
    fi

    echo "OK: 이미지 산출물 검증 성공 ($image_path, $file_size bytes)"
    return 0
}

# 함수: 통합 검증 진입점
validate_artifact() {
    local artifact_type="$1"
    local artifact_path="$2"

    [ -z "$artifact_type" ] && { echo "ERROR: artifact_type required" >&2; return 2; }
    [ -z "$artifact_path" ] && { echo "ERROR: artifact_path required" >&2; return 2; }

    case "$artifact_type" in
        file)
            validate_file_artifact "$artifact_path"
            ;;
        http)
            validate_http_artifact "$artifact_path"
            ;;
        pdf)
            validate_pdf_artifact "$artifact_path"
            ;;
        html)
            validate_html_artifact "$artifact_path"
            ;;
        json)
            validate_json_artifact "$artifact_path"
            ;;
        image)
            validate_image_artifact "$artifact_path"
            ;;
        *)
            echo "ERROR: 알 수 없는 산출물 유형: $artifact_type" >&2
            return 2
            ;;
    esac
}

# 함수: 복수 산출물 검증 (단계별)
validate_artifacts() {
    local -a artifacts=("$@")
    local failed_count=0

    for artifact in "${artifacts[@]}"; do
        # 형식: "type:path"
        local type="${artifact%%:*}"
        local path="${artifact#*:}"

        validate_artifact "$type" "$path" || failed_count=$((failed_count + 1))
    done

    if [ "$failed_count" -gt 0 ]; then
        echo "FAIL: $failed_count개 산출물 검증 실패" >&2
        return 1
    fi

    return 0
}

# 내보내기
export -f validate_file_artifact
export -f validate_http_artifact
export -f validate_pdf_artifact
export -f validate_html_artifact
export -f validate_json_artifact
export -f validate_image_artifact
export -f validate_artifact
export -f validate_artifacts
