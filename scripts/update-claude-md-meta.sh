#!/bin/bash
set -euo pipefail

# update-claude-md-meta.sh — CLAUDE.md 파일 메타정보 자동 갱신 (cl-ef335e743892c676)
# CLAUDE.md에 기재된 파일 줄 수를 실제 wc -l 값으로 동적으로 비교·갱신한다.
# 하드코딩 베이스라인 제거: CLAUDE.md 현재값을 기준으로 비교.
# 트리거: 주 1회 크론 (일요일 03:40) / pre-commit 훅에서도 호출 가능

# [오픈클로 이식 2026-09-10] 주인님 지시로 중지. crontab 쓰기가 막혀 스크립트 층에 가드를 둔다.
# 재개: rm ~/.openclaw-data/runtime/state/stopped/update-claude-md-meta
if [[ -f "${HOME}/.openclaw-data/runtime/state/stopped/update-claude-md-meta" ]]; then
    echo "[update-claude-md-meta] 중지 플래그 있음 — 실행하지 않는다 (state/stopped/update-claude-md-meta)"
    exit 0
fi

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly JARVIS_HOME="${SCRIPT_DIR%/scripts}"
JARVIS_RUNTIME="${JARVIS_RUNTIME:-${BOT_HOME:-$HOME/.openclaw-data/runtime}}"  # 회차8: 런타임은 코드 루트 밑이 아니다
readonly RESULTS_DIR="${JARVIS_RUNTIME}/results"
readonly LOG_FILE="${JARVIS_RUNTIME}/logs/update-claude-md-meta.log"
readonly CHANGE_LOG="${JARVIS_RUNTIME}/logs/claude-md-meta-audit.log"

THRESHOLD=10  # 괴리 허용 임계값(%)
MODE="${1:-update}"  # update|check

mkdir -p "${RESULTS_DIR}" "$(dirname "$LOG_FILE")"

log() {
  local level="$1"; shift
  printf "[%s] [%s] %s\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$*" | tee -a "$LOG_FILE"
}

# 쉼표 포함 숫자 파싱: "3,088" → 3088
parse_count() {
  echo "$1" | tr -d ','
}

# 파일명으로 실제 경로 탐색 (known_roots → home 순)
resolve_path() {
  local name="$1"
  local hint_dir="$2"
  local base; base="$(basename "$name")"

  # 절대경로
  if [[ "$name" == /* ]] && [[ -f "$name" ]]; then
    echo "$name"; return 0
  fi

  # 알려진 루트 (bounded depth)
  local roots=("$hint_dir" "${hint_dir%/*}" "$HOME/jarvis-board" "$HOME/projects/jarvis")
  local r found
  for r in "${roots[@]}"; do
    [[ -d "$r" ]] || continue
    found=$(find "$r" -maxdepth 6 -name "$base" -type f 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then echo "$found"; return 0; fi
  done

  # 홈 전체 (마지막 수단)
  found=$(find "$HOME" -maxdepth 7 -name "$base" -type f 2>/dev/null | head -1)
  if [[ -n "$found" ]]; then echo "$found"; return 0; fi

  echo ""
}

# CLAUDE.md 하나 처리
process_file() {
  local claude_file="$1"
  local claude_dir; claude_dir="$(dirname "$claude_file")"

  log "INFO" "스캔: $claude_file"

  local total=0 updated=0 warned=0 ok=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    # "(숫자,숫자줄)" 패턴이 있는 줄만 처리
    echo "$line" | grep -qE '\([0-9,]+[[:space:]]*줄[^수]' || continue

    # 줄 수 추출: 쉼표 먼저 제거 후 숫자 추출 (comma-format 버그 방지)
    local recorded
    recorded=$(echo "$line" | grep -oE '\([0-9,]+[[:space:]]*줄' | tr -d ',' | grep -oE '[0-9]+' | head -1)
    [[ -n "$recorded" ]] || continue

    # 파일명 추출 (확장자 포함)
    local filename
    filename=$(echo "$line" | grep -oE '[a-zA-Z0-9_./\-]+\.(tsx?|js|mjs|sh|py|md|ts)' | head -1)
    if [[ -z "$filename" ]]; then
      log "WARN" "파일명 추출 실패: $line"
      continue
    fi

    ((total++)) || true

    local full_path
    full_path=$(resolve_path "$filename" "$claude_dir")
    if [[ -z "$full_path" ]] || [[ ! -f "$full_path" ]]; then
      log "WARN" "파일 없음: $filename"
      continue
    fi

    local actual; actual=$(wc -l < "$full_path")
    local diff=$(( actual - recorded ))
    local pct_dev=0
    (( recorded > 0 )) && pct_dev=$(( 100 * diff / recorded ))
    local abs_pct=${pct_dev#-}

    if (( abs_pct > THRESHOLD )); then
      log "WARN" "STALE: $filename — 기재=$recorded줄, 실제=$actual줄, 괴리=${pct_dev}%"
      printf '{"ts":"%s","file":"%s","recorded":%d,"actual":%d,"pct":%d,"mode":"%s"}\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$filename" "$recorded" "$actual" "$pct_dev" "$MODE" >> "$CHANGE_LOG"

      if [[ "$MODE" == "update" ]]; then
        local bak="${claude_file}.bak.$(date +%s)"
        cp "$claude_file" "$bak"

        # 쉼표 포맷팅
        local actual_fmt
        if (( actual >= 1000 )); then
          actual_fmt="$(printf '%d,%03d' $((actual/1000)) $((actual%1000)))"
        else
          actual_fmt="$actual"
        fi

        local base; base="$(basename "$filename")"
        # "basename(기재,값줄)" 패턴 치환
        local escaped_base; escaped_base=$(printf '%s' "$base" | sed 's/[\/&.]/\\&/g')
        sed -i '' \
          "s/${escaped_base}([0-9,]*줄/${escaped_base}(${actual_fmt}줄/g" \
          "$claude_file"
        log "INFO" "갱신: $filename ($recorded줄 → $actual줄)"
        ((updated++)) || true
      else
        ((warned++)) || true
      fi
    else
      log "INFO" "OK: $filename (실제=${actual}줄, 기재=${recorded}줄, 괴리=${pct_dev}%)"
      ((ok++)) || true
    fi
  done < "$claude_file"

  log "INFO" "완료: total=$total ok=$ok updated=$updated warned=$warned"
}

main() {
  log "INFO" "=== CLAUDE.md 메타 동기화 시작 (mode=$MODE, threshold=±${THRESHOLD}%) ==="

  local targets=(
    "$HOME/CLAUDE.md"
    "$HOME/projects/jarvis/CLAUDE.md"
    "$HOME/jarvis-board/CLAUDE.md"
  )

  local checked=0
  for f in "${targets[@]}"; do
    if [[ -f "$f" ]]; then
      process_file "$f"
      ((checked++)) || true
    fi
  done

  (( checked == 0 )) && log "WARN" "처리 대상 CLAUDE.md 없음"
  log "INFO" "=== 완료 ==="
}

main "$@"
