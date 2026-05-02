#!/usr/bin/env bash
# claude-md-audit.sh — CLAUDE.md 비대화·stale·중복 점검 (P1)
#
# 영상 벤치마킹 (Addy Osmani / Claude.md Management):
#   "claude-md-improver"가 CLAUDE.md를 6가지 기준으로 평가하는 패턴을 자비스에 이식.
#
# 매주 1회 cron 실행 → cron-master 일일 리포트에 통합.
# 결과 JSON: ~/jarvis/runtime/state/claude-md-audit.json

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LOG_FILE="${BOT_HOME}/logs/claude-md-audit.log"
RESULT="${BOT_HOME}/state/claude-md-audit.json"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$RESULT")"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] [claude-md-audit] $*" | tee -a "$LOG_FILE"; }

log "=== CLAUDE.md Audit start ==="

# 점검 대상 (LLM에 자동 주입되는 모든 CLAUDE.md / rules)
CANDIDATES=(
  "${HOME}/CLAUDE.md"
  "${HOME}/jarvis/CLAUDE.md"
)
# .claude/rules/*.md 추가
while IFS= read -r f; do CANDIDATES+=("$f"); done < <(ls "${HOME}"/.claude/rules/*.md 2>/dev/null)

# 1. 파일별 크기 + 라인 수 + 60일+ 미수정(stale) 검사
TOTAL_BYTES=0
TOTAL_LINES=0
STALE_FILES=()
LARGE_FILES=()  # 5KB+
declare -a FILE_STATS

NOW=$(date +%s)
SIXTY_DAYS=$((60 * 86400))

for f in "${CANDIDATES[@]}"; do
  [[ -f "$f" ]] || continue
  size=$(wc -c < "$f" | tr -d ' ')
  lines=$(wc -l < "$f" | tr -d ' ')
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
  age=$(( NOW - mtime ))

  TOTAL_BYTES=$((TOTAL_BYTES + size))
  TOTAL_LINES=$((TOTAL_LINES + lines))

  basename=$(basename "$f")
  FILE_STATS+=("\"$basename\": {\"bytes\": $size, \"lines\": $lines, \"age_days\": $((age / 86400))}")

  if (( size > 5000 )); then LARGE_FILES+=("$basename ($((size / 1024))KB)"); fi
  if (( age > SIXTY_DAYS )); then STALE_FILES+=("$basename"); fi
done

# 2. 중복 라인 검사 (모든 파일 합쳐서 같은 라인 3회+ 반복)
DUP_LINES=$(cat "${CANDIDATES[@]}" 2>/dev/null \
  | grep -vE '^\s*$|^\s*#|^\s*<!--' \
  | sort | uniq -c | awk '$1 >= 3 {sum++} END {print sum+0}')

# 3. 작동 안 하는 명령 검사 (bash 명령 패턴 grep — 실제 호출 흔적 0건)
# 단순화: ~/.jarvis/scripts/*.sh / ~/jarvis/infra/bin/*.sh 호출 grep만  # ALLOW-DOTJARVIS
BROKEN_CMDS=0
DEAD_REFS=()
for f in "${CANDIDATES[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS= read -r script_path; do
    # 틸드 → HOME 변환 (스크립트 실재 여부 검사용)
    expanded=$(echo "$script_path" | sed "s|~|${HOME}|")
    if [[ ! -e "$expanded" ]] && [[ ! -L "$expanded" ]]; then
      BROKEN_CMDS=$((BROKEN_CMDS + 1))
      DEAD_REFS+=("$(basename "$f"): $script_path")
    fi
  done < <(grep -oE '~/[a-zA-Z0-9._/-]+\.(sh|mjs|js|py)' "$f" 2>/dev/null | sort -u)
done

# 4. 결과 JSON
TOTAL_KB=$((TOTAL_BYTES / 1024))
STATUS="OK"
WARNINGS=()

if (( TOTAL_KB > 100 )); then STATUS="WARN"; WARNINGS+=("총 $((TOTAL_KB))KB 초과 (권고 100KB 이내)"); fi
if (( ${#STALE_FILES[@]} > 3 )); then STATUS="WARN"; WARNINGS+=("60일+ stale 파일 ${#STALE_FILES[@]}건"); fi
if (( DUP_LINES > 10 )); then STATUS="WARN"; WARNINGS+=("중복 라인 $DUP_LINES건"); fi
if (( BROKEN_CMDS > 0 )); then STATUS="WARN"; WARNINGS+=("dead 스크립트 참조 $BROKEN_CMDS건"); fi

# JSON 직렬화
{
  echo "{"
  echo "  \"ts\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\","
  echo "  \"total_files\": ${#CANDIDATES[@]},"
  echo "  \"total_bytes\": $TOTAL_BYTES,"
  echo "  \"total_kb\": $TOTAL_KB,"
  echo "  \"total_lines\": $TOTAL_LINES,"
  echo "  \"stale_count\": ${#STALE_FILES[@]},"
  echo "  \"large_count\": ${#LARGE_FILES[@]},"
  echo "  \"dup_lines\": $DUP_LINES,"
  echo "  \"broken_cmds\": $BROKEN_CMDS,"
  echo "  \"status\": \"$STATUS\","
  if (( ${#STALE_FILES[@]} > 0 )); then
    printf '  "stale_files": ['
    printf '"%s",' "${STALE_FILES[@]}" | sed 's/,$//'
    echo "],"
  fi
  if (( ${#LARGE_FILES[@]} > 0 )); then
    printf '  "large_files": ['
    printf '"%s",' "${LARGE_FILES[@]}" | sed 's/,$//'
    echo "],"
  fi
  if (( ${#DEAD_REFS[@]} > 0 )); then
    printf '  "dead_refs": ['
    printf '"%s",' "${DEAD_REFS[@]}" | sed 's/,$//'
    echo "],"
  fi
  printf '  "files": {'
  IFS=','; echo "${FILE_STATS[*]}}"
  echo "}"
} > "$RESULT"

log "결과: total=${TOTAL_KB}KB / stale=${#STALE_FILES[@]} / dup=$DUP_LINES / broken=$BROKEN_CMDS / status=$STATUS"
[[ "$STATUS" != "OK" ]] && for w in "${WARNINGS[@]}"; do log "  ⚠️  $w"; done

log "=== CLAUDE.md Audit end ==="
exit 0
