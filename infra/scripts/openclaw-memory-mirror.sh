#!/bin/bash
# 클로드 코드 오토메모리 → 오픈클로 워크스페이스 메모리 단방향 미러 + 재색인
# 2026-09-09 임시. 회차 3에서 워크스페이스 공유로 대체 예정(계획 문서 참조).
set -euo pipefail
export PATH="$HOME/.nvm/versions/node/v24.21.0/bin:/opt/homebrew/bin:/usr/bin:/bin"
# 오픈클로 호출은 반드시 env -i 로 격리한다 — 9/2 기동 실패의 진짜 원인이 셸 env 의
# TELEGRAM_BOT_TOKEN·BRAVE_API_KEY 누수였다(오픈클로가 그 이름을 보고 플러그인 자동 활성화 → fail-closed).
# 이 스크립트는 아직 미배선이라 호출자의 env 를 알 수 없다. 계획 문서 "유지되는 선" 준수.
OC_BIN="$HOME/.nvm/versions/node/v24.21.0/bin"
oc() { /usr/bin/env -i HOME="$HOME" PATH="$OC_BIN:/usr/bin:/bin" "$OC_BIN/openclaw" "$@"; }
SRC="$HOME/.openclaw-data/runtime/claude-automemory/"
DST="$HOME/.openclaw/workspace/memory/imports/claude-code/jarvis-automemory/"
mkdir -p "$DST"

# --- SSoT 이관 드레인 (2026-09-09 추가) ---------------------------------------
# 클로드 코드가 새로 쓴 auto memory 는 실파일로 남고, 그것을 SSoT
# (runtime/context/claude-memory)로 옮겨 심링크를 남기는 다리가 post-memory-sync.sh 다.
# 그 훅이 2026-09-02 훅 41개 일괄 제거 때 빠졌고 재배선 8건에도 안 들어갔다.
# 결과: 9/3부터 새 기억이 자비스 RAG 색인 대상 밖에 머물렀다
# (rag-index.mjs 는 context/{owner,career,claude-memory} 만 훑는다).
# 훅을 되살리는 대신 이미 10분마다 도는 이 미러에 드레인을 얹는다 —
# 주인님의 9/2 훅 제거 지시를 건드리지 않으면서 다리를 복구하는 경로다.
# 스크립트 자체 로직을 그대로 쓴다(이전 판 보존·실패 시 원위치 복원이 그 안에 있다).
SYNC_HOOK="$HOME/.claude/hooks/post-memory-sync.sh"
if [ -x "$SYNC_HOOK" ]; then
  find "$SRC" -maxdepth 1 -type f -name '*.md' ! -name 'MEMORY.md' 2>/dev/null |
    while IFS= read -r f; do
      printf '{"tool_input":{"file_path":"%s"}}' "$f" | bash "$SYNC_HOOK" >/dev/null 2>&1 || true
    done
fi
# -----------------------------------------------------------------------------
# -L: 심링크를 실파일로 펼친다. 오픈클로 메모리는 심링크를 색인하지 않고
# memory_get 도 "path must be a regular file" 로 거부한다(2026-09-09 실측).
# -a 그대로 두면 원본의 심링크 5건이 검색에서 통째로 사라진다.
CHANGED=$(rsync -aL --delete --itemize-changes --include='*.md' --exclude='*' "$SRC" "$DST" | grep -c '^[<>c]' || true)

# --- 프로젝트별 오토메모리 미러 (2026-09-14 추가) -------------------------------
# 클로드 코드가 2026-09-13 부터 auto memory 를 프로젝트별 경로에 쓴다:
#   ~/.claude/projects/<슬러그>/memory/*.md
# 위의 SSoT(runtime/claude-automemory)는 그 경로를 모르므로 신규 기억이 통째로
# 색인 밖에 머물렀다(실측 2026-09-14: 신규 3건 미색인, memory_search 미검출).
# 경로를 옮기지 않고 미러 대상만 넓힌다 — 클로드 코드 쪽 동작을 건드리지 않는 경로다.
# /private/tmp 하위(봇 1회성 작업 디렉토리)는 제외한다. 영속 프로젝트만 담는다.
PROJ_DST="$HOME/.openclaw/workspace/memory/imports/claude-code/claude-projects"
mkdir -p "$PROJ_DST"
for d in "$HOME"/.claude/projects/-Users-ramsbaby*/memory; do
  [ -d "$d" ] || continue
  # -type f 는 의도적이다(-L 로 펼치지 않는다). 심링크만 있는 프로젝트 memory 디렉토리는
  # SSoT(runtime/context/claude-memory)를 가리키는 옛 배선이고 그 내용은 위 1단계에서 이미
  # 담긴다. 펼치면 같은 기억이 두 벌 색인돼 검색 순위가 왜곡된다.
  # 실측 2026-09-14: -Users-ramsbaby-jarvis 는 심링크 22 + RETIRED.txt — 건너뛰는 게 맞다.
  count=$(find "$d" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -gt 0 ] || continue
  slug=$(basename "$(dirname "$d")")
  mkdir -p "$PROJ_DST/$slug"
  c=$(rsync -aL --delete --itemize-changes --include='*.md' --exclude='*' "$d/" "$PROJ_DST/$slug/" | grep -c '^[<>c]' || true)
  CHANGED=$((CHANGED + c))
done
# 사라진 프로젝트의 잔재 정리 — 원본이 없어진 슬러그 디렉토리는 지운다.
for d in "$PROJ_DST"/*; do
  [ -d "$d" ] || continue
  slug=$(basename "$d")
  if [ ! -d "$HOME/.claude/projects/$slug/memory" ]; then
    rm -rf "$d"
    CHANGED=$((CHANGED + 1))
  fi
done
# -----------------------------------------------------------------------------

if [ "$CHANGED" -gt 0 ]; then
  oc memory index --agent main >/dev/null 2>&1 && echo "MIRROR_UPDATED files=$CHANGED reindexed"
else
  echo "MIRROR_NOCHANGE"
fi
