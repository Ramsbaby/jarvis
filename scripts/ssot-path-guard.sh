#!/usr/bin/env bash
# ssot-path-guard.sh — SSoT 경로 중복·귀인 오류 자동 가드 (독립 실행 / 훅 호출용)
#
# 클러스터 가드: cl-eba9e129c709bb2a
# 용도: 파일 편집 전 SSoT 루트(~/.jarvis, ~/projects/jarvis, ~/Jarvis-Vault 등)를 자동 스캔하여
#       중복·불일치 경로를 감지. 경로 귀인 오류를 시스템 수준에서 차단.
#
# 사용:
#   bash ~/projects/jarvis/scripts/ssot-path-guard.sh                    # 전체 중복 스캔
#   bash ~/projects/jarvis/scripts/ssot-path-guard.sh --verify <파일>    # 특정 파일/경로 실측
#   bash ~/projects/jarvis/scripts/ssot-path-guard.sh --cross <파일명>   # 이중 경로 교차 비교
#   bash ~/projects/jarvis/scripts/ssot-path-guard.sh --status           # 마지막 결과 조회
#   bash ~/projects/jarvis/scripts/ssot-path-guard.sh --scan             # 루트 파일 수 통계만
#   bash ~/projects/jarvis/scripts/ssot-path-guard.sh --all <파일명>     # verify + cross 통합
#
# 반환 코드:
#   0 = 문제 없음
#   1 = 중복 또는 불일치 감지
#   2 = 의존 도구 없음 또는 가드 라이브러리 없음

set -uo pipefail

# ── 경로 설정 ────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JARVIS_INFRA="${SCRIPT_DIR%/scripts}/infra/lib"
GUARD_LIB="${JARVIS_INFRA}/cluster-guard-cl-eba9e129c709bb2a.sh"

# ── 가드 라이브러리 로드 ──────────────────────────────────────────────────────

if [[ ! -f "$GUARD_LIB" ]]; then
  echo "❌ [ssot-path-guard] 가드 라이브러리 없음: ${GUARD_LIB}" >&2
  exit 2
fi

# shellcheck source=../infra/lib/cluster-guard-cl-eba9e129c709bb2a.sh
source "$GUARD_LIB"

# ── 인자 파싱 ────────────────────────────────────────────────────────────────

MODE="detect"
TARGET=""

usage() {
  cat >&2 <<'EOF'
사용법: ssot-path-guard.sh [옵션] [대상]

옵션:
  (없음)              전체 SSoT 루트 중복 파일 스캔
  --scan              루트별 파일 수 통계 출력
  --verify <경로|명>  지정 파일의 실재 여부 + 다른 위치 탐색
  --cross <파일명>    runtime/config vs infra/config 이중 경로 교차 비교
  --all <파일명>      --verify + --cross 통합 실행
  --status            마지막 스캔 결과 요약
  -h, --help          이 도움말 출력

예시:
  ssot-path-guard.sh                            # 전체 중복 감지
  ssot-path-guard.sh --verify agent_tiers.json  # 특정 파일 실측
  ssot-path-guard.sh --cross discord-channels.json
  ssot-path-guard.sh --all channel-map.json     # verify + cross 통합
EOF
}

for arg in "$@"; do
  case "$arg" in
    --scan)   MODE="scan";   shift ;;
    --verify) MODE="verify"; shift; TARGET="${1:-}"; shift ;;
    --cross)  MODE="cross";  shift; TARGET="${1:-}"; shift ;;
    --all)    MODE="all";    shift; TARGET="${1:-}"; shift ;;
    --status) MODE="status"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "⚠️  알 수 없는 옵션: $arg" >&2
      usage
      exit 1
      ;;
    *)  ;;
  esac
done

# ── 실행 ─────────────────────────────────────────────────────────────────────

TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')
RC=0

echo "━━━ SSoT Path Guard [${TIMESTAMP}] (${_CL_EBA9_ID}) ━━━" >&2

case "$MODE" in
  scan)
    ssot_scan_roots || RC=$?
    ;;

  detect)
    ssot_detect_duplicates || RC=$?
    ;;

  verify)
    if [[ -z "$TARGET" ]]; then
      echo "❌ --verify 에는 파일 경로 또는 이름 인자가 필요합니다." >&2
      usage
      exit 1
    fi
    ssot_verify_path "$TARGET" || RC=$?
    ;;

  cross)
    if [[ -z "$TARGET" ]]; then
      echo "❌ --cross 에는 파일명 인자가 필요합니다." >&2
      usage
      exit 1
    fi
    ssot_cross_check_config "$TARGET" || RC=$?
    ;;

  all)
    if [[ -z "$TARGET" ]]; then
      echo "❌ --all 에는 파일명 인자가 필요합니다." >&2
      usage
      exit 1
    fi
    ssot_verify_path "$TARGET" || RC=$?
    ssot_cross_check_config "$TARGET" || RC=$?
    ;;

  status)
    ssot_guard_status
    ;;

  *)
    echo "❌ 알 수 없는 모드: $MODE" >&2
    usage
    exit 1
    ;;
esac

# ── 종료 코드 출력 ────────────────────────────────────────────────────────────

if [[ $RC -ne 0 ]]; then
  echo "" >&2
  echo "━━━ 결과: 문제 감지 (exit ${RC}) — 편집 전 위 경고 확인 필수 ━━━" >&2
else
  echo "" >&2
  echo "━━━ 결과: 이상 없음 (exit 0) ━━━" >&2
fi

exit $RC
