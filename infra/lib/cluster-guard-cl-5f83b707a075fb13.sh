#!/usr/bin/env bash
# cluster-guard-cl-5f83b707a075fb13.sh — 메타인지 실패 방어 가드
#
# 클러스터 ID  : cl-5f83b707a075fb13 (최근 7일 재발 5건)
# 대표 시드    : 규칙 탓으로 단정한 후 실측으로 정정 (메타인지 실패)
# 멤버 패턴    :
#   - 규칙 탓으로 단정한 후 실측으로 정정 (메타인지 실패)
#   - 메타인지 요청 후에도 첫 진단을 재검증하지 않음
#   - 단계별 검증 절차 생략 — 1~2단계 충분하지 않아 중도 재정정
#   - 코드 구조 파악 전 문제 단언 (경로 필터링 미인지)
#   - 편향 과다, 불완전한 초기 응답으로 반복 수정 유도
#
# 공개 API:
#   meta_check_detect_signal <prompt>
#       — 프롬프트에서 '다시 확인해봐' 류 메타인지 요청 신호 감지
#       — 반환: 0=신호 감지, 1=신호 없음
#
#   meta_check_inject_guardrail <task_id> [system_prompt_var=SYSTEM_PROMPT]
#       — 신호 감지 시 SYSTEM_PROMPT에 가정 명시 강제 섹션 주입
#       — 반환: 0=주입됨, 1=신호 없음(미주입)
#
#   meta_check_validate_response <task_id> <result_text>
#       — 신호가 있었을 때 응답에 핵심 가정 명시 여부 검증 (경고만, 차단 없음)
#       — 반환: 0=검증 통과, 1=가정 명시 없음(경고)
#
#   guard_cl_5f83b_status
#       — 현재 가드 상태 요약 출력
#
# 사용:
#   source ~/.openclaw-data/runtime/lib/cluster-guard-cl-5f83b707a075fb13.sh
#   if meta_check_detect_signal "$PROMPT"; then
#       meta_check_inject_guardrail "$TASK_ID"
#   fi
#   # ... claude 실행 후 ...
#   meta_check_validate_response "$TASK_ID" "$RESULT" || true
#
# 기존 동작 보호: 차단 없음. 경고는 stderr, 로그는 JSONL. 모든 호출은 || true 권장.

set -o pipefail

# ── 상수 ────────────────────────────────────────────────────────────────────

readonly _CL_5F83_ID="cl-5f83b707a075fb13"
readonly _CL_5F83_STATE_DIR="${HOME}/.openclaw-data/runtime/state/cluster-guards"
readonly _CL_5F83_LOG="${HOME}/.openclaw-data/runtime/logs/cluster-guard-${_CL_5F83_ID}.jsonl"
readonly _CL_5F83_SIGNAL_MARKER_DIR="${_CL_5F83_STATE_DIR}/${_CL_5F83_ID}-signals"
readonly _CL_5F83_PREFIX="[meta-check ${_CL_5F83_ID}]"

# 메타인지 요청 신호 패턴 (한국어 중심, 영어 보조)
# '다시 확인', '재확인', '한번 더 봐', '정말?', '확실해?' 등
readonly _CL_5F83_SIGNAL_PATTERNS=(
    "다시 확인"
    "재확인"
    "다시 봐"
    "다시 검토"
    "재검토"
    "다시 생각"
    "다시 보"
    "한번 더 봐"
    "한 번 더 봐"
    "다시 한번"
    "다시 한 번"
    "정말 맞아"
    "정말이야"
    "확실해"
    "맞는거야"
    "맞는 거야"
    "진짜야"
    "재고"
    "다시 점검"
    "다시 진단"
    "초기 진단"
    "첫 번째 진단"
    "처음 답"
    "첫 답"
    "다시 체크"
    "check again"
    "double.check"
    "re.verify"
    "are you sure"
    "think again"
    "reconsider"
    "re-examine"
)

# ── 내부 헬퍼 ───────────────────────────────────────────────────────────────

_5f83_now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

_5f83_ensure_dirs() {
    mkdir -p "$_CL_5F83_STATE_DIR" "$_CL_5F83_SIGNAL_MARKER_DIR" 2>/dev/null || true
    mkdir -p "$(dirname "$_CL_5F83_LOG")" 2>/dev/null || true
}

_5f83_log() {
    local level="$1" task_id="$2" detail="$3" extra="${4:-}"
    _5f83_ensure_dirs
    printf '{"ts":"%s","cluster":"%s","level":"%s","task_id":"%s","detail":"%s","extra":"%s"}\n' \
        "$(_5f83_now_iso)" "$_CL_5F83_ID" "$level" "$task_id" \
        "${detail//\"/\'}" "${extra//\"/\'}" \
        >> "$_CL_5F83_LOG" 2>/dev/null || true
}

_5f83_warn() { printf '⚠️  %s [WARN]  %s\n' "$_CL_5F83_PREFIX" "$*" >&2; }
_5f83_info() { printf 'ℹ️  %s [INFO]  %s\n' "$_CL_5F83_PREFIX" "$*" >&2; }
_5f83_ok()   { printf '✅ %s [OK]    %s\n' "$_CL_5F83_PREFIX" "$*" >&2; }

# 신호 감지 마커 경로 반환
_5f83_signal_marker() {
    local task_id="$1"
    echo "${_CL_5F83_SIGNAL_MARKER_DIR}/${task_id}.signal"
}

# ── 공개 API: 0. meta_check_is_forced ──────────────────────────────────────
#
# meta_check_is_forced
#
# JARVIS_META_CHECK=1 환경변수가 설정된 경우 강제 트리거 상태를 반환한다.
# ask-claude.sh --meta-check 플래그 구현체 (env-var 방식).
# 반환: 0=강제 트리거 활성, 1=비활성
meta_check_is_forced() {
    if [[ "${JARVIS_META_CHECK:-0}" == "1" ]]; then
        _5f83_info "강제 트리거 활성 (JARVIS_META_CHECK=1)"
        return 0
    fi
    return 1
}

# ── 공개 API: 1. meta_check_detect_signal ───────────────────────────────────
#
# meta_check_detect_signal <prompt>
#
# 프롬프트에서 메타인지 요청 신호를 감지한다.
# JARVIS_META_CHECK=1 환경변수가 설정되면 신호 감지로 간주한다 (강제 트리거).
# 감지된 패턴을 stderr에 알리고 0을 반환.
# 반환: 0=신호 감지됨, 1=신호 없음
meta_check_detect_signal() {
    local prompt="$1"

    # 강제 트리거 환경변수 우선 체크
    if meta_check_is_forced 2>/dev/null; then
        return 0
    fi

    if [[ -z "$prompt" ]]; then
        return 1
    fi

    local lower_prompt
    lower_prompt=$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')

    for pattern in "${_CL_5F83_SIGNAL_PATTERNS[@]}"; do
        local lower_pattern
        lower_pattern=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')
        if printf '%s' "$lower_prompt" | grep -qF "$lower_pattern" 2>/dev/null; then
            _5f83_info "메타인지 신호 감지: '${pattern}'"
            return 0
        fi
    done

    return 1
}

# ── 공개 API: 2. meta_check_get_guardrail_section ───────────────────────────
#
# meta_check_get_guardrail_section
#
# 가드레일 섹션 텍스트를 stdout으로 출력한다.
# 호출자가 직접 SYSTEM_PROMPT+="$(meta_check_get_guardrail_section)" 으로 주입.
meta_check_get_guardrail_section() {
    printf '%s\n' \
        '<!-- SECTION:meta-check-cl-5f83b707a075fb13:DYNAMIC -->' \
        '## 메타인지 재검증 강제 (cluster-guard cl-5f83b707a075fb13)' \
        '' \
        '사용자가 초기 진단/답변의 재확인을 요청하고 있다.' \
        '다음 순서를 반드시 따르라:' \
        '' \
        '1. **핵심 가정 명시**: 이전 답변에서 "당연하다"고 전제한 가정들을 번호 목록으로 열거한다.' \
        '   예) "가정 1: X는 Y이다", "가정 2: 경로 Z가 존재한다"' \
        '2. **가정별 실측 검증**: 각 가정에 대해 실제 코드/파일/로그를 확인하여 맞는지 반증한다.' \
        '   실측 없이 "이전 판단이 맞다"고 단언하지 말 것.' \
        '3. **정정 또는 확인**: 검증 결과를 토대로 오류를 정정하거나 초기 답변을 확인한다.' \
        '' \
        '⚠️ 주의: "규칙 때문이다", "당연히 그렇다", "이전 검토에서 확인했다" 등의 표현으로' \
        '실측 없이 결론을 재단언하는 패턴은 반복 실수 cl-5f83b707a075fb13에 해당한다.' \
        '반드시 실측(코드 읽기, 로그 확인, 파일 존재 여부 등) 후 답변하라.' \
        '<!-- /SECTION:meta-check-cl-5f83b707a075fb13 -->'
}

# ── 공개 API: 3. meta_check_inject_guardrail ────────────────────────────────
#
# meta_check_inject_guardrail <task_id>
#
# 메타인지 신호가 있는 경우에만 호출.
# 가드레일 섹션을 stdout으로 출력하고 신호 마커를 기록한다.
# 호출자는: SYSTEM_PROMPT+="$(meta_check_inject_guardrail "$TASK_ID")"
# 반환: 0=완료
meta_check_inject_guardrail() {
    local task_id="$1"
    _5f83_ensure_dirs

    meta_check_get_guardrail_section

    # 신호 마커 기록 (validate_response에서 읽음)
    printf '%s\n' "$(_5f83_now_iso)" > "$(_5f83_signal_marker "$task_id")"
    _5f83_log "INFO" "$task_id" "GUARDRAIL_INJECTED" ""
    _5f83_info "[$task_id] 메타인지 가드레일 주입 완료"
    return 0
}

# ── 공개 API: 3. meta_check_validate_response ───────────────────────────────
#
# meta_check_validate_response <task_id> <result_text>
#
# 이 태스크에 신호 마커가 있으면 result_text에 가정 명시 패턴이 있는지 확인.
# 차단은 없고 경고+로그만 수행.
# 반환: 0=검증 통과 또는 신호 없음, 1=가정 명시 없음(경고)
meta_check_validate_response() {
    local task_id="$1"
    local result_text="$2"
    local marker
    marker="$(_5f83_signal_marker "$task_id")"

    # 신호 마커가 없으면 검사 불필요
    if [[ ! -f "$marker" ]]; then
        return 0
    fi

    # 마커 사용 후 제거 (다음 호출에서 중복 검사 방지)
    rm -f "$marker" 2>/dev/null || true

    if [[ -z "$result_text" ]]; then
        _5f83_warn "[$task_id] meta_check: 결과 텍스트 없음 — 검증 생략"
        _5f83_log "WARN" "$task_id" "EMPTY_RESULT" ""
        return 1
    fi

    # 가정 명시 패턴 확인 (한/영)
    local assumption_patterns=(
        "가정"
        "전제"
        "假定"
        "assumption"
        "assumed"
        "assuming"
        "핵심 전제"
        "초기 판단"
        "첫 번째 가정"
        "실측 결과"
        "실제 확인"
        "확인 결과"
        "재검증"
        "재확인 결과"
    )

    for pat in "${assumption_patterns[@]}"; do
        if printf '%s' "$result_text" | grep -qi "$pat" 2>/dev/null; then
            _5f83_ok "[$task_id] 메타인지 응답 검증 통과 (패턴 발견: '${pat}')"
            _5f83_log "OK" "$task_id" "ASSUMPTION_EXPLICIT" "pattern=${pat}"
            return 0
        fi
    done

    # 가정 명시 없음 — 경고만 (차단 없음)
    _5f83_warn "[$task_id] 메타인지 신호 있었으나 응답에 핵심 가정 명시 없음 — 반복 실수 위험"
    _5f83_log "WARN" "$task_id" "ASSUMPTION_NOT_EXPLICIT" "result_len=${#result_text}"
    return 1
}

# ── 공개 API: 4. guard_cl_5f83b_status ──────────────────────────────────────
#
# guard_cl_5f83b_status
# 현재 가드 상태 요약
guard_cl_5f83b_status() {
    printf '=== %s 상태 요약 ===\n' "$_CL_5F83_PREFIX"
    printf '로그: %s\n' "$_CL_5F83_LOG"

    if [[ -f "$_CL_5F83_LOG" ]]; then
        local total fail warn ok
        total=$(wc -l < "$_CL_5F83_LOG" 2>/dev/null | tr -d ' ' || echo 0)
        fail=$(grep -c '"level":"FAIL"' "$_CL_5F83_LOG" 2>/dev/null || echo 0)
        warn=$(grep -c '"level":"WARN"' "$_CL_5F83_LOG" 2>/dev/null || echo 0)
        ok=$(grep -c '"level":"OK"' "$_CL_5F83_LOG" 2>/dev/null || echo 0)
        printf '전체=%s OK=%s WARN=%s FAIL=%s\n\n' "$total" "$ok" "$warn" "$fail"
        printf '최근 5건:\n'
        tail -5 "$_CL_5F83_LOG" 2>/dev/null || printf '(로그 없음)\n'
    else
        printf '(로그 파일 없음)\n'
    fi

    local pending_signals
    pending_signals=$(find "$_CL_5F83_SIGNAL_MARKER_DIR" -name "*.signal" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${pending_signals:-0}" -gt 0 ]]; then
        printf '\n⚠️  미처리 신호 마커: %s건\n' "$pending_signals"
        find "$_CL_5F83_SIGNAL_MARKER_DIR" -name "*.signal" 2>/dev/null | while read -r f; do
            printf '  - %s\n' "$(basename "$f" .signal)"
        done
    fi
}

# ── 초기화 ───────────────────────────────────────────────────────────────────
_5f83_ensure_dirs
