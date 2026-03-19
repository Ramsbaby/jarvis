#!/usr/bin/env bash
# deploy-private.sh — jarvis-private(비공개) 레포에 민감 파일 포함 전체 백업
# 사용: bash ~/.jarvis/scripts/deploy-private.sh
# 공개 레포(origin)는 .gitignore 적용. 비공개 레포(private)는 민감 파일 포함.

set -euo pipefail
# Recursion guard: post-commit hook이 deploy를 트리거 → deploy가 commit → hook이 다시 트리거되는 루프 방지
if [[ "${JARVIS_PRIVATE_DEPLOYING:-}" == "1" ]]; then exit 0; fi
export JARVIS_PRIVATE_DEPLOYING=1

BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
cd "$BOT_HOME"

echo "=== Jarvis Private 레포 배포 ==="

# 1. 비공개 레포 remote 확인
if ! git remote get-url private &>/dev/null; then
  echo "❌ 'private' remote 없음. 먼저 실행:"
  echo "   git remote add private https://github.com/Ramsbaby/jarvis-private.git"
  exit 1
fi

# 2. 현재 브랜치 저장
CURRENT_BRANCH=$(git branch --show-current)
TEMP_BRANCH="private-deploy-$(date +%s)"

# 민감 파일 목록
PRIVATE_FILES=(
  "discord/personas.json"
  "config/secrets"
  "config/user-schedule.json"
  "config/user_profiles.json"
  "config/goals.json"
  "discord/.env"
  "context/owner/preferences.md"
)

# ⚠️ 중요: git checkout 브랜치 전환 시 커밋된 파일이 삭제됨 방지
# 브랜치 전환 전 민감 파일을 tmp에 백업, 전환 후 복원
SAFE_BACKUP_DIR="/tmp/jarvis-deploy-safe-$$"
mkdir -p "$SAFE_BACKUP_DIR"
echo "▶ 민감 파일 사전 백업 (브랜치 전환 시 삭제 방지):"
for f in "${PRIVATE_FILES[@]}"; do
  if [[ -e "$BOT_HOME/$f" ]]; then
    mkdir -p "$SAFE_BACKUP_DIR/$(dirname "$f")"
    cp -r "$BOT_HOME/$f" "$SAFE_BACKUP_DIR/$f" && echo "  💾 $f"
  fi
done

# trap: 어떤 경우에도 민감 파일 복원 + 임시 백업 제거
cleanup_deploy() {
  echo "▶ 민감 파일 복원 중..."
  for f in "${PRIVATE_FILES[@]}"; do
    if [[ -e "$SAFE_BACKUP_DIR/$f" && ! -e "$BOT_HOME/$f" ]]; then
      mkdir -p "$(dirname "$BOT_HOME/$f")"
      cp -r "$SAFE_BACKUP_DIR/$f" "$BOT_HOME/$f" && echo "  ♻️  복원: $f"
    fi
  done
  rm -rf "$SAFE_BACKUP_DIR"
  # 임시 브랜치 정리 (이미 삭제됐을 수 있음)
  git branch -D "$TEMP_BRANCH" 2>/dev/null || true
}
trap cleanup_deploy EXIT

echo "▶ 임시 브랜치 생성: $TEMP_BRANCH"
git checkout -b "$TEMP_BRANCH"

# 3. 민감 파일 강제 추가 (gitignore 우회)
echo "▶ 민감 파일 force-add:"
for f in "${PRIVATE_FILES[@]}"; do
  if [[ -e "$BOT_HOME/$f" ]]; then
    git add -f "$f" && echo "  ✅ $f" || echo "  ⚠️ 스킵: $f"
  else
    echo "  — 없음: $f"
  fi
done

# 4. 변경 사항 있을 때만 커밋
if git diff --cached --quiet; then
  echo "▶ 민감 파일 변경 없음 — 기존 커밋 그대로 푸시"
else
  git commit -m "chore(private): 민감 설정 파일 백업 $(date '+%Y-%m-%d %H:%M')"
fi

# 5. private remote에 푸시
echo "▶ jarvis-private으로 푸시..."
git push private "$TEMP_BRANCH:main" --force-with-lease 2>/dev/null || \
git push private "$TEMP_BRANCH:main" --force

echo "✅ jarvis-private 푸시 완료"

# 6. 원래 브랜치로 복귀 (trap이 민감 파일 자동 복원 + temp 브랜치 정리)
git checkout "$CURRENT_BRANCH"

echo ""
echo "=== 완료 ==="
echo "- 공개 레포 (origin): 민감 파일 제외"
echo "- 비공개 레포 (private): 민감 파일 포함 전체 백업"
