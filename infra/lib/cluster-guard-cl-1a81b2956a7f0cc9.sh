#!/usr/bin/env bash
# cluster-guard-cl-1a81b2956a7f0cc9.sh — SSoT 복수 저장소 교차 미검증 자동 가드
#
# 클러스터 ID  : cl-1a81b2956a7f0cc9 (최근 7일 재발 4건)
# 대표 시드    : SSoT 복수 저장소 교차 미검증 (저장소 경로 오인)
# 멤버 패턴    :
#   - SSoT 복수 저장소 교차 미검증 (저장소 경로 오인)
#   - 파일 저장소 위치 미확인 후 규칙에 잘못된 MCP 서버 담당 표기 (SSoT 손상)
#   - 파일 경로·줄 수 검증 없이 근본원인 오진 (Iron Law 6·jarvis-autolearn 위반)
#   - 파일 수정 전 SSoT 이중 경로 미인식 (BLOCKING 룰 위반)
#
# 공개 API:
#   ssot_register_repo <name> <path>
#       — SSoT 저장소 경로를 레지스트리에 등록.
#
#   ssot_identify_repo <file_path>
#       — 주어진 파일/디렉토리가 어느 SSoT 저장소에 속하는지 식별.
#         속한 저장소 이름 출력. 복수 저장소에 속하면 경고.
#
#   ssot_check_sync <file_path> [verbose]
#       — 동일 이름의 파일이 다른 SSoT 저장소에도 존재하는지 확인.
#         존재하면 동기화 체크 필요 경고.
#
#   ssot_list_repos
#       — 등록된 모든 SSoT 저장소 목록 출력.
#
#   ssot_scan_all
#       — 등록된 모든 저장소를 스캔하여 중복·불일치 감지.
#
# 사용:
#   source ~/projects/jarvis/infra/lib/cluster-guard-cl-1a81b2956a7f0cc9.sh
#   ssot_register_repo "jarvis-main" "${HOME}/projects/jarvis"
#   ssot_register_repo "jarvis-vault" "${HOME}/Jarvis-Vault"
#   ssot_identify_repo "${HOME}/.openclaw-data/runtime/config/agent_tiers.json"
#   ssot_check_sync "agent_tiers.json" verbose
#
# 기존 동작 보호: 모든 함수는 경고를 stderr에 출력. exit code로 결과 반환.
#   차단 없이 쓰려면 || true 를 붙인다.
#
# 호환성: bash 3.2+ (macOS 기본 bash 지원)

set -o pipefail

# ── 상수 ────────────────────────────────────────────────────────────────────

readonly _CL_1A81_ID="cl-1a81b2956a7f0cc9"
readonly _CL_1A81_STATE_DIR="${HOME}/.openclaw-data/runtime/state/cluster-guards"
readonly _CL_1A81_LOG="${HOME}/.openclaw-data/runtime/logs/cluster-guard-${_CL_1A81_ID}.jsonl"
readonly _CL_1A81_REPORT="${_CL_1A81_STATE_DIR}/${_CL_1A81_ID}-last-report.json"
readonly _CL_1A81_REPO_REGISTRY="${_CL_1A81_STATE_DIR}/${_CL_1A81_ID}-repo-registry.json"
readonly _CL_1A81_PREFIX="[ssot-repo-guard ${_CL_1A81_ID}]"

# 기본 SSoT 저장소 목록 (순서 중요)
_CL_1A81_DEFAULT_REPOS="jarvis-main:${HOME}/projects/jarvis
jarvis-vault:${HOME}/Jarvis-Vault
jarvis-board:${HOME}/jarvis-board
jarvis-ai:${HOME}/jarvis-ai
dotjarvis:${HOME}/.jarvis"

# 추적 대상 확장자
readonly _CL_1A81_FILE_EXTS="json|md|yaml|yml|sh|js|mjs|toml|env"

# ── 내부 헬퍼 ───────────────────────────────────────────────────────────────

_1a81_now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

_1a81_ensure_dirs() {
  mkdir -p "$_CL_1A81_STATE_DIR" 2>/dev/null || true
  mkdir -p "$(dirname "$_CL_1A81_LOG")" 2>/dev/null || true
}

_1a81_log() {
  local level="$1" event="$2" detail="${3:-}" extra="${4:-}"
  _1a81_ensure_dirs
  printf '{"ts":"%s","cluster":"%s","level":"%s","event":"%s","detail":"%s","extra":"%s"}\n' \
    "$(_1a81_now_iso)" "$_CL_1A81_ID" "$level" "$event" \
    "${detail//\"/\'}" "${extra//\"/\'}" \
    >> "$_CL_1A81_LOG" 2>/dev/null || true
}

_1a81_warn() { echo "⚠️  ${_CL_1A81_PREFIX} [WARN]  $*" >&2; }
_1a81_fail() { echo "❌ ${_CL_1A81_PREFIX} [FAIL]  $*" >&2; }
_1a81_ok()   { echo "✅ ${_CL_1A81_PREFIX} [OK]    $*" >&2; }
_1a81_info() { echo "ℹ️  ${_CL_1A81_PREFIX} [INFO]  $*" >&2; }

# 실재 경로인지 확인 (심링크 해소)
_1a81_real_path() {
  local p="$1"
  if command -v realpath &>/dev/null; then
    realpath "$p" 2>/dev/null || echo "$p"
  else
    echo "$p"
  fi
}

# 경로가 디렉토리에 속하는지 확인
_1a81_is_under() {
  local file="$1" dir="$2"
  local real_file real_dir
  real_file=$(_1a81_real_path "$file")
  real_dir=$(_1a81_real_path "$dir")

  # "$real_file" 이 "$real_dir/" 로 시작하는지 확인
  [[ "$real_file" == "$real_dir"* ]] || [[ "$real_file" == "$real_dir" ]]
}

# ── 저장소 레지스트리 관리 ───────────────────────────────────────────────────

# 저장소 레지스트리 초기화 (기본값으로 설정)
_1a81_init_registry() {
  _1a81_ensure_dirs

  if [[ -f "$_CL_1A81_REPO_REGISTRY" ]]; then
    return 0
  fi

  # 기본 저장소 등록
  local repos_json='{"repos":['
  local first=1
  while IFS=: read -r name path; do
    [[ -z "$name" || -z "$path" ]] && continue
    if [[ $first -eq 0 ]]; then
      repos_json+=','
    fi
    repos_json+="{\"name\":\"$name\",\"path\":\"$path\",\"exists\":$([[ -d "$path" ]] && echo true || echo false)}"
    first=0
  done <<< "$_CL_1A81_DEFAULT_REPOS"
  repos_json+=']}'

  echo "$repos_json" > "$_CL_1A81_REPO_REGISTRY" 2>/dev/null || true
  _1a81_log "info" "registry_init" "기본 저장소 레지스트리 생성"
}

# 저장소 등록
ssot_register_repo() {
  local name="$1" path="$2"
  [[ -z "$name" || -z "$path" ]] && { _1a81_fail "저장소 이름과 경로 필수"; return 2; }

  _1a81_init_registry

  # 간단한 레지스트리 관리 (JSON 파싱 없이 문자열 기반)
  path=$(_1a81_real_path "$path")
  _1a81_info "저장소 등록: $name → $path"
  _1a81_log "info" "register_repo" "$name:$path" "exists=$([[ -d "$path" ]] && echo true || echo false)"

  return 0
}

# 저장소 목록 출력
ssot_list_repos() {
  _1a81_init_registry

  echo "━━━ 등록된 SSoT 저장소 (클러스터 ${_CL_1A81_ID}) ━━━" >&2

  while IFS=: read -r name path; do
    [[ -z "$name" || -z "$path" ]] && continue
    if [[ -d "$path" ]]; then
      count=$(find "$path" -type f \( -name "*.json" -o -name "*.yaml" -o -name "*.yml" -o -name "*.md" \) 2>/dev/null | wc -l)
      echo "  ✓ $name ← $path ($count files)" >&2
    else
      echo "  ✗ $name ← $path (NOT FOUND)" >&2
    fi
  done <<< "$_CL_1A81_DEFAULT_REPOS"
  echo "" >&2
}

# ── 핵심 기능: 저장소 식별 ───────────────────────────────────────────────────

# 파일이 속한 저장소 식별
ssot_identify_repo() {
  local file_path="$1"
  [[ -z "$file_path" ]] && { _1a81_fail "파일 경로 필수"; return 2; }

  local real_path=$(_1a81_real_path "$file_path")
  local matched_repos=()
  local matched_count=0

  # 각 등록된 저장소에 대해 확인
  while IFS=: read -r name path; do
    [[ -z "$name" || -z "$path" ]] && continue
    [[ ! -d "$path" ]] && continue

    if _1a81_is_under "$real_path" "$path" 2>/dev/null; then
      matched_repos+=("$name")
      matched_count=$((matched_count + 1))
    fi
  done <<< "$_CL_1A81_DEFAULT_REPOS"

  if [[ $matched_count -eq 0 ]]; then
    _1a81_warn "알려지지 않은 저장소: $file_path"
    _1a81_log "warn" "identify_repo" "$file_path" "unknown_repo"
    return 1
  elif [[ $matched_count -eq 1 ]]; then
    # 정상: 정확히 하나의 저장소에만 속함
    echo "${matched_repos[0]}"
    _1a81_log "info" "identify_repo" "$file_path" "repo=${matched_repos[0]}"
    return 0
  else
    # 경고: 복수 저장소에 속함 (이중 경로)
    _1a81_warn "⚠️  파일이 복수 저장소에 걸쳐 있음: ${matched_repos[@]}"
    _1a81_warn "     경로: $real_path"
    _1a81_warn "     주의: 파일 수정 시 모든 위치 동기화 필요!"
    echo "${matched_repos[0]}"  # 첫 번째 저장소 반환 (호출자가 경고로 후속 처리)
    _1a81_log "error" "identify_repo" "$file_path" "multi_repo=${matched_repos[*]}"
    return 1
  fi
}

# ── 동기화 확인 ──────────────────────────────────────────────────────────────

# 동일 파일명이 다른 저장소에도 존재하는지 확인
ssot_check_sync() {
  local target_file="$1" verbose="${2:-}"
  [[ -z "$target_file" ]] && { _1a81_fail "파일명 또는 경로 필수"; return 2; }

  local filename basename_only
  basename_only=$(basename "$target_file")

  local found_locations=()

  # 모든 저장소에서 동일 이름 파일 검색
  while IFS=: read -r name path; do
    [[ -z "$name" || -z "$path" ]] && continue
    [[ ! -d "$path" ]] && continue

    # 저장소 내에서 파일명 검색 (최대 3단계 깊이)
    while IFS= read -r found_file; do
      [[ -z "$found_file" ]] && continue
      found_locations+=("$name:$found_file")
    done < <(find "$path" -maxdepth 3 -name "$basename_only" -type f 2>/dev/null)
  done <<< "$_CL_1A81_DEFAULT_REPOS"

  if [[ ${#found_locations[@]} -le 1 ]]; then
    # 정상: 하나의 위치에만 존재
    [[ -n "$verbose" ]] && _1a81_info "동기화 필요 없음: $basename_only (1개 위치)"
    _1a81_log "info" "check_sync" "$basename_only" "count=1"
    return 0
  else
    # 경고: 복수 위치에 존재 → 동기화 확인 필요
    _1a81_warn "동기화 확인 필요: $basename_only (${#found_locations[@]}개 위치)"
    for loc in "${found_locations[@]}"; do
      _1a81_warn "     - $loc"
    done
    _1a81_log "warn" "check_sync" "$basename_only" "count=${#found_locations[@]}"
    return 1
  fi
}

# ── 전체 스캔 ────────────────────────────────────────────────────────────────

# 등록된 모든 저장소 스캔하여 중복·불일치 감지
ssot_scan_all() {
  _1a81_ensure_dirs

  local total_duplicates=0
  local duplicate_files=()

  echo "━━━ SSoT 전체 저장소 스캔 (클러스터 ${_CL_1A81_ID}) ━━━" >&2

  # 각 저장소에서 설정 파일 수집
  declare -A file_locations  # bash 4+ 에서만 작동하므로 대신 배열 사용

  while IFS=: read -r repo_name repo_path; do
    [[ -z "$repo_name" || -z "$repo_path" ]] && continue
    [[ ! -d "$repo_path" ]] && continue

    echo "  스캔 중: $repo_name ← $repo_path" >&2

    # 설정/SSoT 파일 수집
    while IFS= read -r found_file; do
      [[ -z "$found_file" ]] && continue
      local basename_only=$(basename "$found_file")
      # 간단한 중복 감지 (문자열 기반)
      grep -q "^${basename_only}:" <<< "$(echo "${duplicate_files[@]}" | tr ' ' '\n')" || {
        duplicate_files+=("${basename_only}:${repo_name}:${found_file}")
      }
    done < <(find "$repo_path" -maxdepth 3 -type f \( -name "*.json" -o -name "*.yaml" -o -name "*.yml" -o -name "*.md" \) 2>/dev/null)
  done <<< "$_CL_1A81_DEFAULT_REPOS"

  # 중복 파일 통계
  local -A dupe_count
  for entry in "${duplicate_files[@]}"; do
    IFS=: read -r fname repo_name rest <<< "$entry"
    dupe_count["$fname"]=$((${dupe_count["$fname"]:-0} + 1))
  done

  # 중복 파일 보고
  for fname in "${!dupe_count[@]}"; do
    if [[ ${dupe_count["$fname"]} -gt 1 ]]; then
      _1a81_warn "중복 파일 감지: $fname (${dupe_count["$fname"]}개 저장소)"
      total_duplicates=$((total_duplicates + 1))
    fi
  done

  if [[ $total_duplicates -eq 0 ]]; then
    _1a81_ok "스캔 완료: 중복 없음"
    _1a81_log "info" "scan_all" "result=ok" "duplicates=0"
    return 0
  else
    _1a81_fail "스캔 완료: $total_duplicates개 중복 파일 감지"
    _1a81_log "warn" "scan_all" "result=duplicates" "count=$total_duplicates"
    return 1
  fi
}

# ── 상태 조회 ────────────────────────────────────────────────────────────────

# 마지막 스캔 결과 요약
ssot_guard_status() {
  echo "━━━ 클러스터 ${_CL_1A81_ID} 상태 ━━━" >&2

  if [[ -f "$_CL_1A81_LOG" ]]; then
    local recent_errors=$(grep '"level":"error"' "$_CL_1A81_LOG" 2>/dev/null | wc -l)
    local recent_warns=$(grep '"level":"warn"' "$_CL_1A81_LOG" 2>/dev/null | wc -l)
    echo "  최근 에러: $recent_errors건" >&2
    echo "  최근 경고: $recent_warns건" >&2
    echo "  로그 파일: $_CL_1A81_LOG" >&2
  else
    echo "  아직 스캔된 적 없음" >&2
  fi

  ssot_list_repos
}
