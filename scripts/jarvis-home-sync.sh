#!/usr/bin/env bash
# jarvis-home-sync.sh — upstream(claude-discord-bridge) 변경사항을 자동으로
# jarvis-home(private)에 병합·푸시
# 크론: 매일 새벽 4시 (서버 정비 후)

set -euo pipefail
BOT_HOME="${BOT_HOME:-$HOME/.jarvis}"
LOG="$BOT_HOME/logs/jarvis-home-sync.log"
ROUTE="$BOT_HOME/bin/route-result.sh"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

alert() {
  local msg="$1"
  log "ALERT: $msg"
  if [[ -f "$ROUTE" ]]; then
    "$ROUTE" discord jarvis-home-sync "$msg" jarvis-infra 2>/dev/null || true
  fi
}

cd "$BOT_HOME"

# git 저장소 + upstream remote 사전 검증
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  alert "jarvis-home-sync: $BOT_HOME 은 git 저장소가 아님"
  exit 1
fi
if ! git remote get-url upstream >/dev/null 2>&1; then
  alert "jarvis-home-sync: upstream remote 미설정 — git remote add upstream <url> 필요"
  exit 1
fi

# upstream 최신 상태 fetch
log "upstream fetch 시작"
if ! git fetch upstream main --quiet 2>>"$LOG"; then
  alert "jarvis-home-sync: upstream fetch 실패"
  exit 1
fi

# 새 커밋 여부 확인
BEHIND=$(git rev-list HEAD..upstream/main --count 2>/dev/null || echo 0)
if [[ "$BEHIND" -eq 0 ]]; then
  log "upstream과 동기화됨 — 변경 없음"
  exit 0
fi

log "upstream에 ${BEHIND}개 새 커밋 감지"

# 로컬 미커밋 변경사항이 있으면 stash
STASHED=0
if ! git diff --quiet || ! git diff --cached --quiet; then
  log "미커밋 변경사항 stash"
  git stash push -m "jarvis-home-sync auto-stash $(date '+%F %T')" >>"$LOG" 2>&1
  STASHED=1
fi

# merge 시도
if ! git merge upstream/main --no-edit --quiet >>"$LOG" 2>&1; then
  log "merge 충돌 발생 — 중단"
  git merge --abort 2>/dev/null || true
  if [[ "$STASHED" -eq 1 ]]; then
    if ! git stash pop >>"$LOG" 2>&1; then
      alert "⚠️ jarvis-home-sync: merge 충돌 후 stash pop도 실패. stash 잔류 가능 — \`git stash list\` 확인 필요"
    fi
  fi
  alert "⚠️ jarvis-home-sync: upstream merge 충돌. 수동 처리 필요 (\`cd ~/.jarvis && git merge upstream/main\`)"
  exit 1
fi

# stash 복원
if [[ "$STASHED" -eq 1 ]]; then
  if ! git stash pop >>"$LOG" 2>&1; then
    alert "⚠️ jarvis-home-sync: stash pop 충돌. 확인 필요 (\`cd ~/.jarvis && git stash show\`)"
    exit 1
  fi
fi

# origin(jarvis-home private)에 push
if ! git push origin main --quiet >>"$LOG" 2>&1; then
  alert "jarvis-home-sync: origin push 실패"
  exit 1
fi

MERGED=$(git log --oneline upstream/main~"$BEHIND"..upstream/main 2>/dev/null | head -5 | sed 's/^/  /')
log "sync 완료 — ${BEHIND}개 커밋 반영"
alert "✅ jarvis-home-sync: upstream ${BEHIND}개 커밋 반영됨
$MERGED"
