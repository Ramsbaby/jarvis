#!/usr/bin/env bash
# 마지막 태그부터 HEAD까지의 커밋을 conventional commits 타입별로 묶어
# 오너가 한눈에 읽기 쉬운 release notes를 만든다. 결과는 stdout.
#
# Usage: release-notes.sh <last_tag> <new_tag> [repo_slug]
#   repo_slug: 기본 ${GITHUB_REPOSITORY} (Actions 환경에서 자동 주입)
#
# 로컬 테스트 (macOS bash 3.2 호환):
#   bash .github/scripts/release-notes.sh v2.1.0 v2.2.0 Ramsbaby/jarvis

set -euo pipefail

LAST_TAG="${1:?last_tag required (e.g. v2.1.0)}"
NEW_TAG="${2:?new_tag required (e.g. v2.2.0)}"
REPO_SLUG="${3:-${GITHUB_REPOSITORY:-Ramsbaby/jarvis}}"

# 범위 끝: NEW_TAG가 이미 git 태그로 존재하면 그 커밋까지,
# 없으면 HEAD (workflow에서 release create 직전에 호출되는 케이스).
if git rev-parse --verify "${NEW_TAG}^{commit}" >/dev/null 2>&1; then
  RANGE_END="$NEW_TAG"
else
  RANGE_END="HEAD"
fi

TYPES="feat fix perf refactor docs test build ci chore style revert"

title_for() {
  case "$1" in
    feat)     echo "✨ 새 기능" ;;
    fix)      echo "🐛 버그 수정" ;;
    perf)     echo "⚡ 성능 개선" ;;
    refactor) echo "♻️ 리팩토링" ;;
    docs)     echo "📝 문서" ;;
    test)     echo "✅ 테스트" ;;
    build)    echo "📦 빌드" ;;
    ci)       echo "👷 CI" ;;
    chore)    echo "🔧 기타" ;;
    style)    echo "💄 스타일" ;;
    revert)   echo "⏪ 되돌림" ;;
    *)        echo "🔀 기타" ;;
  esac
}

# 특정 타입 커밋 → "- subject (`hash`)" 라인들
commits_of_type() {
  local type="$1"
  git log "${LAST_TAG}..${RANGE_END}" --format='%h %s' 2>/dev/null |
    grep -E "^[a-f0-9]+ ${type}(\([^)]+\))?!?: " |
    sed -E "s/^([a-f0-9]+) (.+)$/- \2 (\`\1\`)/" || true
}

# 알려진 타입에 안 잡히는 커밋
commits_other() {
  git log "${LAST_TAG}..${RANGE_END}" --format='%h %s' 2>/dev/null |
    grep -vE "^[a-f0-9]+ (feat|fix|perf|refactor|docs|test|build|ci|chore|style|revert)(\([^)]+\))?!?: " |
    sed -E "s/^([a-f0-9]+) (.+)$/- \2 (\`\1\`)/" || true
}

# breaking 커밋: subject에 `!:` 또는 body에 BREAKING CHANGE
commits_breaking() {
  local shas
  shas=$(git log "${LAST_TAG}..${RANGE_END}" --format='%H' 2>/dev/null || true)
  [ -z "$shas" ] && return 0
  for sha in $shas; do
    local subj body
    subj=$(git log -1 --format='%s' "$sha")
    body=$(git log -1 --format='%b' "$sha")
    if echo "$subj" | grep -qE '^[a-z]+(\([^)]+\))?!:' || echo "$body" | grep -qE '^BREAKING CHANGE:'; then
      local hash
      hash=$(git log -1 --format='%h' "$sha")
      echo "- ${subj} (\`${hash}\`)"
    fi
  done
}

TOTAL=$(git log "${LAST_TAG}..${RANGE_END}" --oneline 2>/dev/null | wc -l | tr -d ' ')

# ── 출력 ────────────────────────────────────────────────────
echo "## ${NEW_TAG}"
echo ""

if [ "$TOTAL" = "0" ]; then
  echo "마지막 릴리즈 [\`${LAST_TAG}\`](https://github.com/${REPO_SLUG}/releases/tag/${LAST_TAG}) 이후 코드 변경 없음."
  echo ""
  exit 0
fi

echo "마지막 릴리즈 [\`${LAST_TAG}\`](https://github.com/${REPO_SLUG}/releases/tag/${LAST_TAG}) 이후 **${TOTAL}개 커밋**."
echo ""

BREAKING=$(commits_breaking)
if [ -n "$BREAKING" ]; then
  echo "### ⚠️ Breaking Changes"
  echo ""
  echo "$BREAKING"
  echo ""
fi

for type in $TYPES; do
  content=$(commits_of_type "$type")
  if [ -n "$content" ]; then
    echo "### $(title_for "$type")"
    echo ""
    echo "$content"
    echo ""
  fi
done

other=$(commits_other)
if [ -n "$other" ]; then
  echo "### $(title_for _other)"
  echo ""
  echo "$other"
  echo ""
fi

echo "---"
echo ""
echo "**전체 변경 비교**: [\`${LAST_TAG}...${NEW_TAG}\`](https://github.com/${REPO_SLUG}/compare/${LAST_TAG}...${NEW_TAG})"
