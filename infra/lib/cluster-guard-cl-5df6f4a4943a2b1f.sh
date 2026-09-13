#!/usr/bin/env bash
# cluster-guard-cl-5df6f4a4943a2b1f.sh — MCP 서버 경로 실측 검증 가드
#
# 클러스터 ID  : cl-5df6f4a4943a2b1f (최근 7일 재발 8건)
# 대표 시드    : Serena 미사용 원인을 규칙 문서 표 가독성 탓으로 단정 (실측 없음)
# 멤버 패턴    :
#   - MCP Serena 경로 오류 (SSoT 양방향 불일치)
#   - 규칙과 실제 파일 위치 미검증 후 Serena 미사용 원인 단정
#   - MCP 규칙 해석 미실측 — Serena 사용률 저조 원인 단언
#
# 공개 API:
#   mcp_validate_paths [config_file...]
#       — 지정(또는 기본) .mcp.json 파일들의 경로 항목을 실측 검증.
#         누락 경로 발견 시 non-zero 반환 + 경고 출력.
#
#   mcp_cross_validate
#       — 모든 known .mcp.json에서 동일 서버 이름이 다른 경로를 가리키는지 교차 검증.
#
#   mcp_guard_status
#       — 마지막 검증 결과 요약 출력.
#
# 사용:
#   source ~/projects/jarvis/infra/lib/cluster-guard-cl-5df6f4a4943a2b1f.sh
#   mcp_validate_paths                       # 기본 검색
#   mcp_validate_paths ~/.mcp.json ~/projects/jarvis/.mcp.json
#   mcp_cross_validate
#
# 기존 동작 보호: 모든 함수는 경고를 stderr에 출력. exit code로 결과 반환.
#   차단 없이 쓰려면 || true 를 붙인다.

set -o pipefail

# ── 상수 ────────────────────────────────────────────────────────────────────

readonly _CL_5DF6_ID="cl-5df6f4a4943a2b1f"
readonly _CL_5DF6_STATE_DIR="${HOME}/.openclaw-data/runtime/state/cluster-guards"
readonly _CL_5DF6_LOG="${HOME}/.openclaw-data/runtime/logs/cluster-guard-${_CL_5DF6_ID}.jsonl"
readonly _CL_5DF6_REPORT="${_CL_5DF6_STATE_DIR}/${_CL_5DF6_ID}-last-report.json"
readonly _CL_5DF6_PREFIX="[mcp-path-guard ${_CL_5DF6_ID}]"

# 검색할 기본 .mcp.json 위치 목록
readonly -a _CL_5DF6_DEFAULT_CONFIGS=(
  "${HOME}/.mcp.json"
  "${HOME}/projects/jarvis/.mcp.json"
  "${HOME}/jarvis-board/.mcp.json"
  "${HOME}/projects/jarvis-company-board/.mcp.json"
)

# ── 내부 헬퍼 ───────────────────────────────────────────────────────────────

_5df6_now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

_5df6_ensure_dirs() {
  mkdir -p "$_CL_5DF6_STATE_DIR" 2>/dev/null || true
  mkdir -p "$(dirname "$_CL_5DF6_LOG")" 2>/dev/null || true
}

_5df6_log() {
  local level="$1" event="$2" detail="${3:-}" extra="${4:-}"
  _5df6_ensure_dirs
  printf '{"ts":"%s","cluster":"%s","level":"%s","event":"%s","detail":"%s","extra":"%s"}\n' \
    "$(_5df6_now_iso)" "$_CL_5DF6_ID" "$level" "$event" \
    "${detail//\"/\'}" "${extra//\"/\'}" \
    >> "$_CL_5DF6_LOG" 2>/dev/null || true
}

_5df6_warn() { echo "⚠️  ${_CL_5DF6_PREFIX} [WARN]  $*" >&2; }
_5df6_fail() { echo "❌ ${_CL_5DF6_PREFIX} [FAIL]  $*" >&2; }
_5df6_ok()   { echo "✅ ${_CL_5DF6_PREFIX} [OK]    $*" >&2; }
_5df6_info() { echo "ℹ️  ${_CL_5DF6_PREFIX} [INFO]  $*" >&2; }

# .mcp.json에서 검증 대상 절대경로 추출 (jq 사용)
# 대상: args 배열 내 /로 시작하는 항목, command 값이 절대경로인 경우
_5df6_extract_paths() {
  local config_file="$1"
  jq -r '
    .mcpServers // {} | to_entries[] |
    .key as $srv |
    (
      ([.value.args // [] | .[] | select(type=="string" and startswith("/"))] +
      [.value.command // "" | select(startswith("/"))])
      | unique | .[]
    ) |
    "\($srv)\t\(.)"
  ' "$config_file" 2>/dev/null || true
}

# ── 공개 API: 1. mcp_validate_paths ─────────────────────────────────────────
#
# 인자: [config_file...]  — 생략 시 기본 목록 사용
# 반환: 0 = 모두 존재, 1 = 1건 이상 누락
#
mcp_validate_paths() {
  local configs=("$@")
  if [[ ${#configs[@]} -eq 0 ]]; then
    configs=("${_CL_5DF6_DEFAULT_CONFIGS[@]}")
  fi

  local total=0 missing=0 missing_list=()

  for cfg in "${configs[@]}"; do
    if [[ ! -f "$cfg" ]]; then
      _5df6_info "설정 파일 없음 (skip): $cfg"
      continue
    fi

    _5df6_info "검증 중: $cfg"
    local line srv path_val

    while IFS=$'\t' read -r srv path_val; do
      [[ -z "$srv" || -z "$path_val" ]] && continue
      (( total++ )) || true

      if [[ ! -e "$path_val" ]]; then
        (( missing++ )) || true
        missing_list+=("${cfg}::${srv}::${path_val}")
        _5df6_fail "경로 누락: [${srv}] ${path_val}  (in ${cfg})"
        _5df6_log "FAIL" "path_missing" "${srv}" "${path_val} | cfg=${cfg}"
      else
        _5df6_ok "경로 확인: [${srv}] ${path_val}"
        _5df6_log "OK" "path_exists" "${srv}" "${path_val} | cfg=${cfg}"
      fi
    done < <(_5df6_extract_paths "$cfg")
  done

  # 결과 보고서 저장
  _5df6_ensure_dirs
  cat > "$_CL_5DF6_REPORT" <<EOF
{
  "ts": "$(_5df6_now_iso)",
  "cluster_id": "${_CL_5DF6_ID}",
  "total_checked": ${total},
  "missing": ${missing},
  "missing_entries": $(printf '%s\n' "${missing_list[@]:-}" | jq -Rn '[inputs | select(length>0)]' 2>/dev/null || echo "[]")
}
EOF

  if [[ $missing -gt 0 ]]; then
    _5df6_warn "${missing}/${total} 경로 누락 — Serena 등 MCP 서버 경로 불일치 가능"
    return 1
  else
    _5df6_ok "전체 ${total}개 경로 정상 확인"
    return 0
  fi
}

# ── 공개 API: 2. mcp_cross_validate ─────────────────────────────────────────
#
# 동일 서버 이름이 여러 .mcp.json에서 다른 경로를 가리키는지 교차 검증
# 반환: 0 = 불일치 없음, 1 = 불일치 감지
#
mcp_cross_validate() {
  local configs=("${_CL_5DF6_DEFAULT_CONFIGS[@]}")
  # bash 3.2 호환: 연관 배열 대신 임시 파일로 누적
  local tmp_pairs
  tmp_pairs=$(mktemp /tmp/_5df6_cross.XXXXXX)
  local conflicts=0

  for cfg in "${configs[@]}"; do
    [[ -f "$cfg" ]] || continue
    local srv path_val
    while IFS=$'\t' read -r srv path_val; do
      [[ -z "$srv" || -z "$path_val" ]] && continue
      # "서버명\t설정파일\t경로" 형식으로 누적
      printf '%s\t%s\t%s\n' "$srv" "$cfg" "$path_val" >> "$tmp_pairs"
    done < <(_5df6_extract_paths "$cfg")
  done

  # awk: 동일 서버명에서 경로가 2종 이상이고, 서로 다른 설정 파일에서 왔으며,
  #      그 중 하나 이상이 글로벌 설정($HOME/.mcp.json)일 때만 충돌로 판정.
  #      이유:
  #        ① 같은 파일 내 다중 경로(filesystem 서버의 multi-arg) → 정상, 스킵
  #        ② 프로젝트별 로컬 설정끼리의 분기(jarvis vs jarvis-board) → 의도적, 스킵
  local home_dir="$HOME"
  local conflict_output
  conflict_output=$(awk -v home="$home_dir" -F'\t' '
    {
      srv=$1; cfg=$2; path=$3

      # config 파일의 디렉토리 (dirname)
      cfg_dir=cfg; sub(/\/[^\/]+$/, "", cfg_dir)
      is_global=(cfg_dir == home) ? 1 : 0

      # srv 등장 순서 추적 (중복 없이)
      srv_key=srv
      if (!(srv_key in seen_srv)) { seen_srv[srv_key]=1; srv_list[++nsrv]=srv }

      # (srv, path) 중복 제거
      key=srv SUBSEP path
      if (!(key in seen_paths)) {
        seen_paths[key]=1

        # (srv, cfg) 단위 카운트: 같은 서버가 몇 개 config에 등장하는지
        srv_cfg_key=srv SUBSEP cfg
        if (!(srv_cfg_key in seen_srv_cfg)) {
          seen_srv_cfg[srv_cfg_key]=1
          cfg_count[srv]++
          if (is_global) global_count[srv]++
        }

        path_count[srv]++
        entries[srv]=entries[srv] "|" cfg ":" path
      }
    }
    END {
      for (i=1; i<=nsrv; i++) {
        s=srv_list[i]
        # 실제 충돌 조건:
        #   경로가 2종 이상 AND 서로 다른 config 파일에서 온 AND 글로벌 config 포함
        if (path_count[s] > 1 && cfg_count[s] > 1 && global_count[s] > 0) {
          sub(/^\|/, "", entries[s])
          print "CONFLICT\t" s "\t" entries[s]
        }
      }
    }
  ' "$tmp_pairs" 2>/dev/null || true)

  rm -f "$tmp_pairs"

  if [[ -n "$conflict_output" ]]; then
    while IFS=$'\t' read -r _ srv entries; do
      (( conflicts++ )) || true
      _5df6_warn "교차 불일치: 서버 '${srv}'가 여러 경로를 가리킴:"
      echo "$entries" | tr '|' '\n' | while IFS=: read -r c p; do
        _5df6_warn "  → ${c} : ${p}"
      done
      _5df6_log "WARN" "cross_mismatch" "${srv}" "${entries}"
    done <<< "$conflict_output"
  fi

  if [[ $conflicts -gt 0 ]]; then
    _5df6_warn "교차 검증 결과: ${conflicts}개 서버에서 경로 불일치"
    return 1
  else
    _5df6_ok "교차 검증 통과: 모든 서버 경로 일관성 확인"
    return 0
  fi
}

# ── 공개 API: 3. mcp_guard_status ───────────────────────────────────────────
#
# 마지막 검증 결과 요약 출력
#
mcp_guard_status() {
  if [[ ! -f "$_CL_5DF6_REPORT" ]]; then
    _5df6_info "아직 검증 실행 기록 없음. mcp_validate_paths 를 먼저 실행하세요."
    return 0
  fi
  local ts total missing
  ts=$(jq -r '.ts' "$_CL_5DF6_REPORT" 2>/dev/null || echo "unknown")
  total=$(jq -r '.total_checked' "$_CL_5DF6_REPORT" 2>/dev/null || echo "?")
  missing=$(jq -r '.missing' "$_CL_5DF6_REPORT" 2>/dev/null || echo "?")
  echo "━━━ MCP Path Guard 상태 (${_CL_5DF6_ID}) ━━━"
  echo "마지막 검증: ${ts}"
  echo "검증 경로 수: ${total}  |  누락: ${missing}"
  if [[ "$missing" != "0" ]]; then
    echo "누락 목록:"
    jq -r '.missing_entries[]' "$_CL_5DF6_REPORT" 2>/dev/null | sed 's/^/  - /'
  fi
}
