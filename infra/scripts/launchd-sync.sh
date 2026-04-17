#!/usr/bin/env bash
# 레포 infra/launchd/*.plist → ~/Library/LaunchAgents/ 동기화.
# 기존 로드된 잡은 bootout 후 bootstrap으로 재등록.
#
# 재설치·다른 Mac 마이그레이션 시 이 스크립트 한 번으로 복구.
# 개별 plist는 레포가 SSoT. 로컬 파일 직접 편집 금지.

set -euo pipefail

REPO_LAUNCHD="${REPO_LAUNCHD:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../launchd" && pwd)}"
TARGET_DIR="$HOME/Library/LaunchAgents"
UID_NOW=$(id -u)

if [[ ! -d "$REPO_LAUNCHD" ]]; then
  echo "ERROR: 레포 launchd 디렉토리 없음: $REPO_LAUNCHD" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"

changed=0
for plist in "$REPO_LAUNCHD"/ai.jarvis.*.plist; do
  [[ -f "$plist" ]] || continue
  fname=$(basename "$plist")
  label="${fname%.plist}"
  target="$TARGET_DIR/$fname"

  # 내용 동일하면 스킵 (idempotent)
  if [[ -f "$target" ]] && cmp -s "$plist" "$target"; then
    echo "  [$label] 변경 없음 — 스킵"
    continue
  fi

  # 기존 잡 bootout (이름으로 확인)
  if launchctl list 2>/dev/null | awk '{print $3}' | grep -qx "$label"; then
    echo "  [$label] bootout (기존 잡 unload)"
    launchctl bootout "gui/$UID_NOW/$label" 2>/dev/null || true
  fi

  cp "$plist" "$target"
  echo "  [$label] 복사 완료 → $target"

  launchctl bootstrap "gui/$UID_NOW" "$target"
  echo "  [$label] bootstrap 완료"
  changed=$((changed + 1))
done

echo ""
echo "✅ launchd-sync 완료 — ${changed}개 갱신/신규"
launchctl list | grep -E "ai\.jarvis\.(report|watchdog|board)" | sort || true
