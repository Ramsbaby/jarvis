#!/usr/bin/env bash
set -euo pipefail
# install-hooks.sh — git hook 자동 설치 (fork/clone 사용자용)
#
# 기본 git은 .git/hooks/ 를 추적하지 않으므로 fork 사용자는 hook 없이 시작.
# 이 스크립트는 core.hooksPath를 .githooks로 지정해 git-tracked hook을 활성화.
#
# Usage:
#   bash infra/scripts/install-hooks.sh

# 메인 레포 우선 (worktree에서 실행 시 common dir 참조)
if GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null); then
    REPO_ROOT=$(dirname "$(cd "$GIT_COMMON_DIR" && pwd)")
else
    REPO_ROOT="$HOME/jarvis"
fi
HOOKS_SRC="$REPO_ROOT/.githooks"

if [[ ! -d "$HOOKS_SRC" ]]; then
    echo "ERROR: $HOOKS_SRC 디렉토리 없음"
    exit 1
fi

if [[ ! -d "$HOOKS_SRC" ]]; then
    echo "ERROR: $HOOKS_SRC 디렉토리 없음"
    exit 1
fi

# Option 1 (권장): core.hooksPath 설정 — 모든 hook 자동 반영
git -C "$REPO_ROOT" config core.hooksPath .githooks
echo "✅ git config core.hooksPath = .githooks (repo: $REPO_ROOT)"

# 실행 권한
chmod +x "$HOOKS_SRC"/* 2>/dev/null || true
echo "✅ .githooks/* executable"

# 검증
HOOK_LIST=$(ls "$HOOKS_SRC" 2>/dev/null | tr '\n' ' ')
echo "✅ 설치된 hooks: $HOOK_LIST"
echo ""
echo "이제 커밋 시 .githooks/pre-commit이 자동 실행됩니다."
echo "롤백: git -C $REPO_ROOT config --unset core.hooksPath"
