#!/usr/bin/env bash
# guard-main.sh — 클러스터 cl-525648978b1b80de 통합 가드 진입점
#
# 클러스터 ID  : cl-525648978b1b80de (최근 7일 재발 19건)
# 대표 시드    : PDF/HTML 재생성 완료 선언 후 변경사항 구체값 미제시
#
# 역할:
#   - checklist-guard.sh   (완료 선언 차단)
#   - session-diff-guard.sh (이전 세션 개선사항 미적용 감지)
#   두 가드를 통합 실행하는 단일 진입점
#
# 사용법:
#   ./guard-main.sh [옵션] <서브커맨드> [인자...]
#
# 옵션:
#   --dry-run     실제 동작 없이 검사만 수행 (기존 파일·상태 변경 없음)
#   --verbose     상세 로그 출력
#   --cluster-id  클러스터 ID 지정 (기본: cl-525648978b1b80de)
#
# 서브커맨드:
#   checklist init  항목1 항목2 ...  체크리스트 초기화
#   checklist done  "레이블"         항목 완료 표시
#   checklist verify                 완료 선언 검사 (exit 0/1)
#   checklist status                 상태 출력
#
#   session record  "개선사항"       이전 세션 개선사항 기록
#   session applied "레이블"         개선사항 적용 확인
#   session check   [파일명]         신규 파일 생성 전 검사 (exit 0/1)
#   session list                     전체 개선사항 목록
#
#   full-check                       두 가드 모두 실행 (체크리스트 + 세션 개선사항)
#   status                           전체 상태 요약 출력
#
# --dry-run 보장:
#   --dry-run 플래그 시 어떤 파일도 생성·수정·삭제하지 않습니다.
#   검사 결과만 stdout/stderr로 출력하고 exit 코드로 결과를 반환합니다.

set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# 전역 설정
# ═══════════════════════════════════════════════════════════════

GUARD_CLUSTER_ID="cl-525648978b1b80de"
GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKLIST_GUARD="${GUARD_DIR}/checklist-guard.sh"
SESSION_DIFF_GUARD="${GUARD_DIR}/session-diff-guard.sh"

DRY_RUN=0
VERBOSE=0
GM_LOG_PREFIX="[guard-main ${GUARD_CLUSTER_ID}]"

# ═══════════════════════════════════════════════════════════════
# 로깅
# ═══════════════════════════════════════════════════════════════

_gm_log() {
  local level="$1"; shift
  echo "${GM_LOG_PREFIX} [${level}] $*" >&2
}

_gm_verbose() {
  [[ "${VERBOSE}" -eq 1 ]] && _gm_log "DEBUG" "$@" || true
}

# ═══════════════════════════════════════════════════════════════
# 의존성 확인
# ═══════════════════════════════════════════════════════════════

_gm_check_deps() {
  local missing=0

  if [[ ! -f "${CHECKLIST_GUARD}" ]]; then
    _gm_log "ERROR" "checklist-guard.sh 미발견: ${CHECKLIST_GUARD}"
    missing=1
  fi

  if [[ ! -f "${SESSION_DIFF_GUARD}" ]]; then
    _gm_log "ERROR" "session-diff-guard.sh 미발견: ${SESSION_DIFF_GUARD}"
    missing=1
  fi

  return "${missing}"
}

# ═══════════════════════════════════════════════════════════════
# --dry-run 모드: 환경변수로 서브 스크립트에 전파
# ═══════════════════════════════════════════════════════════════

_gm_apply_dry_run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    # 상태 디렉터리를 임시 디렉터리로 교체 → 실제 파일 변경 없음
    local tmpdir
    tmpdir="$(mktemp -d)"
    export JARVIS_STATE_DIR="${tmpdir}"
    export CHECKLIST_SESSION_ID="dry-run-$$"
    _gm_log "DRY-RUN" "임시 상태 디렉터리 사용: ${tmpdir}"
    # 프로세스 종료 시 임시 디렉터리 정리
    trap "rm -rf '${tmpdir}'" EXIT
  fi
}

# ═══════════════════════════════════════════════════════════════
# 서브커맨드: checklist
# ═══════════════════════════════════════════════════════════════

_cmd_checklist() {
  # shellcheck source=/dev/null
  source "${CHECKLIST_GUARD}"

  local subcmd="${1:-help}"
  shift || true

  case "$subcmd" in
    init)
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        _gm_log "DRY-RUN" "checklist init '$*' — 실제 파일 변경 없음 (dry-run)"
        checklist_init "$@"
      else
        checklist_init "$@"
      fi
      ;;
    done)
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        _gm_log "DRY-RUN" "checklist done '$*' — dry-run 모드"
      fi
      checklist_done "$@"
      ;;
    verify)
      checklist_verify
      ;;
    status)
      checklist_status
      ;;
    reset)
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        _gm_log "DRY-RUN" "checklist reset — dry-run 모드에서는 임시 디렉터리만 정리됨"
      fi
      checklist_reset
      ;;
    *)
      _gm_log "ERROR" "알 수 없는 checklist 서브커맨드: ${subcmd}"
      _gm_usage
      exit 1
      ;;
  esac
}

# ═══════════════════════════════════════════════════════════════
# 서브커맨드: session
# ═══════════════════════════════════════════════════════════════

_cmd_session() {
  # shellcheck source=/dev/null
  source "${SESSION_DIFF_GUARD}"

  local subcmd="${1:-help}"
  shift || true

  case "$subcmd" in
    record)
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        _gm_log "DRY-RUN" "session record '$*' — dry-run 모드"
      fi
      session_improvement_record "$@"
      ;;
    applied)
      session_improvement_applied "$@"
      ;;
    check)
      session_diff_check "$@"
      ;;
    list)
      session_diff_list
      ;;
    *)
      _gm_log "ERROR" "알 수 없는 session 서브커맨드: ${subcmd}"
      _gm_usage
      exit 1
      ;;
  esac
}

# ═══════════════════════════════════════════════════════════════
# 서브커맨드: full-check
# 두 가드 모두 실행 — 하나라도 실패하면 exit 1
# ═══════════════════════════════════════════════════════════════

_cmd_full_check() {
  local context_file="${1:-}"
  local overall_exit=0

  _gm_log "INFO" "=== 통합 가드 검사 시작 (cluster: ${GUARD_CLUSTER_ID}) ==="
  [[ "${DRY_RUN}" -eq 1 ]] && _gm_log "DRY-RUN" "dry-run 모드 — 상태 변경 없음"

  # [1] 체크리스트 완료 검사
  _gm_log "INFO" "[1/2] 체크리스트 완료 선언 차단 검사..."
  # shellcheck source=/dev/null
  source "${CHECKLIST_GUARD}"
  if ! checklist_verify 2>&1; then
    _gm_log "BLOCK" "체크리스트 미완료 항목 존재 → 완료 선언 차단"
    overall_exit=1
  else
    _gm_log "OK" "체크리스트 전체 완료"
  fi

  # [2] 세션 개선사항 미적용 검사
  _gm_log "INFO" "[2/2] 세션 개선사항 미적용 감지 검사..."
  # shellcheck source=/dev/null
  source "${SESSION_DIFF_GUARD}"
  if ! session_diff_check "${context_file}" 2>&1; then
    _gm_log "WARN" "미적용 개선사항 감지 → 신규 파일 생성 주의"
    overall_exit=1
  else
    _gm_log "OK" "미적용 개선사항 없음"
  fi

  # 최종 결과
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  if [[ "${overall_exit}" -eq 0 ]]; then
    _gm_log "PASS" "전체 가드 통과 ✓"
  else
    _gm_log "FAIL" "가드 검사 실패 — 완료 선언 전 위 항목을 처리하세요"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2

  return "${overall_exit}"
}

# ═══════════════════════════════════════════════════════════════
# 서브커맨드: status
# ═══════════════════════════════════════════════════════════════

_cmd_status() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "${GM_LOG_PREFIX} 전체 상태 요약" >&2
  echo "  클러스터: ${GUARD_CLUSTER_ID}" >&2
  echo "  DRY-RUN : ${DRY_RUN}" >&2
  echo "  VERBOSE : ${VERBOSE}" >&2
  echo "" >&2

  # shellcheck source=/dev/null
  source "${CHECKLIST_GUARD}"
  echo "[ 체크리스트 ]" >&2
  checklist_status || true

  # shellcheck source=/dev/null
  source "${SESSION_DIFF_GUARD}"
  echo "[ 세션 개선사항 ]" >&2
  session_diff_list || true

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
}

# ═══════════════════════════════════════════════════════════════
# 사용법 출력
# ═══════════════════════════════════════════════════════════════

_gm_usage() {
  cat >&2 <<HELP
사용법: $(basename "$0") [--dry-run] [--verbose] <서브커맨드> [인자...]

옵션:
  --dry-run     실제 파일 변경 없이 검사만 수행 (기존 동작 파괴 없음)
  --verbose     상세 로그 출력

서브커맨드:
  checklist init  항목1 항목2 ...   체크리스트 초기화
  checklist done  "레이블"          항목 완료 표시
  checklist verify                  완료 선언 검사 (exit 0 = 전체완료, exit 1 = 미완료)
  checklist status                  체크리스트 상태 출력
  checklist reset                   체크리스트 초기화 (삭제)

  session record  "개선사항 설명"   이전 세션 개선사항 기록
  session applied "레이블"          개선사항 적용 확인 표시
  session check   [파일명]          신규 파일 생성 전 미적용 항목 검사
  session list                      전체 개선사항 목록 출력

  full-check  [파일명]   두 가드 모두 실행 (exit 0/1)
  status                 전체 상태 요약

예시:
  # 다중 항목 지시 수신 시
  $(basename "$0") checklist init "HTML 태그 완전 제거" "PDF 변경사항 구체값 명시" "TTS 딜레이 검증"

  # 각 항목 완료 후
  $(basename "$0") checklist done "HTML 태그"
  $(basename "$0") checklist done "PDF 변경사항"

  # 완료 선언 전 검사
  $(basename "$0") checklist verify   # 미완료 항목 있으면 exit 1

  # 신규 파일 생성 전
  $(basename "$0") session check "새파일.html"

  # dry-run 검사 (어떤 파일도 수정하지 않음)
  $(basename "$0") --dry-run full-check

클러스터: ${GUARD_CLUSTER_ID}
HELP
}

# ═══════════════════════════════════════════════════════════════
# 메인 진입점
# ═══════════════════════════════════════════════════════════════

main() {
  # 옵션 파싱
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --verbose)
        VERBOSE=1
        shift
        ;;
      --cluster-id)
        GUARD_CLUSTER_ID="${2:-${GUARD_CLUSTER_ID}}"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      -*)
        _gm_log "ERROR" "알 수 없는 옵션: $1"
        _gm_usage
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  # 서브커맨드
  local cmd="${1:-help}"
  shift || true

  # 의존성 확인
  _gm_check_deps || {
    _gm_log "ERROR" "가드 스크립트 누락. ${GUARD_DIR} 에 checklist-guard.sh / session-diff-guard.sh 가 있어야 합니다."
    exit 1
  }

  # dry-run 환경 적용
  _gm_apply_dry_run

  _gm_verbose "cmd=${cmd} dry_run=${DRY_RUN} verbose=${VERBOSE}"

  case "$cmd" in
    checklist)  _cmd_checklist "$@" ;;
    session)    _cmd_session "$@" ;;
    full-check) _cmd_full_check "$@" ;;
    status)     _cmd_status ;;
    help|--help|-h)
      _gm_usage
      exit 0
      ;;
    *)
      _gm_log "ERROR" "알 수 없는 서브커맨드: ${cmd}"
      _gm_usage
      exit 1
      ;;
  esac
}

main "$@"
