#!/bin/bash
#
# measure-session-size.sh
# 세션 크기 진단: 파일 크기(bytes)와 추정 토큰 수 자동 산출
#
# 용도: 세션 크기 추정값을 실측 기반 메트릭으로 보고
# 출력: JSON 형식 (bytes, estimated_tokens, file_list 필드 포함)
#
# 호출:
#   measure-session-size.sh [session_path]
#   measure-session-size.sh  # 기본: ~/.jarvis/context/
#
# 출력 예시:
#   {
#     "timestamp": "2026-06-14T09:00:00Z",
#     "session_path": "/Users/ramsbaby/jarvis/context",
#     "total_bytes": 524288,
#     "file_count": 42,
#     "estimated_tokens": 65000,
#     "files": [
#       {"name": "user-profile.md", "bytes": 4096, "tokens": 512},
#       ...
#     ]
#   }

set -euo pipefail

# 설정
SESSION_PATH="${1:-${HOME}/jarvis/runtime/state}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 함수: 파일 크기를 토큰으로 추정 (4 chars ≈ 1 token)
estimate_tokens() {
    local file_bytes=$1
    # 보수적 추정: 1 token ≈ 4 bytes (평균적 영문 기준)
    # Claude의 tokenizer는 더 복잡하지만, 진단용 추정값으로는 충분
    echo $((file_bytes / 4))
}

# 경로 검증
if [[ ! -d "$SESSION_PATH" ]]; then
    jq -n --arg path "$SESSION_PATH" --arg error "directory not found" \
        '{timestamp: $ENV.TIMESTAMP, error: $error, session_path: $path}' \
        TIMESTAMP="$TIMESTAMP"
    exit 1
fi

# 파일 목록 수집 및 크기 계산
total_bytes=0
file_count=0
files_json="[]"

while IFS= read -r -d '' file; do
    file_bytes=$(stat -f%z "$file" 2>/dev/null || echo 0)
    file_name=$(basename "$file")
    file_tokens=$(estimate_tokens "$file_bytes")

    total_bytes=$((total_bytes + file_bytes))
    file_count=$((file_count + 1))

    # JSON 배열에 파일 정보 추가
    files_json=$(jq \
        --arg name "$file_name" \
        --argjson bytes "$file_bytes" \
        --argjson tokens "$file_tokens" \
        '. += [{"name": $name, "bytes": $bytes, "tokens": $tokens}]' \
        <<<"$files_json")
done < <(find "$SESSION_PATH" -type f -print0 2>/dev/null)

# 전체 토큰 추정
total_tokens=$(estimate_tokens "$total_bytes")

# 최종 JSON 출력
jq -n \
    --arg timestamp "$TIMESTAMP" \
    --arg session_path "$SESSION_PATH" \
    --argjson total_bytes "$total_bytes" \
    --argjson file_count "$file_count" \
    --argjson estimated_tokens "$total_tokens" \
    --argjson files "$files_json" \
    '{
        timestamp: $timestamp,
        session_path: $session_path,
        total_bytes: $total_bytes,
        file_count: $file_count,
        estimated_tokens: $estimated_tokens,
        files: $files
    }'

exit 0
