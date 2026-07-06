#!/usr/bin/env bash
# mistake-guard-wrapper.sh — 세션 초기화 및 가드 자동 실행 래퍼 (cl-a3200445ee1623e8)
#
# 목적: mistake-promoter 를 통해 할당된 tier_b 작업 시
#       - 학생 메모리 자동 로드 및 주입
#       - 가드 체크리스트 자동 실행 (응답 생성 전)
#       - 기존 mistake-promoter 동작 무손상 확인
#
# 사용법:
#   source mistake-guard-wrapper.sh
#   guard_init_session <student_id>
#   guard_check_response <response_text> <student_id> [context_json]
#
# 환경 변수:
#   MISTAKE_GUARD_ENABLED: true|false (기본: true)
#   MISTAKE_GUARD_STRICT: true|false (기본: false — WARN 무시)

set -euo pipefail

# ─── 경로 상수 ───
export JARVIS_HOME="${JARVIS_HOME:=${HOME}/jarvis}"
export JARVIS_INFRA="${JARVIS_INFRA:=${HOME}/jarvis/infra}"
MEMORY_MANAGER="${JARVIS_INFRA}/lib/student-memory-manager.mjs"
GUARD_CHECKER="${JARVIS_INFRA}/lib/mistake-guard-checker.mjs"
RULES_FILE="${JARVIS_INFRA}/lib/mistake-guard-rules.md"
MEMORY_DIR="${JARVIS_HOME}/runtime/state/student-memory"
GUARD_LOG="${JARVIS_HOME}/runtime/logs/mistake-guard.log"

# ─── 정책 상수 ───
MISTAKE_GUARD_ENABLED="${MISTAKE_GUARD_ENABLED:-true}"
MISTAKE_GUARD_STRICT="${MISTAKE_GUARD_STRICT:-false}"

# ─── 로깅 ───
function guard_log() {
    local msg="$1"
    local ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "[$ts] $msg" | tee -a "$GUARD_LOG" >&2
}

# ─── 세션 초기화 (학생 메모리 로드) ───
# guard_init_session <student_id>
function guard_init_session() {
    local student_id="${1:?'student_id 필수'}"

    if [[ "$MISTAKE_GUARD_ENABLED" != "true" ]]; then
        guard_log "[SKIP] 가드 비활성화 상태"
        return 0
    fi

    guard_log "[INIT] 세션 시작: student_id=$student_id"

    # 메모리 매니저 확인
    if [[ ! -f "$MEMORY_MANAGER" ]]; then
        guard_log "[ERROR] 메모리 매니저 없음: $MEMORY_MANAGER"
        return 1
    fi

    # 메모리 로드 (없으면 템플릿 생성)
    local mem_file="$MEMORY_DIR/${student_id}.json"
    if [[ ! -f "$mem_file" ]]; then
        guard_log "[WARN] 메모리 파일 없음 — 템플릿 생성: $student_id"
        node "$MEMORY_MANAGER" init-template --student-id "$student_id" || {
            guard_log "[ERROR] 템플릿 생성 실패"
            return 1
        }
    fi

    # 메모리 로드 및 변수에 저장
    local memory_json
    memory_json=$(node "$MEMORY_MANAGER" load --student-id "$student_id" 2>/dev/null) || {
        guard_log "[ERROR] 메모리 로드 실패: $student_id"
        return 1
    }

    # 환경 변수로 내보내기 (세션 컨텍스트)
    export GUARD_SESSION_STUDENT_ID="$student_id"
    export GUARD_SESSION_MEMORY="$memory_json"
    export GUARD_SESSION_STARTED=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    guard_log "[OK] 세션 초기화 완료: $student_id (메모리 로드, 가드 활성화)"
    return 0
}

# ─── 응답 검증 (가드 체크리스트 실행) ───
# guard_check_response <response_text> <student_id> [context_json]
# 반환: 0 (PASS|WARN), 1 (FAIL)
function guard_check_response() {
    local response="${1:?'response 필수'}"
    local student_id="${2:?'student_id 필수'}"
    local context="${3:-}"

    if [[ "$MISTAKE_GUARD_ENABLED" != "true" ]]; then
        return 0
    fi

    if [[ ! -f "$GUARD_CHECKER" ]]; then
        guard_log "[ERROR] 체크 스크립트 없음: $GUARD_CHECKER"
        return 0  # 체크 불가 시에도 진행 (안전 장치)
    fi

    # 임시 파일에 응답 저장 (셸 인젝션 방어)
    local tmp_resp tmp_ctx
    tmp_resp=$(mktemp)
    tmp_ctx=$(mktemp)
    trap "rm -f $tmp_resp $tmp_ctx" RETURN

    echo "$response" > "$tmp_resp"

    # 컨텍스트 JSON 준비
    if [[ -n "$context" ]]; then
        echo "$context" > "$tmp_ctx"
    else
        # 기본 컨텍스트: 메모리에서 추출
        if [[ -n "${GUARD_SESSION_MEMORY:-}" ]]; then
            # 메모리의 이전 세션들을 컨텍스트로 포함
            echo "$GUARD_SESSION_MEMORY" > "$tmp_ctx"
        else
            echo '{}' > "$tmp_ctx"
        fi
    fi

    # guard-checker 실행
    local check_result
    check_result=$(node "$GUARD_CHECKER" \
        --response "$(cat "$tmp_resp")" \
        --context "$(cat "$tmp_ctx")" \
        --student-id "$student_id" 2>/dev/null) || {
        guard_log "[ERROR] 가드 체크 실행 실패"
        return 0  # 실패해도 진행
    }

    # 결과 파싱
    local overall
    overall=$(echo "$check_result" | jq -r '.overall // "UNKNOWN"' 2>/dev/null)

    # 로그 기록
    guard_log "[CHECK] cluster=cl-a3200445ee1623e8 student=$student_id overall=$overall"

    # 상세 결과 로깅
    if [[ "$overall" == "FAIL" ]]; then
        local failures
        failures=$(echo "$check_result" | jq -r '.checks[] | select(.status=="FAIL") | "\(.rule_id): \(.message)"' 2>/dev/null)
        if [[ -n "$failures" ]]; then
            guard_log "[FAIL] 실패 항목:"
            while IFS= read -r line; do
                guard_log "  - $line"
            done <<< "$failures"
        fi

        if [[ "$MISTAKE_GUARD_STRICT" == "true" ]]; then
            guard_log "[STRICT] 엄격 모드 활성화 — FAIL 시 차단"
            return 1
        fi
    elif [[ "$overall" == "WARN" ]]; then
        local warnings
        warnings=$(echo "$check_result" | jq -r '.checks[] | select(.status=="WARN") | "\(.rule_id): \(.message)"' 2>/dev/null)
        if [[ -n "$warnings" ]]; then
            guard_log "[WARN] 경고 항목:"
            while IFS= read -r line; do
                guard_log "  - $line"
            done <<< "$warnings"
        fi
    else
        guard_log "[PASS] 모든 가드 통과"
    fi

    # 체크 결과를 JSON으로 저장 (나중에 회고용)
    mkdir -p "$(dirname "$GUARD_LOG")"
    echo "$check_result" | jq ". + {session_id: \"$GUARD_SESSION_STUDENT_ID\", checked_at: \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}" >> "${GUARD_LOG%.log}.jsonl" 2>/dev/null || true

    # 엄격 모드가 아니면 항상 0 반환 (경고만으로는 진행)
    [[ "$overall" == "FAIL" && "$MISTAKE_GUARD_STRICT" == "true" ]] && return 1
    return 0
}

# ─── 세션 종료 (상호작용 기록 저장) ───
# guard_end_session <student_id> <interaction_json>
function guard_end_session() {
    local student_id="${1:?'student_id 필수'}"
    local interaction="${2:-}"

    if [[ "$MISTAKE_GUARD_ENABLED" != "true" ]]; then
        return 0
    fi

    guard_log "[END] 세션 종료: $student_id"

    # 상호작용 기록 저장
    if [[ -n "$interaction" ]]; then
        node "$MEMORY_MANAGER" add-session \
            --student-id "$student_id" \
            --interaction "$interaction" || {
            guard_log "[WARN] 세션 기록 저장 실패"
        }
    fi

    # 세션 환경 변수 정리
    unset GUARD_SESSION_STUDENT_ID GUARD_SESSION_MEMORY GUARD_SESSION_STARTED

    return 0
}

# ─── 초기화 확인 (backward compatibility check) ───
# guard_check_init: 기존 시스템 동작 확인
function guard_check_init() {
    local issues=()

    guard_log "[CHECK_INIT] 시스템 준비 상태 확인"

    # 필수 파일 확인
    [[ -f "$MEMORY_MANAGER" ]] || issues+=("메모리 매니저 없음")
    [[ -f "$GUARD_CHECKER" ]] || issues+=("가드 체커 없음")
    [[ -f "$RULES_FILE" ]] || issues+=("규칙 파일 없음")

    # 기존 mistake-promoter 스크립트 확인
    local promoter_script="${JARVIS_INFRA}/scripts/mistake-promoter.mjs"
    [[ -f "$promoter_script" ]] || issues+=("mistake-promoter.mjs 없음")

    if [[ ${#issues[@]} -gt 0 ]]; then
        guard_log "[ERROR] 초기화 실패:"
        for issue in "${issues[@]}"; do
            guard_log "  - $issue"
        done
        return 1
    fi

    guard_log "[OK] 모든 컴포넌트 준비 완료"
    return 0
}

# ─── 로그 디렉토리 보장 ───
mkdir -p "$(dirname "$GUARD_LOG")"

export -f guard_log guard_init_session guard_check_response guard_end_session guard_check_init
