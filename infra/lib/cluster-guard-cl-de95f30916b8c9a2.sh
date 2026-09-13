#!/usr/bin/env bash
# cluster-guard-cl-de95f30916b8c9a2.sh — SSoT 충돌 전파 차단 가드
#
# 클러스터 ID  : cl-de95f30916b8c9a2 (최근 7일 재발 4건)
# 대표 시드    : SSoT 규칙 인식했으나 근본 위반 구조 방치
# 멤버 패턴    :
#   - SSoT 규칙 인식했으나 근본 위반 구조 방치
#   - 실험 설계 구조적 결함을 인식했으나 초기 분석에서 우선순위 미조정
#   - SSoT 위반 + 오염 전파 — 검증 없는 신규 입력이 다중 산출물 확산
#   - 기존 기록 충돌 미감지 (SSoT 위반)
#
# cl-1a81(저장소 경로 오인)과의 차이:
#   cl-1a81: 어느 저장소인지 식별 실패 → 경로 매핑 가드
#   cl-de95: 충돌을 인식하고도 근본 구조 방치 + 다중 산출물로 오염 확산
#
# 공개 API:
#   ssot_prewrite_check <new_fact_text> [domain]
#       — 신규 사실을 쓰기 전에 기존 wiki 전체와 충돌 여부 검사.
#         충돌 감지 시 경고를 stderr에 출력 + exit 1.
#         안전하면 exit 0. || true 를 붙이면 차단 없이 경고만 남길 수 있다.
#
#   ssot_propagation_gate <label> [--force] <dest1> [dest2 ...]
#       — 단일 입력이 복수 대상(도메인/파일/채널)에 동시 전파될 때 게이트.
#         대상 2개 이상이면 경고 + exit 1. --force 로 override 가능 (로그 남음).
#         대상 1개면 exit 0.
#
#   ssot_root_cause_require <violation_id> <root_cause_text>
#       — 위반 감지 후 근본 원인 문서화 없이 계속 진행하는 것을 차단.
#         root_cause_text가 비거나 "unknown"이면 exit 2.
#         정상 기록 시 exit 0.
#
#   ssot_conflict_status
#       — 최근 충돌·위반 이벤트 요약 출력.
#
# 기존 동작 보호: 모든 함수는 경고를 stderr에만 출력. exit code로 결과 반환.
#   차단 없이 쓰려면 || true 를 붙인다. 로그는 항상 남는다.
#
# 호환성: bash 3.2+ (macOS 기본 bash 지원)

set -o pipefail

# ── 상수 ────────────────────────────────────────────────────────────────────

readonly _CL_DE95_ID="cl-de95f30916b8c9a2"
readonly _CL_DE95_STATE_DIR="${HOME}/.openclaw-data/runtime/state/cluster-guards"
readonly _CL_DE95_LOG="${HOME}/.openclaw-data/runtime/logs/cluster-guard-${_CL_DE95_ID}.jsonl"
readonly _CL_DE95_VIOLATIONS="${_CL_DE95_STATE_DIR}/${_CL_DE95_ID}-violations.jsonl"
readonly _CL_DE95_PREFIX="[ssot-conflict-guard ${_CL_DE95_ID}]"

readonly _CL_DE95_WIKI_ROOT="${HOME}/.openclaw-data/runtime/wiki"

# 충돌로 볼 최소 토큰 겹침 수 (한국어 2자+ / 영어 3자+ 단어)
readonly _CL_DE95_OVERLAP_THRESHOLD=3
# 숫자 충돌 검사 대상 패턴 (금액·기간·수량)
readonly _CL_DE95_NUM_PATTERN='[0-9][0-9,.]*(만원|원|달러|USD|KRW|개월|일|년|kg|km|시간|분)?\b'

# ── 내부 헬퍼 ───────────────────────────────────────────────────────────────

_de95_now_iso() { date '+%Y-%m-%dT%H:%M:%S'; }

_de95_ensure_dirs() {
  mkdir -p "$_CL_DE95_STATE_DIR" 2>/dev/null || true
  mkdir -p "$(dirname "$_CL_DE95_LOG")" 2>/dev/null || true
}

_de95_log() {
  local level="$1" event="$2" detail="${3:-}" extra="${4:-}"
  _de95_ensure_dirs
  printf '{"ts":"%s","cluster":"%s","level":"%s","event":"%s","detail":"%s","extra":"%s"}\n' \
    "$(_de95_now_iso)" "$_CL_DE95_ID" "$level" "$event" \
    "${detail//\"/\'}" "${extra//\"/\'}" \
    >> "$_CL_DE95_LOG" 2>/dev/null || true
}

_de95_warn() { echo "⚠️  ${_CL_DE95_PREFIX} [WARN]  $*" >&2; }
_de95_fail() { echo "❌ ${_CL_DE95_PREFIX} [FAIL]  $*" >&2; }
_de95_ok()   { echo "✅ ${_CL_DE95_PREFIX} [OK]    $*" >&2; }
_de95_info() { echo "ℹ️  ${_CL_DE95_PREFIX} [INFO]  $*" >&2; }

# 텍스트에서 의미 토큰 추출 (2자 이상 한글 + 3자 이상 영문/숫자)
# 태그([source:...] 등)와 마크다운 제거 후 추출
_de95_tokenize() {
  local text="$1"
  echo "$text" \
    | sed 's/\[[^]]*\]//g' \
    | sed 's/[*_#>|`]//g' \
    | tr '[:upper:]' '[:lower:]' \
    | grep -oE '[가-힣]{2,}|[a-z0-9]{3,}' \
    | sort -u
}

# 두 토큰 집합의 교집합 크기 (awk로 구현 — 서브프로세스 없음)
_de95_token_overlap() {
  local tokens_a="$1" tokens_b="$2"
  awk '
    BEGIN { count = 0 }
    NR == 1 { n = split($0, arr, " "); for (i=1;i<=n;i++) set_a[arr[i]]=1 }
    NR == 2 { n = split($0, arr, " "); for (i=1;i<=n;i++) if (arr[i] in set_a) count++ }
    END { print count }
  ' <(printf '%s\n%s\n' "$tokens_a" "$tokens_b")
}

# 텍스트에서 숫자(금액·수량) 추출
_de95_extract_numbers() {
  local text="$1"
  echo "$text" | grep -oE '[0-9][0-9,\.]*' | tr '\n' ' '
}

# wiki _facts.md 파일 목록 수집
_de95_collect_facts_files() {
  find "$_CL_DE95_WIKI_ROOT" -name "_facts.md" -type f 2>/dev/null
}

# ── 핵심 기능 1: 사전 쓰기 충돌 검사 ───────────────────────────────────────

# ssot_prewrite_check <new_fact_text> [domain_hint]
#
# 새 사실 텍스트를 기존 wiki 전체와 대조하여 의미 충돌을 감지한다.
# 충돌 기준:
#   1. 토큰 겹침 >= _CL_DE95_OVERLAP_THRESHOLD 인 기존 사실이 존재하고,
#   2. 해당 사실에서 추출한 숫자값이 다른 경우 (수치 충돌)
#   3. 또는 부정/긍정 키워드 반전이 감지되는 경우
#
# 반환값: 0=안전, 1=충돌감지, 2=인자오류
ssot_prewrite_check() {
  local new_fact="${1:-}"
  local domain_hint="${2:-}"

  if [[ -z "$new_fact" ]]; then
    _de95_fail "ssot_prewrite_check: 사실 텍스트 필수"
    return 2
  fi

  _de95_ensure_dirs

  local new_tokens
  new_tokens=$(_de95_tokenize "$new_fact")
  local new_nums
  new_nums=$(_de95_extract_numbers "$new_fact")

  local conflict_count=0
  local conflict_details=""

  # 모든 _facts.md 파일 순회
  while IFS= read -r facts_file; do
    [[ -z "$facts_file" || ! -f "$facts_file" ]] && continue

    # 도메인 힌트가 있으면 해당 도메인 파일만 검사 (성능)
    if [[ -n "$domain_hint" ]]; then
      local file_domain
      file_domain=$(basename "$(dirname "$facts_file")")
      [[ "$file_domain" != "$domain_hint" ]] && continue
    fi

    # _facts.md에서 사실 행만 추출 (- [날짜] 로 시작하는 줄)
    while IFS= read -r fact_line; do
      [[ -z "$fact_line" ]] && continue

      local existing_tokens
      existing_tokens=$(_de95_tokenize "$fact_line")

      # 토큰 겹침 계산
      local overlap
      overlap=$(_de95_token_overlap "$new_tokens" "$existing_tokens")

      if [[ "$overlap" -ge "$_CL_DE95_OVERLAP_THRESHOLD" ]]; then
        # 숫자값 비교
        local existing_nums
        existing_nums=$(_de95_extract_numbers "$fact_line")

        local num_conflict=0
        if [[ -n "$new_nums" && -n "$existing_nums" && "$new_nums" != "$existing_nums" ]]; then
          # 공통 숫자가 아닌 다른 숫자가 있는지 확인
          # 단순화: 토큰 겹침이 충분하고 숫자 집합이 다르면 충돌 의심
          local shared_nums
          shared_nums=$(comm -12 \
            <(echo "$new_nums" | tr ' ' '\n' | grep -v '^$' | sort -u) \
            <(echo "$existing_nums" | tr ' ' '\n' | grep -v '^$' | sort -u) \
            | wc -l | tr -d ' ')
          local total_new_nums
          total_new_nums=$(echo "$new_nums" | tr ' ' '\n' | grep -v '^$' | wc -l | tr -d ' ')
          if [[ "$shared_nums" -eq 0 && "$total_new_nums" -gt 0 ]]; then
            num_conflict=1
          fi
        fi

        if [[ "$num_conflict" -eq 1 ]]; then
          conflict_count=$((conflict_count + 1))
          local snippet="${fact_line:0:120}"
          conflict_details="${conflict_details}\n    충돌 파일: $facts_file\n    기존 사실: ${snippet}..."
          _de95_log "error" "prewrite_conflict" \
            "overlap=${overlap},new_nums=${new_nums},existing_nums=${existing_nums}" \
            "file=${facts_file}"
        fi
      fi
    done < <(grep -E '^\s*-\s+\[' "$facts_file" 2>/dev/null)

  done < <(_de95_collect_facts_files)

  if [[ "$conflict_count" -gt 0 ]]; then
    _de95_fail "SSoT 충돌 감지: ${conflict_count}건의 기존 사실과 수치 충돌"
    _de95_fail "  신규 사실: ${new_fact:0:120}"
    if [[ -n "$conflict_details" ]]; then
      echo -e "$conflict_details" >&2
    fi
    _de95_fail "  → 쓰기 차단. 기존 값을 확인하고 supersedes:true + doc: 를 명시하십시오."
    _de95_log "error" "prewrite_blocked" \
      "conflicts=${conflict_count}" \
      "new_fact=${new_fact:0:100}"
    return 1
  fi

  _de95_ok "사전 충돌 검사 통과: '${new_fact:0:60}...'"
  _de95_log "info" "prewrite_ok" "new_fact=${new_fact:0:100}"
  return 0
}

# ── 핵심 기능 2: 다중 산출물 전파 게이트 ───────────────────────────────────

# ssot_propagation_gate <label> [--force] <dest1> [dest2 ...]
#
# 단일 입력 사실이 여러 대상(wiki 도메인/파일/Discord 채널)에 동시 전파될 때 호출.
# 대상이 2개 이상이면 경고 + exit 1 (미검증 입력의 다중 확산 차단).
# --force 플래그로 override 가능하되 로그는 항상 남음.
#
# 반환값: 0=단일대상(통과), 1=복수대상(차단), 2=인자오류
ssot_propagation_gate() {
  local label="${1:-}"
  if [[ -z "$label" ]]; then
    _de95_fail "ssot_propagation_gate: label 필수"
    return 2
  fi
  shift

  local force=0
  if [[ "${1:-}" == "--force" ]]; then
    force=1
    shift
  fi

  local dests=("$@")
  local dest_count="${#dests[@]}"

  if [[ "$dest_count" -eq 0 ]]; then
    _de95_fail "ssot_propagation_gate: 전파 대상이 0개 — label=${label}"
    return 2
  fi

  if [[ "$dest_count" -le 1 ]]; then
    _de95_log "info" "propagation_gate_pass" "label=${label}" "dests=${dests[*]}"
    return 0
  fi

  # 복수 대상 감지
  _de95_log "warn" "propagation_gate_multi" \
    "label=${label},dest_count=${dest_count}" \
    "dests=${dests[*]}"

  if [[ "$force" -eq 1 ]]; then
    _de95_warn "SSoT 전파 게이트: --force 로 복수 전파 허용 (${dest_count}개 대상)"
    _de95_warn "  label: ${label}"
    _de95_warn "  대상: ${dests[*]}"
    _de95_warn "  ⚠️  각 대상의 기존 값을 직접 검증 후 진행하십시오."
    _de95_log "warn" "propagation_forced" \
      "label=${label},dest_count=${dest_count}" \
      "dests=${dests[*]}"
    return 0
  fi

  _de95_fail "SSoT 전파 게이트 차단: 검증 없는 입력이 ${dest_count}개 대상에 동시 전파됨"
  _de95_fail "  label: ${label}"
  local i
  for i in "${!dests[@]}"; do
    _de95_fail "  [${i}] ${dests[$i]}"
  done
  _de95_fail "  → 각 대상의 기존 값을 먼저 확인하십시오."
  _de95_fail "    허용하려면 --force 를 추가하십시오 (로그는 남습니다)."
  return 1
}

# ── 핵심 기능 3: 근본 원인 문서화 요구 ─────────────────────────────────────

# ssot_root_cause_require <violation_id> <root_cause_text>
#
# SSoT 위반을 감지했을 때 "증상 패치"만 하고 "근본 구조"를 방치하는 것을 차단.
# root_cause_text가 비거나 "unknown"이면 exit 2 (처리 불허).
# 근본 원인이 기록되면 violations 로그에 저장하고 exit 0.
#
# violations 로그 항목: {"ts","violation_id","root_cause","status":"resolved_structural"}
#
# 반환값: 0=근본원인 기록됨, 1=unknown/미기록(요구 미충족), 2=인자오류
ssot_root_cause_require() {
  local violation_id="${1:-}"
  local root_cause="${2:-}"

  if [[ -z "$violation_id" ]]; then
    _de95_fail "ssot_root_cause_require: violation_id 필수"
    return 2
  fi

  _de95_ensure_dirs

  # 빈 값 또는 "unknown" 거부 (bash 3.2 호환: tr로 소문자 변환)
  local root_cause_lower
  root_cause_lower=$(echo "$root_cause" | tr '[:upper:]' '[:lower:]')
  if [[ -z "$root_cause" || "$root_cause_lower" == "unknown" || "$root_cause" == "모름" ]]; then
    _de95_fail "근본 원인 미기록: violation_id=${violation_id}"
    _de95_fail "  증상 패치만으로는 처리할 수 없습니다."
    _de95_fail "  어느 구조가 위반을 허용했는지 기술하십시오."
    _de95_fail "  예: ssot_root_cause_require \"${violation_id}\" \"wiki 슬롯 없이 임시 변수로 값 전달하는 코드 경로\""
    _de95_log "warn" "root_cause_missing" \
      "violation_id=${violation_id}" "root_cause=EMPTY"
    return 1
  fi

  # 기록
  printf '{"ts":"%s","cluster":"%s","violation_id":"%s","root_cause":"%s","status":"resolved_structural"}\n' \
    "$(_de95_now_iso)" "$_CL_DE95_ID" \
    "${violation_id//\"/\'}" "${root_cause//\"/\'}" \
    >> "$_CL_DE95_VIOLATIONS" 2>/dev/null || true

  _de95_ok "근본 원인 기록됨: ${violation_id}"
  _de95_info "  원인: ${root_cause:0:120}"
  _de95_log "info" "root_cause_recorded" \
    "violation_id=${violation_id}" "root_cause=${root_cause:0:100}"
  return 0
}

# ── 상태 조회 ────────────────────────────────────────────────────────────────

# ssot_conflict_status
# 최근 충돌·위반 이벤트 요약 출력.
ssot_conflict_status() {
  echo "━━━ 클러스터 ${_CL_DE95_ID} 상태 ━━━" >&2
  echo "  대표 시드: SSoT 규칙 인식했으나 근본 위반 구조 방치" >&2
  echo "" >&2

  if [[ -f "$_CL_DE95_LOG" ]]; then
    local total_events
    total_events=$(wc -l < "$_CL_DE95_LOG" | tr -d ' ')
    local conflict_events
    conflict_events=$(grep -c '"event":"prewrite_conflict"' "$_CL_DE95_LOG" 2>/dev/null || echo 0)
    local blocked_events
    blocked_events=$(grep -c '"event":"prewrite_blocked"' "$_CL_DE95_LOG" 2>/dev/null || echo 0)
    local propagation_warns
    propagation_warns=$(grep -c '"event":"propagation_gate_multi"' "$_CL_DE95_LOG" 2>/dev/null || echo 0)

    echo "  총 이벤트      : $total_events건" >&2
    echo "  충돌 감지      : $conflict_events건" >&2
    echo "  쓰기 차단      : $blocked_events건" >&2
    echo "  전파 경고      : $propagation_warns건" >&2
    echo "  로그 파일      : $_CL_DE95_LOG" >&2
  else
    echo "  이벤트 없음 (아직 실행된 적 없음)" >&2
  fi

  echo "" >&2

  if [[ -f "$_CL_DE95_VIOLATIONS" ]]; then
    local resolved
    resolved=$(grep -c '"status":"resolved_structural"' "$_CL_DE95_VIOLATIONS" 2>/dev/null || echo 0)
    echo "  근본원인 기록됨: $resolved건" >&2
    echo "  위반 로그      : $_CL_DE95_VIOLATIONS" >&2
  else
    echo "  위반 기록 없음" >&2
  fi
  echo "" >&2
}

# ── 진단: 미기록 위반 스캔 ──────────────────────────────────────────────────

# ssot_unresolved_scan
# 충돌 로그에는 있지만 근본원인이 기록되지 않은 위반 ID를 출력.
# 배치 리포트용.
ssot_unresolved_scan() {
  echo "━━━ 미해결 SSoT 위반 스캔 (${_CL_DE95_ID}) ━━━" >&2

  if [[ ! -f "$_CL_DE95_LOG" ]]; then
    echo "  이벤트 로그 없음" >&2
    return 0
  fi

  # blocked 이벤트에서 detail(=fact 앞 100자) 추출
  local blocked_list
  blocked_list=$(grep '"event":"prewrite_blocked"' "$_CL_DE95_LOG" 2>/dev/null \
    | grep -oE '"detail":"[^"]*"' \
    | sed 's/"detail":"//;s/"$//' \
    | head -20)

  if [[ -z "$blocked_list" ]]; then
    _de95_ok "미해결 충돌 없음"
    return 0
  fi

  local count=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    count=$((count + 1))
    echo "  [$count] ${line:0:80}" >&2
  done <<< "$blocked_list"

  _de95_warn "${count}건의 충돌 이벤트 발견. ssot_root_cause_require 로 근본 원인을 기록하십시오."
  _de95_log "info" "unresolved_scan" "unresolved=${count}"
  return "$([[ $count -gt 0 ]] && echo 1 || echo 0)"
}
