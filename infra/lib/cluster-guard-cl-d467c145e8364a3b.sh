#!/bin/bash
# cluster-guard-cl-d467c145e8364a3b.sh — 사용자 의도 오독 방지 가드
#
# 문제: User 명확한 요청을 '새로운 지시 없다'고 오판 (재발 9건/7일)
# 멤버 패턴:
#   - 파일 상태 단언 후 사용자 정정받았으나, 재정정에서도 같은 결론 반복
#   - 오너 새 제작 요청을 재전송으로 대응 + 의도 파악 실패
#   - 사용자 의도 명확화 생략 후 광범위 승인 과다 확대
#   - 모호한 요청을 기존 파일 확인만으로 판단 → 오너 의도 오독
#
# 솔루션:
#   1. ask-claude.sh 호출 전 PROMPT 분석
#   2. 사용자 입력 유형 분류 (신규생성/수정/재전송/범위확장/의도불명)
#   3. 의도 불명확 시 한 줄 확인 질문 강제 출력 + CLARIFICATION_REQUIRED 신호
#   4. '다시 만들어줘', '다시 해줘' 등 표현 감지 → 신규 요청으로 인식
#   5. 모호한 표현 패턴 차단 ('이건 뭐죠?', '맞나요?', 파일만 명시하고 액션 없음)
#
# 사용:
#   source ~/projects/jarvis/infra/lib/cluster-guard-cl-d467c145e8364a3b.sh
#   classify_user_intent "$PROMPT"
#   check_intent_clarity "$PROMPT"
#   get_guard_status

set -euo pipefail

# ============================================================================
# 설정
# ============================================================================

readonly CLUSTER_ID="cl-d467c145e8364a3b"
readonly JARVIS_HOME="${HOME}/projects/jarvis"
JARVIS_RUNTIME="${JARVIS_RUNTIME:-${BOT_HOME:-$HOME/.openclaw-data/runtime}}"  # 회차8: 런타임은 코드 루트 밑이 아니다
readonly STATE_DIR="${JARVIS_RUNTIME}/state/cluster-guards"
readonly GUARD_STATE="${STATE_DIR}/${CLUSTER_ID}-state.json"
readonly INTENT_LOG="${STATE_DIR}/${CLUSTER_ID}-intents.jsonl"

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ============================================================================
# 패턴 매핑 테이블
# ============================================================================

# 신규 생성을 나타내는 표현 (재전송이 아님)
NEW_REQUEST_PATTERNS=(
  "다시 만들어줘|다시 제작|새로 만들어|처음부터 다시"
  "처음부터|밑바닥부터|새로"
  "완전히 다른|전혀 다른|완전 다른"
  "다시 작성|새로 작성|처음부터 작성"
  "전면 수정|완전 수정|밑바닥 수정"
)

# 의도 불명확한 표현 (확인 질문 필요)
UNCLEAR_PATTERNS=(
  "이거 맞나|이게 맞나|이건 뭐야|이게 뭐야|파일 확인해|파일 봐줘"
  "잘 되나|맞나|맞죠|맞게|제대로"
  "마저|계속|더|추가로|또"
  "다시 보냄|재전송|다시 줄게|다시 줄"
)

# 수정을 명확히 나타내는 표현
MODIFY_PATTERNS=(
  "수정해|수정줘|고쳐|고쳐줘|바꿔|변경해"
  "추가해|추가줘|더하기|포함해"
  "삭제해|삭제줘|빼줘|제거해|없애줘"
  "변경해|바꾸어|바꿔|교체|대체"
)

# 범위 확장을 나타내는 표현
SCOPE_EXPAND_PATTERNS=(
  "혹시|그리고|또한|아|참고|추가로"
  "전체|모든|다 다시|전부"
)

# ============================================================================
# 유틸리티
# ============================================================================

log() {
  local level=$1
  shift
  local msg="$*"
  case $level in
    info) echo -e "${BLUE}[${CLUSTER_ID}] ℹ️  ${msg}${NC}" ;;
    ok) echo -e "${GREEN}[${CLUSTER_ID}] ✅ ${msg}${NC}" ;;
    warn) echo -e "${YELLOW}[${CLUSTER_ID}] ⚠️  ${msg}${NC}" ;;
    err) echo -e "${RED}[${CLUSTER_ID}] ❌ ${msg}${NC}" ;;
    clarify) echo -e "${MAGENTA}[${CLUSTER_ID}] ❓ ${msg}${NC}" ;;
  esac
}

_ensure_dirs() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
}

_init_guard_state() {
  _ensure_dirs

  if [[ ! -f "$GUARD_STATE" ]]; then
    cat > "$GUARD_STATE" <<EOF
{
  "cluster_id": "${CLUSTER_ID}",
  "cluster_name": "User 명확한 요청을 '새로운 지시 없다'고 오판",
  "initialized_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "total_checks": 0,
  "new_request": 0,
  "modify": 0,
  "resend": 0,
  "scope_expand": 0,
  "unclear": 0,
  "clarifications_issued": 0,
  "last_check_at": null
}
EOF
    log ok "가드 상태 초기화됨"
  fi
}

_update_guard_state() {
  local intent_type=$1
  local is_clarified=$2

  _ensure_dirs

  local clarified_val=$([[ "$is_clarified" == "true" ]] && echo "1" || echo "0")

  jq \
    --arg intent "$intent_type" \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson clarified "$clarified_val" \
    '.total_checks += 1 |
     .[$intent] += 1 |
     .clarifications_issued += $clarified |
     .last_check_at = $now' \
    "$GUARD_STATE" > "${GUARD_STATE}.tmp" 2>/dev/null || true
  mv "${GUARD_STATE}.tmp" "$GUARD_STATE" 2>/dev/null || true
}

_record_intent() {
  local prompt=$1
  local intent_type=$2
  local confidence=$3
  local clarification_needed=$4

  _ensure_dirs

  local record=$(cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cluster_id": "${CLUSTER_ID}",
  "prompt_hash": "$(echo -n "$prompt" | sha256sum | awk '{print $1}')",
  "prompt_length": ${#prompt},
  "intent_type": "$intent_type",
  "confidence": $confidence,
  "clarification_needed": $clarification_needed
}
EOF
  )

  echo "$record" >> "$INTENT_LOG"
}

# ============================================================================
# 패턴 매칭 로직
# ============================================================================

# 패턴 목록에서 매치 검사
_match_patterns() {
  local prompt=$1
  local pattern_type=$2

  local patterns=()
  case "$pattern_type" in
    new)
      patterns=("${NEW_REQUEST_PATTERNS[@]}")
      ;;
    modify)
      patterns=("${MODIFY_PATTERNS[@]}")
      ;;
    unclear)
      patterns=("${UNCLEAR_PATTERNS[@]}")
      ;;
    scope)
      patterns=("${SCOPE_EXPAND_PATTERNS[@]}")
      ;;
  esac

  for pattern_str in "${patterns[@]}"; do
    if grep -iE "$pattern_str" <<< "$prompt" >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

# ============================================================================
# 의도 분류 로직
# ============================================================================

# 사용자 입력 유형 분류 → 신규/수정/재전송/범위확장/의도불명
classify_user_intent() {
  local prompt="${1:?Usage: classify_user_intent PROMPT}"

  _init_guard_state

  # 1. 신규 생성인지 확인 (다시 만들어줘, 처음부터 등)
  if _match_patterns "$prompt" "new" >/dev/null 2>&1; then
    echo "new_request"
    _update_guard_state "new_request" "false"
    _record_intent "$prompt" "new_request" "0.95" "false"
    return 0
  fi

  # 2. 명확한 수정인지 확인 (수정해, 고쳐줘, 추가해 등)
  if _match_patterns "$prompt" "modify" >/dev/null 2>&1; then
    echo "modify"
    _update_guard_state "modify" "false"
    _record_intent "$prompt" "modify" "0.90" "false"
    return 0
  fi

  # 3. 범위 확장인지 확인 (그리고, 또한, 아 등)
  if _match_patterns "$prompt" "scope" >/dev/null 2>&1; then
    echo "scope_expand"
    _update_guard_state "scope_expand" "false"
    _record_intent "$prompt" "scope_expand" "0.75" "false"
    return 0
  fi

  # 4. 의도 불명확한지 확인 (이거 맞나, 파일 봐줘 등)
  if _match_patterns "$prompt" "unclear" >/dev/null 2>&1; then
    echo "unclear"
    _update_guard_state "unclear" "true"
    _record_intent "$prompt" "unclear" "0.50" "true"
    return 0
  fi

  # 5. 기본값: 재전송으로 의심 (새 지시 없음 = 재전송)
  # 프롬프트가 매우 짧거나 단순한 경우
  if [[ ${#prompt} -lt 20 ]] || grep -iE "^(맞나|돼|됐|해|했|맞게|제대로)$" <<< "$prompt" >/dev/null 2>&1; then
    echo "possible_resend"
    _update_guard_state "resend" "true"
    _record_intent "$prompt" "possible_resend" "0.60" "true"
    return 0
  fi

  # 6. 기타: 의도 불명확 (구체적 액션 없음, 파일명만 있음 등)
  echo "ambiguous"
  _update_guard_state "unclear" "true"
  _record_intent "$prompt" "ambiguous" "0.40" "true"
  return 0
}

# ============================================================================
# 의도 명확성 검사 (불명확 시 확인 질문 발급)
# ============================================================================

check_intent_clarity() {
  local prompt="${1:?Usage: check_intent_clarity PROMPT}"

  local intent
  intent=$(classify_user_intent "$prompt")

  case "$intent" in
    new_request|modify)
      # 명확한 요청: 통과
      log ok "의도 명확: $intent"
      return 0
      ;;

    unclear|possible_resend|ambiguous)
      # 의도 불명확: 확인 질문 발급
      log clarify "의도 불명확 감지 — 확인 질문 필요"
      echo ""
      echo "════════════════════════════════════════════════════════════════"
      echo "❓ 의도 명확화 필요"
      echo "════════════════════════════════════════════════════════════════"
      echo ""
      echo "🔍 감지된 요청:"
      echo "  프롬프트: ${prompt:0:100}..."
      echo ""
      echo "📌 확인 질문:"
      case "$intent" in
        unclear)
          echo "  - 이건 기존 파일을 수정하려는 건가요, 아니면 새로 만들려는 건가요?"
          ;;
        possible_resend)
          echo "  - 이 명령이 새로운 요청일까요, 아니면 이전 작업의 재전송일까요?"
          ;;
        ambiguous)
          echo "  - 어떤 파일을 어떻게 수정/생성하고 싶으신가요? (구체적인 액션을 명시해주세요)"
          ;;
      esac
      echo ""
      echo "💡 다음 중 하나를 명시해주세요:"
      echo "  • '새로 만들어줘' (신규 생성)"
      echo "  • '수정해줘' (수정)"
      echo "  • '다시 만들어줘' (전체 재작업)"
      echo "════════════════════════════════════════════════════════════════"
      echo ""
      return 1
      ;;

    scope_expand)
      # 범위 확장: 경고
      log warn "범위 확장 감지 — 명확성 확인"
      echo ""
      echo "⚠️  범위 확장이 감지되었습니다."
      echo "   기존 요청 + 추가 요청이 섞여 있을 수 있습니다."
      echo "   각각 명확히 분리해주세요."
      echo ""
      return 0
      ;;
  esac
}

# ============================================================================
# 상태 조회 & 리포팅
# ============================================================================

get_guard_status() {
  _init_guard_state

  log info "클러스터 가드 상태:"
  echo ""
  cat "$GUARD_STATE" | jq '.'
}

get_recent_intents() {
  local count=${1:-10}

  _ensure_dirs

  if [[ ! -f "$INTENT_LOG" ]]; then
    log warn "의도 분류 이력 없음"
    return
  fi

  log info "최근 의도 분류 이력 (${count}건):"
  echo ""
  tail -n "$count" "$INTENT_LOG" | jq '.'
}

reset_guard() {
  _ensure_dirs
  rm -f "$GUARD_STATE" "$INTENT_LOG"
  _init_guard_state
  log ok "가드 상태 초기화 완료"
}

generate_cluster_report() {
  _init_guard_state

  local report_file="${STATE_DIR}/${CLUSTER_ID}-report-$(date +%Y%m%d-%H%M%S).json"
  local check_count=0
  local unclear_count=0

  if [[ -f "$INTENT_LOG" ]]; then
    check_count=$(wc -l < "$INTENT_LOG" 2>/dev/null | tr -d ' \n' || echo 0)
    unclear_count=$(grep -c '"clarification_needed":true' "$INTENT_LOG" 2>/dev/null | tr -d ' \n' || echo 0)
  fi

  local clarity_rate="N/A"
  if [[ $check_count -gt 0 ]] && [[ "$unclear_count" =~ ^[0-9]+$ ]]; then
    clarity_rate="$((100 - (unclear_count * 100 / check_count)))%"
  fi

  cat > "$report_file" <<EOF
{
  "cluster_id": "${CLUSTER_ID}",
  "cluster_name": "User 명확한 요청을 '새로운 지시 없다'고 오판",
  "report_timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "guard_status": $(cat "$GUARD_STATE"),
  "statistics": {
    "total_intent_checks": $check_count,
    "clarifications_issued": $unclear_count,
    "clarity_rate": "$clarity_rate"
  }
}
EOF

  log ok "리포트 생성: $report_file"
  cat "$report_file" | jq '.'
}

# ============================================================================
# CLI 인터페이스
# ============================================================================

usage() {
  cat <<EOF
사용법: $(basename "$0") <command> [options]

명령어:
  classify <prompt>      사용자 의도 분류 (신규/수정/재전송/범위확장/불명확)
  check <prompt>         의도 명확성 검사 + 필요시 확인 질문 발급
  status                 가드 상태 조회
  logs [COUNT]           최근 의도 분류 이력 조회 (기본값: 10)
  report                 클러스터 리포트 생성
  reset                  가드 상태 초기화

예시:
  $(basename "$0") classify "수정해줘"
  $(basename "$0") check "파일 맞나요?"
  $(basename "$0") status
  $(basename "$0") logs 20
EOF
}

main() {
  local cmd=${1:-help}

  _init_guard_state

  case "$cmd" in
    classify)
      if [[ -z "${2:-}" ]]; then
        log err "프롬프트를 제공하세요"
        usage
        exit 1
      fi
      classify_user_intent "$2"
      ;;
    check)
      if [[ -z "${2:-}" ]]; then
        log err "프롬프트를 제공하세요"
        usage
        exit 1
      fi
      check_intent_clarity "$2"
      ;;
    status)
      get_guard_status
      ;;
    logs)
      get_recent_intents "${2:-10}"
      ;;
    report)
      generate_cluster_report
      ;;
    reset)
      reset_guard
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      log err "알 수 없는 명령어: $cmd"
      usage
      exit 1
      ;;
  esac
}

# 직접 실행 시에만 main 호출
case "$0" in
  */cluster-guard-cl-d467c145e8364a3b.sh)
    main "$@"
    ;;
esac
