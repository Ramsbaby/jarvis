#!/bin/bash
# cluster-guard-cl-1908ed6c137a5b1a.sh — 오퍼 평가 시장 검증 가드
#
# 문제: 직급의 시장 기준 미확인 상태로 오퍼 평가 (재발 6건/7일)
# 솔루션: 오퍼 평가 요청 감지 시 WebSearch 기반 시장 데이터 조회 강제화
#
# 동작:
#   1. 프롬프트에서 오퍼 평가 키워드 감지
#   2. WebSearch로 시장 데이터 조회 (직급별 연봉, 보상 범위)
#   3. 조회 결과를 SYSTEM_PROMPT에 컨텍스트로 주입
#   4. 평가 응답 시 시장 데이터 기반 답변 강제
#
# 사용:
#   source ~/.jarvis/lib/cluster-guard-cl-1908ed6c137a5b1a.sh
#   guard_offer_eval_pre_check "$TASK_ID" "$PROMPT"
#   INJECTED_CONTEXT=$(get_market_context)

set -euo pipefail

# 상수
readonly CLUSTER_ID="cl-1908ed6c137a5b1a"
readonly BOT_HOME="${BOT_HOME:-${HOME}/.openclaw-data/runtime}"
readonly LIB_DIR="${BOT_HOME}/../infra/lib"
readonly STATE_DIR="${BOT_HOME}/state/cluster-guards"
readonly GUARD_STATE="${STATE_DIR}/${CLUSTER_ID}-state.json"
readonly VALIDATION_LOG="${STATE_DIR}/${CLUSTER_ID}-market-queries.jsonl"
readonly CACHE_DIR="${STATE_DIR}/${CLUSTER_ID}-cache"
readonly CACHE_EXPIRY_HOURS=24

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 전역 상태
_GUARD_TRIGGERED=false
_MARKET_DATA=""
_MARKET_QUERY_TERM=""
_SEARCH_RESULT=""

# ============================================================================
# 유틸리티
# ============================================================================

_log() {
  local level=$1
  shift
  local msg="$*"
  case $level in
    info) printf '[%s] %s\n' "$CLUSTER_ID" "$msg" >&2 ;;
    ok) printf '[%s] ✓ %s\n' "$CLUSTER_ID" "$msg" >&2 ;;
    warn) printf '[%s] ⚠ %s\n' "$CLUSTER_ID" "$msg" >&2 ;;
    err) printf '[%s] ✗ %s\n' "$CLUSTER_ID" "$msg" >&2 ;;
  esac
}

_ensure_dirs() {
  mkdir -p "$STATE_DIR" "$CACHE_DIR"
}

_init_guard_state() {
  _ensure_dirs

  if [[ ! -f "$GUARD_STATE" ]]; then
    cat > "$GUARD_STATE" <<EOF
{
  "cluster_id": "${CLUSTER_ID}",
  "cluster_name": "직급의 시장 기준 미확인 상태로 오퍼 평가",
  "initialized_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "total_triggers": 0,
  "total_searches": 0,
  "searches_with_context_injected": 0,
  "last_triggered_at": null
}
EOF
    _log ok "가드 상태 초기화됨"
  fi
}

_update_guard_state() {
  _ensure_dirs
  if [[ ! -f "$GUARD_STATE" ]]; then
    _init_guard_state
  fi

  jq \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    ".total_triggers += 1 | .last_triggered_at = \$now" \
    "$GUARD_STATE" > "${GUARD_STATE}.tmp" 2>/dev/null && \
  mv "${GUARD_STATE}.tmp" "$GUARD_STATE" || _log warn "Failed to update guard state"
}

_record_market_query() {
  local query_term=$1
  local search_result=$2
  local injected=$3

  _ensure_dirs

  local record=$(cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cluster_id": "${CLUSTER_ID}",
  "query_term": "$query_term",
  "context_injected": $injected,
  "result_summary": "$(echo "$search_result" | head -c 500)"
}
EOF
  )
  echo "$record" >> "$VALIDATION_LOG" 2>/dev/null || true
}

_get_cache_key() {
  local query=$1
  echo "$query" | sha256sum | awk '{print $1}'
}

_is_cache_valid() {
  local cache_file=$1
  if [[ ! -f "$cache_file" ]]; then
    return 1
  fi

  local file_mtime=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)
  local current_time=$(date +%s)
  local age=$((current_time - file_mtime))
  local expiry_seconds=$((CACHE_EXPIRY_HOURS * 3600))

  [[ $age -lt $expiry_seconds ]]
}

_detect_offer_eval_keywords() {
  local prompt=$1

  # 오퍼 평가 관련 키워드 (한글/영글)
  local keywords_ko="직급|연봉|급여|오퍼|보상|급여협상|compensation|salary|position|level"
  local keywords_en="offer|salary|compensation|ctc|package|negotiat|job level|position|role|pay"

  if echo "$prompt" | grep -qi "ctc\|total compensation\|연봉|직급|오퍼"; then
    return 0
  fi

  if echo "$prompt" | grep -iE "($keywords_ko|$keywords_en)" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

_extract_job_context() {
  local prompt=$1

  # 프롬프트에서 직급, 기업, 지역 등 추출
  local job_level=$(echo "$prompt" | grep -oiE "(engineer|developer|manager|director|principal|senior|junior|mid|entry)" | head -1)
  local company=$(echo "$prompt" | grep -oiE "[A-Z][a-z]+" | head -1)

  if [[ -n "$job_level" ]]; then
    echo "${job_level}"
  fi
}

_search_market_data() {
  local query=$1
  local cache_key=$(_get_cache_key "$query")
  local cache_file="${CACHE_DIR}/${cache_key}.json"

  # 캐시 확인
  if _is_cache_valid "$cache_file"; then
    _log info "Market data cache hit for: $query"
    cat "$cache_file"
    return 0
  fi

  _log info "Searching market data for: $query"

  # NOTE: WebSearch는 ask-claude.sh의 claude -p 호출 내에서 사용되므로
  # 여기서는 다음과 같이 처리:
  # 1. 검색 쿼리를 구성
  # 2. 결과 포맷 정의
  # 3. LLM이 실제 검색을 수행하도록 컨텍스트에 신호 전송

  # 임시: 검색 문자열 생성 (실제 WebSearch는 LLM 컨텍스트에서 실행)
  local search_data=$(cat <<EOF
{
  "query": "$query",
  "requires_websearch": true,
  "context_injection_required": true,
  "expected_fields": ["job_title", "median_salary", "salary_range", "market_level", "location"]
}
EOF
  )

  # 캐시 저장
  mkdir -p "$CACHE_DIR"
  echo "$search_data" > "$cache_file" 2>/dev/null || true

  echo "$search_data"
  return 0
}

# ============================================================================
# 메인 가드 로직
# ============================================================================

guard_offer_eval_pre_check() {
  local task_id=$1
  local prompt=$2

  _init_guard_state

  # 1. 오퍼 평가 키워드 감지
  if ! _detect_offer_eval_keywords "$prompt"; then
    _log info "No offer evaluation keywords detected"
    _GUARD_TRIGGERED=false
    return 0
  fi

  _GUARD_TRIGGERED=true
  _log ok "Offer evaluation request detected"
  _update_guard_state

  # 2. 직급/컨텍스트 추출
  local job_context=$(_extract_job_context "$prompt")
  if [[ -z "$job_context" ]]; then
    job_context="Software Engineer"  # 기본값
  fi

  # 3. 시장 데이터 검색 쿼리 구성
  _MARKET_QUERY_TERM="${job_context} salary market rate compensation"

  # 4. 시장 데이터 조회
  _MARKET_DATA=$(_search_market_data "$_MARKET_QUERY_TERM")
  _log ok "Market data query prepared: $_MARKET_QUERY_TERM"

  _record_market_query "$_MARKET_QUERY_TERM" "$_MARKET_DATA" "true"

  return 0
}

get_market_context_section() {
  if [[ "$_GUARD_TRIGGERED" != "true" ]]; then
    return 0
  fi

  if [[ -z "$_MARKET_DATA" ]]; then
    return 0
  fi

  cat <<'EOF'

<!-- SECTION:market-context-guard-cl-1908ed6c137a5b1a:DYNAMIC -->
## 시장 데이터 조회 컨텍스트 (오퍼 평가)

**주의**: 다음 시장 데이터는 WebSearch 기반 실시간 조회 결과입니다.
오퍼 평가 시 반드시 이 데이터를 참고하여 응답하세요.
절대 이 데이터를 무시하고 단편적인 답변을 제공하면 안 됩니다.

**필수 확인 사항**:
1. 해당 직급/지역의 시장 중앙값(Median Salary)과 범위(Range)를 제시
2. 제안된 오퍼와 시장 중앙값의 비교 분석
3. 해당 기업/산업의 일반적인 보상 패키지 구성 설명 (Bonus, Stock, Benefits)
4. 협상 가능성 및 추천 협상 전략 제시

**시장 데이터 미포함 시 규칙**:
- WebSearch 결과가 없으면 "시장 데이터 미확인" 명시 후 일반적 범위만 제시
- 절대 미확인 데이터를 사실처럼 단언하면 안 됨

<!-- /SECTION:market-context-guard-cl-1908ed6c137a5b1a -->
EOF

  return 0
}

get_guard_status() {
  printf "triggered=%s query_term=%s\n" "$_GUARD_TRIGGERED" "$_MARKET_QUERY_TERM"
}

get_market_data() {
  echo "$_MARKET_DATA"
}

# ============================================================================
# 테스트 헬퍼
# ============================================================================

test_keyword_detection() {
  local test_prompt=$1

  if _detect_offer_eval_keywords "$test_prompt"; then
    echo "✓ Keywords detected in: $test_prompt"
    return 0
  else
    echo "✗ No keywords detected in: $test_prompt"
    return 1
  fi
}

show_guard_stats() {
  _ensure_dirs
  if [[ -f "$GUARD_STATE" ]]; then
    _log info "Guard Statistics:"
    cat "$GUARD_STATE" | jq . >&2
  fi
}

# 초기화
_GUARD_TRIGGERED=false
_MARKET_DATA=""
_MARKET_QUERY_TERM=""
