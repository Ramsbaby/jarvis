#!/usr/bin/env bash
# mcp-path-validator.sh — MCP 서버 설정 경로 실측 검증 (독립 실행 / 훅 호출용)
#
# 클러스터 가드: cl-5df6f4a4943a2b1f
# 용도: .mcp.json 에 등록된 모든 경로가 실제 존재하는지 자동 검증.
#        저장소 구조 변경 시 git hook에서 호출되거나 독립 실행.
#
# 사용:
#   bash ~/projects/jarvis/infra/lib/mcp-path-validator.sh              # 기본 전체 검증
#   bash ~/projects/jarvis/infra/lib/mcp-path-validator.sh --cross      # 교차 검증 포함
#   bash ~/projects/jarvis/infra/lib/mcp-path-validator.sh --status     # 마지막 결과 조회
#   bash ~/projects/jarvis/infra/lib/mcp-path-validator.sh ~/.mcp.json  # 특정 파일만
#
# 반환 코드:
#   0 = 모든 경로 정상
#   1 = 경로 누락 또는 교차 불일치 감지
#   2 = 의존 도구(jq) 없음

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_LIB="${SCRIPT_DIR}/cluster-guard-cl-5df6f4a4943a2b1f.sh"

# ── 의존성 확인 ─────────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  echo "❌ [mcp-path-validator] jq 없음 — brew install jq 로 설치 필요" >&2
  exit 2
fi

if [[ ! -f "$GUARD_LIB" ]]; then
  echo "❌ [mcp-path-validator] 가드 라이브러리 없음: ${GUARD_LIB}" >&2
  exit 2
fi

# shellcheck source=cluster-guard-cl-5df6f4a4943a2b1f.sh
source "$GUARD_LIB"

# ── 인자 파싱 ───────────────────────────────────────────────────────────────

MODE="validate"
EXTRA_CONFIGS=()

for arg in "$@"; do
  case "$arg" in
    --cross)  MODE="cross" ;;
    --status) MODE="status" ;;
    --help|-h)
      echo "사용: mcp-path-validator.sh [--cross|--status] [config_file...]"
      echo "  --cross    교차 검증 (동일 서버 다른 경로 탐지) 포함"
      echo "  --status   마지막 검증 결과 조회"
      exit 0
      ;;
    -*)
      echo "⚠️  알 수 없는 옵션: $arg" >&2
      ;;
    *)
      EXTRA_CONFIGS+=("$arg")
      ;;
  esac
done

# ── 실행 ─────────────────────────────────────────────────────────────────────

RC=0
TIMESTAMP=$(date '+%Y-%m-%dT%H:%M:%S')

echo "━━━ MCP Path Validator [$TIMESTAMP] ━━━" >&2

case "$MODE" in
  status)
    mcp_guard_status
    ;;
  cross)
    mcp_validate_paths "${EXTRA_CONFIGS[@]+"${EXTRA_CONFIGS[@]}"}" || RC=$?
    echo "" >&2
    mcp_cross_validate || RC=$?
    ;;
  validate)
    mcp_validate_paths "${EXTRA_CONFIGS[@]+"${EXTRA_CONFIGS[@]}"}" || RC=$?
    ;;
esac

# 누락 감지 시 교차 검증 자동 추가 실행
if [[ $RC -ne 0 && "$MODE" == "validate" ]]; then
  echo "" >&2
  echo "ℹ️  [mcp-path-validator] 누락 감지 — 교차 검증 자동 실행" >&2
  mcp_cross_validate || true
fi

if [[ $RC -ne 0 ]]; then
  echo "" >&2
  echo "━━━ 조치 안내 ━━━" >&2
  echo "  1. 위 누락 경로가 실제로 존재하는지 확인: ls <경로>" >&2
  echo "  2. 경로 이동/삭제 시 해당 .mcp.json 의 args 항목을 함께 갱신" >&2
  echo "  3. Serena 미작동 전에 이 스크립트로 경로 확인: bash ${BASH_SOURCE[0]}" >&2
  echo "━━━━━━━━━━━━━━━━" >&2
fi

exit $RC
