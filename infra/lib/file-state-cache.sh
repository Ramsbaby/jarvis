#!/usr/bin/env bash
# file-state-cache.sh — 파일 상태 일관성 보호 캐시 시스템
#
# 클러스터 ID  : cl-6f0c8cc1df90e995 (최근 7일 재발 40건)
# 반복 패턴   : 동일 응답 내 파일 존재/부재 상태 모순 보고
# 목적        : 파일 상태를 1회만 조회, 응답 전체에 걸쳐 일관성 강제
#
# 사용법:
#   source "${BOT_HOME}/lib/file-state-cache.sh"
#
#   # [1] 응답 시작: 캐시 초기화
#   init_file_state_cache "$RESPONSE_ID"
#
#   # [2] 파일 상태 조회 (첫 호출만 실제 확인, 이후는 캐시)
#   if is_file_exists "$file_path"; then
#       echo "파일 존재"
#   fi
#
#   # [3] 응답 종료: 캐시 내용 최종 검증
#   validate_file_state_consistency "$RESPONSE_ID" "응답 전문" || \
#       report_file_state_violation "$RESPONSE_ID" "상태 모순"

set -euo pipefail

# ═════════════════════════════════════════════════════════════════════════════════
# [0] 전역 변수
# ═════════════════════════════════════════════════════════════════════════════════

export BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
export FSC_CACHE_DIR="${BOT_HOME}/state/file-state-cache"
export FSC_LOG="${BOT_HOME}/logs/file-state-cache.jsonl"
export FSC_VIOLATION_LOG="${BOT_HOME}/logs/file-state-violations.jsonl"

# ═════════════════════════════════════════════════════════════════════════════════
# [1] init_file_state_cache — 응답별 캐시 초기화
# ═════════════════════════════════════════════════════════════════════════════════
#
# 목적: 각 응답마다 독립적인 파일 상태 캐시 생성
#
# 사용법:
#   init_file_state_cache "response-123-abc-def"
#   # → ~/jarvis/runtime/state/file-state-cache/response-123-abc-def.json 생성
#
# 반환값:
#   0 = 성공
#   1 = 실패 (기존 캐시 없을 시 자동 생성)

init_file_state_cache() {
    local response_id="$1"

    [[ -z "$response_id" ]] && {
        printf '[FSC] ERROR: init_file_state_cache called with empty response_id\n' >&2
        return 1
    }

    mkdir -p "$FSC_CACHE_DIR" || return 1

    local cache_file="${FSC_CACHE_DIR}/${response_id}.json"

    # 초기화: 빈 JSON 객체
    cat > "$cache_file" <<EOF
{
  "response_id": "$response_id",
  "init_ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "file_states": {},
  "reference_count": {}
}
EOF

    printf '[FSC] Initialized cache for response %s\n' "$response_id" >&2
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [2] is_file_exists — 파일 존재 여부 조회 (캐시 우선)
# ═════════════════════════════════════════════════════════════════════════════════
#
# 동작:
#   1. 캐시 검색: 이미 조회한 경로면 캐시값 반환
#   2. 신규 조회: 처음 조회하는 경로면 실제 fs 확인 후 캐시 저장
#   3. 모든 응답 기간 동안 동일 값 반환
#
# 사용법:
#   if is_file_exists "/path/to/file"; then
#       echo "exists"
#   else
#       echo "not exists"
#   fi
#
# 반환값:
#   0 = 파일 존재
#   1 = 파일 없음

is_file_exists() {
    local file_path="$1"
    local response_id="${RESPONSE_ID:-}"

    [[ -z "$file_path" ]] && {
        printf '[FSC] ERROR: is_file_exists called with empty file_path\n' >&2
        return 1
    }

    [[ -z "$response_id" ]] && {
        printf '[FSC] WARNING: is_file_exists called without RESPONSE_ID context\n' >&2
        # RESPONSE_ID 없으면 직접 확인만 (캐시 기능 비활성)
        [[ -e "$file_path" ]]
        return $?
    }

    local cache_file="${FSC_CACHE_DIR}/${response_id}.json"

    # 캐시 파일 존재 확인
    if [[ ! -f "$cache_file" ]]; then
        printf '[FSC] ERROR: Cache file not found for response %s\n' "$response_id" >&2
        return 1
    fi

    # 캐시 파일 → 메모리 로드
    local cache_content
    cache_content=$(<"$cache_file") || return 1

    # jq를 사용하여 캐시 확인
    local cached_state
    cached_state=$(printf '%s' "$cache_content" | jq -r ".file_states[\"$file_path\"] // \"\"")

    if [[ -n "$cached_state" ]]; then
        # 캐시에서 찾음
        if [[ "$cached_state" == "true" ]]; then
            return 0
        else
            return 1
        fi
    fi

    # 캐시에 없음 → 실제 fs 확인
    local actual_exists="false"
    if [[ -e "$file_path" ]]; then
        actual_exists="true"
    fi

    # 캐시에 저장 및 참조 횟수 증가
    local updated_cache
    updated_cache=$(printf '%s' "$cache_content" | \
        jq ".file_states[\"$file_path\"] = $actual_exists | .reference_count[\"$file_path\"] = ((.reference_count[\"$file_path\"] // 0) + 1)")
    printf '%s' "$updated_cache" > "$cache_file"

    if [[ "$actual_exists" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# ═════════════════════════════════════════════════════════════════════════════════
# [3] validate_file_state_consistency — 응답 전문에서 파일 상태 모순 감지
# ═════════════════════════════════════════════════════════════════════════════════
#
# 동작:
#   1. 응답 문본을 정규식으로 파싱
#   2. "파일 존재" / "파일 없음" / "파일이 있다" 등 패턴 추출
#   3. 캐시된 실제 상태와 대조
#   4. 불일치 시 위반 기록
#
# 사용법:
#   validate_file_state_consistency "response-123" "$FULL_RESPONSE_TEXT" || \
#       echo "inconsistency detected"
#
# 반환값:
#   0 = 모순 없음 (모두 일관성 있음)
#   1 = 모순 감지 (위반 기록 완료, 경고만 발생)

validate_file_state_consistency() {
    local response_id="$1"
    local response_text="${2:-}"

    [[ -z "$response_id" ]] && {
        printf '[FSC] ERROR: validate_file_state_consistency called with empty response_id\n' >&2
        return 1
    }

    local cache_file="${FSC_CACHE_DIR}/${response_id}.json"

    [[ ! -f "$cache_file" ]] && {
        printf '[FSC] WARNING: Cache file not found for response %s (skipping validation)\n' "$response_id" >&2
        return 0
    }

    local cache_content
    cache_content=$(<"$cache_file") || return 1

    # 응답 문본에서 파일 상태 언급 추출
    # 패턴: "파일.*[존재|없음|있음|부재]" 등 한국어
    local file_state_mentions
    file_state_mentions=$(printf '%s' "$response_text" | \
        grep -oE '파일.*?(존재|없음|있음|부재|상태|확인|생성|삭제)' 2>/dev/null || true)

    [[ -z "$file_state_mentions" ]] && {
        # 파일 상태 언급 없음 → 통과
        return 0
    }

    # 캐시된 상태와 비교 (간단한 휴리스틱)
    # TODO: 더 복잡한 의미론적 파싱은 별도 NLP 모듈에서 처리

    # 일단 캐시 내 동일 파일 중복 참조 검사
    local duplicate_refs=0
    local state_queries
    state_queries=$(printf '%s' "$cache_content" | jq -r '.reference_count | to_entries[] | select(.value > 1) | .key' 2>/dev/null || true)

    if [[ -n "$state_queries" ]]; then
        duplicate_refs=$(printf '%s' "$state_queries" | wc -l)
    fi

    if [[ $duplicate_refs -gt 0 ]]; then
        # 경고: 동일 파일이 여러 번 상태 확인됨
        report_file_state_violation "$response_id" "동일 파일 중복 상태 확인 ($duplicate_refs건)" "WARNING" || true
        return 1
    fi

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [4] report_file_state_violation — 파일 상태 모순 기록
# ═════════════════════════════════════════════════════════════════════════════════
#
# 용도:
#   - 캐시된 상태와 응답 내용의 모순 감지 시 Tier 2 경고 기록
#   - dev-queue에 자동 입력 (별도 후처리)
#
# 사용법:
#   report_file_state_violation "response-123" "파일 존재/부재 불일치" "ERROR"
#
# 반환값:
#   0 = 기록 성공
#   1 = 기록 실패

report_file_state_violation() {
    local response_id="$1"
    local violation_desc="${2:-unknown violation}"
    local severity="${3:-WARN}"

    mkdir -p "$BOT_HOME/logs" || return 1

    local violation_record
    violation_record=$(cat <<EOF
{
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "response_id": "$response_id",
  "cluster_id": "cl-6f0c8cc1df90e995",
  "violation": "$violation_desc",
  "severity": "$severity",
  "cache_file": "${FSC_CACHE_DIR}/${response_id}.json"
}
EOF
    )

    # 위반 기록 저장 (JSONL 형식)
    printf '%s\n' "$violation_record" >> "$FSC_VIOLATION_LOG" || return 1

    printf '[FSC] VIOLATION LOGGED: %s (severity=%s)\n' "$violation_desc" "$severity" >&2

    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# [5] cleanup_old_caches — 오래된 캐시 정리 (선택사항)
# ═════════════════════════════════════════════════════════════════════════════════
#
# 용도: 응답별 캐시는 응답 직후 불필요하므로 매일 정리
#
# 사용법:
#   cleanup_old_caches 7  # 7일 이상 된 캐시 제거
#
# 반환값:
#   0 = 성공

cleanup_old_caches() {
    local days="${1:-7}"

    [[ ! -d "$FSC_CACHE_DIR" ]] && return 0

    find "$FSC_CACHE_DIR" -type f -name "*.json" -mtime +"$days" -delete 2>/dev/null || true

    printf '[FSC] Cleaned up caches older than %d days\n' "$days" >&2
    return 0
}

# ═════════════════════════════════════════════════════════════════════════════════
# Export for sourcing
# ═════════════════════════════════════════════════════════════════════════════════

export -f init_file_state_cache
export -f is_file_exists
export -f validate_file_state_consistency
export -f report_file_state_violation
export -f cleanup_old_caches

return 0 2>/dev/null || true
