#!/usr/bin/env bash
# post-memory-sync.sh — Claude Code auto memory 파일을 claude-memory/ SSoT로 이동 + symlink 복원
#
# 사용법:
#   (stdin 에 PostToolUse payload)      기본 — 동기화 수행
#   post-memory-sync.sh --print-watched  감시 대상 디렉터리 목록만 출력(부작용 없음)
#
# 이 훅이 없으면 auto memory 는 RAG 에 영원히 들어가지 않는다.
#   rag-index.mjs 가 훑는 대상은 BOT_HOME/context/{owner,career,claude-memory} 뿐이고
#   auto memory 디렉터리는 그 바깥이다. SSoT 로 옮겨 심링크를 남기는 이 훅이 유일한 다리다.
#
# 2026-08-06: 감시 경로를 settings.json 의 autoMemoryDirectory 에서 동적으로 읽도록 고쳤다.
#   계기 — 같은 날 auto memory 가 ~/jarvis/runtime/claude-automemory 로 옮겨졌으나
#   이 훅은 옛 경로(~/.claude/projects/*/memory)에 하드코딩돼 있어 조용히 죽었다.
#   경로를 또 하드코딩하면 다음 전환 때 같은 사고가 반복된다.
#   --print-watched 는 그 드리프트를 감사가 부작용 없이 잡기 위한 창구다
#   (symlink-topology-audit.sh Check 6).

set -euo pipefail

MODE="${1:-sync}"

# SSoT — RAG 가 실제로 색인하는 경로 표기를 정본으로 쓴다(~/.jarvis 는 이곳으로 가는 호환 링크).
SSOT_DIR="${HOME}/jarvis/runtime/context/claude-memory"
LOG_FILE="${HOME}/jarvis/runtime/logs/memory-sync.log"

if [[ "$MODE" == "--print-watched" ]]; then
  INPUT=""
else
  INPUT=$(cat)
  # 값싼 사전 필터 — Write/Edit 대부분이 여기서 걸려 python 기동조차 하지 않는다.
  # file_path 가 .md 로 끝나면 payload 에 `.md"` 가 반드시 나타난다(정확한 판정은 아래 python).
  case "$INPUT" in *'.md"'*) ;; *) exit 0 ;; esac
fi

RESULT=$(HOOK_MODE="$MODE" SSOT_DIR="$SSOT_DIR" python3 -c '
import json, os, sys

def norm(p):
    return os.path.normpath(os.path.realpath(os.path.expanduser(p)))

def watched_dirs():
    """auto memory 로 쓰이는 디렉터리 전부. 정본(설정) + 폴백(옛 경로)."""
    dirs = []

    # 1) 정본 — settings.json 의 autoMemoryDirectory
    try:
        with open(os.path.expanduser("~/.claude/settings.json")) as fh:
            v = json.load(fh).get("autoMemoryDirectory")
        if isinstance(v, str) and v.strip():
            dirs.append(norm(v))
    except Exception:
        pass                          # 설정을 못 읽어도 아래 폴백으로 계속 산다

    # 2) 폴백 — 옛 프로젝트별 경로(전환기 이중 커버). 설정이 사라져도 훅이 죽지 않는다.
    proj = os.path.expanduser("~/.claude/projects")
    if os.path.isdir(proj):
        try:
            for name in os.listdir(proj):
                cand = os.path.join(proj, name, "memory")
                if os.path.isdir(cand):
                    dirs.append(norm(cand))
        except Exception:
            pass

    # SSoT 자신은 대상이 아니다(자기참조 이동 방지)
    ssot = norm(os.environ["SSOT_DIR"])
    return [d for d in dict.fromkeys(dirs) if d != ssot]

watched = watched_dirs()

if os.environ.get("HOOK_MODE") == "--print-watched":
    print("\n".join(watched))
    sys.exit(0)

if not watched:
    sys.exit(0)

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)

fp = (payload.get("tool_input") or {}).get("file_path") or ""
if not fp.endswith(".md"):
    sys.exit(0)
if os.path.basename(fp) == "MEMORY.md":
    sys.exit(0)                       # 인덱스 파일은 auto memory 디렉터리에 그대로 둔다
if os.path.islink(fp) or not os.path.isfile(fp):
    sys.exit(0)                       # 이미 심링크면 SSoT 가 작동 중

# auto memory 는 flat 구조다. 부모 디렉터리가 정확히 일치할 때만 손댄다(하위 트리 오작동 방지).
if norm(os.path.dirname(fp)) not in watched:
    sys.exit(0)

print(os.path.realpath(os.path.expanduser(fp)))
' <<<"$INPUT" || true)

if [[ "$MODE" == "--print-watched" ]]; then
  printf '%s\n' "$RESULT"
  exit 0
fi

[[ -n "$RESULT" ]] || exit 0

SRC="$RESULT"
FILENAME="$(basename "$SRC")"
DEST="${SSOT_DIR}/${FILENAME}"

mkdir -p "$SSOT_DIR" "$(dirname "$LOG_FILE")"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE" 2>/dev/null || true; }

# 동명 파일이 SSoT 에 이미 있으면 이전 판을 먼저 보존한다.
#   덮어쓰기는 기억의 소실이고, 기억은 되살릴 수 없다(2026-08-06 링크 20개 소실 확인).
if [[ -f "$DEST" ]]; then
  if cmp -s "$SRC" "$DEST"; then
    ln -sfn "$DEST" "$SRC"            # 내용 동일 — 링크만 복원하고 끝
    log "memory-sync: ${FILENAME} 내용 동일 → 링크만 복원"
    exit 0
  fi
  ARCHIVE_DIR="${HOME}/jarvis/runtime/backups/claude-memory-superseded"
  mkdir -p "$ARCHIVE_DIR"
  cp -p "$DEST" "${ARCHIVE_DIR}/${FILENAME%.md}.$(date +%Y%m%d-%H%M%S).md"
  log "memory-sync: ${FILENAME} 이전 판 보존 → backups/claude-memory-superseded/"
fi

# 이동 → 심링크. mv 가 실패하면 원본을 그대로 둔 채 끝낸다(부분 상태를 만들지 않는다).
if mv "$SRC" "$DEST"; then
  if ln -sfn "$DEST" "$SRC"; then
    log "memory-sync: ${FILENAME} → claude-memory/ SSoT (RAG 색인 대상 진입)"
  else
    cp -p "$DEST" "$SRC"              # 링크 실패 시 원위치 복원 — 기억이 사라지는 것보다 중복이 낫다
    log "memory-sync: ${FILENAME} 심링크 실패 → 원본 복원(중복 상태). 수동 확인 필요"
  fi
fi

exit 0
