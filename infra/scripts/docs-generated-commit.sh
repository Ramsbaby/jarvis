#!/usr/bin/env bash
set -euo pipefail

# docs-generated-commit.sh — 자동 생성 문서를 "내용이 실제로 바뀐 경우에만" git commit
#
# 배경 (2026-09-19):
#   gen-tasks-index.mjs 등 생성기는 매 실행마다 파일을 통째로 다시 쓴다. 타임스탬프
#   한 줄만 바뀌어도 작업 트리에 M 으로 남는데 아무도 커밋하지 않아 드리프트가 쌓였다
#   (jarvis-gen-indexes 매일 06:17, jarvis-docs-freshness-audit 월 09:10). 원래 기대하던
#   agent-batch-commit 은 런타임 저장소만 보고 비활성이라 이 파일들을 건드리지 않는다.
#
# 판정:
#   - 타임스탬프 줄(generatedAt / Last run / Generated)을 제외한 diff 가 비어 있으면
#     "내용 변화 없음" → 커밋하지 않고 파일을 HEAD 로 되돌린다 (작업 트리 청결 유지).
#   - 한 파일이라도 내용이 바뀌었으면, 변경된 파일 전부(타임스탬프만 바뀐 형제 포함)를
#     add + commit 한다. `--only` 라 다른 스테이징 변경은 섞이지 않는다.
#   - push 는 하지 않는다. 공개 저장소이므로 push 는 주인님 결재 사항.
#   - 커밋 훅(.githooks/pre-commit 프라이버시 스캔)은 우회하지 않는다. --no-verify 금지.
#
# 사용:
#   docs-generated-commit.sh [--repo DIR] [--message MSG] [--ignore ERE]... -- FILE...
#   FILE 은 저장소 루트 기준 상대 경로. 추적되지 않는 파일은 경고 후 건너뛴다.
#   --ignore 를 하나도 주지 않으면 기본 타임스탬프 패턴 2종을 쓴다.
#
# 종료코드: 0 = 변화 없음(커밋 생략) 또는 커밋 성공 / 1 = 인자 오류·git 없음·커밋 실패
#
# bash 3.2(/bin/bash) 호환: 빈 배열은 길이 검사 후에만 펼친다 (set -u).

LOG() { echo "[$(date '+%H:%M:%S')] docs-generated-commit: $*"; }
ERR() { LOG "[ERROR] $*" >&2; }

usage() {
    sed -n '4,25p' "$0" | sed 's/^# \{0,1\}//'
}

REPO="${HOME}/projects/jarvis"
MESSAGE="docs: 자동 생성 문서 갱신"
declare -a IGNORES
declare -a FILES

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)    REPO="$2"; shift 2 ;;
        --message) MESSAGE="$2"; shift 2 ;;
        --ignore)  IGNORES+=("$2"); shift 2 ;;
        --)        shift; FILES=("$@"); break ;;
        -h|--help) usage; exit 0 ;;
        *)         ERR "알 수 없는 인자: $1"; usage >&2; exit 1 ;;
    esac
done

if [[ ${#FILES[@]} -eq 0 ]]; then
    ERR "대상 파일 없음 (-- FILE... 필요)"
    exit 1
fi

# 기본 무시 패턴 — 생성기 3종(gen-tasks-index / gen-cron-matrix / gen-launchagent-catalog /
# gen-discord-channels)이 찍는 타임스탬프 줄. git diff -I 는 POSIX ERE 를 받는다.
if [[ ${#IGNORES[@]} -eq 0 ]]; then
    IGNORES=('^> (Last run|Generated): ' '^[[:space:]]*"generatedAt": ')
fi
declare -a IGNORE_ARGS
for re in "${IGNORES[@]}"; do IGNORE_ARGS+=("-I" "$re"); done

if ! command -v git >/dev/null 2>&1; then
    ERR "git 없음 (PATH=$PATH)"
    exit 1
fi
if ! git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
    ERR "git 저장소 아님: $REPO"
    exit 1
fi

declare -a CHANGED   # HEAD 대비 어떤 식으로든 바뀐 파일
declare -a REAL      # 타임스탬프 줄을 제외하고도 바뀐 파일
for f in "${FILES[@]}"; do
    if ! git -C "$REPO" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
        LOG "[WARN] 추적되지 않는 파일 — 건너뜀: $f"
        continue
    fi
    # HEAD 기준으로 본다. 생성기는 작업 트리를 쓰므로 인덱스 상태와 무관하게 판정.
    if git -C "$REPO" diff --quiet HEAD -- "$f"; then
        continue
    fi
    CHANGED+=("$f")
    if ! git -C "$REPO" diff --quiet "${IGNORE_ARGS[@]}" HEAD -- "$f"; then
        REAL+=("$f")
    fi
done

if [[ ${#CHANGED[@]} -eq 0 ]]; then
    LOG "변경 없음 — 커밋 생략"
    exit 0
fi

if [[ ${#REAL[@]} -eq 0 ]]; then
    LOG "타임스탬프만 변경 (${#CHANGED[@]}개) — 커밋하지 않고 HEAD 로 되돌림: ${CHANGED[*]}"
    git -C "$REPO" checkout --quiet HEAD -- "${CHANGED[@]}"
    exit 0
fi

LOG "내용 변경 ${#REAL[@]}개: ${REAL[*]}"
LOG "커밋 대상 ${#CHANGED[@]}개 (타임스탬프만 바뀐 형제 포함): ${CHANGED[*]}"
git -C "$REPO" add -- "${CHANGED[@]}"
# --only: 명시한 경로의 작업 트리 내용만 커밋. 다른 스테이징 변경은 그대로 둔다.
# 훅은 우회하지 않는다 — 프라이버시 스캔이 거부하면 커밋은 실패해야 한다.
if ! GIT_TERMINAL_PROMPT=0 git -C "$REPO" commit --only --quiet -m "$MESSAGE" -- "${CHANGED[@]}"; then
    ERR "커밋 실패 (프라이버시 훅 거부 등) — 스테이징 해제, 작업 트리 변경은 보존"
    git -C "$REPO" reset --quiet -- "${CHANGED[@]}" || true
    exit 1
fi
LOG "커밋 완료: $(git -C "$REPO" log -1 --format='%h %s')"
exit 0
