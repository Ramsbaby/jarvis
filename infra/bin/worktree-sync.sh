#!/usr/bin/env bash
# worktree-sync.sh — 모든 worktree에 main branch 자동 merge (Verify 4회차 P0-1)
#
# 문제 배경:
#   git worktree 17개가 각자 `claude/<slug>` branch를 보유. main에 hotfix 들어가도
#   worktree 쪽 코드는 자동 갱신 안 됨 → 구버전 실행 위험 (예: mistake-extractor B1
#   수정 32줄이 2026-04-21 시점에 main에만 있고 worktree에는 누락).
#
# 동작:
#   1. `git worktree list` 로 모든 worktree 순회
#   2. 각 worktree에서 `git fetch origin main` → `git merge origin/main --no-edit`
#   3. 충돌 시 `git merge --abort` + Discord 경보 (jarvis-system 채널)
#   4. 성공·스킵·실패 카운트 집계 후 요약 Discord 송출
#   5. 모든 조치는 append-only 로그 기록
#
# 안전 원칙:
#   - main branch 자체는 건드리지 않음 (pull/merge 대상 제외)
#   - 각 worktree cwd 고립 실행 (서로 영향 無)
#   - 충돌 발견 시 abort — 자동 해결 시도 금지 (Iron Law 3 User Sovereignty)
#   - dry-run 모드 지원 (`--dry-run`) — 실제 merge 수행 안 함
#
# 호출:
#   bash ~/jarvis/infra/bin/worktree-sync.sh          # 실 merge
#   bash ~/jarvis/infra/bin/worktree-sync.sh --dry-run # 대상만 출력
#
# 스케줄 권고:
#   매일 00:00 KST (LaunchAgent ai.jarvis.worktree-sync 또는 crontab)
#
# 로그: ~/jarvis/runtime/logs/worktree-sync.log (append-only, daily 로테이션 권장)

set -euo pipefail

# ── 설정 ─────────────────────────────────────────────────────────────────────
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; fi

REPO="${HOME}/jarvis"
LOG_DIR="${HOME}/jarvis/runtime/logs"
LOG_FILE="${LOG_DIR}/worktree-sync.log"
DISCORD_VISUAL="${HOME}/jarvis/runtime/scripts/discord-visual.mjs"
DISCORD_CHANNEL="jarvis-system"

mkdir -p "$LOG_DIR"

# ── 로거 (KST ISO) ───────────────────────────────────────────────────────────
log() {
  printf '[%s] [worktree-sync] %s\n' \
    "$(TZ=Asia/Seoul date '+%F %T %z')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

log "=== worktree-sync 시작 (dry-run=${DRY_RUN}) ==="

# ── Homebrew PATH (cron 실행 보험) ───────────────────────────────────────────
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ── 카운터 ───────────────────────────────────────────────────────────────────
TOTAL=0
UP_TO_DATE=0
MERGED=0
CONFLICTED=0
FAILED=0
SKIPPED_BUSY=0  # uncommitted tracked 변경 있어 보호 차원 skip
declare -a CONFLICT_LIST=()

# ── main repo fetch (한 번만, 공유 objects) ──────────────────────────────────
cd "$REPO"
if [[ $DRY_RUN -eq 0 ]]; then
  git fetch origin main 2>&1 | while read -r line; do log "  fetch: $line"; done || {
    log "FATAL: git fetch origin main 실패"
    exit 1
  }
fi

# ── worktree 순회 ────────────────────────────────────────────────────────────
# `git worktree list --porcelain` 파싱: "worktree <path>" 블록 추출
while IFS= read -r path; do
  if [[ -z "$path" ]]; then continue; fi
  # main repo 자체는 skip
  if [[ "$path" == "$REPO" ]]; then continue; fi
  if [[ ! -d "$path/.git" && ! -f "$path/.git" ]]; then continue; fi  # .git dir or gitdir ref

  TOTAL=$((TOTAL + 1))
  wt_name=$(basename "$path")
  log ""
  log "[$TOTAL] $wt_name ($path)"

  # 해당 worktree로 cd
  if ! cd "$path" 2>/dev/null; then
    log "  SKIP: cd 실패"
    FAILED=$((FAILED + 1))
    continue
  fi

  # 현재 branch (detached HEAD면 skip)
  cur_branch=$(git branch --show-current 2>/dev/null || echo "")
  if [[ -z "$cur_branch" ]]; then
    log "  SKIP: detached HEAD 또는 branch 없음"
    continue
  fi
  log "  branch: $cur_branch"

  # 이미 main 최신과 동일?
  behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
  if [[ "$behind" == "0" ]]; then
    log "  UP_TO_DATE: origin/main과 동일"
    UP_TO_DATE=$((UP_TO_DATE + 1))
    continue
  fi
  log "  behind origin/main: $behind commits"

  # Dry-run이면 여기서 종료
  if [[ $DRY_RUN -eq 1 ]]; then
    log "  DRY-RUN: merge skip"
    continue
  fi

  # Tracked 파일의 uncommitted 변경만 보호 (untracked .bak·세션 파일은 merge 안전)
  # `git diff --quiet` = tracked working tree vs index
  # `git diff --cached --quiet` = index vs HEAD
  # untracked 파일(`??`)은 git merge가 건드리지 않으므로 무시
  if ! git diff --quiet || ! git diff --cached --quiet; then
    log "  SKIP_BUSY: tracked uncommitted 변경 있음 (주인님 작업 중 — 보호)"
    SKIPPED_BUSY=$((SKIPPED_BUSY + 1))
    continue
  fi

  # Merge 시도
  if git merge origin/main --no-edit --no-ff >/dev/null 2>>"$LOG_FILE"; then
    # merge 성공 후 2026-04-22 재발방지: conflict 마커 잔존 검사
    # git이 충돌 없이 완료했다고 보고해도 마커가 남아있는 edge case 방어
    _conflict_marker_files=$(git diff HEAD --name-only 2>/dev/null | \
      grep -E '\.(js|ts|json)$' | \
      while read -r f; do
        [[ -f "$f" ]] && grep -l '<<<<<<<' "$f" 2>/dev/null || true
      done || true)
    # 추가로 전체 worktree에서 마커 grep (git diff에 안 잡히는 경우 대비)
    if [[ -z "$_conflict_marker_files" ]]; then
      _conflict_marker_files=$(grep -rl '<<<<<<<' . \
        --include="*.js" --include="*.ts" --include="*.json" \
        --exclude-dir=node_modules --exclude-dir=".git" 2>/dev/null || true)
    fi
    if [[ -n "$_conflict_marker_files" ]]; then
      log "  CONFLICT_MARKER: merge 완료 후 conflict 마커 발견 — safe-abort (commit 금지)"
      _marker_list=$(echo "$_conflict_marker_files" | tr '\n' ' ')
      log "  마커 파일: ${_marker_list}"
      # merge 결과를 되돌림 (HEAD로 reset — merge commit 전 상태로)
      git reset --merge 2>/dev/null || git merge --abort 2>/dev/null || true
      CONFLICTED=$((CONFLICTED + 1))
      CONFLICT_LIST+=("${wt_name}:${cur_branch}[marker:${_marker_list}]")
    else
      log "  MERGED: origin/main → $cur_branch 성공 (마커 검사 통과)"
      MERGED=$((MERGED + 1))
    fi
  else
    # 충돌 또는 실패 → abort
    log "  CONFLICT: merge 실패 — abort"
    git merge --abort 2>/dev/null || true
    CONFLICTED=$((CONFLICTED + 1))
    CONFLICT_LIST+=("$wt_name:$cur_branch")
  fi
done < <(git -C "$REPO" worktree list --porcelain | awk '/^worktree / { print substr($0, 10) }')

# ── 결과 요약 ────────────────────────────────────────────────────────────────
SUMMARY="worktree: ${TOTAL}개 | up-to-date: ${UP_TO_DATE} | merged: ${MERGED} | conflict: ${CONFLICTED} | skipped_busy: ${SKIPPED_BUSY} | failed: ${FAILED}"
log ""
log "=== $SUMMARY ==="
echo "$SUMMARY"

# ── Discord 알림 (충돌 또는 failed 있을 때 또는 매번 — 환경변수로 제어) ─────
SEND_ALWAYS="${WORKTREE_SYNC_DISCORD:-always}"
if [[ $DRY_RUN -eq 0 ]]; then
  if [[ $CONFLICTED -gt 0 || $FAILED -gt 0 || "$SEND_ALWAYS" == "always" ]]; then
    if [[ -f "$DISCORD_VISUAL" ]]; then
      STATUS_ICON="✅"
      if [[ $CONFLICTED -gt 0 ]]; then STATUS_ICON="⚠️"; fi
      if [[ $FAILED -gt 0 ]]; then STATUS_ICON="🚨"; fi
      CONFLICT_STR="${CONFLICT_LIST[*]:-없음}"
      DATA=$(jq -cn \
        --arg total "${TOTAL}개" \
        --arg uptodate "${UP_TO_DATE}" \
        --arg merged "${MERGED}" \
        --arg conflict "${CONFLICTED} (${CONFLICT_STR})" \
        --arg failed "${FAILED}" \
        --arg ts "$(TZ=Asia/Seoul date '+%F %H:%M KST')" \
        '{title:("\($ARGS.positional[0]) worktree-sync" | .), data:{"총": $total, "최신": $uptodate, "merge": $merged, "충돌": $conflict, "실패": $failed}, timestamp:$ts}' \
        --args "$STATUS_ICON" 2>/dev/null || echo '{}')
      node "$DISCORD_VISUAL" --type stats --data "$DATA" --channel "$DISCORD_CHANNEL" >>"$LOG_FILE" 2>&1 || \
        log "Discord 송출 실패 (무시)"
    fi
  fi
fi

log "=== 종료 ==="
exit 0
