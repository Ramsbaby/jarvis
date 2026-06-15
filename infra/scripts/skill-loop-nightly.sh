#!/usr/bin/env bash
# skill-loop-nightly.sh — 스킬 자가 생성 루프 야간 배치 (선별 → 추출)
# DRYRUN 모드: SKILL_LOOP_DRYRUN=1 (기본) — 초안만 생성, Discord 카드 송출 안 함
# 설계: ~/jarvis/runtime/state/autoplan/2026-06-10-skill-evolution-loop.md (Step 5)
set -euo pipefail

export HOME="${HOME:-$(eval echo "~$(whoami)")}"
export PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin"

SCRIPTS_DIR="${HOME}/jarvis/infra/scripts"
DRAFTS_DIR="${HOME}/jarvis/runtime/state/skill-drafts"
LEDGER="${HOME}/jarvis/runtime/ledger/skill-loop.jsonl"
MAX="${SKILL_LOOP_MAX:-3}"
TODAY="$(date +%F)"

# DRYRUN 스위치 SSoT: config.json (tasks.json env는 script 태스크에 전달되지 않음 — /verify B2 실측)
# 본 가동 전환: config.json의 dryrun을 false로 수정 (주인님 결재 후)
CONF="${DRAFTS_DIR}/config.json"
if [ -f "$CONF" ]; then
  DRYRUN="$(python3 -c "import json; print(0 if json.load(open('$CONF')).get('dryrun') is False else 1)" 2>/dev/null || echo 1)"
else
  DRYRUN="${SKILL_LOOP_DRYRUN:-1}"
fi

# 실패 관측: tasks.json discordChannel도 script 태스크엔 비실효 → 직접 알림 (B2 수리)
on_fail() {
  printf '{"ts":"%s","event":"batch-failed","line":"%s"}\n' "$(date -u +%FT%TZ)" "${1:-?}" >> "$LEDGER" 2>/dev/null || true
  node "${HOME}/.jarvis/scripts/discord-visual.mjs" --type stats \
    --data "{\"title\":\"⚠️ skill-loop 야간 배치 실패\",\"data\":{\"시각\":\"$(date '+%F %T KST')\",\"실패 라인\":\"${1:-?}\",\"로그\":\"results/skill-loop-nightly\"},\"timestamp\":\"${TODAY}\"}" \
    --channel jarvis-system >/dev/null 2>&1 || true
}
trap 'on_fail $LINENO' ERR

echo "🔄 skill-loop 야간 배치 시작 (DRYRUN=${DRYRUN}, MAX=${MAX}, $(date '+%F %T KST'))"

# 0단: 전일 결재(decision) 적용 — 승인→등재 / 폐기→보관
# promote 내부가 결정 단위로 예외 격리하지만, 이중 가드로 배치 지속 보장
node "${SCRIPTS_DIR}/skill-loop-promote.mjs" || echo "⚠️ promote 비정상 종료 (exit $?) — 배치 계속"

# 1단+2단: 선별 (진행 중 세션 제외 — 야간이므로 보통 없음)
node "${SCRIPTS_DIR}/skill-loop-select.mjs" --cap "${MAX}"

# 3단: 추출 (4중 게이트)
SELECTED_FILE="${DRAFTS_DIR}/selected-${TODAY}.jsonl"
if [ -s "${SELECTED_FILE}" ]; then
  node "${SCRIPTS_DIR}/skill-loop-extract.mjs" --date "${TODAY}" --max "${MAX}"
else
  echo "ℹ️ 선별 0건 — 추출 생략"
fi

# 만료 스윕: pending 14일 초과 → archive (비파괴)
expired=0
for d in "${DRAFTS_DIR}/pending"/*/; do
  [ -d "$d" ] || continue
  exp="$(grep -m1 '^  expires:' "${d}SKILL.md" 2>/dev/null | awk '{print $2}')" || true
  if [ -n "${exp:-}" ] && [ "$exp" != "never" ] && [[ "$exp" < "$TODAY" ]]; then
    name="$(basename "$d")"
    mv "$d" "${DRAFTS_DIR}/archive/${name}-expired-${TODAY}"
    printf '{"ts":"%s","event":"expired","slug":"%s"}\n' "$(date -u +%FT%TZ)" "$name" >> "$LEDGER"
    expired=$((expired+1))
  fi
done

pending_count="$(find "${DRAFTS_DIR}/pending" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
echo "✅ 배치 완료 — pending ${pending_count}건, 만료 처리 ${expired}건"

# 본 가동 시: 신규 초안 Discord 결재 카드 송출 (DRYRUN=1이면 생략)
if [ "${DRYRUN}" != "1" ]; then
  node "${SCRIPTS_DIR}/skill-loop-notify.mjs" || echo "⚠️ 카드 송출 실패 (배치 결과는 유효)"
fi
