#!/usr/bin/env bash
# jarvis-daily-commit — 매일 밤 jarvis 작업분을 커밋+push (편법 없이 실제 활동을 GitHub 잔디에 반영)
#
# 배경(2026-07-07): 실제로 매일 개발하는데 커밋을 안 해 GitHub 잔디가 비던 문제.
#   가짜 백데이트 커밋 대신, 그날 실제 변경을 그날 커밋해 정당하게 잔디를 채운다.
# 안전: Privacy 가드(pre-commit/pre-push)가 구직·시크릿·PII를, 토폴로지 가드가 구경로를 차단.
#   민감 변경이 섞이면 커밋이 막혀 push되지 않으므로(=잔디 미반영), 유출 위험 없이 실패만 한다.
set -uo pipefail

REPO="$HOME/jarvis"
LOG="$HOME/jarvis/logs/jarvis-daily-commit.log"
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

cd "$REPO" || { log "repo 없음: $REPO"; exit 1; }

git add -A 2>/dev/null

if git diff --cached --quiet; then
  log "변경 없음 — skip"
  exit 0
fi

CNT=$(git diff --cached --name-only | wc -l | tr -d ' ')

if git commit -q -m "chore: 일일 자동 커밋 ($(date '+%Y-%m-%d'), ${CNT}개 파일)" 2>>"$LOG"; then
  if git push origin main 2>>"$LOG"; then
    log "✅ 커밋+push 성공 (${CNT}개 파일)"
  else
    log "⚠️ push 실패 — pre-push 가드 차단 가능. 수동 확인 필요"
  fi
else
  # 커밋이 막힌 경우(민감/구경로 가드) — staging 해제로 원상 복귀, 다음날 정상 파일만 재시도
  log "⚠️ 커밋 차단 (Privacy/토폴로지 가드 — 민감·구경로 변경 포함 가능). 수동 정리 필요"
  git reset -q HEAD 2>/dev/null
fi
