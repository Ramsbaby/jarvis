#!/bin/bash
#
# check-evidence-staleness.sh — SSoT 슬롯의 실측 기준 검증
#
# 목적: 실측 재확인 없이 과거 기록값으로 기술 결정하는 오류 방지 (cl-0bf9522b938afa87)
#
# 사용:
#   check-evidence-staleness.sh [--threshold-days N] [--json] [--key SLOT]
#
# 반환:
#   - 기준선 경과 안 함: exit 0, 메시지 출력 또는 JSON 반환
#   - 기준선 초과: exit 1, 경고 목록 출력

set -euo pipefail

THRESHOLD_DAYS="${THRESHOLD_DAYS:-30}"
JSON_OUTPUT=0
TARGET_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold-days)
      THRESHOLD_DAYS="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=1
      shift
      ;;
    --key)
      TARGET_KEY="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

JARVIS_WIKI_ROOT="${JARVIS_WIKI_ROOT:-$HOME/.openclaw-data/runtime/wiki}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Node.js에서 슬롯 데이터를 JSON으로 가져오기
get_slots_json() {
  local key_filter=""
  if [[ -n "$TARGET_KEY" ]]; then
    key_filter="--key $TARGET_KEY"
  fi
  node "$SCRIPT_DIR/wiki-slots.mjs" --json $key_filter 2>/dev/null || echo "[]"
}

# 현재 날짜 (YYYY-MM-DD)
current_date() {
  date +%Y-%m-%d
}

# 두 날짜 사이의 일수 계산
days_between() {
  local d1="$1" d2="$2"
  # macOS와 Linux 호환
  if command -v gdate &>/dev/null; then
    # GNU date (Linux / macOS with coreutils)
    echo $(($(gdate -d "$d1" +%s) / 86400 - $(gdate -d "$d2" +%s) / 86400))
  else
    # BSD date (macOS)
    echo $(($(date -j -f %Y-%m-%d -u "$d1" +%s) / 86400 - $(date -j -f %Y-%m-%d -u "$d2" +%s) / 86400))
  fi
}

# 슬롯 검사
slots_json=$(get_slots_json)
current="$(current_date)"

stale_count=0
fresh_count=0
no_evidence_count=0
stale_list=()
no_evidence_list=()

# JSON 파싱 (jq 또는 native bash)
if command -v jq &>/dev/null; then
  # jq를 사용한 파싱
  for row in $(echo "$slots_json" | jq -r '.[] | @base64'); do
    _jq() {
      echo "${row}" | base64 -d | jq -r "${1}"
    }

    key=$(_jq '.key')
    evidence_at=$(_jq '.evidence_at // empty')
    active=$(_jq '.active')

    # 비활성 슬롯은 스킵
    if [[ "$active" != "true" ]]; then
      continue
    fi

    # 실측 시점이 없으면 경고
    if [[ -z "$evidence_at" ]]; then
      no_evidence_count=$((no_evidence_count + 1))
      no_evidence_list+=("$key")
      continue
    fi

    # 경과 일수 계산
    days=$(days_between "$current" "$evidence_at")
    if [[ $days -ge $THRESHOLD_DAYS ]]; then
      stale_count=$((stale_count + 1))
      stale_list+=("$key (측정: $evidence_at, $days일 경과)")
    else
      fresh_count=$((fresh_count + 1))
    fi
  done
else
  # jq 없으면 간단한 JSON 파싱 (문자열 기반)
  echo "$slots_json" | grep -o '"key":"[^"]*"\|"evidence_at":"[^"]*"\|"active":true' | \
    paste -d'\n' - - - | while IFS=$'\t' read -r key_line evidence_line active_line; do

    key=$(echo "$key_line" | sed 's/.*:"//; s/".*//')
    evidence_at=$(echo "$evidence_line" | sed 's/.*:"//; s/".*//' 2>/dev/null || echo "")

    # 비활성 스킵
    if [[ ! "$active_line" =~ "active.*true" ]]; then
      continue
    fi

    if [[ -z "$evidence_at" ]]; then
      no_evidence_count=$((no_evidence_count + 1))
      no_evidence_list+=("$key")
      continue
    fi

    days=$(days_between "$current" "$evidence_at")
    if [[ $days -ge $THRESHOLD_DAYS ]]; then
      stale_count=$((stale_count + 1))
      stale_list+=("$key (측정: $evidence_at, $days일 경과)")
    else
      fresh_count=$((fresh_count + 1))
    fi
  done
fi

# 출력
if [[ $JSON_OUTPUT -eq 1 ]]; then
  cat <<EOF
{
  "timestamp": "$(current_date)T$(date +%H:%M:%S)",
  "threshold_days": $THRESHOLD_DAYS,
  "fresh": $fresh_count,
  "stale": $stale_count,
  "no_evidence": $no_evidence_count,
  "stale_keys": [$(printf '"%s", ' "${stale_list[@]}" | sed 's/, *$//')]
  "no_evidence_keys": [$(printf '"%s", ' "${no_evidence_list[@]}" | sed 's/, *$//')]
}
EOF
else
  echo "📊 SSoT 슬롯 실측 기준 검사 (기준선: ${THRESHOLD_DAYS}일)"
  echo "  ✅ 신선: $fresh_count개"
  echo "  ⚠️  경과: $stale_count개"
  echo "  🔴 미기록: $no_evidence_count개"

  if [[ ${#stale_list[@]} -gt 0 ]]; then
    echo ""
    echo "🔴 기준선 초과한 슬롯 (기술 결정 직전 재측정 필수):"
    printf '  - %s\n' "${stale_list[@]}"
  fi

  if [[ ${#no_evidence_list[@]} -gt 0 ]]; then
    echo ""
    echo "🔴 실측 시점 미기록 슬롯 (evidence_at 필드 필수, cl-0bf9522b938afa87):"
    printf '  - %s\n' "${no_evidence_list[@]}"
  fi
fi

# 종료 코드
if [[ $stale_count -gt 0 ]] || [[ $no_evidence_count -gt 0 ]]; then
  exit 1
else
  exit 0
fi
