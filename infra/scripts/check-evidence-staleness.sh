#!/usr/bin/env bash
#
# check-evidence-staleness.sh — SSoT 슬롯의 실측 기준 검증
#
# 목적: 실측 재확인 없이 과거 기록값으로 기술 결정하는 오류 방지 (cl-0bf9522b938afa87)
#
# 사용:
#   check-evidence-staleness.sh [--threshold-days N] [--json] [--key SLOT]
#   (--key SLOT 은 wiki-slots.mjs 의 `--get SLOT` 으로 전달된다)
#
# 반환:
#   - 기준선 경과 안 함: exit 0, 메시지 출력 또는 JSON 반환
#   - 기준선 초과: exit 1, 경고 목록 출력
#   - 검사한 슬롯이 0건(위키 경로 없음·키 미등재·조회 실패): exit 2
#     — 2026-09-19: 조회 실패가 `[]` 로 삼켜져 "노후 0건" 거짓 통과가 나던 구멍을 막는다.

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 위키 경로는 여기서 정하지 않는다. wiki-slots.mjs 가 자체 폴백을 가진다
# (명시 env JARVIS_WIKI_ROOT → BOT_HOME/wiki → ~/.openclaw-data/wiki → 옛 경로).
# 2026-09-19 이전엔 이 파일이 `~/.openclaw-data/runtime/wiki` 를 기본값으로 들고 있었는데,
# 정본(~/.openclaw-data/wiki)과 어긋난 사본이었고 export 도 안 돼 node 에 전달되지도 않았다.
# 경로를 바꾸려면 호출자가 `export JARVIS_WIKI_ROOT=...` 로 넘긴다.

# Node.js에서 슬롯 데이터를 JSON으로 가져오기
get_slots_json() {
  # wiki-slots.mjs 의 단일 키 조회 플래그는 `--get` 이다(`--key` 는 없어서 조용히 무시됐다).
  if [[ -n "$TARGET_KEY" ]]; then
    node "$SCRIPT_DIR/wiki-slots.mjs" --json --get "$TARGET_KEY"
  else
    node "$SCRIPT_DIR/wiki-slots.mjs" --json
  fi
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

# 문자열 배열 → JSON 배열. 인자가 없으면 `[]`.
# printf 는 인자가 0개여도 형식을 한 번 찍기 때문에 빈 배열이 `[""]` 로 나갔다(2026-09-19 실측).
json_array() {
  if [[ $# -eq 0 ]]; then
    printf '[]'
    return
  fi
  local out="" item
  for item in "$@"; do
    item=${item//\\/\\\\}
    item=${item//\"/\\\"}
    out+="\"$item\", "
  done
  printf '[%s]' "${out%, }"
}

# 슬롯 검사 — 조회 실패는 삼키지 않는다. 빈 결과로 "노후 0건" 통과가 되면 안 된다.
if ! slots_json=$(get_slots_json); then
  echo "[ERROR] wiki-slots.mjs 조회 실패 — 슬롯을 읽지 못해 검사를 수행하지 않았다" >&2
  exit 2
fi

# wiki-slots.mjs 는 위키 경로가 없어도, 키가 미등재여도 `[]` 에 exit 0 을 낸다(2026-09-19 실측).
# 그래서 종료 코드만 믿으면 안 되고, 받은 배열이 비었는지를 여기서 직접 센다.
if command -v jq &>/dev/null; then
  if ! slot_total=$(printf '%s' "$slots_json" | jq -e 'if type=="array" then length else error("not an array") end' 2>/dev/null); then
    echo "[ERROR] wiki-slots.mjs 출력이 JSON 배열이 아니다 — 검사를 수행하지 않았다" >&2
    exit 2
  fi
  if [[ "$slot_total" -eq 0 ]]; then
    echo "[ERROR] 검사할 슬롯이 0건 — 위키 경로(JARVIS_WIKI_ROOT=${JARVIS_WIKI_ROOT:-미설정, mjs 폴백 사용}) 또는 키(${TARGET_KEY:-전체}) 를 확인하라" >&2
    exit 2
  fi
fi
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

# 실제로 센 슬롯이 0건이면 검사가 아니다. (jq 없는 폴백 파서가 파이프 서브셸에서 돌아
# 카운터가 안 올라오는 경우도 여기서 걸린다 — 조용히 0/0/0 통과로 나가지 않는다.)
checked_count=$((fresh_count + stale_count + no_evidence_count))
if [[ $checked_count -eq 0 ]]; then
  echo "[ERROR] 센 슬롯이 0건 — 파싱 실패 또는 빈 입력. 검사를 수행하지 않았다" >&2
  exit 2
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
  "checked": $checked_count,
  "stale_keys": $(json_array ${stale_list[@]+"${stale_list[@]}"}),
  "no_evidence_keys": $(json_array ${no_evidence_list[@]+"${no_evidence_list[@]}"})
}
EOF
  # 위 두 줄의 `${arr[@]+"${arr[@]}"}` — macOS 기본 bash 3.2 는 빈 배열을 "${arr[@]}" 로 펼치면
  # set -u 에 걸려 죽는다. 또 stale_keys 줄 끝 쉼표가 빠져 JSON 이 깨져 있었다(2026-09-19 실측).
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
