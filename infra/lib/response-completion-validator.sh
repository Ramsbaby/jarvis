#!/bin/bash
# response-completion-validator.sh — 응답 완전성 자동 검증
#
# 역할:
#   - 응답이 중단되지 않았는지 확인
#   - 텍스트 출력의 길이 이상 감지
#   - 실제 결과물과의 불일치 검증
#
# 사용:
#   source ~/.jarvis/infra/lib/response-completion-validator.sh
#   validate_response_completion "<response_text>" "<expected_output_file>"
#
# 반환값:
#   0 - 응답 완전함
#   1 - 응답 불완전 (중단됨)
#   2 - 결과물 미확인

set -o pipefail

# 최소 응답 길이 기준 (bytes)
RESPONSE_MIN_LENGTH_BYTES=50

# 응답의 "완료 신호" 패턴들
COMPLETION_PATTERNS=(
  "완료했습니다|완료되었습니다|완료 선언|작업 완료"
  "✅|✓|완료"
  "완료.*보고|보고 완료"
)

# 응답 중단 의심 패턴들 (텍스트가 갑자기 끝남)
TRUNCATION_PATTERNS=(
  "[가-힣]$"  # 한글 1글자로 끝남
  "[a-z]$"    # 영문 소문자 1글자로 끝남
  "[0-9]$"    # 숫자 1글자로 끝남
)

# 함수: 응답 텍스트 검증
validate_response_completion() {
    local response_text="$1"
    local output_file="$2"

    [ -z "$response_text" ] && { echo "ERROR: response_text required" >&2; return 1; }

    local response_len=${#response_text}
    local is_truncated=0

    # 1. 길이 확인 (경고만, 실패 아님)
    if [ "$response_len" -lt "$RESPONSE_MIN_LENGTH_BYTES" ]; then
        echo "WARN: 응답 길이 이상 (${response_len} < ${RESPONSE_MIN_LENGTH_BYTES})" >&2
        # is_truncated=1은 하지 않음 — 길이만으로는 판단하지 않음
    fi

    # 2. 중단 패턴 검증 — 조사+어미 패턴 (불완전한 종결)
    # 패턴: 조사 다음 "다/고/요"로 끝남 (예: "는 다", "은 다", "를 고" 등)
    if echo "$response_text" | grep -qE '(은|는|를|을|이|가|에|의|로|와) (다|고|요)$'; then
        echo "WARN: 응답 중단 의심 — 불완전한 종결: '$(echo "$response_text" | tail -c 4)'" >&2
        is_truncated=1
    fi

    # 3. 실제 파일 vs. 응답 텍스트 일관성 검증
    if [ -n "$output_file" ]; then
        if [ ! -f "$output_file" ]; then
            echo "ERROR: 산출물 파일 미존재: $output_file" >&2
            return 2
        fi

        local file_size=$(stat -f%z "$output_file" 2>/dev/null || stat -c%s "$output_file" 2>/dev/null)
        if [ "$file_size" -eq 0 ]; then
            echo "ERROR: 산출물 파일 비어있음: $output_file" >&2
            return 2
        fi

        # 파일이 존재하고 비어있지 않으면 OK
        echo "OK: 파일 존재 및 크기 확인 ($file_size bytes)"
    fi

    if [ "$is_truncated" -eq 1 ]; then
        return 1
    fi

    return 0
}

# 함수: 완료 선언과 실제 작업 상태 대조
validate_completion_vs_reality() {
    local response_text="$1"
    local artifact_path="$2"  # 생성되어야 할 파일
    local http_url="$3"       # HTTP로 접근 가능해야 할 URL

    local mismatches=0

    # 완료 선언 여부 확인
    local has_completion_claim=0
    if echo "$response_text" | grep -qiE '완료했|완료되었|작업.*완료'; then
        has_completion_claim=1
    fi

    if [ "$has_completion_claim" -eq 0 ]; then
        echo "OK: 완료 선언 없음 (보수적 응답)"
        return 0
    fi

    echo "완료 선언 감지, 실제 검증 시작..."

    # 파일 존재성 검증
    if [ -n "$artifact_path" ]; then
        if [ ! -f "$artifact_path" ]; then
            echo "MISMATCH: 완료 선언했으나 파일 미존재 — $artifact_path" >&2
            mismatches=$((mismatches + 1))
        else
            local fsize=$(stat -f%z "$artifact_path" 2>/dev/null || stat -c%s "$artifact_path" 2>/dev/null)
            if [ "$fsize" -eq 0 ]; then
                echo "MISMATCH: 완료 선언했으나 파일 비어있음 — $artifact_path ($fsize bytes)" >&2
                mismatches=$((mismatches + 1))
            fi
        fi
    fi

    # HTTP 접근성 검증
    if [ -n "$http_url" ]; then
        local http_status=$(curl -s -o /dev/null -w "%{http_code}" "$http_url" 2>/dev/null || echo "000")
        if [ "$http_status" != "200" ] && [ "$http_status" != "201" ] && [ "$http_status" != "204" ]; then
            echo "MISMATCH: 완료 선언했으나 HTTP 접근 실패 — $http_url ($http_status)" >&2
            mismatches=$((mismatches + 1))
        fi
    fi

    if [ "$mismatches" -gt 0 ]; then
        return 1
    fi

    return 0
}

# 함수: 연관 기능 일관성 검증 (예: 설명 추가 후 인터랙티브 기능)
validate_feature_consistency() {
    local html_file="$1"  # HTML/웹 파일
    local description_exists="$2"  # 설명 섹션 존재 여부 (0/1)
    local interactive_required="$3"  # 인터랙티브 기능 필수 여부 (0/1)

    if [ -z "$html_file" ] || [ ! -f "$html_file" ]; then
        echo "SKIP: HTML 파일 미제공 또는 미존재"
        return 0
    fi

    # 설명이 추가되었으나 인터랙티브 기능 일관성 검증
    if [ "$description_exists" -eq 1 ] && [ "$interactive_required" -eq 1 ]; then
        # JavaScript 또는 이벤트 핸들러 확인
        if grep -q 'onclick\|addEventListener\|<script' "$html_file"; then
            echo "OK: 설명 추가 및 인터랙티브 기능 일관성 확인"
            return 0
        else
            echo "MISMATCH: 설명은 추가했으나 인터랙티브 기능 누락" >&2
            return 1
        fi
    fi

    return 0
}

# 함수: 최소 품질 게이트
validate_output_quality() {
    local output_file="$1"
    local min_lines="$2"  # 최소 라인 수

    [ -z "$output_file" ] || [ ! -f "$output_file" ] && return 2

    local actual_lines=$(wc -l < "$output_file")
    if [ "$actual_lines" -lt "${min_lines:-10}" ]; then
        echo "QUALITY: 산출물 라인 수 부족 (${actual_lines} < ${min_lines:-10})" >&2
        return 1
    fi

    return 0
}

# 내보내기
export -f validate_response_completion
export -f validate_completion_vs_reality
export -f validate_feature_consistency
export -f validate_output_quality
