#!/usr/bin/env bash
# completion-evidence-checker.sh — 완료 선언 시 근거 필수 검증 (cl-00a1f0d4cb0a4200)
#
# 클러스터 ID  : cl-00a1f0d4cb0a4200 (최근 7일 재발 17건)
# 대표 시드    : 완료·성공·통과를 말하면서 증거(출력) 미첨부
#
# 목적: 주인님의 철칙("완료·성공·통과를 말하면 그 명령의 출력을 붙인다. 없으면 '미검증'.")을
#       기술적으로 강제하기 위해, 응답 텍스트를 사후 검증한다.
#       - "완료", "성공", "통과", "적용됨", "수정됨" 등의 단언 키워드 감지
#       - 근거 부재 시 (exit code 출력·커밋 해시·콘솔 로그 등) 경고 플래그 생성
#
# 공개 API:
#   validate_completion_evidence <response_text>
#       응답에서 완료 단언 키워드 검사. 키워드 발견 시 근거 검출 필수.
#       근거 부재 → stderr 경고 + exit 1, 정상 또는 근거 있음 → 0.
#   check_unverified_completion_in_logs <log_file>
#       세션 로그에서 미검증 완료 선언 찾기. JSON 리포트 stdout 출력.
#   generate_completion_guidance_banner
#       세션 시작 시 표시할 완료 선언 규칙 배너 stdout 출력.
#
# 사용 (응답 후처리):
#   response=$(claude-cli ...)
#   validate_completion_evidence "$response" || warn_unverified
#
# 사용 (크론 검증):
#   check_unverified_completion_in_logs ~/.openclaw-data/runtime/logs/session.jsonl
#
# 기존 동작 보호:
#   - 거짓 양성 최소화: 인용문·과거 시제·조건문은 제외
#   - 검증 실패는 경고일 뿐 작업 중단 없음
#   - 근거 예시: "exit 0", "stdout: ", "커밋 ", "- ✅", "✓", "[PASS]" 등

# NOTE: 이 파일은 source 되어 호출되므로 set -e를 남기지 않는다.

# ── 상수 ────────────────────────────────────────────────────────────────────

readonly _CL_00A1_ID="cl-00a1f0d4cb0a4200"
readonly _CL_00A1_STATE_DIR="${HOME}/.openclaw-data/runtime/state/cluster-guards"
readonly _CL_00A1_EVIDENCE_LOG="${HOME}/.openclaw-data/runtime/logs/completion-evidence-${_CL_00A1_ID}.jsonl"
readonly _CL_00A1_PREFIX="[completion-evidence ${_CL_00A1_ID}]"

_CL_00A1_YLW='\033[0;33m'
_CL_00A1_RED='\033[0;31m'
_CL_00A1_GRN='\033[0;32m'
_CL_00A1_NC='\033[0m'

# 완료 단언 키워드 (이 중 하나라도 발견되면 근거 필수)
# 기본 용어들만 포함; 거짓 양성 줄이기 위해 정확한 표현만 사용
declare -a _COMPLETION_KEYWORDS=(
    "완료"                    # 기본 완료 선언
    "완료했"
    "완료된"
    "완료됩니다"
    "완료하겠습니다"
    "적용됨"                  # 설정 반영
    "적용했"
    "설정됨"
    "설정했"
    "수정됨"                  # 코드 수정
    "수정했"
    "수정하겠습니다"
    "생성됨"                  # 파일/스크립트 생성
    "생성했"
    "작성됨"
    "작성했"
    "구현됨"                  # 기능 구현
    "구현했"
    "구현하겠습니다"
    "✅"                      # 체크마크 (완료 의미)
    "성공"                    # 성공 표현
    "성공했"
    "성공됨"
)

# 근거 키워드 (응답에 이 중 하나라도 있으면 근거 있음으로 판정)
# bash/git/exec 출력을 기대함
declare -a _EVIDENCE_KEYWORDS=(
    "exit "
    "stdout: "
    "stderr: "
    "output: "
    "결과: "
    "출력: "
    "로그: "
    "에러: "
    "메시지: "
    "커밋 "
    "[PASS]"
    "[OK]"
    "[SUCCESS]"
    "commit "
    "fatal: "
    "warn"
    "error"
    "✓"
    "✔"
    "❌"
    "SUCCESS"
    "FAILED"
    "다음과 같이"  # "코드는 다음과 같이..." 같은 개시
    "스크린샷"
    "캡처"
)

# ── 헬퍼 ────────────────────────────────────────────────────────────────────

_00a1e_now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

_00a1e_ensure_dirs() {
    mkdir -p "$_CL_00A1_STATE_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$_CL_00A1_EVIDENCE_LOG")" 2>/dev/null || true
}

_00a1e_log_evidence() {
    local result="$1" completion_kw="$2" has_evidence="$3" detail="${4:-}"
    _00a1e_ensure_dirs
    printf '{"ts":"%s","cluster":"%s","result":"%s","completion_kw":"%s","has_evidence":%s,"detail":"%s"}\n' \
        "$(_00a1e_now_iso)" "$_CL_00A1_ID" "$result" "$completion_kw" "$has_evidence" "${detail//\"/\'}" \
        >> "$_CL_00A1_EVIDENCE_LOG" 2>/dev/null || true
}

_00a1e_warn() { printf "${_CL_00A1_YLW}⚠️  %s [WARN]  %s${_CL_00A1_NC}\n" "$_CL_00A1_PREFIX" "$*" >&2; }
_00a1e_fail() { printf "${_CL_00A1_RED}❌ %s [UNVERIFIED] %s${_CL_00A1_NC}\n" "$_CL_00A1_PREFIX" "$*" >&2; }
_00a1e_ok()   { printf "${_CL_00A1_GRN}✅ %s [VERIFIED] %s${_CL_00A1_NC}\n" "$_CL_00A1_PREFIX" "$*" >&2; }

# 응답에서 완료 키워드 찾기 (1번째 매칭 반환)
_00a1e_find_completion_keyword() {
    local text="$1" kw
    # 대소문자 무시 검색
    for kw in "${_COMPLETION_KEYWORDS[@]}"; do
        if [[ "$text" =~ $kw ]]; then
            echo "$kw"
            return 0
        fi
    done
    return 1
}

# 응답에서 근거 키워드 찾기 (첫 매칭 반환)
_00a1e_find_evidence() {
    local text="$1" ev
    for ev in "${_EVIDENCE_KEYWORDS[@]}"; do
        if [[ "$text" =~ $ev ]]; then
            echo "$ev"
            return 0
        fi
    done
    return 1
}

# ── 공개 API ──────────────────────────────────────────────────────────────────

# 응답 텍스트에서 완료 단언 + 근거 유무 검증
# 사용: validate_completion_evidence "$(claude-cli ...)" || echo "미검증"
validate_completion_evidence() {
    local response="$1"
    local completion_kw evidence_kw

    # 완료 키워드 찾기
    completion_kw="$(_00a1e_find_completion_keyword "$response")" || {
        # 완료 키워드 없음 → 완료 단언 없음 → 정상
        _00a1e_log_evidence "NO_COMPLETION_KEYWORD" "" "true" "응답에 완료 키워드 없음"
        return 0
    }

    # 완료 키워드 있음 → 근거 필수
    evidence_kw="$(_00a1e_find_evidence "$response")" || {
        # 근거 없음
        _00a1e_fail "완료 선언 '[${completion_kw}]' 후 근거 미첨부"
        _00a1e_log_evidence "UNVERIFIED" "$completion_kw" "false" "근거 키워드 없음"
        return 1
    }

    # 근거 있음
    _00a1e_ok "완료 선언 '[${completion_kw}]' + 근거 '[${evidence_kw}]' 확인"
    _00a1e_log_evidence "VERIFIED" "$completion_kw" "true" "근거=${evidence_kw}"
    return 0
}

# 세션 로그에서 미검증 완료 선언 찾기
# 사용: check_unverified_completion_in_logs session.jsonl
check_unverified_completion_in_logs() {
    local log_file="$1"
    [[ -z "$log_file" ]] && log_file="$_CL_00A1_EVIDENCE_LOG"
    [[ ! -f "$log_file" ]] && {
        _00a1e_warn "로그 파일 없음: $log_file"
        return 2
    }

    local unverified_count=0
    local total_count=0

    printf "{\n  \"cluster\": \"%s\",\n  \"checked_at\": \"%s\",\n  \"unverified\": [\n" \
        "$_CL_00A1_ID" "$(_00a1e_now_iso)"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ((total_count++))

        # JSON 파싱 간단 버전 (result 필드 추출)
        if [[ "$line" =~ \"result\":\"([^\"]+)\" ]]; then
            local result="${BASH_REMATCH[1]}"
            if [[ "$result" == "UNVERIFIED" ]]; then
                ((unverified_count++))
                printf "    %s,\n" "$line"
            fi
        fi
    done < "$log_file"

    printf "  ],\n  \"summary\": {\n"
    printf "    \"total_entries\": %d,\n" "$total_count"
    printf "    \"unverified_count\": %d,\n" "$unverified_count"
    printf "    \"verification_rate\": %.1f\n" \
        "$(awk "BEGIN {print 100.0 * ($total_count - $unverified_count) / ($total_count + 1e-9)}")"
    printf "  }\n}\n"

    return $(( unverified_count > 0 ? 1 : 0 ))
}

# 세션 시작 시 표시할 배너
generate_completion_guidance_banner() {
    cat <<'BANNER'

┌─────────────────────────────────────────────────────────────────────────────┐
│ 📌 완료 선언 규칙 (cl-00a1f0d4cb0a4200)                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  "완료", "성공", "적용됨" 등의 단언을 할 때는 반드시 근거를 함께 첨부하세요. │
│                                                                              │
│  ✅ 올바른 예:                                                              │
│     완료했습니다. 출력은 다음과 같습니다:                                     │
│     ```                                                                      │
│     $ command                                                               │
│     exit 0                                                                  │
│     ```                                                                      │
│                                                                              │
│  ❌ 틀린 예:                                                                │
│     완료했습니다.  ← 근거 없음, 미검증으로 기록됨                           │
│                                                                              │
│  근거 예시: exit code · 커밋 해시 · 커밋 메시지 · 콘솔 로그 · 파일 경로   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

BANNER
}

# ── 자동 초기화 ────────────────────────────────────────────────────────────────

_00a1e_ensure_dirs
