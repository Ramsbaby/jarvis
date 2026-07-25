#!/usr/bin/env bash
# shadow-path-merge.sh — 그림자 디렉터리에 새던 데이터를 정본으로 이관 (1회성 마이그레이션)
#
# 배경: JARVIS_HOME/BOT_HOME 혼선으로 데이터가 두 그림자 경로에 샜다.
#   B형: ~/jarvis/runtime/runtime/**  ← "$JARVIS_HOME/runtime/..." 에서 JARVIS_HOME 이 한 단계 아래로 떨어진 경우
#   A형: ~/.jarvis/runtime/**         ← 스크립트에 하드코딩된 경로  # ALLOW-DOTJARVIS
#   정본: ~/jarvis/runtime/**  (실측: state 14,315개/1.1GB — 그림자는 0~122개)
#
# 처리 규칙 (데이터 손실 0 원칙):
#   1) 실행 전 그림자 전체를 보관소에 복사 (되돌리기 가능)
#   2) 정본에 없는 파일        → 그대로 이동
#   3) 추가 기록(.jsonl/.log) → 병합 (중복 줄 제거, 덮어쓰기 금지)
#   4) 그 외 충돌 파일
#        - 정본이 최신  → 정본 유지, 그림자본은 보관소에만 남김
#        - 그림자가 최신 → 정본을 백업한 뒤 그림자본 채택 (누락됐던 최신 데이터 복구)
#   5) 빈 디렉터리 정리
#
# 멱등: 재실행해도 안전 (그림자가 비어 있으면 아무 것도 하지 않음)

set -euo pipefail

JARVIS_ROOT="${JARVIS_ROOT:-${HOME}/jarvis}"
CANON="${JARVIS_ROOT}/runtime"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${CANON}/state/migrations/shadow-merge-${STAMP}"
LEDGER="${ARCHIVE}/actions.jsonl"
DRYRUN="${DRYRUN:-0}"

SHADOWS=(
  "${CANON}/runtime"
  "${HOME}/.jarvis/runtime"  # ALLOW-DOTJARVIS
)

log() { echo "[$(date '+%H:%M:%S')] $*"; }
record() { # type|rel|detail
  [ "$DRYRUN" = "1" ] && return 0
  printf '{"ts":"%s","action":"%s","file":"%s","detail":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "$LEDGER"
}

moved=0; merged=0; kept=0; recovered=0

for SHADOW in "${SHADOWS[@]}"; do
  [ -d "$SHADOW" ] || continue
  count=$(find "$SHADOW" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 0 ] && { log "빈 그림자 건너뜀: $SHADOW"; continue; }

  log "그림자 처리: $SHADOW (${count}개 파일)"

  # 1) 안전 보관 (되돌리기용)
  if [ "$DRYRUN" != "1" ]; then
    mkdir -p "$ARCHIVE"
    tag="$(basename "$(dirname "$SHADOW")")-$(basename "$SHADOW")"
    mkdir -p "${ARCHIVE}/${tag}"
    cp -R "$SHADOW/." "${ARCHIVE}/${tag}/" 2>/dev/null || true
    log "  보관 완료 → ${ARCHIVE}/${tag}"
  fi

  while IFS= read -r src; do
    rel="${src#"$SHADOW"/}"
    dst="${CANON}/${rel}"

    if [ ! -e "$dst" ]; then
      # 2) 정본에 없음 → 이동
      if [ "$DRYRUN" != "1" ]; then
        mkdir -p "$(dirname "$dst")"
        mv "$src" "$dst"
      fi
      moved=$((moved + 1)); record moved "$rel" "정본에 없어 이동"
      continue
    fi

    case "$rel" in
      *.jsonl|*.log)
        # 3) 추가 기록 → 병합 (순서 보존 + 중복 제거)
        if [ "$DRYRUN" != "1" ]; then
          tmp="$(mktemp)"
          cat "$dst" "$src" | awk '!seen[$0]++' > "$tmp"
          mv "$tmp" "$dst"
          rm -f "$src"
        fi
        merged=$((merged + 1)); record merged "$rel" "추가기록 병합(중복 제거)"
        ;;
      *)
        if [ "$src" -nt "$dst" ]; then
          # 4b) 그림자가 최신 → 정본 백업 후 채택
          if [ "$DRYRUN" != "1" ]; then
            cp "$dst" "${dst}.pre-shadow-merge-${STAMP}"
            mv "$src" "$dst"
          fi
          recovered=$((recovered + 1)); record recovered "$rel" "그림자가 최신 — 누락 데이터 복구(정본 백업함)"
        else
          # 4a) 정본이 최신 → 유지
          if [ "$DRYRUN" != "1" ]; then rm -f "$src"; fi
          kept=$((kept + 1)); record kept "$rel" "정본이 최신 — 정본 유지"
        fi
        ;;
    esac
  done < <(find "$SHADOW" -type f 2>/dev/null)

  # 5) 빈 디렉터리 정리
  if [ "$DRYRUN" != "1" ]; then
    find "$SHADOW" -type d -empty -delete 2>/dev/null || true
    [ -d "$SHADOW" ] && rmdir "$SHADOW" 2>/dev/null || true
  fi
done

log "완료 — 이동 ${moved} / 병합 ${merged} / 정본유지 ${kept} / 복구 ${recovered}"
[ "$DRYRUN" != "1" ] && log "보관소: $ARCHIVE"
exit 0
