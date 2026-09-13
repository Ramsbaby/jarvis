#!/usr/bin/env bash
# cluster-guard-cl-eba9e129c709bb2a.sh — SSoT 경로 중복·불일치 자동 감지 가드
#
# 클러스터 ID  : cl-eba9e129c709bb2a (최근 7일 재발 6건)
# 대표 시드    : 파일 위치 오류를 문서 유지보수 문제로 귀인했으나 실제는 저장소 구조 미이해
# 멤버 패턴    :
#   - 파일 위치 오류를 문서 유지보수 문제로 귀인 (저장소 구조 미이해)
#   - 문서 수치를 검증 없이 인용 — 파일 이동 감지 실패
#   - SSoT 복수 저장소 교차 미검증 (저장소 경로 오인)
#   - 파일 경로·줄 수 검증 없이 근본원인 오진 (Iron Law 6·jarvis-autolearn 위반)
#   - 문서·설정 미탐색 → SSoT 위반 발생 후 미인지 (파일 위치 중복·불일치)
#
# 공개 API:
#   ssot_scan_roots [root...]
#       — 지정 루트(기본: 4개 SSoT 루트)에서 설정·SSoT 파일 목록 수집.
#
#   ssot_detect_duplicates [root...]
#       — 동일 파일명이 여러 SSoT 루트에 존재하는 경우를 감지.
#         중복 발견 시 non-zero 반환 + 위치 목록 출력.
#
#   ssot_verify_path <file_path_or_name>
#       — 주어진 경로/이름이 실제로 존재하는지 확인.
#         동일 이름의 다른 위치도 자동으로 출력 (귀인 오류 방지).
#
#   ssot_cross_check_config <filename>
#       — runtime/config vs infra/config 등 이중 경로에서 동일 파일 비교.
#         내용 불일치 감지 시 경고.
#
#   ssot_guard_status
#       — 마지막 스캔 결과 요약 출력.
#
# 사용:
#   source ~/projects/jarvis/infra/lib/cluster-guard-cl-eba9e129c709bb2a.sh
#   ssot_detect_duplicates
#   ssot_verify_path "agent_tiers.json"
#
# 기존 동작 보호: 모든 함수는 경고를 stderr에 출력. exit code로 결과 반환.
#   차단 없이 쓰려면 || true 를 붙인다.
#
# 호환성: bash 3.2+ (macOS 기본 bash 지원)

set -o pipefail

# ── 상수 ────────────────────────────────────────────────────────────────────

readonly _CL_EBA9_ID="cl-eba9e129c709bb2a"
readonly _CL_EBA9_STATE_DIR="${HOME}/.openclaw-data/runtime/state/cluster-guards"
readonly _CL_EBA9_LOG="${HOME}/.openclaw-data/runtime/logs/cluster-guard-${_CL_EBA9_ID}.jsonl"
readonly _CL_EBA9_REPORT="${_CL_EBA9_STATE_DIR}/${_CL_EBA9_ID}-last-report.json"
readonly _CL_EBA9_PREFIX="[ssot-path-guard ${_CL_EBA9_ID}]"

# 기본 SSoT 루트 (bash 3.2: readonly -a 미지원 → 일반 변수로 관리)
_CL_EBA9_DEFAULT_ROOTS="${HOME}/.jarvis
${HOME}/projects/jarvis
${HOME}/Jarvis-Vault
${HOME}/jarvis-board"

# 추적 대상 확장자
readonly _CL_EBA9_FILE_EXTS="json|md|yaml|yml|sh|js|mjs|toml"

# ── 내부 헬퍼 ───────────────────────────────────────────────────────────────

_eba9_now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

_eba9_ensure_dirs() {
  mkdir -p "$_CL_EBA9_STATE_DIR" 2>/dev/null || true
  mkdir -p "$(dirname "$_CL_EBA9_LOG")" 2>/dev/null || true
}

_eba9_log() {
  local level="$1" event="$2" detail="${3:-}" extra="${4:-}"
  _eba9_ensure_dirs
  printf '{"ts":"%s","cluster":"%s","level":"%s","event":"%s","detail":"%s","extra":"%s"}\n' \
    "$(_eba9_now_iso)" "$_CL_EBA9_ID" "$level" "$event" \
    "${detail//\"/\'}" "${extra//\"/\'}" \
    >> "$_CL_EBA9_LOG" 2>/dev/null || true
}

_eba9_warn() { echo "⚠️  ${_CL_EBA9_PREFIX} [WARN]  $*" >&2; }
_eba9_fail() { echo "❌ ${_CL_EBA9_PREFIX} [FAIL]  $*" >&2; }
_eba9_ok()   { echo "✅ ${_CL_EBA9_PREFIX} [OK]    $*" >&2; }
_eba9_info() { echo "ℹ️  ${_CL_EBA9_PREFIX} [INFO]  $*" >&2; }

# 루트 목록 출력 (인자 있으면 인자, 없으면 기본값 — 개행 구분 문자열로 반환)
_eba9_get_roots() {
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@"
  else
    printf '%s\n' $_CL_EBA9_DEFAULT_ROOTS
  fi
}

# 실재 경로인지 확인 (심링크 해소)
_eba9_real_path() {
  local p="$1"
  if command -v realpath &>/dev/null; then
    realpath "$p" 2>/dev/null || echo "$p"
  else
    echo "$p"
  fi
}

# find 명령 공통 래퍼: 지정 루트들에서 설정 파일 목록 출력
_eba9_find_files() {
  local root="$1"
  find "$root" -maxdepth 5 \
    \( -name ".git" -o -name "node_modules" -o -name "__pycache__" \) -prune \
    -o -type f -name "*.json" -print \
    -o -type f -name "*.md" -print \
    -o -type f -name "*.yaml" -print \
    -o -type f -name "*.yml" -print \
    -o -type f -name "*.sh" -print \
    -o -type f -name "*.js" -print \
    -o -type f -name "*.mjs" -print \
    -o -type f -name "*.toml" -print \
    2>/dev/null
}

# ── 공개 API: 1. ssot_scan_roots ───────────────────────────────────────────
#
# 지정 루트(또는 기본 4개)에서 SSoT·설정 파일 수 통계 출력.
#
ssot_scan_roots() {
  _eba9_ensure_dirs
  local ts
  ts=$(_eba9_now_iso)

  echo "━━━ SSoT 루트 스캔 [${ts}] ━━━" >&2

  local total=0
  local root

  while IFS= read -r root; do
    [[ -z "$root" ]] && continue
    if [[ ! -d "$root" ]]; then
      _eba9_warn "루트 없음 (건너뜀): ${root}"
      _eba9_log "warn" "root_missing" "$root"
      continue
    fi

    local real_root
    real_root=$(_eba9_real_path "$root")
    if [[ "$real_root" != "$root" ]]; then
      _eba9_info "심링크 감지: ${root} → ${real_root}"
      _eba9_log "info" "symlink_detected" "$root" "$real_root"
    fi

    local count
    count=$(_eba9_find_files "$root" | wc -l | tr -d ' ')
    _eba9_info "  ${root}: ${count}개 파일"
    total=$((total + count))
  done < <(_eba9_get_roots "$@")

  _eba9_info "전체 추적 파일 수: ${total}"
  _eba9_log "info" "scan_complete" "total=${total}"
  return 0
}

# ── 공개 API: 2. ssot_detect_duplicates ───────────────────────────────────
#
# 동일 파일명이 여러 SSoT 루트에 존재하는 경우를 감지.
# Python3으로 basename 집계 → bash 3.2 associative array 우회.
#
# 반환:
#   0 = 중복 없음
#   1 = 중복 감지
#
ssot_detect_duplicates() {
  _eba9_ensure_dirs
  local ts
  ts=$(_eba9_now_iso)

  echo "" >&2
  echo "━━━ SSoT 중복 파일 감지 [${ts}] ━━━" >&2

  # 존재하는 루트만 수집
  local roots_exist=""
  local root
  while IFS= read -r root; do
    [[ -z "$root" ]] && continue
    [[ -d "$root" ]] && roots_exist="${roots_exist} ${root}"
  done < <(_eba9_get_roots "$@")

  if [[ -z "$roots_exist" ]]; then
    _eba9_warn "검사할 루트가 하나도 없음"
    return 0
  fi

  # Python3으로 중복 감지 (bash 3.2 associative array 미지원 우회)
  local dup_result
  dup_result=$(python3 - $roots_exist <<'PYEOF'
import sys, os, collections

roots = sys.argv[1:]
name_to_paths = collections.defaultdict(list)

for root in roots:
    root = os.path.expanduser(root)
    if not os.path.isdir(root):
        continue
    for dirpath, dirnames, filenames in os.walk(root, topdown=True):
        # 제외 디렉터리
        dirnames[:] = [d for d in dirnames if d not in ('.git', 'node_modules', '__pycache__')]
        # 깊이 제한 (maxdepth 5)
        depth = dirpath[len(root):].count(os.sep)
        if depth >= 5:
            dirnames[:] = []
            continue
        for fname in filenames:
            ext = os.path.splitext(fname)[1].lstrip('.')
            if ext in ('json','md','yaml','yml','sh','js','mjs','toml'):
                fpath = os.path.join(dirpath, fname)
                name_to_paths[fname].append((root, fpath))

duplicates = 0
for fname, entries in sorted(name_to_paths.items()):
    unique_roots = []
    paths = []
    for root, fpath in entries:
        if root not in unique_roots:
            unique_roots.append(root)
        paths.append(fpath)
    if len(unique_roots) > 1:
        duplicates += 1
        print(f"DUP:{fname}")
        for p in paths:
            print(f"  PATH:{p}")

print(f"TOTAL_DUPS:{duplicates}")
print(f"ROOTS_CHECKED:{len(roots)}")
PYEOF
  )

  local duplicates=0
  local roots_checked=0
  local current_dup=""

  while IFS= read -r line; do
    if [[ "$line" == DUP:* ]]; then
      current_dup="${line#DUP:}"
      _eba9_warn "중복 감지: ${current_dup}"
    elif [[ "$line" == "  PATH:"* ]]; then
      local path="${line#  PATH:}"
      echo "     └─ ${path}" >&2
      _eba9_log "warn" "duplicate_file" "$current_dup" "$path"
    elif [[ "$line" == TOTAL_DUPS:* ]]; then
      duplicates="${line#TOTAL_DUPS:}"
    elif [[ "$line" == ROOTS_CHECKED:* ]]; then
      roots_checked="${line#ROOTS_CHECKED:}"
    fi
  done <<< "$dup_result"

  local exit_code=0
  if [[ "$duplicates" -gt 0 ]]; then
    _eba9_fail "${duplicates}개 파일이 여러 SSoT 루트에 중복 존재 — 편집 전 어떤 것이 권위 있는 SSoT인지 확인 필요"
    _eba9_log "fail" "duplicates_found" "count=${duplicates}"
    exit_code=1
  else
    _eba9_ok "SSoT 루트 간 중복 파일 없음"
    _eba9_log "ok" "no_duplicates"
  fi

  # 보고서 저장
  printf '{"ts":"%s","cluster":"%s","duplicates":%s,"roots_checked":%s}\n' \
    "$ts" "$_CL_EBA9_ID" "${duplicates:-0}" "${roots_checked:-0}" \
    > "$_CL_EBA9_REPORT" 2>/dev/null || true

  return $exit_code
}

# ── 공개 API: 3. ssot_verify_path ──────────────────────────────────────────
#
# 주어진 파일 경로 또는 파일명의 실재 여부를 확인하고,
# 동일 이름이 다른 위치에도 존재하는지 자동으로 나열.
# (귀인 오류 방지: "이 경로에 있어야 한다"는 가정을 실측으로 교체)
#
# 인자:
#   $1 — 절대경로 또는 파일명 (예: "agent_tiers.json")
#
# 반환:
#   0 = 지정 경로가 실재하며 다른 위치와 일치
#   1 = 경로 없거나 다른 위치 발견
#
ssot_verify_path() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    _eba9_warn "인자 없음 — ssot_verify_path <경로 또는 파일명>"
    return 1
  fi

  _eba9_ensure_dirs
  local ts
  ts=$(_eba9_now_iso)

  echo "" >&2
  echo "━━━ SSoT 경로 실측 검증 [${ts}]: ${target} ━━━" >&2

  local issues=0

  # 절대경로 vs 파일명 분기
  if [[ "$target" == /* ]] || [[ "$target" == ~* ]]; then
    local expanded="${target/#\~/$HOME}"
    if [[ -e "$expanded" ]]; then
      _eba9_ok "경로 실재 확인: ${expanded}"
      local real
      real=$(_eba9_real_path "$expanded")
      if [[ "$real" != "$expanded" ]]; then
        _eba9_warn "심링크 경로! 실제 위치: ${real}"
        issues=$((issues + 1))
      fi
    else
      _eba9_fail "경로 없음: ${expanded}"
      _eba9_log "fail" "path_missing" "$expanded"
      issues=$((issues + 1))
    fi

    local fname
    fname=$(basename "$expanded")
    _eba9_info "동일 이름(${fname}) 다른 위치 탐색 중..."

    local others=""
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      [[ "$p" == "$expanded" ]] && continue
      others="${others}${p}\n"
      echo "     └─ ${p}" >&2
    done < <(find "${HOME}/.jarvis" "${HOME}/projects/jarvis" "${HOME}/Jarvis-Vault" "${HOME}/jarvis-board" \
      -maxdepth 6 \
      \( -name ".git" -o -name "node_modules" -o -name "__pycache__" \) -prune \
      -o -name "$fname" -print 2>/dev/null \
      | grep -v "^${expanded}$" || true)

    if [[ -n "$others" ]]; then
      _eba9_warn "동일 이름 파일이 다른 위치에 존재 — 귀인 전 교차 확인 필요"
      _eba9_log "warn" "other_locations_found" "$fname"
      issues=$((issues + 1))
    else
      _eba9_ok "다른 위치에 동일 이름 없음"
    fi

  else
    local fname="$target"
    _eba9_info "파일명 '${fname}' 을 SSoT 루트 전체에서 검색..."

    local found_count=0
    local found_first=""
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      found_count=$((found_count + 1))
      [[ $found_count -eq 1 ]] && found_first="$p"
      echo "     └─ ${p}" >&2
    done < <(find "${HOME}/.jarvis" "${HOME}/projects/jarvis" "${HOME}/Jarvis-Vault" "${HOME}/jarvis-board" \
      -maxdepth 6 \
      \( -name ".git" -o -name "node_modules" -o -name "__pycache__" \) -prune \
      -o -name "$fname" -print 2>/dev/null || true)

    if [[ $found_count -eq 0 ]]; then
      _eba9_fail "파일명 '${fname}' — 어떤 SSoT 루트에도 없음"
      _eba9_log "fail" "file_not_found_anywhere" "$fname"
      issues=$((issues + 1))
    elif [[ $found_count -eq 1 ]]; then
      _eba9_ok "유일한 위치: ${found_first}"
      _eba9_log "ok" "unique_location" "$fname" "${found_first}"
    else
      _eba9_warn "'${fname}' 이 ${found_count}개 위치에 존재 — 어느 것이 권위 있는 SSoT인지 확인 필요"
      _eba9_log "warn" "multiple_locations" "$fname" "count=${found_count}"
      issues=$((issues + 1))
    fi
  fi

  if [[ $issues -gt 0 ]]; then
    return 1
  fi
  return 0
}

# ── 공개 API: 4. ssot_cross_check_config ───────────────────────────────────
#
# runtime/config vs infra/config 등 이중 경로에서 동일 파일 내용 비교.
# 불일치 감지 시 경고 출력.
#
# 인자:
#   $1 — 비교할 파일명 (예: "agent_tiers.json")
#
# 반환:
#   0 = 일치 또는 한쪽만 존재
#   1 = 내용 불일치 감지
#
ssot_cross_check_config() {
  local fname="${1:-}"
  if [[ -z "$fname" ]]; then
    _eba9_warn "인자 없음 — ssot_cross_check_config <파일명>"
    return 1
  fi

  _eba9_ensure_dirs
  local ts
  ts=$(_eba9_now_iso)

  echo "" >&2
  echo "━━━ 이중 경로 교차 비교 [${ts}]: ${fname} ━━━" >&2

  local check_roots=(
    "${HOME}/.openclaw-data/runtime/config"
    "${HOME}/projects/jarvis/infra/config"
    "${HOME}/.jarvis/config"
    "${BOT_HOME:-${HOME}/.openclaw-data/runtime}/config"
  )

  local found_files=()
  local r
  for r in "${check_roots[@]}"; do
    local fpath="${r}/${fname}"
    if [[ -f "$fpath" ]]; then
      found_files+=("$fpath")
    fi
  done

  if [[ ${#found_files[@]} -eq 0 ]]; then
    _eba9_info "'${fname}' — 이중 경로 어디에도 없음 (정상)"
    return 0
  fi

  if [[ ${#found_files[@]} -eq 1 ]]; then
    _eba9_ok "'${fname}' — 단일 위치만 존재: ${found_files[0]}"
    return 0
  fi

  _eba9_warn "'${fname}' 이 ${#found_files[@]}개 이중 경로에 존재 — 내용 비교 중..."
  local p
  for p in "${found_files[@]}"; do
    echo "     └─ ${p}" >&2
  done

  local mismatch=0
  local ref="${found_files[0]}"
  local i
  for (( i=1; i<${#found_files[@]}; i++ )); do
    if ! diff -q "$ref" "${found_files[$i]}" &>/dev/null; then
      _eba9_fail "내용 불일치: ${ref} ≠ ${found_files[$i]}"
      _eba9_log "fail" "content_mismatch" "$ref" "${found_files[$i]}"
      diff "$ref" "${found_files[$i]}" >&2 || true
      mismatch=$((mismatch + 1))
    fi
  done

  if [[ $mismatch -gt 0 ]]; then
    return 1
  fi

  _eba9_ok "내용 동일 — 단, 이중 경로 자체가 SSoT 위반 가능성 있음"
  _eba9_log "warn" "identical_but_duplicated" "$fname"
  return 0
}

# ── 공개 API: 5. ssot_guard_status ─────────────────────────────────────────
#
# 마지막 스캔 결과 요약 출력.
#
ssot_guard_status() {
  if [[ ! -f "$_CL_EBA9_REPORT" ]]; then
    _eba9_info "아직 스캔 실행 기록 없음. ssot_detect_duplicates 를 먼저 실행하세요."
    return 0
  fi
  local ts dups roots
  ts=$(python3 -c "import json; d=json.load(open('${_CL_EBA9_REPORT}')); print(d.get('ts','?'))" 2>/dev/null || echo "unknown")
  dups=$(python3 -c "import json; d=json.load(open('${_CL_EBA9_REPORT}')); print(d.get('duplicates','?'))" 2>/dev/null || echo "?")
  roots=$(python3 -c "import json; d=json.load(open('${_CL_EBA9_REPORT}')); print(d.get('roots_checked','?'))" 2>/dev/null || echo "?")
  echo "━━━ SSoT Path Guard 상태 (${_CL_EBA9_ID}) ━━━"
  echo "마지막 스캔: ${ts}"
  echo "검사 루트 수: ${roots}  |  중복 파일: ${dups}"
  if [[ "$dups" != "0" ]] && [[ "$dups" != "?" ]]; then
    echo "⚠️  중복 발견 — ssot-path-guard.sh 를 직접 실행해 상세 확인 권장"
  fi
}
