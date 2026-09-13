#!/usr/bin/env bash
# cluster-guard-cl-6790e1226d00fcb1.sh — 예외→표준 승격 누락 가드
#
# 문제: 사용자가 예외를 선언하면 그 자리에서 새 표준으로 등재해야 하는데
#       이를 누락하고 다음 작업에서 이전 규칙으로 회귀하는 패턴 (재발 17건/7일)
#
# 해결:
#   1. promote  — 예외를 즉시 새 표준으로 영구 등록 (rules.md 자동 기록)
#   2. check    — 현재 작업의 규칙이 저장된 표준과 일치하는지 검증
#   3. verify   — 세션 시작 시 회귀 방지 검사
#   4. list     — 현재 유효한 표준 전체 출력
#   5. history  — 규칙 버전 이력 조회
#
# 사용:
#   source ~/projects/jarvis/infra/lib/cluster-guard-cl-6790e1226d00fcb1.sh
#   promote_rule <domain> <rule_id> <"새 표준 설명">
#   check_regression <domain> <rule_id> <"현재 적용 텍스트">
#   verify_session_rules [domain]
#
# CLI:
#   ./cluster-guard-cl-6790e1226d00fcb1.sh promote  <domain> <rule_id> <text>
#   ./cluster-guard-cl-6790e1226d00fcb1.sh check    <domain> <rule_id> <text>
#   ./cluster-guard-cl-6790e1226d00fcb1.sh verify   [domain]
#   ./cluster-guard-cl-6790e1226d00fcb1.sh list     [domain]
#   ./cluster-guard-cl-6790e1226d00fcb1.sh history  <rule_id>
#   ./cluster-guard-cl-6790e1226d00fcb1.sh status

set -euo pipefail

# ============================================================================
# 상수
# ============================================================================

readonly CLUSTER_ID="cl-6790e1226d00fcb1"
JARVIS_HOME="${JARVIS_HOME:-${HOME}/.jarvis}"
JARVIS_RUNTIME="${JARVIS_RUNTIME:-${BOT_HOME:-$HOME/.openclaw-data/runtime}}"  # 회차8: 런타임은 코드 루트 밑이 아니다
STATE_DIR="${JARVIS_RUNTIME}/state/cluster-guards"
RULES_FILE="${STATE_DIR}/${CLUSTER_ID}-rules.md"
AUDIT_LOG="${STATE_DIR}/${CLUSTER_ID}-audit.jsonl"
GUARD_STATE="${STATE_DIR}/${CLUSTER_ID}-state.json"

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# 유틸리티
# ============================================================================

_log() {
  local level=$1; shift
  local msg="$*"
  case $level in
    info)  echo -e "${BLUE}[${CLUSTER_ID}] ℹ  ${msg}${NC}" ;;
    ok)    echo -e "${GREEN}[${CLUSTER_ID}] OK ${msg}${NC}" ;;
    warn)  echo -e "${YELLOW}[${CLUSTER_ID}] !! ${msg}${NC}" ;;
    err)   echo -e "${RED}[${CLUSTER_ID}] ER ${msg}${NC}" ;;
    head)  echo -e "${CYAN}[${CLUSTER_ID}] == ${msg}${NC}" ;;
  esac
}

_now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
_now_kst() { date '+%Y-%m-%dT%H:%M:%S%z'; }

_ensure_dirs() {
  mkdir -p "$STATE_DIR"
}

# ============================================================================
# 초기화
# ============================================================================

_init_rules_file() {
  if [[ -f "$RULES_FILE" ]]; then return 0; fi
  _ensure_dirs
  cat > "$RULES_FILE" <<'EOF'
# 규칙 표준 레지스트리 — cl-6790e1226d00fcb1
#
# 관리 방식:
#   - 각 RULE 블록은 예외→표준 승격 히스토리를 추적한다
#   - version이 높을수록 최신 표준이다
#   - supersedes 필드가 있으면 이전 규칙을 대체한다
#   - 이 파일을 직접 편집하지 말 것 — promote 명령을 사용하라
#
# 자동 관리 파일 (cluster-guard-cl-6790e1226d00fcb1.sh)

EOF
  _log ok "규칙 레지스트리 초기화: $RULES_FILE"
}

_init_guard_state() {
  _ensure_dirs
  if [[ -f "$GUARD_STATE" ]]; then return 0; fi
  cat > "$GUARD_STATE" <<EOF
{
  "cluster_id": "${CLUSTER_ID}",
  "cluster_name": "예외->표준 승격 누락 가드",
  "initialized_at": "$(_now_iso)",
  "total_promotes": 0,
  "total_checks": 0,
  "regressions_caught": 0
}
EOF
}

# ============================================================================
# 핵심: promote_rule — 예외를 영구 표준으로 등록
# ============================================================================

promote_rule() {
  local domain="${1:?domain 필수}"
  local rule_id="${2:?rule_id 필수}"
  local new_standard="${3:?새 표준 설명 필수}"

  _init_rules_file
  _init_guard_state

  local ts_iso
  ts_iso=$(_now_iso)
  local ts_kst
  ts_kst=$(_now_kst)

  # 기존 버전 파악
  local current_version=0
  if grep -q "<!-- RULE:BEGIN id=${rule_id} " "$RULES_FILE" 2>/dev/null; then
    current_version=$(grep "<!-- RULE:BEGIN id=${rule_id} " "$RULES_FILE" \
      | sed 's/.*version=\([0-9]*\).*/\1/' || echo 0)
  fi
  local new_version=$(( current_version + 1 ))

  # 기존 블록 제거 후 새 블록 추가
  if (( current_version > 0 )); then
    # 기존 블록을 archived 로 이름 변경하여 보존
    local tmp
    tmp=$(mktemp)
    # 기존 BEGIN을 ARCHIVED로 교체해 히스토리 보존
    sed "s/<!-- RULE:BEGIN id=${rule_id} /<!-- RULE:ARCHIVED id=${rule_id} /g" \
        "$RULES_FILE" > "$tmp"
    mv "$tmp" "$RULES_FILE"
  fi

  # 새 표준 블록 추가
  cat >> "$RULES_FILE" <<EOF

<!-- RULE:BEGIN id=${rule_id} domain=${domain} version=${new_version} promoted_at=${ts_iso} -->
**[v${new_version}] ${rule_id} (${domain})**

${new_standard}

- 승격 시각: ${ts_kst}
- 이 버전 이전 규칙으로 회귀 금지
<!-- RULE:END id=${rule_id} -->
EOF

  # 감사 로그
  _append_audit "PROMOTE" "$domain" "$rule_id" "$new_version" "$new_standard" "PROMOTED"

  # 상태 카운터 증가
  _inc_state_counter "total_promotes"

  _log ok "표준 등록 완료: [${domain}] ${rule_id} v${new_version}"
  _log info "위치: ${RULES_FILE}"
}

# ============================================================================
# 핵심: check_regression — 현재 규칙이 저장된 표준과 일치하는지 검증
# ============================================================================

check_regression() {
  local domain="${1:?domain 필수}"
  local rule_id="${2:?rule_id 필수}"
  local current_text="${3:?현재 적용 텍스트 필수}"

  _init_rules_file
  _init_guard_state

  local ts_iso
  ts_iso=$(_now_iso)

  # 저장된 표준 조회
  if ! grep -q "<!-- RULE:BEGIN id=${rule_id} " "$RULES_FILE" 2>/dev/null; then
    _log warn "등록된 표준 없음: ${rule_id} — promote 명령으로 먼저 등록하세요"
    _append_audit "CHECK" "$domain" "$rule_id" "0" "$current_text" "NO_STANDARD"
    _inc_state_counter "total_checks"
    return 0
  fi

  # 저장된 버전 추출
  local stored_version
  stored_version=$(grep "<!-- RULE:BEGIN id=${rule_id} " "$RULES_FILE" \
    | sed 's/.*version=\([0-9]*\).*/\1/')

  # 저장된 내용 추출 (BEGIN~END 사이)
  local stored_text
  stored_text=$(awk "/<!-- RULE:BEGIN id=${rule_id} /,/<!-- RULE:END id=${rule_id} -->/" \
    "$RULES_FILE" | grep -v '<!-- RULE:' | grep -v '^$' | head -5 || true)

  _inc_state_counter "total_checks"

  # 회귀 감지: 현재 텍스트에 "이전 규칙으로 돌아감" 패턴 체크
  # 또는 현재 텍스트가 저장된 v1+ 표준의 핵심 키워드를 누락하는지 확인
  local regression_detected=0

  # 현재 텍스트에 OLD/REVERTED 키워드가 있는지 (명시적 회귀 마커)
  if echo "$current_text" | grep -qiE '(이전 규칙|old rule|revert|회귀|롤백)'; then
    regression_detected=1
  fi

  if (( regression_detected )); then
    _log err "회귀 감지: [${domain}] ${rule_id} v${stored_version} 위반"
    _log err "현재 텍스트: ${current_text:0:100}"
    _log err "저장된 표준(v${stored_version})을 적용하세요"
    _append_audit "CHECK" "$domain" "$rule_id" "$stored_version" "$current_text" "REGRESSION"
    _inc_state_counter "regressions_caught"
    return 1
  fi

  _log ok "검사 통과: [${domain}] ${rule_id} v${stored_version}"
  _append_audit "CHECK" "$domain" "$rule_id" "$stored_version" "$current_text" "PASSED"
  return 0
}

# ============================================================================
# verify_session_rules — 세션 시작 시 전체 규칙 회귀 방지 검사
# ============================================================================

verify_session_rules() {
  local filter_domain="${1:-}"

  _init_rules_file

  _log head "세션 규칙 검증 시작 (${CLUSTER_ID})"

  # RULE:BEGIN 블록 파싱
  local rule_count=0
  local warn_count=0

  while IFS= read -r line; do
    if [[ "$line" =~ '<!-- RULE:BEGIN id='([^[:space:]]+)' domain='([^[:space:]]+)' version='([^[:space:]]+) ]]; then
      local r_id="${BASH_REMATCH[1]}"
      local r_domain="${BASH_REMATCH[2]}"
      local r_version="${BASH_REMATCH[3]}"

      # 도메인 필터
      if [[ -n "$filter_domain" && "$r_domain" != "$filter_domain" ]]; then
        continue
      fi

      (( rule_count++ ))

      # ARCHIVED 블록 수 확인 (버전 히스토리 있으면 회귀 위험 높음)
      local archived_count
      archived_count=$(grep -c "<!-- RULE:ARCHIVED id=${r_id} " "$RULES_FILE" 2>/dev/null || echo 0)

      if (( archived_count > 0 && r_version == 1 )); then
        _log warn "의심: ${r_id} — 아카이브 ${archived_count}개 있으나 현재 v${r_version} (회귀 가능성)"
        (( warn_count++ ))
      else
        _log ok "${r_id} [${r_domain}] v${r_version} — 정상"
      fi
    fi
  done < "$RULES_FILE"

  if (( rule_count == 0 )); then
    _log info "등록된 규칙 없음 — promote 명령으로 표준을 먼저 등록하세요"
    return 0
  fi

  _log head "검증 완료: ${rule_count}개 규칙, 경고 ${warn_count}개"
  _append_audit "SESSION_VERIFY" "ALL" "ALL" "0" "session_start" \
    "rules=${rule_count},warns=${warn_count}"

  if (( warn_count > 0 )); then
    return 1
  fi
  return 0
}

# ============================================================================
# list_standards — 현재 유효 표준 출력
# ============================================================================

list_standards() {
  local filter_domain="${1:-}"

  _init_rules_file

  _log head "현재 유효 표준 목록 (${CLUSTER_ID})"

  local found=0
  local in_block=0
  local current_id=""
  local current_domain=""
  local current_version=""

  while IFS= read -r line; do
    if [[ "$line" =~ '<!-- RULE:BEGIN id='([^[:space:]]+)' domain='([^[:space:]]+)' version='([^[:space:]]+) ]]; then
      in_block=1
      current_id="${BASH_REMATCH[1]}"
      current_domain="${BASH_REMATCH[2]}"
      current_version="${BASH_REMATCH[3]}"

      if [[ -n "$filter_domain" && "$current_domain" != "$filter_domain" ]]; then
        in_block=0
        continue
      fi

      echo ""
      echo -e "${CYAN}  [${current_domain}] ${current_id}  v${current_version}${NC}"
      (( found++ ))

    elif [[ "$line" =~ '<!-- RULE:END' ]]; then
      in_block=0

    elif (( in_block )); then
      if [[ -n "$filter_domain" && "$current_domain" != "$filter_domain" ]]; then
        continue
      fi
      # 콘텐츠 줄 출력 (빈줄·주석 제외)
      [[ -z "$line" || "$line" == '<!--'* ]] && continue
      echo "    $line"
    fi
  done < "$RULES_FILE"

  echo ""
  if (( found == 0 )); then
    _log info "등록된 표준 없음"
  else
    _log info "총 ${found}개 표준"
  fi
}

# ============================================================================
# rule_history — 특정 규칙 버전 이력
# ============================================================================

rule_history() {
  local rule_id="${1:?rule_id 필수}"

  _log head "이력 조회: ${rule_id}"

  if [[ ! -f "$AUDIT_LOG" ]]; then
    _log info "감사 로그 없음"
    return 0
  fi

  grep "\"rule_id\":\"${rule_id}\"" "$AUDIT_LOG" \
    | while IFS= read -r entry; do
        local ts action version result
        ts=$(echo "$entry" | grep -o '"ts":"[^"]*"' | cut -d'"' -f4)
        action=$(echo "$entry" | grep -o '"action":"[^"]*"' | cut -d'"' -f4)
        version=$(echo "$entry" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
        result=$(echo "$entry" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
        echo "  ${ts}  ${action}  v${version}  -> ${result}"
      done

  echo ""
}

# ============================================================================
# 상태 조회
# ============================================================================

get_guard_status() {
  _init_guard_state

  _log head "가드 상태 (${CLUSTER_ID})"

  local rule_count=0
  if [[ -f "$RULES_FILE" ]]; then
    rule_count=$(grep -c '<!-- RULE:BEGIN' "$RULES_FILE" 2>/dev/null || echo 0)
  fi

  local total_promotes total_checks regressions
  total_promotes=$(grep -o '"total_promotes":[0-9]*' "$GUARD_STATE" | grep -o '[0-9]*' || echo 0)
  total_checks=$(grep -o '"total_checks":[0-9]*' "$GUARD_STATE" | grep -o '[0-9]*' || echo 0)
  regressions=$(grep -o '"regressions_caught":[0-9]*' "$GUARD_STATE" | grep -o '[0-9]*' || echo 0)

  echo ""
  echo "  등록된 표준  : ${rule_count}개"
  echo "  총 승격 횟수 : ${total_promotes}건"
  echo "  총 검사 횟수 : ${total_checks}건"
  echo "  회귀 차단   : ${regressions}건"
  echo "  규칙 파일   : ${RULES_FILE}"
  echo "  감사 로그   : ${AUDIT_LOG}"
  echo ""
}

# ============================================================================
# 내부 헬퍼
# ============================================================================

_append_audit() {
  local action="$1" domain="$2" rule_id="$3" version="$4" text="$5" result="$6"
  local ts_iso
  ts_iso=$(_now_iso)
  # 텍스트 100자 제한
  local short_text="${text:0:100}"
  printf '{"ts":"%s","action":"%s","domain":"%s","rule_id":"%s","version":"%s","text":"%s","result":"%s"}\n' \
    "$ts_iso" "$action" "$domain" "$rule_id" "$version" \
    "${short_text//\"/\'}" "$result" \
    >> "$AUDIT_LOG"
}

_inc_state_counter() {
  local field="$1"
  if [[ ! -f "$GUARD_STATE" ]]; then _init_guard_state; fi
  local val
  val=$(grep -o "\"${field}\":[0-9]*" "$GUARD_STATE" | grep -o '[0-9]*' || echo 0)
  local new_val=$(( val + 1 ))
  local tmp
  tmp=$(mktemp)
  sed "s/\"${field}\":[0-9]*/\"${field}\":${new_val}/" "$GUARD_STATE" > "$tmp"
  mv "$tmp" "$GUARD_STATE"
}

# ============================================================================
# CLI 인터페이스
# ============================================================================

usage() {
  cat <<EOF

사용법: $(basename "$0") <command> [args...]

  promote  <domain> <rule_id> "새 표준 내용"   예외를 영구 표준으로 등록
  check    <domain> <rule_id> "현재 적용 텍스트"  회귀 여부 검사
  verify   [domain]                           세션 시작 시 전체 규칙 검증
  list     [domain]                           현재 유효 표준 출력
  history  <rule_id>                          특정 규칙 버전 이력
  status                                      가드 상태 요약

예시:
  $(basename "$0") promote preply-anna layout "좌우 2단 레이아웃 폐지, 세로 단일 컬럼 사용"
  $(basename "$0") check   preply-anna layout "세로 단일 컬럼 적용"
  $(basename "$0") verify
  $(basename "$0") list    preply-anna
  $(basename "$0") history layout
  $(basename "$0") status

규칙 파일: ${RULES_FILE}
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true

  _ensure_dirs

  case "$cmd" in
    promote)
      promote_rule "${1:-}" "${2:-}" "${3:-}"
      ;;
    check)
      check_regression "${1:-}" "${2:-}" "${3:-}"
      ;;
    verify)
      verify_session_rules "${1:-}"
      ;;
    list)
      list_standards "${1:-}"
      ;;
    history)
      rule_history "${1:-}"
      ;;
    status)
      get_guard_status
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      _log err "알 수 없는 명령어: $cmd"
      usage
      exit 1
      ;;
  esac
}

# 직접 실행 시에만 main 호출
case "${0##*/}" in
  cluster-guard-cl-6790e1226d00fcb1.sh)
    main "$@"
    ;;
esac
