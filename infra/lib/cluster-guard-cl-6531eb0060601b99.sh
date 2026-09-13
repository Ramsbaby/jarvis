#!/usr/bin/env bash
# cluster-guard-cl-6531eb0060601b99.sh — 세션 컨텍스트 미추적 + 규칙-예시 이중 부실 가드
#
# 클러스터: cl-6531eb0060601b99 (최근 7일 재발 10건)
# 대표 패턴:
#   1. 세션 컨텍스트 미추적 + 빈 사과 규칙 위반
#   2. 정의 추가 후 예시 반영 누락 (이중 부실)
#   3. 규칙의 모든 항목에 예시 제공 누락
#   4. 대상자 맥락 미파악 — 타인용으로 가정 후 정정
#   5. 레이아웃 시각적 오류 사전 검토 누락
#
# 솔루션:
#   1. 세션 내 적용한 규칙·변경 파일 목록 자동 추적 (session_checklist)
#   2. 규칙 추가 시 예시 존재 여부 검증 (rule_example_check)
#   3. 신규 규칙 추가 시 영향 파일 자동 식별 + 미갱신 경고 (rule_impact_scan)
#   4. 대상자 컨텍스트 명시 강제 (audience_context_check)
#   5. 완료 선언 전 레이아웃 사전 검토 강제 (layout_precheck)
#
# 사용:
#   source ~/projects/jarvis/infra/lib/cluster-guard-cl-6531eb0060601b99.sh
#
#   # 세션 시작 시
#   session_checklist_start "Anna Unit3 요약본 작업"
#
#   # 규칙 추가 시
#   rule_example_check "동사 과거형 규칙" "파일.html" "예시1" "예시2"
#
#   # 신규 규칙이 영향 주는 파일 자동 스캔
#   rule_impact_scan "동사 과거형 규칙" ~/projects/jarvis/preply-engine/
#
#   # 대상자 컨텍스트 확인
#   audience_context_check "Anna" "Unit3" "Summary"
#
#   # 완료 선언 전 레이아웃 검토 확인
#   layout_precheck_required "Anna_Unit3_Summary.html"
#
#   # 세션 종료 시 체크리스트 요약
#   session_checklist_end

set -euo pipefail

# ============================================================================
# 설정
# ============================================================================

readonly CLUSTER_ID="cl-6531eb0060601b99"
readonly GUARD_VERSION="1.0.0"
readonly JARVIS_HOME="${HOME}/projects/jarvis"
JARVIS_RUNTIME="${JARVIS_RUNTIME:-${BOT_HOME:-$HOME/.openclaw-data/runtime}}"  # 회차8: 런타임은 코드 루트 밑이 아니다
readonly STATE_DIR="${JARVIS_RUNTIME}/state/cluster-guards"
readonly GUARD_STATE="${STATE_DIR}/${CLUSTER_ID}-state.json"
readonly VALIDATION_LOG="${STATE_DIR}/${CLUSTER_ID}-validations.jsonl"
readonly SESSION_CHECKLIST="${STATE_DIR}/${CLUSTER_ID}-session.json"
readonly IMPACT_LOG="${STATE_DIR}/${CLUSTER_ID}-impact.jsonl"

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================================
# 내부 유틸리티
# ============================================================================

_log() {
  local level=$1; shift
  local msg="$*"
  local ts; ts=$(date +"%H:%M:%S")
  case $level in
    info) echo -e "${BLUE}[${CLUSTER_ID}] ${ts} ℹ  ${msg}${NC}" >&2 ;;
    ok)   echo -e "${GREEN}[${CLUSTER_ID}] ${ts} ✓  ${msg}${NC}" >&2 ;;
    warn) echo -e "${YELLOW}[${CLUSTER_ID}] ${ts} ⚠  ${msg}${NC}" >&2 ;;
    err)  echo -e "${RED}${BOLD}[${CLUSTER_ID}] ${ts} ✗  ${msg}${NC}" >&2 ;;
    head) echo -e "${CYAN}${BOLD}[${CLUSTER_ID}] ${ts}    ${msg}${NC}" >&2 ;;
  esac
}

_ensure_dirs() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
}

_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

_init_guard_state() {
  _ensure_dirs
  if [[ ! -f "$GUARD_STATE" ]]; then
    cat > "$GUARD_STATE" <<GUARDEOF
{
  "cluster_id": "${CLUSTER_ID}",
  "cluster_name": "세션 컨텍스트 미추적 + 규칙-예시 이중 부실 가드",
  "guard_version": "${GUARD_VERSION}",
  "initialized_at": "$(_now_iso)",
  "total_validations": 0,
  "passed": 0,
  "failed": 0,
  "last_validation_at": null
}
GUARDEOF
    _log ok "가드 상태 초기화됨: ${GUARD_STATE}"
  fi
}

_inc_stat() {
  local field=$1 delta=${2:-1}
  _ensure_dirs
  if command -v jq &>/dev/null && [[ -f "$GUARD_STATE" ]]; then
    jq --arg now "$(_now_iso)" \
      ".${field} += ${delta} | .last_validation_at = \$now" \
      "$GUARD_STATE" > "${GUARD_STATE}.tmp" 2>/dev/null && \
      mv "${GUARD_STATE}.tmp" "$GUARD_STATE" 2>/dev/null || true
  fi
}

_append_log() {
  local payload="$1"
  _ensure_dirs
  echo "$payload" >> "$VALIDATION_LOG"
}

# ============================================================================
# [1] 세션 체크리스트 — 적용 규칙 + 변경 파일 자동 추적
# ============================================================================

# 세션 시작: 체크리스트 초기화
session_checklist_start() {
  local task_desc="${1:-작업 미정의}"
  _ensure_dirs

  cat > "$SESSION_CHECKLIST" <<CLEOF
{
  "cluster_id": "${CLUSTER_ID}",
  "session_task": "$(_json_escape "$task_desc")",
  "started_at": "$(_now_iso)",
  "ended_at": null,
  "applied_rules": [],
  "changed_files": [],
  "audience_context": null,
  "layout_precheck_done": false,
  "completion_allowed": false
}
CLEOF
  _log ok "세션 체크리스트 시작: ${task_desc}"
  _log info "세션 파일: ${SESSION_CHECKLIST}"
}

# 적용한 규칙 기록
session_rule_applied() {
  local rule_name="$1"
  local rule_detail="${2:-}"
  _ensure_dirs
  [[ ! -f "$SESSION_CHECKLIST" ]] && session_checklist_start "자동 시작 (rule_applied)"

  if command -v jq &>/dev/null; then
    jq --arg rule "$(_json_escape "$rule_name")" \
       --arg detail "$(_json_escape "$rule_detail")" \
       --arg ts "$(_now_iso)" \
       '.applied_rules += [{"rule": $rule, "detail": $detail, "at": $ts}]' \
       "$SESSION_CHECKLIST" > "${SESSION_CHECKLIST}.tmp" 2>/dev/null && \
       mv "${SESSION_CHECKLIST}.tmp" "$SESSION_CHECKLIST" 2>/dev/null || true
  fi
  _log info "규칙 기록: ${rule_name}"
}

# 변경된 파일 기록
session_file_changed() {
  local file_path="$1"
  local change_type="${2:-modified}"  # modified | created | deleted
  _ensure_dirs
  [[ ! -f "$SESSION_CHECKLIST" ]] && session_checklist_start "자동 시작 (file_changed)"

  if command -v jq &>/dev/null; then
    jq --arg path "$(_json_escape "$file_path")" \
       --arg type "$change_type" \
       --arg ts "$(_now_iso)" \
       '.changed_files += [{"path": $path, "type": $type, "at": $ts}]' \
       "$SESSION_CHECKLIST" > "${SESSION_CHECKLIST}.tmp" 2>/dev/null && \
       mv "${SESSION_CHECKLIST}.tmp" "$SESSION_CHECKLIST" 2>/dev/null || true
  fi
  _log info "파일 변경 기록: [${change_type}] ${file_path}"
}

# 세션 체크리스트 요약 출력 + 완료 여부 판정
session_checklist_end() {
  if [[ ! -f "$SESSION_CHECKLIST" ]]; then
    _log warn "체크리스트 없음 — session_checklist_start를 먼저 호출하세요"
    return 1
  fi

  local rules_count files_count audience layout_done
  if command -v jq &>/dev/null; then
    rules_count=$(jq '.applied_rules | length' "$SESSION_CHECKLIST" 2>/dev/null || echo 0)
    files_count=$(jq '.changed_files | length' "$SESSION_CHECKLIST" 2>/dev/null || echo 0)
    audience=$(jq -r '.audience_context // "미설정"' "$SESSION_CHECKLIST" 2>/dev/null || echo "미설정")
    layout_done=$(jq -r '.layout_precheck_done' "$SESSION_CHECKLIST" 2>/dev/null || echo "false")
  else
    rules_count=0; files_count=0; audience="미설정"; layout_done="false"
  fi

  _log head "═══ 세션 체크리스트 요약 ═══"
  _log info "적용 규칙: ${rules_count}건"
  _log info "변경 파일: ${files_count}건"
  _log info "대상자 컨텍스트: ${audience}"

  local issues=0

  if [[ "$audience" == "미설정" ]]; then
    _log warn "대상자 컨텍스트 미설정 → audience_context_check 호출 필요"
    (( issues++ )) || true
  fi

  if [[ "$layout_done" != "true" && "$files_count" -gt 0 ]]; then
    _log warn "레이아웃 사전 검토 미완료 → layout_precheck_required 호출 필요"
    (( issues++ )) || true
  fi

  if [[ "$rules_count" -eq 0 ]]; then
    _log warn "적용 규칙 0건 — 규칙 추가 시 session_rule_applied 호출 필요"
    (( issues++ )) || true
  fi

  if [[ "$issues" -eq 0 ]]; then
    _log ok "세션 체크리스트 완료 (이슈 0건) — 완료 선언 허용"
    if command -v jq &>/dev/null; then
      jq --arg ts "$(_now_iso)" '.ended_at = $ts | .completion_allowed = true' \
        "$SESSION_CHECKLIST" > "${SESSION_CHECKLIST}.tmp" 2>/dev/null && \
        mv "${SESSION_CHECKLIST}.tmp" "$SESSION_CHECKLIST" 2>/dev/null || true
    fi
    _inc_stat passed
    return 0
  else
    _log err "세션 체크리스트 미완료 (이슈 ${issues}건) — 완료 선언 차단"
    _inc_stat failed
    return 1
  fi
}

# ============================================================================
# [2] 규칙-예시 완전성 검사 — 정의 추가 시 예시 동반 여부 검증
# ============================================================================

# 규칙/정의 추가 시 예시 존재 여부 검증
# 사용: rule_example_check "규칙명" "파일" "예시1" ["예시2" ...]
rule_example_check() {
  local rule_name="$1"
  local target_file="$2"
  shift 2
  local examples=("$@")

  _init_guard_state
  _log info "규칙-예시 검사: '${rule_name}' @ ${target_file}"

  local has_examples="${#examples[@]}"
  local file_has_rule=false
  local file_has_examples=false
  local issues=()

  # 파일 존재 검사
  if [[ ! -f "$target_file" ]]; then
    _log warn "파일 미존재: ${target_file} — 파일 기반 검사 생략"
  else
    # 파일에서 규칙명 존재 확인 (한국어·영어 모두 지원)
    if grep -qi "$(echo "$rule_name" | cut -c1-10)" "$target_file" 2>/dev/null; then
      file_has_rule=true
    fi

    # 파일에서 예시 섹션 존재 확인 (예시/example/예문/보기 패턴)
    if grep -qiE "(예시|예문|example|보기|예:|e\.g\.|예\))" "$target_file" 2>/dev/null; then
      file_has_examples=true
    fi

    if $file_has_rule && ! $file_has_examples; then
      issues+=("파일에 규칙 정의는 있으나 예시 섹션 없음: ${target_file}")
    fi
  fi

  # 인자로 전달된 예시 수 검사
  if [[ "$has_examples" -eq 0 ]]; then
    issues+=("규칙 '${rule_name}'에 예시 인자 미전달 — 최소 1개 이상 필수")
  elif [[ "$has_examples" -lt 2 ]]; then
    _log warn "예시 ${has_examples}건만 전달됨 — 권장: 2건 이상"
  fi

  # 결과 기록
  local status="PASSED"
  if [[ "${#issues[@]}" -gt 0 ]]; then
    status="FAILED"
    for issue in "${issues[@]}"; do
      _log err "  → ${issue}"
    done
    _log err "규칙-예시 검사 실패: '${rule_name}'"
    _inc_stat total_validations
    _inc_stat failed
    _append_log "{\"ts\":\"$(_now_iso)\",\"cluster\":\"${CLUSTER_ID}\",\"check\":\"rule_example\",\"rule\":\"$(_json_escape "$rule_name")\",\"file\":\"$(_json_escape "$target_file")\",\"examples_count\":${has_examples},\"status\":\"FAILED\"}"
    return 1
  fi

  _log ok "규칙-예시 검사 통과: '${rule_name}' (예시 ${has_examples}건)"
  session_rule_applied "$rule_name" "examples=${has_examples}"
  _inc_stat total_validations
  _inc_stat passed
  _append_log "{\"ts\":\"$(_now_iso)\",\"cluster\":\"${CLUSTER_ID}\",\"check\":\"rule_example\",\"rule\":\"$(_json_escape "$rule_name")\",\"file\":\"$(_json_escape "$target_file")\",\"examples_count\":${has_examples},\"status\":\"PASSED\"}"
  return 0
}

# ============================================================================
# [3] 신규 규칙 → 영향 파일 자동 스캔 및 미갱신 경고
# ============================================================================

# 신규 규칙 추가 시 영향 받는 파일을 자동 식별
# 사용: rule_impact_scan "규칙 키워드" [검색 디렉토리] [파일 패턴]
rule_impact_scan() {
  local rule_keyword="$1"
  local search_dir="${2:-${HOME}/projects/jarvis}"
  local file_pattern="${3:-*.html *.md *.json *.txt}"

  _log info "영향 파일 스캔: '${rule_keyword}' in ${search_dir}"

  local -a affected_files=()
  local -a patterns
  IFS=' ' read -ra patterns <<< "$file_pattern"

  # find 명령으로 관련 파일 검색
  local find_args=("$search_dir" -type f \( -false \))
  for pat in "${patterns[@]}"; do
    find_args+=(-o -name "$pat")
  done
  find_args+=(\))

  local keyword_short; keyword_short=$(echo "$rule_keyword" | cut -c1-15)

  while IFS= read -r f; do
    if grep -qli "$keyword_short" "$f" 2>/dev/null; then
      affected_files+=("$f")
    fi
  done < <(find "${find_args[@]}" 2>/dev/null | head -200)

  _log head "영향 파일 스캔 결과: ${#affected_files[@]}건"

  if [[ "${#affected_files[@]}" -eq 0 ]]; then
    _log info "관련 파일 없음 — 신규 규칙으로 처리"
    return 0
  fi

  # 세션 변경 파일 목록과 비교
  local unchecked=()
  if command -v jq &>/dev/null && [[ -f "$SESSION_CHECKLIST" ]]; then
    local changed_json; changed_json=$(jq -r '.changed_files[].path' "$SESSION_CHECKLIST" 2>/dev/null || echo "")
    for af in "${affected_files[@]}"; do
      if ! echo "$changed_json" | grep -qF "$af"; then
        unchecked+=("$af")
      fi
    done
  else
    unchecked=("${affected_files[@]}")
  fi

  # 결과 출력
  if [[ "${#unchecked[@]}" -gt 0 ]]; then
    _log warn "미갱신 영향 파일 ${#unchecked[@]}건 감지:"
    for f in "${unchecked[@]:0:10}"; do  # 최대 10건 출력
      _log warn "  미갱신: ${f}"
    done
    [[ "${#unchecked[@]}" -gt 10 ]] && _log warn "  ... 외 $((${#unchecked[@]} - 10))건"

    # 영향 로그 기록
    _append_log "{\"ts\":\"$(_now_iso)\",\"cluster\":\"${CLUSTER_ID}\",\"check\":\"rule_impact\",\"rule\":\"$(_json_escape "$rule_keyword")\",\"affected\":${#affected_files[@]},\"unchecked\":${#unchecked[@]}}"

    _inc_stat total_validations
    _inc_stat failed
    return 1
  fi

  _log ok "영향 파일 ${#affected_files[@]}건 모두 세션 내 갱신 확인됨"
  _append_log "{\"ts\":\"$(_now_iso)\",\"cluster\":\"${CLUSTER_ID}\",\"check\":\"rule_impact\",\"rule\":\"$(_json_escape "$rule_keyword")\",\"affected\":${#affected_files[@]},\"unchecked\":0}"
  _inc_stat total_validations
  _inc_stat passed
  return 0
}

# ============================================================================
# [4] 대상자 컨텍스트 명시 강제
# ============================================================================

# 대상자 컨텍스트를 명시하고 세션에 기록
# 사용: audience_context_check "Anna" "Unit3" "Summary"
audience_context_check() {
  local student_name="${1:-}"
  local unit="${2:-}"
  local doc_type="${3:-}"

  if [[ -z "$student_name" ]]; then
    _log err "대상자(student_name) 미지정 — 타인용 혼동 방지를 위해 명시 필수"
    _log err "사용: audience_context_check <학생명> [유닛] [문서타입]"
    _inc_stat failed
    return 1
  fi

  local context="${student_name}"
  [[ -n "$unit" ]]    && context+=" / ${unit}"
  [[ -n "$doc_type" ]] && context+=" / ${doc_type}"

  # 세션 체크리스트에 대상자 기록
  _ensure_dirs
  if [[ -f "$SESSION_CHECKLIST" ]] && command -v jq &>/dev/null; then
    jq --arg ctx "$(_json_escape "$context")" \
       '.audience_context = $ctx' \
       "$SESSION_CHECKLIST" > "${SESSION_CHECKLIST}.tmp" 2>/dev/null && \
       mv "${SESSION_CHECKLIST}.tmp" "$SESSION_CHECKLIST" 2>/dev/null || true
  fi

  _log ok "대상자 컨텍스트 설정됨: ${context}"
  _append_log "{\"ts\":\"$(_now_iso)\",\"cluster\":\"${CLUSTER_ID}\",\"check\":\"audience_context\",\"context\":\"$(_json_escape "$context")\",\"status\":\"SET\"}"
  _inc_stat total_validations
  _inc_stat passed
  return 0
}

# ============================================================================
# [5] 레이아웃 사전 검토 강제
# ============================================================================

# 완료 선언 전 레이아웃 검토 완료 여부 확인
# 사용: layout_precheck_required "파일.html" [검토 방식: "manual"|"render-check"]
layout_precheck_required() {
  local target_file="${1:-}"
  local check_mode="${2:-manual}"

  _log head "레이아웃 사전 검토 확인: ${target_file}"

  local issues=()

  if [[ -z "$target_file" ]]; then
    issues+=("대상 파일 미지정")
  elif [[ ! -f "$target_file" ]]; then
    issues+=("파일 미존재: ${target_file}")
  fi

  # HTML 파일의 경우 기본적인 구조 검사
  if [[ -f "$target_file" ]] && [[ "$target_file" == *.html ]]; then
    # 닫히지 않은 태그 감지 (간단한 휴리스틱)
    local open_divs close_divs open_tables close_tables
    open_divs=$(grep -o '<div' "$target_file" 2>/dev/null | wc -l | tr -d ' ')
    close_divs=$(grep -o '</div>' "$target_file" 2>/dev/null | wc -l | tr -d ' ')
    open_tables=$(grep -o '<table' "$target_file" 2>/dev/null | wc -l | tr -d ' ')
    close_tables=$(grep -o '</table>' "$target_file" 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$open_divs" -ne "$close_divs" ]]; then
      issues+=("div 태그 불일치: <div>${open_divs} vs </div>${close_divs}")
    fi
    if [[ "$open_tables" -ne "$close_tables" ]]; then
      issues+=("table 태그 불일치: <table>${open_tables} vs </table>${close_tables}")
    fi

    # render-check 스크립트 존재 시 실행
    local render_check_bin="${JARVIS_HOME}/infra/lib/post-edit-lint.sh"
    if [[ "$check_mode" == "render-check" ]] && [[ -f "$render_check_bin" ]]; then
      _log info "render-check 실행 중..."
      if ! bash "$render_check_bin" "$target_file" 2>/dev/null; then
        issues+=("render-check 실패: ${target_file}")
      fi
    fi
  fi

  # 결과 판정
  if [[ "${#issues[@]}" -gt 0 ]]; then
    _log err "레이아웃 사전 검토 실패:"
    for issue in "${issues[@]}"; do
      _log err "  → ${issue}"
    done
    _inc_stat failed
    _append_log "{\"ts\":\"$(_now_iso)\",\"cluster\":\"${CLUSTER_ID}\",\"check\":\"layout_precheck\",\"file\":\"$(_json_escape "${target_file:-}")\",\"status\":\"FAILED\",\"issues\":${#issues[@]}}"
    return 1
  fi

  # 세션 체크리스트에 레이아웃 검토 완료 표시
  if [[ -f "$SESSION_CHECKLIST" ]] && command -v jq &>/dev/null; then
    jq '.layout_precheck_done = true' \
       "$SESSION_CHECKLIST" > "${SESSION_CHECKLIST}.tmp" 2>/dev/null && \
       mv "${SESSION_CHECKLIST}.tmp" "$SESSION_CHECKLIST" 2>/dev/null || true
  fi

  _log ok "레이아웃 사전 검토 완료: ${target_file}"
  _inc_stat passed
  _append_log "{\"ts\":\"$(_now_iso)\",\"cluster\":\"${CLUSTER_ID}\",\"check\":\"layout_precheck\",\"file\":\"$(_json_escape "${target_file:-}")\",\"status\":\"PASSED\"}"
  return 0
}

# ============================================================================
# [종합] 완료 선언 통합 게이트 — 모든 검사 통과 후만 완료 허용
# ============================================================================

# 완료 선언 전 전체 가드 통합 실행
# 사용: completion_gate_check [파일목록...]
completion_gate_check() {
  local files=("$@")
  _log head "═══ 완료 선언 통합 게이트 (${CLUSTER_ID}) ═══"

  local gate_issues=0

  # 1. 세션 체크리스트 최종 확인
  if [[ -f "$SESSION_CHECKLIST" ]]; then
    local completion_allowed
    completion_allowed=$(command -v jq &>/dev/null && jq -r '.completion_allowed' "$SESSION_CHECKLIST" 2>/dev/null || echo "false")

    local audience
    audience=$(command -v jq &>/dev/null && jq -r '.audience_context // "미설정"' "$SESSION_CHECKLIST" 2>/dev/null || echo "미설정")

    if [[ "$audience" == "미설정" ]]; then
      _log err "게이트 차단: 대상자 컨텍스트 미설정"
      (( gate_issues++ )) || true
    fi

    local layout_done
    layout_done=$(command -v jq &>/dev/null && jq -r '.layout_precheck_done' "$SESSION_CHECKLIST" 2>/dev/null || echo "false")
    if [[ "$layout_done" != "true" && "${#files[@]}" -gt 0 ]]; then
      _log err "게이트 차단: 레이아웃 사전 검토 미완료 (대상 파일 ${#files[@]}건)"
      (( gate_issues++ )) || true
    fi
  else
    _log warn "세션 체크리스트 없음 — 추적 없이 진행 중"
  fi

  # 2. 전달된 파일들 레이아웃 검사
  for f in "${files[@]}"; do
    if [[ "$f" == *.html ]] && [[ -f "$f" ]]; then
      local od cd ot ct
      od=$(grep -o '<div' "$f" 2>/dev/null | wc -l | tr -d ' ')
      cd=$(grep -o '</div>' "$f" 2>/dev/null | wc -l | tr -d ' ')
      ot=$(grep -o '<table' "$f" 2>/dev/null | wc -l | tr -d ' ')
      ct=$(grep -o '</table>' "$f" 2>/dev/null | wc -l | tr -d ' ')
      if [[ "$od" -ne "$cd" ]] || [[ "$ot" -ne "$ct" ]]; then
        _log err "게이트 차단: 태그 불일치 — ${f}"
        (( gate_issues++ )) || true
      fi
    fi
  done

  if [[ "$gate_issues" -eq 0 ]]; then
    _log ok "완료 선언 게이트 통과 — 완료 선언 허용"
    _inc_stat passed
    return 0
  else
    _log err "완료 선언 게이트 차단 (${gate_issues}건 미해결)"
    _log err "해결 후 재호출: completion_gate_check"
    _inc_stat failed
    return 1
  fi
}

# ============================================================================
# 가드 상태 조회
# ============================================================================

get_guard_status() {
  _init_guard_state
  _log head "═══ 가드 상태: ${CLUSTER_ID} ═══"

  if command -v jq &>/dev/null && [[ -f "$GUARD_STATE" ]]; then
    jq -r '
      "  총 검사: \(.total_validations)건",
      "  통과:   \(.passed)건",
      "  실패:   \(.failed)건",
      "  마지막: \(.last_validation_at // "없음")"
    ' "$GUARD_STATE" 2>/dev/null | while IFS= read -r line; do
      _log info "$line"
    done
  fi

  if [[ -f "$SESSION_CHECKLIST" ]]; then
    _log info "세션 파일: ${SESSION_CHECKLIST}"
    if command -v jq &>/dev/null; then
      local task audience rules files layout
      task=$(jq -r '.session_task' "$SESSION_CHECKLIST" 2>/dev/null || echo "미상")
      audience=$(jq -r '.audience_context // "미설정"' "$SESSION_CHECKLIST" 2>/dev/null || echo "미설정")
      rules=$(jq '.applied_rules | length' "$SESSION_CHECKLIST" 2>/dev/null || echo 0)
      files=$(jq '.changed_files | length' "$SESSION_CHECKLIST" 2>/dev/null || echo 0)
      layout=$(jq -r '.layout_precheck_done' "$SESSION_CHECKLIST" 2>/dev/null || echo "false")
      _log info "  작업: ${task}"
      _log info "  대상자: ${audience}"
      _log info "  적용 규칙: ${rules}건 / 변경 파일: ${files}건"
      _log info "  레이아웃 검토: ${layout}"
    fi
  fi
}

# ============================================================================
# 자가 진단 테스트
# ============================================================================

_self_test() {
  _log head "═══ 자가 진단 테스트: ${CLUSTER_ID} ═══"
  local pass=0 fail=0

  # T1: 세션 체크리스트 시작
  session_checklist_start "자가진단 테스트 세션"
  _log ok "T1 PASS: session_checklist_start"
  (( pass++ )) || true

  # T2: 대상자 컨텍스트
  if audience_context_check "TestStudent" "Unit1" "Summary"; then
    _log ok "T2 PASS: audience_context_check"
    (( pass++ )) || true
  else
    _log err "T2 FAIL: audience_context_check"
    (( fail++ )) || true
  fi

  # T3: 규칙-예시 검사 (예시 없음 → 실패 기대)
  if ! rule_example_check "테스트규칙" "/nonexistent/file.html"; then
    _log ok "T3 PASS: rule_example_check (예시 없음 시 실패 확인)"
    (( pass++ )) || true
  else
    _log err "T3 FAIL: 예시 없음인데 통과됨"
    (( fail++ )) || true
  fi

  # T4: 레이아웃 사전 검토 (가상 파일)
  local tmp_html; tmp_html=$(mktemp /tmp/test_layout_XXXX.html)
  cat > "$tmp_html" <<'HTMLEOF'
<html><body><div><table><tr><td>test</td></tr></table></div></body></html>
HTMLEOF
  if layout_precheck_required "$tmp_html"; then
    _log ok "T4 PASS: layout_precheck_required (균형 태그)"
    (( pass++ )) || true
  else
    _log err "T4 FAIL: 균형 태그인데 실패"
    (( fail++ )) || true
  fi
  rm -f "$tmp_html"

  # T5: 불균형 태그 감지
  local tmp_bad; tmp_bad=$(mktemp /tmp/test_bad_XXXX.html)
  cat > "$tmp_bad" <<'HTMLEOF'
<html><body><div><div>unmatched</body></html>
HTMLEOF
  if ! layout_precheck_required "$tmp_bad"; then
    _log ok "T5 PASS: layout_precheck_required (불균형 태그 감지)"
    (( pass++ )) || true
  else
    _log err "T5 FAIL: 불균형 태그를 통과시킴"
    (( fail++ )) || true
  fi
  rm -f "$tmp_bad"

  # 결과
  _log head "═══ 자가 진단 결과: PASS ${pass} / FAIL ${fail} ═══"
  [[ "$fail" -eq 0 ]] && return 0 || return 1
}

# ============================================================================
# 초기화
# ============================================================================

_init_guard_state

# ============================================================================
# CLI 직접 실행 지원
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --test|-t)
      _self_test
      ;;
    --status|-s)
      get_guard_status
      ;;
    --help|-h)
      echo "사용법:"
      echo "  source ${0}                            # 함수 로드"
      echo "  ${0} --test                            # 자가 진단"
      echo "  ${0} --status                          # 가드 상태"
      echo ""
      echo "주요 함수:"
      echo "  session_checklist_start <작업명>       # 세션 시작"
      echo "  session_rule_applied <규칙명> [설명]   # 규칙 적용 기록"
      echo "  session_file_changed <파일> [타입]     # 파일 변경 기록"
      echo "  rule_example_check <규칙> <파일> ...   # 규칙-예시 검사"
      echo "  rule_impact_scan <키워드> [디렉토리]   # 영향 파일 스캔"
      echo "  audience_context_check <학생> [유닛]   # 대상자 확인"
      echo "  layout_precheck_required <파일>        # 레이아웃 검토"
      echo "  completion_gate_check [파일...]        # 완료 게이트"
      echo "  session_checklist_end                  # 세션 종료 요약"
      echo "  get_guard_status                       # 상태 조회"
      ;;
    *)
      _log err "알 수 없는 명령. --help 참조"
      exit 1
      ;;
  esac
fi
