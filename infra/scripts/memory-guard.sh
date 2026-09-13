#!/bin/bash
# memory-guard.sh: automemory 파일의 신선도 검증 및 경고
# 용도: 메모리 항목이 일정 기간 미검증되면 재검증 경고 표시
# 호출: bash ~/projects/jarvis/infra/scripts/memory-guard.sh [file_path]

set -euo pipefail

THRESHOLD_DAYS=30
GUARD_LOG="${HOME}/.openclaw-data/runtime/state/memory-guard.log"

# 옵션: 특정 파일만 검증하거나 전체 스캔
TARGET_FILE="${1:-}"

# 타임스탬프 파싱 (YYYY-MM-DD 또는 ISO 8601)
parse_date() {
  local datestr="$1"
  # ISO 8601: 2026-08-07T02:14:15.000Z
  if [[ "$datestr" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
    datestr="${datestr%%T*}"
  fi
  # YYYY-MM-DD
  if [[ "$datestr" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    date -j -f "%Y-%m-%d" "$datestr" "+%s" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# 파일이 미검증 상태인지 체크
check_memory_freshness() {
  local filepath="$1"

  # frontmatter 추출
  local fm=$(sed -n '1,/^---$/p' "$filepath" 2>/dev/null | tail -20)

  # last-verified-at 필드 추출
  local last_verified=$(echo "$fm" | grep -E "^\s*last-verified-at:" | head -1 | sed 's/.*: *//' | xargs 2>/dev/null || echo "")

  # modified 또는 updated 필드 추출
  local modified=$(echo "$fm" | grep -E "^\s*(modified|updated):" | head -1 | sed 's/.*: *//' | xargs 2>/dev/null || echo "")

  # 참조 필드 확인 (출처 명시)
  local sources=$(echo "$fm" | grep -E "^\s*sources:" | head -1 | sed 's/.*: *//' | xargs 2>/dev/null || echo "")

  # 타임스탬프가 없으면 스킵
  if [[ -z "$modified" ]]; then
    return 0
  fi

  local modified_sec=$(parse_date "$modified")
  local last_verified_sec=$(parse_date "${last_verified:-0000-00-00}")
  local now_sec=$(date +%s)

  # 검증 기한 판정
  if [[ $last_verified_sec -eq 0 ]]; then
    # last-verified-at이 없으면 modified 기준
    local days_ago=$((($now_sec - $modified_sec) / 86400))
  else
    # last-verified-at이 있으면 그 기준
    local days_ago=$((($now_sec - $last_verified_sec) / 86400))
  fi

  if [[ $days_ago -ge $THRESHOLD_DAYS ]]; then
    local basename=$(basename "$filepath")
    echo "⚠ $basename: 미검증 ${days_ago}일 (임계: ${THRESHOLD_DAYS}일)" >> "$GUARD_LOG" 2>/dev/null || true
    return 1
  fi

  return 0
}

# 메모리 파일에 last-verified-at 필드 추가 (없는 경우만)
add_verification_field() {
  local filepath="$1"

  # 심링크인 경우 원본으로
  if [[ -L "$filepath" ]]; then
    filepath="$(readlink -f "$filepath")"
  fi

  [[ ! -f "$filepath" ]] && return 1

  # 이미 last-verified-at이 있는지 확인
  if grep -q "^\s*last-verified-at:" "$filepath" 2>/dev/null; then
    return 0
  fi

  # last-verified-at 필드 추가 (modified 다음에)
  local now_iso=$(date -u "+%Y-%m-%d")

  # 임시 파일에 수정된 내용 저장
  {
    sed '/^---$/q' "$filepath"
    sed -n '2,/^---$/p' "$filepath" | sed "/^modified:/a\\  last-verified-at: $now_iso"
    sed -n '/^---$/,\$p' "$filepath" | tail -n +2
  } > "$filepath.tmp" && mv "$filepath.tmp" "$filepath"

  return 0
}

# 메인 로직
if [[ -n "$TARGET_FILE" ]]; then
  check_memory_freshness "$TARGET_FILE"
else
  # 전체 메모리 파일 스캔
  mkdir -p "$(dirname "$GUARD_LOG")"
  > "$GUARD_LOG"  # 로그 초기화

  for f in "${HOME}/.openclaw-data/runtime/claude-automemory"/*.md; do
    [[ -f "$f" ]] && [[ "$(basename "$f")" != "MEMORY.md" ]] && check_memory_freshness "$f"
  done
fi

exit 0
