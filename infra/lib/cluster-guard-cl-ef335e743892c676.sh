#!/usr/bin/env bash
# cluster-guard-cl-ef335e743892c676.sh — CLAUDE.md 파일 경로·줄 수 스테일 검증 가드
#
# 클러스터 ID  : cl-ef335e743892c676 (최근 7일 재발 13건)
# 대표 시드    : CLAUDE.md의 파일 경로·줄 수 미동기·미검증 — 문서가 실제와 불일치
# 멤버 패턴    :
#   - CLAUDE.md에 박은 파일 줄 수를 검증 없이 인용 (stale 데이터, 3개월 이상 방치)
#   - 문서 메타데이터(줄 수) 스테일 미인지
#   - CLAUDE.md의 파일 줄 수 정보 미갱신 → 실제 줄 수와 ±38~71% 괴리
#   - CLAUDE.md 파일 메타정보(줄 수) 3개월 미동기 — stale 미감지
#
# 공개 API:
#   claude_md_staleness_check [claude_file]
#       — CLAUDE.md 줄 수 항목을 실측값과 대조; stale 항목이 있으면 1 반환 + stderr 경고
#
#   before_cite_linecount <filename_or_path>
#       — 줄 수를 인용하기 전 실측값 검증; stale이면 실측값을 stdout에 출력하고 1 반환
#
#   pre_commit_claude_md_check
#       — staged CLAUDE.md 변경 시 줄 수 신선도 검사 (pre-commit 훅 호출용)
#       — stale 항목 발견 시 exit 1로 커밋 차단
#
#   guard_cl_ef335_status
#       — 현재 가드 상태 및 최근 로그 요약 출력
#
# 사용:
#   source ~/projects/jarvis/infra/lib/cluster-guard-cl-ef335e743892c676.sh
#   claude_md_staleness_check ~/CLAUDE.md
#   before_cite_linecount "VirtualOffice.tsx"
#
# 기존 동작 보호: 모든 함수는 경고를 stderr에 출력하고 exit code로 결과를 전달한다.
#   호출자가 set -e 환경에서 차단 없이 쓰려면 || true 를 붙인다.

set -o pipefail

# ── 상수 ────────────────────────────────────────────────────────────────────

readonly _CL_EF335_ID="cl-ef335e743892c676"
readonly _CL_EF335_STATE_DIR="${HOME}/.openclaw-data/runtime/state/cluster-guards"
readonly _CL_EF335_LOG="${HOME}/.openclaw-data/runtime/logs/cluster-guard-${_CL_EF335_ID}.jsonl"
readonly _CL_EF335_PREFIX="[claude-md-guard ${_CL_EF335_ID}]"

# 스테일 판정 임계 (%)
readonly _CL_EF335_THRESHOLD=10

# 검사 대상 CLAUDE.md 기본 목록
readonly -a _CL_EF335_DEFAULT_CLAUDE_FILES=(
  "${HOME}/CLAUDE.md"
  "${HOME}/projects/jarvis/CLAUDE.md"
  "${HOME}/jarvis-board/CLAUDE.md"
)

# ── 내부 헬퍼 ───────────────────────────────────────────────────────────────

_ef335_now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

_ef335_ensure_dirs() {
  mkdir -p "$_CL_EF335_STATE_DIR" "$(dirname "$_CL_EF335_LOG")"
}

_ef335_log() {
  local level="$1" msg="$2"
  local extra="${3:-}"
  _ef335_ensure_dirs
  local ts; ts=$(_ef335_now_iso)
  local entry
  entry=$(printf '{"ts":"%s","level":"%s","guard":"%s","msg":%s%s}\n' \
    "$ts" "$level" "$_CL_EF335_ID" \
    "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "$msg")" \
    "${extra:+,$extra}")
  echo "$entry" >> "$_CL_EF335_LOG"
  if [[ "$level" == "WARN" || "$level" == "ERROR" ]]; then
    echo "$_CL_EF335_PREFIX $level: $msg" >&2
  fi
}

# 쉼표 제거 후 숫자 반환
_ef335_strip_commas() { tr -d ',' <<< "$1"; }

# 절댓값 계산
_ef335_abs() { echo "${1#-}"; }

# 파일 경로 해석 (다중 전략)
_ef335_resolve_path() {
  local name="$1"
  local hint_dir="${2:-$HOME}"

  # 절대경로
  [[ "$name" == /* ]] && [[ -f "$name" ]] && { echo "$name"; return 0; }

  # CLAUDE.md 기준 상대경로
  [[ -f "$hint_dir/$name" ]] && { echo "$hint_dir/$name"; return 0; }

  # 부모 디렉터리 기준
  local parent="${hint_dir%/*}"
  [[ -f "$parent/$name" ]] && { echo "$parent/$name"; return 0; }

  # find fallback (깊이 제한 5)
  local found
  found=$(find "$parent" -maxdepth 5 -name "$(basename "$name")" -type f 2>/dev/null | head -1)
  [[ -n "$found" ]] && { echo "$found"; return 0; }

  echo ""
}

# ── 공개 API: 1. claude_md_staleness_check ──────────────────────────────────
#
# claude_md_staleness_check [claude_file ...]
#
# CLAUDE.md 파일에서 "filename(NNN줄)" 또는 "| filename | NNN줄 |" 패턴을 추출해
# 실제 줄 수와 대조한다. 스테일 항목이 1개 이상이면 1을 반환한다.
#
# 반환값:
#   0  — 모든 항목 신선 (또는 검사 불가 항목 없음)
#   1  — 스테일 항목 발견
#
claude_md_staleness_check() {
  _ef335_ensure_dirs

  local -a targets=("$@")
  if (( ${#targets[@]} == 0 )); then
    for f in "${_CL_EF335_DEFAULT_CLAUDE_FILES[@]}"; do
      [[ -f "$f" ]] && targets+=("$f")
    done
  fi

  if (( ${#targets[@]} == 0 )); then
    _ef335_log "WARN" "검사할 CLAUDE.md 파일을 찾지 못했습니다"
    return 0
  fi

  local overall_stale=0

  for claude_file in "${targets[@]}"; do
    [[ -f "$claude_file" ]] || continue
    local claude_dir; claude_dir="$(dirname "$claude_file")"
    local stale_count=0 total_count=0

    _ef335_log "INFO" "검사 시작: $claude_file"

    while IFS= read -r line; do
      # 패턴: (NNN줄) 또는 (N,NNN줄) 포함
      echo "$line" | grep -qE '\([0-9,]+\s*줄\)' || continue

      local recorded_raw
      recorded_raw=$(echo "$line" | grep -oE '\([0-9,]+\s*줄\)' | grep -oE '[0-9,]+' | head -1)
      [[ -z "$recorded_raw" ]] && continue

      local recorded; recorded=$(_ef335_strip_commas "$recorded_raw")

      # 파일명 추출 (확장자 포함 토큰)
      local filename
      filename=$(echo "$line" | grep -oE '[a-zA-Z0-9_./\-]+\.(tsx?|js|mjs|sh|py|md|ts)' | head -1)
      [[ -z "$filename" ]] && continue

      (( total_count++ )) || true

      local full_path; full_path=$(_ef335_resolve_path "$filename" "$claude_dir")
      if [[ -z "$full_path" ]] || [[ ! -f "$full_path" ]]; then
        _ef335_log "WARN" "파일 없음: $filename" "\"claude_file\":\"$claude_file\""
        continue
      fi

      local actual; actual=$(wc -l < "$full_path" | tr -d ' ')

      local diff=$(( actual - recorded ))
      local pct_dev=0
      (( recorded > 0 )) && pct_dev=$(( 100 * diff / recorded ))
      local abs_pct; abs_pct=$(_ef335_abs "$pct_dev")

      if (( abs_pct > _CL_EF335_THRESHOLD )); then
        (( stale_count++ )) || true
        (( overall_stale++ )) || true
        local extra
        extra=$(printf '"file":"%s","recorded":%d,"actual":%d,"deviation_pct":%d' \
          "$filename" "$recorded" "$actual" "$pct_dev")
        _ef335_log "WARN" \
          "STALE: $filename — 문서=${recorded}줄, 실제=${actual}줄, 괴리=${pct_dev}%" \
          "$extra"
        echo "$_CL_EF335_PREFIX STALE: $filename (문서=${recorded}줄, 실제=${actual}줄, 괴리=${pct_dev}%)" >&2
      else
        _ef335_log "INFO" "OK: $filename (실제=${actual}줄, 괴리=${pct_dev}%)"
      fi
    done < "$claude_file"

    _ef335_log "INFO" "검사 완료: $claude_file — 총 ${total_count}건 중 스테일 ${stale_count}건"
  done

  if (( overall_stale > 0 )); then
    echo "$_CL_EF335_PREFIX 스테일 항목 ${overall_stale}건 발견 — 갱신 명령: bash ~/projects/jarvis/scripts/update-claude-md-meta.sh" >&2
    return 1
  fi

  return 0
}

# ── 공개 API: 2. before_cite_linecount ──────────────────────────────────────
#
# before_cite_linecount <filename_or_path>
#
# 줄 수를 인용하기 직전에 실측값을 검증한다.
# 실제 파일을 찾을 수 있으면 실측 줄 수를 stdout에 출력하고 반환한다.
# 파일을 찾지 못하면 경고 후 1을 반환한다.
#
# 반환값:
#   0  — 실측값을 stdout에 출력 (인용 가능)
#   1  — 파일 없음 (인용 금지)
#
before_cite_linecount() {
  local target="$1"
  [[ -z "$target" ]] && { echo "$_CL_EF335_PREFIX before_cite_linecount: 파일명 필요" >&2; return 1; }

  local full_path; full_path=$(_ef335_resolve_path "$target" "$HOME")
  if [[ -z "$full_path" ]] || [[ ! -f "$full_path" ]]; then
    _ef335_log "WARN" "before_cite_linecount: 파일 없음 — $target"
    echo "$_CL_EF335_PREFIX 파일을 찾지 못했습니다: $target (인용 금지)" >&2
    return 1
  fi

  local actual; actual=$(wc -l < "$full_path" | tr -d ' ')
  _ef335_log "INFO" "before_cite_linecount: $target = ${actual}줄" \
    "\"resolved\":\"$full_path\",\"actual\":$actual"
  echo "$actual"
  return 0
}

# ── 공개 API: 3. pre_commit_claude_md_check ─────────────────────────────────
#
# pre_commit_claude_md_check
#
# git staged 파일 중 CLAUDE.md가 포함된 경우 줄 수 항목의 신선도를 검사한다.
# 스테일 항목 발견 시 경고를 출력하고 1을 반환한다 (pre-commit 훅에서 exit 1로 사용).
#
pre_commit_claude_md_check() {
  # staged CLAUDE.md 목록 수집
  local staged_claudes
  staged_claudes=$(git diff --cached --name-only 2>/dev/null | grep -i 'CLAUDE\.md$' || true)

  [[ -z "$staged_claudes" ]] && return 0

  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

  local stale_found=0
  while IFS= read -r rel_path; do
    [[ -z "$rel_path" ]] && continue
    local abs_path="${repo_root:+$repo_root/}${rel_path}"
    [[ -f "$abs_path" ]] || continue

    local claude_dir; claude_dir="$(dirname "$abs_path")"
    local stale_count=0

    while IFS= read -r line; do
      echo "$line" | grep -qE '\([0-9,]+\s*줄\)' || continue

      local recorded_raw
      recorded_raw=$(echo "$line" | grep -oE '\([0-9,]+\s*줄\)' | grep -oE '[0-9,]+' | head -1)
      [[ -z "$recorded_raw" ]] && continue
      local recorded; recorded=$(_ef335_strip_commas "$recorded_raw")

      local filename
      filename=$(echo "$line" | grep -oE '[a-zA-Z0-9_./\-]+\.(tsx?|js|mjs|sh|py|md|ts)' | head -1)
      [[ -z "$filename" ]] && continue

      local full_path; full_path=$(_ef335_resolve_path "$filename" "$claude_dir")
      [[ -z "$full_path" ]] || [[ ! -f "$full_path" ]] && continue

      local actual; actual=$(wc -l < "$full_path" | tr -d ' ')
      local diff=$(( actual - recorded ))
      local pct_dev=0
      (( recorded > 0 )) && pct_dev=$(( 100 * diff / recorded ))
      local abs_pct; abs_pct=$(_ef335_abs "$pct_dev")

      if (( abs_pct > _CL_EF335_THRESHOLD )); then
        (( stale_count++ )) || true
        echo "$_CL_EF335_PREFIX STALE: ${rel_path} 내 ${filename} — 문서=${recorded}줄, 실제=${actual}줄, 괴리=${pct_dev}%" >&2
      fi
    done < "$abs_path"

    if (( stale_count > 0 )); then
      (( stale_found += stale_count )) || true
    fi
  done <<< "$staged_claudes"

  if (( stale_found > 0 )); then
    echo "" >&2
    echo "$_CL_EF335_PREFIX 커밋 경고: CLAUDE.md에 스테일 줄 수 항목 ${stale_found}건 발견" >&2
    echo "   갱신 명령: bash ~/projects/jarvis/scripts/update-claude-md-meta.sh" >&2
    echo "   커밋 강행: CLAUDE_MD_STALE_OK=1 git commit ..." >&2
    echo "" >&2
    # CLAUDE_MD_STALE_OK=1 이면 경고만 하고 통과
    if [[ "${CLAUDE_MD_STALE_OK:-0}" == "1" ]]; then
      _ef335_log "WARN" "pre_commit: 스테일 ${stale_found}건 발견 (CLAUDE_MD_STALE_OK=1 우회)"
      return 0
    fi
    _ef335_log "WARN" "pre_commit: 스테일 ${stale_found}건 발견 — 커밋 차단"
    return 1
  fi

  return 0
}

# ── 공개 API: 4. guard_cl_ef335_status ──────────────────────────────────────
#
# guard_cl_ef335_status
#
# 가드 상태 요약 및 최근 로그 10건 출력
#
guard_cl_ef335_status() {
  echo "═══ cluster-guard $_CL_EF335_ID 상태 ═══"
  echo "로그: $_CL_EF335_LOG"
  echo ""
  if [[ -f "$_CL_EF335_LOG" ]]; then
    echo "최근 이벤트:"
    tail -10 "$_CL_EF335_LOG" | \
      python3 -c '
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line.strip())
        print(f"  [{e.get(\"ts\",\"?\")}] {e.get(\"level\",\"?\")} — {e.get(\"msg\",\"?\")}")
    except:
        print(f"  {line.rstrip()}")
' 2>/dev/null || tail -10 "$_CL_EF335_LOG"
  else
    echo "  (로그 없음)"
  fi
  echo ""

  echo "감시 대상 CLAUDE.md:"
  for f in "${_CL_EF335_DEFAULT_CLAUDE_FILES[@]}"; do
    if [[ -f "$f" ]]; then
      local cnt
      cnt=$(grep -c '줄)' "$f" 2>/dev/null; true)
      echo "  ✓ $f ($cnt 개 항목)"
    else
      echo "  ✗ $f (없음)"
    fi
  done
  echo ""

  echo "크론 등록:"
  crontab -l 2>/dev/null | grep -i "update-claude-md\|claude.*meta" | sed 's/^/  /' || echo "  (없음)"
}

# ── 자동 등록: pre-commit 훅 통합 확인 ──────────────────────────────────────
# source 시 훅 통합 여부를 한 번만 안내 (실제 수정은 하지 않음)
_ef335_hook_hint() {
  local hook_file="${HOME}/projects/jarvis/.githooks/pre-commit"
  if [[ -f "$hook_file" ]] && ! grep -q "ef335e743892c676" "$hook_file" 2>/dev/null; then
    echo "$_CL_EF335_PREFIX INFO: pre-commit 훅에 아직 통합되지 않았습니다." >&2
    echo "  통합 방법: ~/projects/jarvis/infra/lib/cluster-guard-cl-ef335e743892c676.sh 의 pre_commit_claude_md_check 참고" >&2
  fi
}

_ef335_hook_hint
