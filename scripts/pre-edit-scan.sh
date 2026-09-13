#!/usr/bin/env bash
# pre-edit-scan.sh — 편집 착수 전 파일 토폴로지 자동 조회
#
# 클러스터 ID  : cl-6033efa35edc999a (최근 7일 재발 10건)
# 대표 시드    : runtime/config vs infra/config 이중 구조, 그림자 경로 놓침
#
# 사용법:
#   ~/projects/jarvis/scripts/pre-edit-scan.sh [TARGET_DIR]
#   TARGET_DIR 생략 시 현재 디렉터리 + ~/projects/jarvis 구조 스캔
#
# 출력: 심링크 목록, 이중 경로(shadow), config 파일 목록 요약
# 종료 코드: 0=정상, 1=이중 경로 충돌 감지
#
# 이 스크립트는 관찰만 한다 — 파일을 수정하거나 삭제하지 않는다.

set -euo pipefail

JARVIS_ROOT="${JARVIS_ROOT:-${HOME}/projects/jarvis}"
TARGET_DIR="${1:-$(pwd)}"
TS=$(date '+%Y-%m-%dT%H:%M:%S')
LOG_DIR="${JARVIS_ROOT}/runtime/logs"
LOG_FILE="${LOG_DIR}/pre-edit-scan.jsonl"
ISSUES=0

mkdir -p "$LOG_DIR"

# ── 출력 헬퍼 ────────────────────────────────────────────────────────────────

_hr()  { printf '%.0s─' {1..60}; echo; }
_hdr() { echo; _hr; printf '  %s\n' "$1"; _hr; }
_log() {
  local level="$1" msg="$2"
  printf '{"ts":"%s","level":"%s","target":"%s","msg":"%s"}\n' \
    "$TS" "$level" "${TARGET_DIR//\"/\'}" "${msg//\"/\'}" >> "$LOG_FILE" 2>/dev/null || true
}

# ── 1. 대상 디렉터리 기본 정보 ───────────────────────────────────────────────

_hdr "📂 [pre-edit-scan] 파일 토폴로지 스캔: $TARGET_DIR"
echo "  실행 시각 : $TS"
echo "  Jarvis 루트: $JARVIS_ROOT"

if [ ! -d "$TARGET_DIR" ]; then
  echo "  ⚠️  대상 디렉터리가 존재하지 않음: $TARGET_DIR"
  _log "warn" "대상 디렉터리 없음"
  exit 0
fi

# 실제 경로 (심링크 해소)
REAL_TARGET=$(realpath "$TARGET_DIR" 2>/dev/null || echo "$TARGET_DIR")
if [ "$REAL_TARGET" != "$TARGET_DIR" ]; then
  echo "  ⚠️  심링크 감지! 입력 경로 ≠ 실제 경로"
  printf '     입력 : %s\n' "$TARGET_DIR"
  printf '     실제 : %s\n' "$REAL_TARGET"
  _log "warn" "입력 경로가 심링크 — 실제:${REAL_TARGET}"
  ISSUES=$((ISSUES + 1))
fi

# ── 2. 심링크 목록 ───────────────────────────────────────────────────────────

_hdr "🔗 심링크 목록 (최대 2단계)"
SYMLINKS=$(find "$TARGET_DIR" -maxdepth 2 -type l 2>/dev/null | sort)
if [ -z "$SYMLINKS" ]; then
  echo "  (심링크 없음)"
else
  while IFS= read -r lnk; do
    target=$(readlink "$lnk" 2>/dev/null || echo "?")
    resolved=$(realpath "$lnk" 2>/dev/null || echo "broken")
    if [ ! -e "$resolved" ]; then
      printf '  ❌ BROKEN  %s → %s\n' "$lnk" "$target"
      _log "error" "끊어진 심링크: ${lnk} → ${target}"
      ISSUES=$((ISSUES + 1))
    else
      printf '  ✓  %s → %s\n' "$lnk" "$target"
    fi
  done <<< "$SYMLINKS"
fi

# ── 3. config 이중 경로 감지 (runtime/config vs infra/config) ───────────────

_hdr "⚙️  Config 이중 경로 감지"

RUNTIME_CFG="${JARVIS_ROOT}/runtime/config"
INFRA_CFG="${JARVIS_ROOT}/infra/config"

# bash 3.2 호환 — 파일 이름 목록으로 비교 (associative array 미사용)
RUNTIME_NAMES=""
INFRA_NAMES=""

if [ -d "$RUNTIME_CFG" ]; then
  RUNTIME_NAMES=$(find "$RUNTIME_CFG" -maxdepth 1 -type f \
    \( -name "*.json" -o -name "*.yaml" -o -name "*.yml" -o -name "*.md" \) \
    2>/dev/null | xargs -I{} basename {} | sort)
fi
if [ -d "$INFRA_CFG" ]; then
  INFRA_NAMES=$(find "$INFRA_CFG" -maxdepth 1 -type f \
    \( -name "*.json" -o -name "*.yaml" -o -name "*.yml" -o -name "*.md" \) \
    2>/dev/null | xargs -I{} basename {} | sort)
fi

RUNTIME_COUNT=$(echo "$RUNTIME_NAMES" | grep -c . 2>/dev/null || echo 0)
INFRA_COUNT=$(echo "$INFRA_NAMES" | grep -c . 2>/dev/null || echo 0)

# 두 목록에 동시에 존재하는 파일 이름 = 이중 경로 후보
DUAL_FOUND=0
if [ -n "$RUNTIME_NAMES" ] && [ -n "$INFRA_NAMES" ]; then
  while IFS= read -r fname; do
    [ -z "$fname" ] && continue
    if echo "$INFRA_NAMES" | grep -qxF "$fname"; then
      rt_path="${RUNTIME_CFG}/${fname}"
      inf_path="${INFRA_CFG}/${fname}"
      # 심링크라면 이중 경로가 아니라 SSoT 참조 — 제외
      if [ -L "$rt_path" ]; then
        continue
      fi
      printf '  ⚠️  실제 이중 경로 충돌: %s\n' "$fname"
      printf '     runtime : %s (%s줄)\n' "$rt_path" "$(wc -l < "$rt_path" 2>/dev/null | tr -d ' ')"
      printf '     infra   : %s (%s줄)\n' "$inf_path" "$(wc -l < "$inf_path" 2>/dev/null | tr -d ' ')"
      _log "warn" "이중 경로 충돌: ${fname}"
      DUAL_FOUND=$((DUAL_FOUND + 1))
      ISSUES=$((ISSUES + 1))
    fi
  done <<< "$RUNTIME_NAMES"
fi

if [ "$DUAL_FOUND" -eq 0 ]; then
  echo "  ✓ 실제 이중 경로 없음 (심링크 SSoT 참조는 정상)"
  printf '     runtime/config: %s개  |  infra/config: %s개\n' "$RUNTIME_COUNT" "$INFRA_COUNT"
else
  printf '  ⚠️  총 %d개 파일 이름 충돌 — 편집 전 SSoT 경로를 확인하십시오.\n' "$DUAL_FOUND"
fi

# ── 4. 대상 디렉터리 내 config 파일 목록 ─────────────────────────────────────

_hdr "📋 대상 디렉터리 내 Config/설정 파일 목록"
CFG_FILES=$(find "$TARGET_DIR" -maxdepth 3 \
  \( -name "*.json" -o -name "*.yaml" -o -name "*.yml" -o -name "*.toml" -o -name "*.env*" \) \
  -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | sort)

if [ -z "$CFG_FILES" ]; then
  echo "  (설정 파일 없음)"
else
  CFG_COUNT=$(echo "$CFG_FILES" | wc -l | tr -d ' ')
  echo "  총 ${CFG_COUNT}개:"
  echo "$CFG_FILES" | while IFS= read -r f; do
    sz=$(du -sh "$f" 2>/dev/null | cut -f1)
    printf '     %s  (%s)\n' "${f#${TARGET_DIR}/}" "$sz"
  done
fi

# ── 5. 그림자 경로(shadow path) 위험 감지 ──────────────────────────────────

_hdr "👥 그림자 경로 감지 (runtime/runtime / .jarvis/runtime 이중 쌓임)"
SHADOW_RUNTIME="${JARVIS_ROOT}/runtime/runtime"
DOTJARVIS_RUNTIME="${HOME}/.jarvis/runtime"

if [ -d "$SHADOW_RUNTIME" ]; then
  CNT=$(find "$SHADOW_RUNTIME" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
  printf '  ⚠️  B형 그림자 경로 존재: %s (%d항목)\n' "$SHADOW_RUNTIME" "$((CNT - 1))"
  _log "warn" "B형 그림자 경로: ${SHADOW_RUNTIME}"
  ISSUES=$((ISSUES + 1))
else
  echo "  ✓ B형 그림자 없음 (runtime/runtime)"
fi

if [ -d "$DOTJARVIS_RUNTIME" ]; then
  CNT=$(find "$DOTJARVIS_RUNTIME" -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
  printf '  ⚠️  A형 그림자 경로 존재: %s (%d항목)\n' "$DOTJARVIS_RUNTIME" "$((CNT - 1))"
  _log "warn" "A형 그림자 경로: ${DOTJARVIS_RUNTIME}"
  ISSUES=$((ISSUES + 1))
else
  echo "  ✓ A형 그림자 없음 (.jarvis/runtime)"
fi

# ── 6. .example 파일과 실제 파일 불일치 감지 ─────────────────────────────────

_hdr "🔍 .example 파일 ↔ 실제 파일 대조"
MISSING_REAL=0
while IFS= read -r ex; do
  real="${ex%.example.*}"
  real_noext="${ex%.example}"
  # json.example → json, example.json → 해당 없음
  actual=""
  if [[ "$ex" == *.example ]]; then
    actual="${ex%.example}"
  elif [[ "$ex" == *.example.* ]]; then
    ext="${ex##*.}"
    base="${ex%.example.*}"
    actual="${base}.${ext}"
  fi
  if [ -n "$actual" ]; then
    # infra/config의 실제 파일 또는 runtime/config의 실제 파일 중 하나라도 있으면 OK
    actual_runtime="${JARVIS_ROOT}/runtime/config/$(basename "$actual")"
    if [ ! -f "$actual" ] && [ ! -f "$actual_runtime" ]; then
      printf '  ⚠️  .example만 있고 실제 파일 없음: %s\n' "$(basename "$actual")"
      printf '       example: %s\n' "$ex"
      MISSING_REAL=$((MISSING_REAL + 1))
    fi
  fi
done < <(find "${JARVIS_ROOT}/runtime/config" "${JARVIS_ROOT}/infra/config" \
  -maxdepth 1 -name "*.example*" 2>/dev/null | sort)

if [ "$MISSING_REAL" -eq 0 ]; then
  echo "  ✓ 모든 .example 파일에 대응하는 실제 파일 존재"
fi

# ── 7. 요약 ─────────────────────────────────────────────────────────────────

_hdr "📊 스캔 요약"
if [ "$ISSUES" -eq 0 ]; then
  echo "  ✅ 이슈 없음 — 편집을 진행해도 됩니다."
  _log "info" "스캔 완료 — 이슈 없음"
else
  printf '  ⚠️  총 %d개 이슈 감지 — 위 항목을 먼저 확인하고 편집하십시오.\n' "$ISSUES"
  _log "warn" "스캔 완료 — ${ISSUES}개 이슈"
fi
echo
_log "info" "스캔 완료 (exit=${ISSUES})"

[ "$ISSUES" -eq 0 ]
