#!/usr/bin/env bash
set -euo pipefail

# gen-indexes.sh — AI 네비게이션용 인덱스 문서 자동 생성 (일일 크론)
#
# 맥도날드식 아키텍처의 핵심 자동화:
#   - ~/jarvis/infra/docs/TASKS-INDEX.md + tasks-index.json   (82개 크론 → 팀별)
#   - ~/jarvis-board/docs/API-INDEX.md                        (69개 API route → 그룹별)
#
# 이 스크립트가 매일 돌면서 인덱스 문서가 코드와 드리프트되는 것을 방지한다.
# 생성된 파일에 변경이 있으면 알림만 내고, 실제 git commit 은 owner 가 판단한다
# (또는 별도 agent-batch-commit 크론이 나중에 묶어서 커밋).

LOG() { echo "[$(date '+%H:%M:%S')] $*"; }

JARVIS_ROOT="${HOME}/jarvis"
BOARD_ROOT="${HOME}/jarvis-board"

fail=0

# 1) ~/jarvis — TASKS-INDEX 생성
if [[ -f "${JARVIS_ROOT}/infra/scripts/gen-tasks-index.mjs" ]]; then
    LOG "gen-tasks-index.mjs 실행"
    if ! node "${JARVIS_ROOT}/infra/scripts/gen-tasks-index.mjs"; then
        LOG "[ERROR] gen-tasks-index.mjs 실패"
        fail=1
    fi
else
    LOG "[WARN] gen-tasks-index.mjs 없음 — skip"
fi

# 2) ~/jarvis-board — API-INDEX 생성
if [[ -f "${BOARD_ROOT}/scripts/gen-api-index.mjs" ]]; then
    LOG "gen-api-index.mjs 실행"
    if ! ( cd "${BOARD_ROOT}" && node scripts/gen-api-index.mjs ); then
        LOG "[ERROR] gen-api-index.mjs 실패"
        fail=1
    fi
else
    LOG "[WARN] gen-api-index.mjs 없음 — skip"
fi

if [[ ${fail} -eq 1 ]]; then
    LOG "일부 인덱스 생성 실패"
    exit 1
fi

LOG "모든 인덱스 갱신 완료"
exit 0
