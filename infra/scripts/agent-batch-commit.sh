#!/usr/bin/env bash
# agent-batch-commit.sh — 에이전트 산출물 일괄 git commit
# 각 팀 크론이 개별 commit 시 발생하는 충돌을 방지하기 위해
# 별도 크론으로 변경사항을 일괄 처리.
#
# 사용법:
#   ~/jarvis/runtime/scripts/agent-batch-commit.sh [--dry-run]
#
# git add 대상:
#   state/*.md, state/*.json
#   state/board-minutes/, state/decisions/
#   context/**
#   results/**/
#   teams/*/results/
set -euo pipefail

# ── 경로 설정 ────────────────────────────────────────────────
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOCK_FILE="/tmp/jarvis-batch-commit.lock"
LOG_FILE="${BOT_HOME}/logs/agent-batch-commit.log"
DRY_RUN=false

# ── 인자 처리 ────────────────────────────────────────────────
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        DRY_RUN=true
    fi
done

# ── 로그 헬퍼 ───────────────────────────────────────────────
#   INFO/DEBUG 는 stdout 으로, WARN/ERROR 만 stderr 로 분리한다.
#   이전에는 level 상관없이 전부 `>&2` 로 흘려보냈는데, 크론 감사
#   시스템(/api/crons) 이 `-err.log` 비어있지 않음 = 실패 로 판단해서
#   정상 INFO 로그만 있는 agent-batch-commit 이 계속 failed 로 오분류됐다.
log() {
    local level="${1:-INFO}"
    local msg="${2:-}"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local line="${ts} [${level}] agent-batch-commit: ${msg}"
    if [[ "${level}" == "ERROR" || "${level}" == "WARN" ]]; then
        echo "${line}" | tee -a "${LOG_FILE}" >&2
    else
        echo "${line}" | tee -a "${LOG_FILE}"
    fi
}

# ── git repo 여부 확인 ───────────────────────────────────────
if ! git -C "${BOT_HOME}" rev-parse --git-dir >/dev/null 2>&1; then
    log "INFO" "git repo 아님 — skip (${BOT_HOME})"
    exit 0
fi

# ── lock 획득 (동시 실행 방지, macOS mkdir atomic) ──────────
LOCK_DIR="${LOCK_FILE}.d"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    # lock 디렉토리가 이미 존재하면 PID 확인 후 stale이면 제거
    LOCK_PID_FILE="${LOCK_DIR}/pid"
    if [[ -f "${LOCK_PID_FILE}" ]]; then
        LOCK_PID=$(cat "${LOCK_PID_FILE}" 2>/dev/null || echo "")
        if [[ -n "${LOCK_PID}" ]] && kill -0 "${LOCK_PID}" 2>/dev/null; then
            log "WARN" "다른 인스턴스 실행 중 (PID ${LOCK_PID}) — skip"
            exit 0
        else
            log "INFO" "stale lock 제거 후 재시도"
            rm -rf "${LOCK_DIR}"
            mkdir "${LOCK_DIR}" 2>/dev/null || { log "WARN" "lock 재획득 실패 — skip"; exit 0; }
        fi
    else
        log "WARN" "다른 인스턴스 실행 중 — lock 획득 실패, skip"
        exit 0
    fi
fi
echo "$$" > "${LOCK_DIR}/pid"

# ── lock 정리 trap ───────────────────────────────────────────
cleanup() {
    rm -rf "${LOCK_DIR}"
}
trap cleanup EXIT INT TERM

# ── stage 대상 경로 정의 ─────────────────────────────────────
# 존재하는 경로만 add (없으면 git add가 경고하므로 사전 필터)
STAGE_PATHS=(
    "state/*.md"
    "state/*.json"
    "state/board-minutes"
    "state/decisions"
    "context"
    "results"
    "teams"
)

# ── 변경 파일 유무 사전 체크 ─────────────────────────────────
cd "${BOT_HOME}"

# stage 대상 경로들을 임시로 add해서 변경 여부 확인
# (git add --dry-run은 untracked도 포함하므로 신뢰도 높음)
CHANGED=false
for path_pattern in "${STAGE_PATHS[@]}"; do
    # glob이 포함된 경우 eval 없이 처리
    if git add --dry-run -- "${path_pattern}" 2>/dev/null | grep -q .; then
        CHANGED=true
        break
    fi
done

# staged 변경 + unstaged 변경도 체크
if [[ "$CHANGED" == "false" ]]; then
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        CHANGED=true
    fi
fi

if [[ "$CHANGED" == "false" ]]; then
    log "INFO" "변경사항 없음 — skip"
    exit 0
fi

# ── dry-run 모드 ─────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
    log "INFO" "[dry-run] 아래 파일이 커밋 대상입니다:"
    for path_pattern in "${STAGE_PATHS[@]}"; do
        git add --dry-run -- "${path_pattern}" 2>/dev/null || true
    done
    exit 0
fi

# ── git add ─────────────────────────────────────────────────
ADDED_COUNT=0
for path_pattern in "${STAGE_PATHS[@]}"; do
    # shellcheck disable=SC2086  # glob 의도적 사용
    added=$(git add -- ${path_pattern} 2>/dev/null && \
            git diff --cached --name-only -- ${path_pattern} 2>/dev/null | wc -l | tr -d ' ') || added=0
    ADDED_COUNT=$(( ADDED_COUNT + added ))
done

# staged 파일이 실제로 있는지 재확인
if git diff --cached --quiet 2>/dev/null; then
    log "INFO" "stage된 변경사항 없음 — skip"
    exit 0
fi

STAGED_FILES=$(git diff --cached --name-only | wc -l | tr -d ' ')

# ── git commit ───────────────────────────────────────────────
COMMIT_MSG="[jarvis-auto] batch commit $(date '+%Y-%m-%d %H:%M')"

if git commit -m "${COMMIT_MSG}" --no-gpg-sign -q 2>/dev/null; then
    log "INFO" "커밋 완료: ${STAGED_FILES}개 파일 — \"${COMMIT_MSG}\""
else
    EXIT=$?
    log "ERROR" "git commit 실패 (exit ${EXIT})"
    exit "${EXIT}"
fi