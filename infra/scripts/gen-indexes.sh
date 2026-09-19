#!/usr/bin/env bash
set -euo pipefail

# gen-indexes.sh — AI 네비게이션용 인덱스 문서 자동 생성 (일일 크론)
#
# 맥도날드식 아키텍처의 핵심 자동화:
#   - ~/projects/jarvis/infra/docs/TASKS-INDEX.md + tasks-index.json   (82개 크론 → 팀별)
#   - ~/jarvis-board/docs/API-INDEX.md                        (69개 API route → 그룹별)
#
# 이 스크립트가 매일 돌면서 인덱스 문서가 코드와 드리프트되는 것을 방지한다.
#
# 2026-09-19: 생성 후 docs-generated-commit.sh 로 "내용이 실제로 바뀐 경우에만" 커밋한다.
#   예전엔 owner 판단 / agent-batch-commit 에 맡겼는데, batch-commit 은 런타임 저장소만
#   보고 비활성이라 타임스탬프 한 줄짜리 M 이 매일 06:17 마다 작업 트리에 남았다.
#   타임스탬프만 바뀐 경우는 커밋하지 않고 HEAD 로 되돌린다. push 는 하지 않는다
#   (공개 저장소 — 주인님 결재). 프라이버시 훅(.githooks/pre-commit)은 우회하지 않는다.
#   ~/jarvis-board 의 API-INDEX.md 도 같은 규칙으로 처리한다 (husky pre-commit 은 ts/tsx 만
#   보므로 md 단독 커밋은 "해당 작업 없음"으로 통과 — 2026-09-19 잡 PATH 로 확인).

LOG() { echo "[$(date '+%H:%M:%S')] $*"; }

JARVIS_ROOT="${HOME}/projects/jarvis"
BOARD_ROOT="${HOME}/jarvis-board"

fail=0

# 1) ~/projects/jarvis — TASKS-INDEX 생성 (+ 내용이 바뀐 경우에만 커밋)
if [[ -f "${JARVIS_ROOT}/infra/scripts/gen-tasks-index.mjs" ]]; then
    LOG "gen-tasks-index.mjs 실행"
    if ! node "${JARVIS_ROOT}/infra/scripts/gen-tasks-index.mjs"; then
        LOG "[ERROR] gen-tasks-index.mjs 실패"
        fail=1
    elif ! bash "${JARVIS_ROOT}/infra/scripts/docs-generated-commit.sh" \
            --repo "${JARVIS_ROOT}" \
            --message "docs: 태스크 인덱스 자동 갱신 (jarvis-gen-indexes)" \
            -- infra/docs/TASKS-INDEX.md infra/docs/tasks-index.json; then
        LOG "[ERROR] 태스크 인덱스 커밋 실패 — 작업 트리에 변경이 남아 있음"
        fail=1
    fi
else
    LOG "[WARN] gen-tasks-index.mjs 없음 — skip"
fi

# 2) ~/jarvis-board — API-INDEX 생성 (+ 내용이 바뀐 경우에만 커밋)
if [[ -f "${BOARD_ROOT}/scripts/gen-api-index.mjs" ]]; then
    LOG "gen-api-index.mjs 실행"
    if ! ( cd "${BOARD_ROOT}" && node scripts/gen-api-index.mjs ); then
        LOG "[ERROR] gen-api-index.mjs 실패"
        fail=1
    elif ! bash "${JARVIS_ROOT}/infra/scripts/docs-generated-commit.sh" \
            --repo "${BOARD_ROOT}" \
            --message "docs: API 인덱스 자동 갱신 (jarvis-gen-indexes)" \
            -- docs/API-INDEX.md; then
        LOG "[ERROR] API 인덱스 커밋 실패 — ~/jarvis-board 작업 트리에 변경이 남아 있음"
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
