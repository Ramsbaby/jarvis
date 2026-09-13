#!/bin/bash
# precheck-memory-staleness.sh: 메모리 파일 신선도 체크
# 용도: 세션 시작 시 또는 메모리 로드 전에 실행
# 목적: 30일 이상 미검증된 메모리는 경고, 사용자가 재검증 여부를 결정하도록 유도

set -euo pipefail

MEMORY_DIR="${HOME}/.openclaw-data/runtime/claude-automemory"
THRESHOLD_DAYS=30
VERBOSE="${1:-0}"

# 날짜 파싱
parse_date() {
  local datestr="$1"
  # YYYY-MM-DD 형식
  if [[ "$datestr" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    datestr="${datestr%% *}"  # 시간 부분 제거
    date -j -f "%Y-%m-%d" "$datestr" "+%s" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# 메모리 파일 검증
check_file() {
  local filepath="$1"
  local basename=$(basename "$filepath")

  [[ "$basename" == "MEMORY.md" ]] && return 0

  # 심링크인 경우 원본으로
  if [[ -L "$filepath" ]]; then
    filepath="$(readlink -f "$filepath")"
  fi

  [[ ! -f "$filepath" ]] && return 0

  # frontmatter 추출
  local fm=$(sed -n '1,/^---$/p' "$filepath" 2>/dev/null)

  # last-verified-at 추출
  local last_verified=$(echo "$fm" | grep -E "^\s*last-verified-at:" | sed 's/.*: *//' | xargs 2>/dev/null || echo "")

  # 없으면 modified/updated 필드로 폴백
  if [[ -z "$last_verified" ]]; then
    last_verified=$(echo "$fm" | grep -E "^\s*(modified|updated):" | head -1 | sed 's/.*: *//' | xargs 2>/dev/null || echo "")
  fi

  [[ -z "$last_verified" ]] && return 0

  # 날짜 계산
  local verified_sec=$(parse_date "$last_verified")
  [[ $verified_sec -eq 0 ]] && return 0

  local now_sec=$(date +%s)
  local days_ago=$((($now_sec - $verified_sec) / 86400))

  if [[ $days_ago -ge $THRESHOLD_DAYS ]]; then
    return 1  # 미검증
  fi

  return 0  # 신선함
}

# 메인 로직
stale_files=()
total_files=0

for filepath in "$MEMORY_DIR"/*.md; do
  [[ -f "$filepath" ]] || continue
  total_files=$((total_files + 1))

  if ! check_file "$filepath"; then
    stale_files+=("$(basename "$filepath")")
  fi
done

# 결과 보고
if [[ ${#stale_files[@]} -gt 0 ]]; then
  echo "⚠  메모리 신선도 경고:"
  printf "   - %s (30일 이상 미검증)\n" "${stale_files[@]}"
  echo ""
  echo "💡 Tip: 오래된 메모리는 다음 명령으로 재검증하세요:"
  echo "   bash ~/projects/jarvis/infra/scripts/memory-guard.sh"
  echo ""
  exit 1
else
  [[ $VERBOSE -eq 1 ]] && echo "✓ 메모리 파일 모두 신선함"
  exit 0
fi
