#!/bin/bash
# post-edit-consistency-check.sh — 문서 편집 후 내부 일관성 검증 후처리
#
# 클러스터 cl-53499c7975efb1b0 통합:
#   - 문서 편집 후 숫자 일관성 자동 검증
#   - 관련 파일 동기화 확인
#   - 불일치 감지 시 편집 차단 (strict mode)
#
# 사용:
#   post-edit-consistency-check.sh <문서파일> [<요약본> <숙제> ...] [--strict]
#   post-edit-consistency-check.sh Anna_Unit1_Main.pdf Anna_Unit1_Summary.pdf Anna_Unit1_Homework.pdf --strict
#
# 반환값:
#   0: 모든 검증 통과
#   1: 검증 실패 (strict mode) 또는 경고 (non-strict)
#   2: 파일 없음

set -euo pipefail

# ============================================================================
# 설정
# ============================================================================

readonly JARVIS_HOME="${HOME}/jarvis"
readonly GUARD_LIB="${JARVIS_HOME}/infra/lib/cluster-guard-cl-53499c7975efb1b0.sh"
readonly STATE_DIR="${JARVIS_HOME}/runtime/state/consistency-checks"

# 옵션 파싱
STRICT_MODE=0
MAIN_FILE=""
RELATED_FILES=()

while (( $# )); do
  case "$1" in
    --strict) STRICT_MODE=1; shift ;;
    --*) echo "Unknown option: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$MAIN_FILE" ]]; then
        MAIN_FILE="$1"
      else
        RELATED_FILES+=("$1")
      fi
      shift
      ;;
  esac
done

# ============================================================================
# 유틸리티
# ============================================================================

log() {
  local level=$1
  shift
  local msg="$*"
  case $level in
    info) echo -e "\033[34m[consistency-check] ℹ️  ${msg}\033[0m" ;;
    ok) echo -e "\033[32m[consistency-check] ✅ ${msg}\033[0m" ;;
    warn) echo -e "\033[33m[consistency-check] ⚠️  ${msg}\033[0m" ;;
    err) echo -e "\033[31m[consistency-check] ❌ ${msg}\033[0m" ;;
  esac
}

_ensure_state_dir() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
}

_record_check() {
  local file="$1"
  local status="$2"
  local detail="$3"

  _ensure_state_dir

  local record=$(cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "file": "$(basename "$file")",
  "status": "$status",
  "detail": "$detail"
}
EOF
)
  echo "$record" >> "${STATE_DIR}/checks.jsonl" 2>/dev/null || true
}

# ============================================================================
# 메인 검증 로직
# ============================================================================

main() {
  if [[ -z "$MAIN_FILE" ]]; then
    log err "메인 파일을 지정해야 합니다"
    echo "사용법: $0 <문서파일> [<요약본> <숙제> ...] [--strict]" >&2
    exit 2
  fi

  if [[ ! -f "$MAIN_FILE" ]]; then
    log err "파일을 찾을 수 없음: $MAIN_FILE"
    exit 2
  fi

  log info "문서 내부 일관성 검증 시작: $(basename "$MAIN_FILE")"

  # cluster guard 로드
  if [[ ! -f "$GUARD_LIB" ]]; then
    log warn "cluster guard not found: $GUARD_LIB"
    log warn "진행하지만 검증이 축약됩니다"
  else
    # shellcheck disable=SC1090
    source "$GUARD_LIB" 2>/dev/null || {
      log warn "cluster guard 로드 실패"
    }
  fi

  # 1. 메인 파일 일관성 검증
  local has_errors=0

  log info "Step 1: 문서 내부 일관성 검증"
  if ! validate_document_consistency "$MAIN_FILE" 2>&1; then
    has_errors=1
    log err "문서 내부 불일치 감지"
  fi

  # 2. 관련 파일 동기화 검증 (요약본, 숙제 등이 있으면)
  if [[ ${#RELATED_FILES[@]} -gt 0 ]]; then
    log info "Step 2: 관련 파일 동기화 검증"
    if ! validate_related_files "$MAIN_FILE" "${RELATED_FILES[@]}" 2>&1; then
      has_errors=1
      log err "관련 파일 동기화 미확인"
    fi
  fi

  # 3. 결과 처리
  _record_check "$MAIN_FILE" "$([ $has_errors -eq 0 ] && echo "PASSED" || echo "FAILED")" "strict=$STRICT_MODE"

  if [[ $has_errors -eq 0 ]]; then
    log ok "모든 검증 통과"
    return 0
  fi

  if [[ $STRICT_MODE -eq 1 ]]; then
    log err "STRICT_MODE: 불일치 있음 → 편집 차단"
    return 1
  else
    log warn "경고 모드: 불일치가 있으나 계속 진행"
    return 0
  fi
}

main
