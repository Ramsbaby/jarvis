#!/usr/bin/env bash
# ssot-repo-guard.sh — SSoT 복수 저장소 교차 미검증 자동 가드 (pre-edit 훅 호출용)
#
# 클러스터 가드: cl-1a81b2956a7f0cc9
# 용도: 파일 편집 전 SSoT 저장소(~/projects/jarvis, ~/Jarvis-Vault 등)를 자동 스캔하여
#       파일이 어느 저장소에 속하는지 표시. 복수 저장소에 걸쳐있으면 경고.
#
# 사용:
#   bash ~/projects/jarvis/scripts/ssot-repo-guard.sh                    # 전체 저장소 스캔
#   bash ~/projects/jarvis/scripts/ssot-repo-guard.sh --identify <파일>  # 파일 저장소 식별
#   bash ~/projects/jarvis/scripts/ssot-repo-guard.sh --check <파일명>   # 동기화 필요 확인
#   bash ~/projects/jarvis/scripts/ssot-repo-guard.sh --list              # 저장소 목록 출력
#   bash ~/projects/jarvis/scripts/ssot-repo-guard.sh --status            # 마지막 결과 조회
#
# 반환 코드:
#   0 = 문제 없음
#   1 = 복수 저장소 또는 동기화 필요 경고 감지
#   2 = 의존 도구 없음 또는 가드 라이브러리 없음

set -uo pipefail

# ── 경로 설정 ────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JARVIS_INFRA="${SCRIPT_DIR%/scripts}/infra/lib"
GUARD_LIB="${JARVIS_INFRA}/cluster-guard-cl-1a81b2956a7f0cc9.sh"

# ── 가드 라이브러리 로드 ──────────────────────────────────────────────────────

if [[ ! -f "$GUARD_LIB" ]]; then
  echo "❌ [ssot-repo-guard] 가드 라이브러리 없음: ${GUARD_LIB}" >&2
  exit 2
fi

# shellcheck source=../infra/lib/cluster-guard-cl-1a81b2956a7f0cc9.sh
source "$GUARD_LIB"

# ── 인자 파싱 ────────────────────────────────────────────────────────────────

MODE="scan"
TARGET=""

usage() {
  cat >&2 <<'EOF'
사용법: ssot-repo-guard.sh [옵션] [대상]

옵션:
  (없음)                 전체 SSoT 저장소 스캔
  --list                 등록된 저장소 목록 출력
  --identify <파일>      파일이 속한 저장소 식별
  --check <파일명>       동일 이름 파일이 다른 저장소에도 있는지 확인
  --status               마지막 스캔 결과 요약
  -h, --help             이 도움말 출력

예시:
  ssot-repo-guard.sh                            # 전체 스캔
  ssot-repo-guard.sh --identify runtime/config/agent_tiers.json
  ssot-repo-guard.sh --check agent_tiers.json
  ssot-repo-guard.sh --list
EOF
}

for arg in "$@"; do
  case "$arg" in
    --scan)      MODE="scan";     shift ;;
    --list)      MODE="list";     shift ;;
    --identify)  MODE="identify"; shift; TARGET="${1:-}"; shift ;;
    --check)     MODE="check";    shift; TARGET="${1:-}"; shift ;;
    --status)    MODE="status";   shift ;;
    -h|--help)   usage; exit 0 ;;
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

echo "━━━ SSoT Repository Guard [${TIMESTAMP}] (cl-1a81b2956a7f0cc9) ━━━" >&2

case "$MODE" in
  scan)
    ssot_scan_all || RC=$?
    ;;

  list)
    ssot_list_repos || RC=$?
    ;;

  identify)
    if [[ -z "$TARGET" ]]; then
      echo "❌ --identify 에는 파일 경로 인자가 필요합니다." >&2
      usage
      exit 1
    fi
    repo=$(ssot_identify_repo "$TARGET" || true)
    if [[ -n "$repo" ]]; then
      echo "   저장소: $repo" >&2
      RC=0
    else
      RC=1
    fi
    ;;

  check)
    if [[ -z "$TARGET" ]]; then
      echo "❌ --check 에는 파일명 인자가 필요합니다." >&2
      usage
      exit 1
    fi
    ssot_check_sync "$TARGET" "verbose" || RC=$?
    ;;

  status)
    ssot_guard_status || RC=$?
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
  echo "━━━ 결과: 경고 감지 (exit ${RC}) — 편집 전 위 내용 확인 필수 ━━━" >&2
else
  echo "" >&2
  echo "━━━ 결과: 이상 없음 (exit 0) ━━━" >&2
fi

exit $RC
