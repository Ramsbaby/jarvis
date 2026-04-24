#!/usr/bin/env bash
# github-actions-monitor.sh — CI 실패 감지 → Discord jarvis-system 알림
#
# 주기 실행(10분): GitHub Actions 최근 20 run 중 conclusion=failure 탐지.
# 신규 실패만 필터 (알림 중복 방지 원장: state/github-actions-notified.jsonl).
# 오늘처럼 빨간불이 push 후 누적되기 전 주인님 Discord로 선제 알림.
#
# 종료: 실패 여부 무관 exit 0 (알림 실패해도 크론 체인 차단 금지).

set -euo pipefail

STATE_DIR="${HOME}/jarvis/runtime/state"
NOTIFIED="${STATE_DIR}/github-actions-notified.jsonl"
mkdir -p "$STATE_DIR"
touch "$NOTIFIED"

REPO="Ramsbaby/jarvis"

if ! command -v gh >/dev/null 2>&1; then
  echo "⚠️  gh CLI 없음 — skip"
  exit 0
fi

# 최근 20 run 중 failure
FAILED=$(gh run list --limit 20 --repo "$REPO" \
  --json databaseId,conclusion,name,headSha,createdAt,url \
  --jq '[.[] | select(.conclusion == "failure")]' 2>/dev/null || echo "[]")

COUNT_ALL=$(echo "$FAILED" | jq 'length')
if [ "$COUNT_ALL" -eq 0 ]; then
  echo "✅ CI 실패 없음"
  exit 0
fi

# 기존 알림 완료 ID 집합
NOTIFIED_IDS=$(jq -r '.id' "$NOTIFIED" 2>/dev/null | sort -u)

# 신규 실패만 추출
NEW_FAILURES=$(echo "$FAILED" | jq -c '.[]' | while read -r run; do
  id=$(echo "$run" | jq -r '.databaseId')
  if ! echo "$NOTIFIED_IDS" | grep -qxF "$id"; then
    echo "$run"
  fi
done)

if [ -z "$NEW_FAILURES" ]; then
  echo "✅ 신규 실패 없음 (기존 ${COUNT_ALL}건은 알림 완료)"
  exit 0
fi

NEW_COUNT=$(echo "$NEW_FAILURES" | grep -c '^{' || true)
echo "🚨 신규 CI 실패 ${NEW_COUNT}건 — Discord 알림 송출"

# Discord 카드 findings 배열 구성
FINDINGS_JSON=$(echo "$NEW_FAILURES" | jq -s '[.[] | "🔴 \(.name) (\(.headSha[0:7]))"]')

SUMMARY=$(jq -cn \
  --arg red "$NEW_COUNT" \
  --argjson findings "$FINDINGS_JSON" \
  '{overall: ("🔴 CI 실패 " + $red + "건 — 확인 필요"),
    red: ($red | tonumber),
    yellow: 0,
    findings: $findings,
    healthy: ["gh run view <id> --log-failed 로 원인 확인",
              "수정 후 다음 push 때 재검사됩니다"]}')

if [ -f "${HOME}/jarvis/infra/scripts/discord-visual.mjs" ]; then
  node "${HOME}/jarvis/infra/scripts/discord-visual.mjs" \
    --type system-doctor \
    --data "$(jq -cn --arg title "CI 실패 감지 — $(TZ=Asia/Seoul date '+%m-%d %H:%M KST')" \
      --argjson summary "$SUMMARY" '{title:$title, summary:$summary}')" \
    --channel jarvis-system 2>&1 | head -3 || echo "⚠️ discord-visual 실패 — 계속"
fi

# 알림 기록 (중복 방지)
TS=$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')
echo "$NEW_FAILURES" | while read -r run; do
  id=$(echo "$run" | jq -r '.databaseId')
  name=$(echo "$run" | jq -r '.name')
  printf '{"id":%s,"ts":"%s","name":"%s"}\n' "$id" "$TS" "$name" >> "$NOTIFIED"
done

echo "✅ ${NEW_COUNT}건 알림 완료"
exit 0
