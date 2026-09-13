#!/usr/bin/env bash
# ssot-conflict-guard.sh — SSoT 충돌 전파 차단 가드 CLI
#
# 클러스터 ID  : cl-de95f30916b8c9a2 (최근 7일 재발 4건)
# 대표 시드    : SSoT 규칙 인식했으나 근본 위반 구조 방치
#
# 이 파일: lib 가드의 CLI 래퍼. 파이프라인·pre-commit·배치 크론에서 직접 호출한다.
# 핵심 로직은 ~/projects/jarvis/infra/lib/cluster-guard-cl-de95f30916b8c9a2.sh 에 있다.
#
# 사용법:
#   ssot-conflict-guard.sh --test-conflict         # 충돌 감지 셀프테스트 (exit 1 반환)
#   ssot-conflict-guard.sh --test-clean            # 정상 패스 셀프테스트 (exit 0 반환)
#   ssot-conflict-guard.sh prewrite-check <text> [domain]
#   ssot-conflict-guard.sh propagation-gate <label> [--force] <dest1> [dest2 ...]
#   ssot-conflict-guard.sh root-cause <violation_id> <root_cause_text>
#   ssot-conflict-guard.sh status
#   ssot-conflict-guard.sh scan
#
# 파이프라인 통합 예시:
#   ssot-conflict-guard.sh prewrite-check "연봉 <금액>만원 <연도>" career || exit 1
#   ssot-conflict-guard.sh propagation-gate "salary-update" wiki discord || exit 1

set -o pipefail

readonly _GUARD_LIB="${HOME}/projects/jarvis/infra/lib/cluster-guard-cl-de95f30916b8c9a2.sh"

if [[ ! -f "$_GUARD_LIB" ]]; then
  echo "❌ [ssot-conflict-guard] 라이브러리 없음: $_GUARD_LIB" >&2
  exit 127
fi

# shellcheck source=/dev/null
source "$_GUARD_LIB"

_usage() {
  cat >&2 <<'EOF'
ssot-conflict-guard.sh — SSoT 충돌 전파 차단 가드 (cl-de95f30916b8c9a2)

사용법:
  --test-conflict               충돌 감지 셀프테스트 (exit 1 예상)
  --test-clean                  정상 패스 셀프테스트 (exit 0 예상)
  prewrite-check <text> [dom]   신규 사실 쓰기 전 충돌 검사
  propagation-gate <lbl> [--force] <d1> [d2 ...]  다중 전파 게이트
  root-cause <vid> <reason>     위반 근본 원인 기록
  status                        최근 이벤트 요약
  scan                          미해결 위반 스캔
EOF
}

cmd="${1:-}"

case "$cmd" in

  # ── 셀프테스트: 충돌 시나리오 ──────────────────────────────────────────────
  # ssot_propagation_gate는 wiki 스캔 없이도 2개+ 대상에서 즉시 exit 1을 반환한다.
  # 이를 이용해 "wiki 내용 의존 없이" 충돌 감지 동작을 검증한다.
  --test-conflict)
    ssot_propagation_gate "cl-de95-selftest-conflict" "dest_alpha" "dest_beta" >/dev/null 2>&1
    exit_code=$?
    if [[ "$exit_code" -eq 1 ]]; then
      echo "✅ [ssot-conflict-guard] --test-conflict: 충돌 감지 정상 (exit 1)" >&2
      exit 1  # 셀프테스트가 충돌을 올바르게 감지했음을 상위에 알림
    else
      echo "❌ [ssot-conflict-guard] --test-conflict: 충돌 미감지 (exit $exit_code — 예상: 1)" >&2
      exit 2
    fi
    ;;

  # ── 셀프테스트: 정상 패스 ───────────────────────────────────────────────────
  # 완전 고유 토큰을 사용해 wiki _facts.md와 충돌이 없는 케이스를 검증한다.
  --test-clean)
    _unique="CLDE95TESTONLY $(date +%s) ssot-conflict-guard-selftest-xzq9"
    ssot_prewrite_check "$_unique" >/dev/null 2>&1
    exit_code=$?
    if [[ "$exit_code" -eq 0 ]]; then
      echo "✅ [ssot-conflict-guard] --test-clean: 충돌 없음 정상 (exit 0)" >&2
      exit 0
    else
      echo "❌ [ssot-conflict-guard] --test-clean: 예상치 못한 충돌 (exit $exit_code)" >&2
      exit 2
    fi
    ;;

  # ── 서브커맨드 라우팅 ───────────────────────────────────────────────────────
  prewrite-check)
    shift
    ssot_prewrite_check "$@"
    ;;

  propagation-gate)
    shift
    ssot_propagation_gate "$@"
    ;;

  root-cause)
    shift
    ssot_root_cause_require "$@"
    ;;

  status)
    ssot_conflict_status
    ;;

  scan)
    ssot_unresolved_scan
    ;;

  --help|-h|"")
    _usage
    exit 0
    ;;

  *)
    echo "❌ [ssot-conflict-guard] 알 수 없는 명령: $cmd" >&2
    _usage
    exit 1
    ;;
esac
