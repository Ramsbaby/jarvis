#!/usr/bin/env bash
# test-mistake-guard-e2e.sh — E2E 테스트 스위트 (cl-a3200445ee1623e8)
#
# 목적: 클러스터 대표 사례들(인자순서, 포맷, 자격증, 모순, 이력)에 대해
#       가드가 제대로 감지·교정하는지 검증
#
# 사용법:
#   bash test-mistake-guard-e2e.sh [--verbose] [--student-id <id>] [--stop-on-fail]

set -euo pipefail

# ─── 경로 상수 ───
JARVIS_HOME="${HOME}/.jarvis"
JARVIS_INFRA="${JARVIS_HOME}/infra"
GUARD_CHECKER="${JARVIS_INFRA}/lib/mistake-guard-checker.mjs"
MEMORY_MANAGER="${JARVIS_INFRA}/lib/student-memory-manager.mjs"
WRAPPER="${JARVIS_INFRA}/lib/mistake-guard-wrapper.sh"
RULES_FILE="${JARVIS_INFRA}/lib/mistake-guard-rules.md"

# ─── CLI 파싱 ───
VERBOSE=false
STUDENT_ID="test-e2e-$(date +%s)"
STOP_ON_FAIL=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose) VERBOSE=true; shift ;;
        --student-id) STUDENT_ID="$2"; shift 2 ;;
        --stop-on-fail) STOP_ON_FAIL=true; shift ;;
        *) shift ;;
    esac
done

# ─── 로깅 ───
function log_info() {
    echo "[INFO] $*" >&2
}

function log_pass() {
    echo "✓ $*" >&2
}

function log_fail() {
    echo "✗ $*" >&2
}

function log_verbose() {
    [[ "$VERBOSE" == "true" ]] && echo "[VERBOSE] $*" >&2 || true
}

# ─── 테스트 카운터 ───
TOTAL=0
PASSED=0
FAILED=0

# ─── 테스트 함수 ───
# test_case <name> <response> <expected_status> [context_json]
function test_case() {
    local name="$1"
    local response="$2"
    local expected_status="$3"
    local context="${4:-}"

    TOTAL=$((TOTAL + 1))
    log_info "테스트 #$TOTAL: $name"

    # 응답 검사 (임시 파일 경유로 쉘 인젝션 방지)
    local tmp_resp tmp_ctx result_json
    tmp_resp=$(mktemp)
    tmp_ctx=$(mktemp)
    trap "rm -f $tmp_resp $tmp_ctx" RETURN
    echo "$response" > "$tmp_resp"
    [ -n "$context" ] && echo "$context" > "$tmp_ctx" || echo '{}' > "$tmp_ctx"

    result_json=$(node "$GUARD_CHECKER" \
        --response "$(cat "$tmp_resp")" \
        --student-id "$STUDENT_ID" \
        --context "$(cat "$tmp_ctx")" \
        2>/dev/null)

    local overall
    overall=$(echo "$result_json" | jq -r '.overall // "UNKNOWN"')

    log_verbose "응답 길이: ${#response}"
    log_verbose "검사 결과: $overall"

    if [[ "$overall" == "$expected_status" ]]; then
        PASSED=$((PASSED + 1))
        log_pass "$name → $overall"
    else
        FAILED=$((FAILED + 1))
        log_fail "$name → expected $expected_status, got $overall"
        if $VERBOSE; then
            echo "$result_json" | jq '.' >&2
        fi
        if [[ "$STOP_ON_FAIL" == "true" ]]; then
            exit 1
        fi
    fi
}

# ─── E2E 테스트 스위트 ───

log_info "================================"
log_info "오답 승격 가드 E2E 테스트"
log_info "클러스터: cl-a3200445ee1623e8"
log_info "학생: $STUDENT_ID"
log_info "================================"

# 메모리 초기화
log_info "학생 메모리 초기화..."
node "$MEMORY_MANAGER" init-template --student-id "$STUDENT_ID" > /dev/null 2>&1

# ────────────────────────────────────────────────────────────────
# 테스트 1: 인자 순서 검증 (rule-arg-order)
# ────────────────────────────────────────────────────────────────

log_info ""
log_info "테스트 세트 1: 인자 순서 (rule-arg-order)"

test_case \
    "정상 git commit 명령" \
    "다음 명령을 실행하세요: git commit -m \"메시지\" --amend" \
    "PASS"

test_case \
    "npm install 정상 사용" \
    "패키지 설치: npm install express --save" \
    "PASS"

test_case \
    "함수 호출 정상" \
    "함수를 호출합니다: processData(input, output, options)" \
    "PASS"

# ────────────────────────────────────────────────────────────────
# 테스트 2: 포맷 규칙 일관성 (rule-format-consistency)
# ────────────────────────────────────────────────────────────────

log_info ""
log_info "테스트 세트 2: 포맷 일관성 (rule-format-consistency)"

test_case \
    "일관된 마크다운 포맷" \
    "## 섹션 1
- 항목 1
- 항목 2

## 섹션 2
- 항목 3
- 항목 4" \
    "PASS"

test_case \
    "포맷 불일치 (나열 기호)" \
    "## 지시사항
- 단계 1
* 단계 2
+ 단계 3" \
    "WARN"

# ────────────────────────────────────────────────────────────────
# 테스트 3: 자격증 난이도 기준 (rule-cert-level)
# ────────────────────────────────────────────────────────────────

log_info ""
log_info "테스트 세트 3: 자격증 난이도 기준 (rule-cert-level)"

test_case \
    "완전한 자격증 제안 (학생레벨 + 근거)" \
    "당신의 중급 수준으로는 TOEFL이 적합합니다. 이는 대학 진학에 필수이기 때문입니다." \
    "PASS"

test_case \
    "절대 난이도만 언급" \
    "TOEFL은 어렵지 않은 시험입니다. 많은 학생들이 합격합니다." \
    "FAIL"

test_case \
    "자격증 제안 근거 없음" \
    "TOEFL을 준비하세요." \
    "FAIL"

test_case \
    "올바른 상대 난이도 제안" \
    "현재 당신의 초급 수준에서는 기초 영어 교재(A1)부터 시작하시는 것이 권장됩니다. 이렇게 하면 탄탄한 기초를 쌓을 수 있기 때문입니다." \
    "PASS"

# ────────────────────────────────────────────────────────────────
# 테스트 4: 세션 모순 검증 (rule-session-consistency)
# ────────────────────────────────────────────────────────────────

log_info ""
log_info "테스트 세트 4: 세션 모순 검증 (rule-session-consistency)"

test_case \
    "이전 응답 없을 때 (모순 검증 불필요)" \
    "이것은 일반적인 응답입니다." \
    "PASS"

test_case \
    "모순 가능성 있음" \
    "앞서 확인했던 내용에 대해 저는 알 수 없습니다." \
    "WARN" \
    '{"previous_responses":["결론: 당신은 중급 수준입니다"]}'

# ────────────────────────────────────────────────────────────────
# 테스트 5: 학생 메모리 주입 (rule-student-sso-memory)
# ────────────────────────────────────────────────────────────────

log_info ""
log_info "테스트 세트 5: 학생 메모리 주입 (rule-student-sso-memory)"

test_case \
    "메모리 파일이 있고 응답에서 참조" \
    "저번에 확인하신 것처럼 당신의 목표는 TOEFL 합격입니다." \
    "PASS" \
    "{\"student_id\":\"$STUDENT_ID\"}"

test_case \
    "메모리 파일 있지만 응답에서 미참조" \
    "새로운 목표를 생각해보세요." \
    "WARN" \
    "{\"student_id\":\"$STUDENT_ID\"}"

# ────────────────────────────────────────────────────────────────
# 통합 테스트: 실제 클러스터 시나리오
# ────────────────────────────────────────────────────────────────

log_info ""
log_info "테스트 세트 6: 통합 시나리오 (실제 오답 패턴)"

test_case \
    "시나리오: 인자순서 오류 + 포맷 불일치 + 자격증 절대난이도" \
    "다음을 실행하세요: npm install --save express
- 자격증을 추천합니다: TOEFL은 어렵지 않습니다.
* 강좌를 등록하세요" \
    "FAIL"

test_case \
    "시나리오: 모든 가드 통과" \
    "## 제안

당신의 중급 수준에 맞춰 다음을 추천합니다:

- TOEFL: 대학 진학에 필요하기 때문에 적합합니다
- 온라인 강좌: 주 3시간씩 학습하면 효과적입니다

설치 명령: npm install --save-dev jest" \
    "PASS"

# ────────────────────────────────────────────────────────────────
# 결과 출력
# ────────────────────────────────────────────────────────────────

log_info ""
log_info "================================"
log_info "테스트 결과"
log_info "================================"
log_info "총합: $TOTAL"
log_info "통과: $PASSED ✓"
log_info "실패: $FAILED ✗"
log_info ""

if [[ $FAILED -eq 0 ]]; then
    log_pass "모든 E2E 테스트 통과! 🎉"
    echo "cl-a3200445ee1623e8" > /tmp/e2e-test-result.txt
    exit 0
else
    log_fail "일부 테스트 실패 (통과율: $((PASSED * 100 / TOTAL))%)"
    exit 1
fi
