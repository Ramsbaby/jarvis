#!/usr/bin/env bash
# file-existence-guard.sh — 파일 존재 판단 오류 클러스터 방어 가드
#
# 클러스터 ID: cl-3dbad2477e65b7b7 (최근 7일 재발 14건)
# 문제: 파일 존재 여부 판단 모순 — 미확인 후 단언, 자기모순적 표현
#
# 목적:
#   1. 지정 경로의 파일 존재 여부를 정확히 탐색 (Glob/Read 시작 전)
#   2. 탐색 결과를 JSON으로 기록하여 응답에 근거 제공
#   3. 응답에 포함된 존재 단언과 실제 탐색 결과를 대조
#   4. 불일치 시 경고 로그 기록 및 선택적 차단
#
# 사용법:
#   # 1. 가드 실행: 지정 경로 탐색 + JSON 결과 출력
#   ~/jarvis/infra/guards/file-existence-guard.sh scan /path/to/file
#
#   # 2. 가드 실행: 디렉토리 패턴 탐색
#   ~/jarvis/infra/guards/file-existence-guard.sh scan "~/jarvis/**/*.sh"
#
#   # 3. 응답 검증: 파일 단언과 실제 탐색 결과 대조
#   ~/jarvis/infra/guards/file-existence-guard.sh validate \
#       --scan-result "$JSON_SCAN" \
#       --response "$RESPONSE_TEXT"
#
# 성공 기준:
#   [1] 스크립트 실행 권한 있음, 기본 문법 유효
#   [2] scan 명령: 지정 경로의 파일 존재 여부를 정확히 탐색, JSON 출력
#   [3] validate 명령: 응답의 파일 단언과 탐색 결과 대조, 불일치 감지
#   [4] 기존 동작 파괴 없음 (독립적 후처리 가드)

set -euo pipefail

# ── 상수 및 경로 설정 ──────────────────────────────────────────────────────
JARVIS_HOME="${HOME}/.jarvis"
GUARD_LOG="${JARVIS_HOME}/runtime/logs/file-existence-guard.jsonl"
CLUSTER_ID="cl-3dbad2477e65b7b7"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
HOSTNAME="$(hostname 2>/dev/null || echo 'unknown')"

# ── 로그 디렉토리 초기화 ────────────────────────────────────────────────────
_ensure_log_dir() {
    local log_dir
    log_dir=$(dirname "$GUARD_LOG")
    mkdir -p "$log_dir" 2>/dev/null || true
}
_ensure_log_dir

# ── JSON 안전 이스케이프 ────────────────────────────────────────────────────
_escape_json_string() {
    local s="$1"
    # 따옴표, 백슬래시, 개행, 탭 등 이스케이프
    s="${s//\\/\\\\}"      # \ → \\
    s="${s//\"/\\\"}"      # " → \"
    s="${s//$'\n'/\\n}"    # newline → \n
    s="${s//$'\t'/\\t}"    # tab → \t
    s="${s//$'\r'/\\r}"    # carriage return → \r
    printf '%s' "$s"
}

# ── 파일 존재 탐색 함수 ────────────────────────────────────────────────────
# 입력: 파일 경로 또는 glob 패턴
# 출력: JSON 객체 (status, path, exists, type, error 등)
_scan_file_path() {
    local target="$1"

    # 경로 확장 (~ 등)
    target="${target/#~/$HOME}"

    # glob 패턴 검사 (*, ?, [ 포함)
    if [[ "$target" == *\** ]] || [[ "$target" == *\?* ]] || [[ "$target" == *\[* ]]; then
        # glob 패턴: find 사용
        _scan_glob_pattern "$target"
    else
        # 단일 경로: stat/test 사용
        _scan_single_path "$target"
    fi
}

# ── 단일 파일 경로 탐색 ────────────────────────────────────────────────────
_scan_single_path() {
    local path="$1"
    local exists="false"
    local file_type="none"
    local size="0"
    local error=""

    # 파일 존재 여부 판단
    if [[ -e "$path" ]]; then
        exists="true"

        # 타입 판단
        if [[ -f "$path" ]]; then
            file_type="file"
            size=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null || echo "0")
        elif [[ -d "$path" ]]; then
            file_type="directory"
            size=$(du -sb "$path" 2>/dev/null | awk '{print $1}' || echo "0")
        elif [[ -L "$path" ]]; then
            file_type="symlink"
        elif [[ -b "$path" ]]; then
            file_type="block_device"
        elif [[ -c "$path" ]]; then
            file_type="char_device"
        else
            file_type="other"
        fi
    elif [[ -L "$path" ]]; then
        # 깨진 심볼릭 링크
        exists="true"
        file_type="broken_symlink"
        error="Broken symlink"
    else
        exists="false"
        file_type="none"
    fi

    # JSON 결과 생성
    printf '{"status":"ok","path":"%s","exists":%s,"type":"%s","size":%s' \
        "$(_escape_json_string "$path")" "$exists" "$file_type" "$size"

    if [[ -n "$error" ]]; then
        printf ',"error":"%s"' "$(_escape_json_string "$error")"
    fi
    printf '}'
}

# ── Glob 패턴 탐색 ────────────────────────────────────────────────────────
_scan_glob_pattern() {
    local pattern="$1"
    local matches=()

    # glob 확장
    while IFS= read -r match; do
        matches+=("$match")
    done < <(find "$(dirname "$pattern")" -name "$(basename "$pattern")" 2>/dev/null || true)

    # 결과 JSON 배열로 구성
    if [[ ${#matches[@]} -eq 0 ]]; then
        # 매칭 없음
        printf '{"status":"ok","pattern":"%s","exists":false,"count":0,"matches":[]}' \
            "$(_escape_json_string "$pattern")"
    else
        # 매칭 있음
        local match_json="["
        local first=1
        for m in "${matches[@]}"; do
            [[ $first -eq 0 ]] && match_json+=","
            match_json+="\"$(_escape_json_string "$m")\""
            first=0
        done
        match_json+="]"

        printf '{"status":"ok","pattern":"%s","exists":true,"count":%d,"matches":%s}' \
            "$(_escape_json_string "$pattern")" "${#matches[@]}" "$match_json"
    fi
}

# ── 응답 검증: 파일 존재 단언과 실제 탐색 결과 대조 ────────────────────────
# 입력: scan 결과 JSON, 응답 텍스트
# 출력: 검증 결과 JSON
_validate_response() {
    local scan_json="$1"
    local response="$2"

    # scan_json에서 존재 여부 추출
    local claimed_exists
    claimed_exists=$(echo "$scan_json" | jq -r '.exists // "unknown"' 2>/dev/null || echo "unknown")

    # response에서 파일 관련 단언 검색
    # 패턴: "파일 (있음|있습니다|존재|확인|읽음|수정)" / "(없음|없습니다|부재|미존재)"
    local positive_patterns=(
        "파일.*있음"
        "파일.*존재"
        "파일.*확인"
        "파일.*읽음"
        "파일.*수정"
        "파일.*열고"
        "파일.*접근"
    )

    local negative_patterns=(
        "파일.*없음"
        "파일.*부재"
        "파일.*미존재"
        "파일.*못.*찾"
        "파일.*찾지.*못"
        "파일.*존재하지"
        "파일.*검색.*안.*됨"
    )

    local found_positive=0
    local found_negative=0

    # 단언 검색 (case-insensitive)
    for pattern in "${positive_patterns[@]}"; do
        if grep -qEi "$pattern" <<< "$response" 2>/dev/null; then
            found_positive=1
            break
        fi
    done

    for pattern in "${negative_patterns[@]}"; do
        if grep -qEi "$pattern" <<< "$response" 2>/dev/null; then
            found_negative=1
            break
        fi
    done

    # 검증 로직
    local is_consistent="true"
    local discrepancy=""

    # 실제 존재 vs 응답 주장 대조
    if [[ "$claimed_exists" == "true" ]] && [[ $found_negative -eq 1 ]]; then
        is_consistent="false"
        discrepancy="파일은 존재하지만 응답에서 '없음' 단언"
    elif [[ "$claimed_exists" == "false" ]] && [[ $found_positive -eq 1 ]]; then
        is_consistent="false"
        discrepancy="파일이 존재하지 않지만 응답에서 '있음' 단언"
    fi

    # 검증 결과 JSON
    printf '{
        "timestamp":"%s",
        "cluster_id":"%s",
        "is_consistent":%s,
        "file_exists":%s,
        "response_claims_exists":%s,
        "response_claims_missing":%s,
        "discrepancy":"%s",
        "response_preview":"%.200s"
    }' \
        "$TIMESTAMP" \
        "$CLUSTER_ID" \
        "$is_consistent" \
        "$claimed_exists" \
        "$([ $found_positive -eq 1 ] && echo 'true' || echo 'false')" \
        "$([ $found_negative -eq 1 ] && echo 'true' || echo 'false')" \
        "$(_escape_json_string "$discrepancy")" \
        "$(_escape_json_string "$response")"
}

# ── 검증 결과 로깅 ────────────────────────────────────────────────────────
_log_validation() {
    local validation_json="$1"
    echo "$validation_json" >> "$GUARD_LOG" 2>/dev/null || true
}

# ── 메인 함수 ──────────────────────────────────────────────────────────────
main() {
    local command="${1:-scan}"

    case "$command" in
        scan)
            if [[ $# -lt 2 ]]; then
                echo "Usage: $0 scan <file_path_or_pattern>" >&2
                exit 1
            fi
            _scan_file_path "$2"
            ;;

        validate)
            local scan_result=""
            local response=""

            # 파라미터 파싱
            while [[ $# -gt 1 ]]; do
                case "$2" in
                    --scan-result)
                        scan_result="$3"
                        shift 2
                        ;;
                    --response)
                        response="$3"
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done

            if [[ -z "$scan_result" ]] || [[ -z "$response" ]]; then
                echo "Usage: $0 validate --scan-result <json> --response <text>" >&2
                exit 1
            fi

            validation=$(_validate_response "$scan_result" "$response")
            echo "$validation"
            _log_validation "$validation"
            ;;

        *)
            echo "Usage: $0 {scan|validate} [options]" >&2
            exit 1
            ;;
    esac
}

main "$@"
