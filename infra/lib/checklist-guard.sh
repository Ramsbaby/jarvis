#!/usr/bin/env bash
# checklist-guard.sh — 다중 항목 지시 체크리스트 추적 & 완료 선언 차단 가드
#
# 클러스터 ID  : cl-525648978b1b80de (최근 7일 재발 19건)
# 대표 시드    : PDF/HTML 재생성 완료 선언 후 변경사항 구체값 미제시
# 멤버 패턴    : 선행 해결책 미적용 → 신규 파일에 같은 문제 재발
#               / 파일 미실측 후 수정 선언 (TTS 150ms 딜레이 등)
#               / CSS 숨김만으로 완료 단언, HTML 태그 미제거
#
# 역할:
#   1. 다중 항목 지시에서 체크리스트 자동 생성
#   2. 항목별 완료 여부 추적 (상태 파일: ~/jarvis/runtime/state/checklist-<session>.json)
#   3. 미완료 항목이 1개 이상이면 exit 1 반환 → 완료 선언 차단
#   4. 전체 완료 시에만 exit 0 반환
#
# 사용법:
#   source checklist-guard.sh
#   checklist_init "항목1" "항목2" "항목3"    # 체크리스트 초기화
#   checklist_done "항목1"                    # 항목 완료 표시
#   checklist_verify                          # 전체 완료 검사 (exit 0/1 반환)
#   checklist_status                          # 현재 상태 출력

set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# 설정
# ═══════════════════════════════════════════════════════════════

JARVIS_STATE_DIR="${JARVIS_STATE_DIR:-${HOME}/jarvis/runtime/state}"
CHECKLIST_DIR="${JARVIS_STATE_DIR}/checklists"
SESSION_ID="${CHECKLIST_SESSION_ID:-$$}"
CHECKLIST_FILE="${CHECKLIST_DIR}/checklist-${SESSION_ID}.json"

CL_LOG_PREFIX="[checklist-guard cl-525648978b1b80de]"

# ═══════════════════════════════════════════════════════════════
# 내부 헬퍼
# ═══════════════════════════════════════════════════════════════

_cl_log() {
  local level="$1"; shift
  echo "${CL_LOG_PREFIX} [${level}] $*" >&2
}

_cl_ensure_dir() {
  mkdir -p "${CHECKLIST_DIR}"
}

_cl_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# JSON 이스케이프 (간단 구현 — jq 없을 때 폴백)
_cl_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  echo "$s"
}

# ═══════════════════════════════════════════════════════════════
# [공개] checklist_init — 체크리스트 초기화
# 인자: 항목 문자열들 (가변 인자)
# ═══════════════════════════════════════════════════════════════
checklist_init() {
  if [[ $# -eq 0 ]]; then
    _cl_log "ERROR" "항목이 없습니다. checklist_init 항목1 항목2 ..."
    return 1
  fi

  _cl_ensure_dir

  local items_json="["
  local first=1
  for item in "$@"; do
    local escaped
    escaped="$(_cl_json_escape "$item")"
    [[ $first -eq 0 ]] && items_json+=","
    items_json+="{\"label\":\"${escaped}\",\"done\":false,\"completed_at\":null}"
    first=0
  done
  items_json+="]"

  cat > "${CHECKLIST_FILE}" <<EOF
{
  "cluster_id": "cl-525648978b1b80de",
  "session_id": "${SESSION_ID}",
  "created_at": "$(_cl_now)",
  "items": ${items_json}
}
EOF

  _cl_log "INFO" "체크리스트 초기화: $# 개 항목"
  checklist_status
}

# ═══════════════════════════════════════════════════════════════
# [공개] checklist_done — 항목 완료 표시
# 인자: 완료할 항목 레이블 (부분 일치 허용)
# ═══════════════════════════════════════════════════════════════
checklist_done() {
  if [[ $# -eq 0 ]]; then
    _cl_log "ERROR" "완료 표시할 항목을 지정하세요."
    return 1
  fi

  if [[ ! -f "${CHECKLIST_FILE}" ]]; then
    _cl_log "ERROR" "체크리스트 파일 없음. checklist_init을 먼저 실행하세요."
    return 1
  fi

  local label="$1"
  local now
  now="$(_cl_now)"

  # jq 사용 가능 시 정확한 JSON 수정
  if command -v jq &>/dev/null; then
    local escaped_label
    escaped_label="$(_cl_json_escape "$label")"
    local tmp
    tmp="$(mktemp)"
    jq --arg lbl "$label" --arg ts "$now" \
      '(.items[] | select(.label | contains($lbl)) | .done) = true |
       (.items[] | select(.label | contains($lbl)) | .completed_at) = $ts' \
      "${CHECKLIST_FILE}" > "$tmp" && mv "$tmp" "${CHECKLIST_FILE}"
    _cl_log "INFO" "완료 표시: ${label}"
  else
    # jq 없을 때 파이썬 폴백
    python3 - "${CHECKLIST_FILE}" "$label" "$now" <<'PYEOF'
import sys, json
path, label, ts = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    data = json.load(f)
matched = False
for item in data["items"]:
    if label in item["label"]:
        item["done"] = True
        item["completed_at"] = ts
        matched = True
if not matched:
    sys.stderr.write(f"[checklist-guard] 항목 미발견: {label}\n")
    sys.exit(1)
with open(path, "w") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PYEOF
    _cl_log "INFO" "완료 표시: ${label}"
  fi
}

# ═══════════════════════════════════════════════════════════════
# [공개] checklist_verify — 완료 선언 검사
# 반환: 0 = 전체 완료 / 1 = 미완료 항목 있음
# ═══════════════════════════════════════════════════════════════
checklist_verify() {
  if [[ ! -f "${CHECKLIST_FILE}" ]]; then
    _cl_log "WARN" "체크리스트 없음. 검사 생략 (완료로 간주하지 않음)."
    return 1
  fi

  local pending_count=0
  local total_count=0

  if command -v jq &>/dev/null; then
    pending_count=$(jq '[.items[] | select(.done == false)] | length' "${CHECKLIST_FILE}")
    total_count=$(jq '.items | length' "${CHECKLIST_FILE}")
  else
    pending_count=$(python3 - "${CHECKLIST_FILE}" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
print(sum(1 for i in data["items"] if not i["done"]))
PYEOF
)
    total_count=$(python3 - "${CHECKLIST_FILE}" <<'PYEOF'
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
print(len(data["items"]))
PYEOF
)
  fi

  if [[ "${pending_count}" -gt 0 ]]; then
    _cl_log "BLOCK" "완료 선언 차단: 미완료 ${pending_count}/${total_count} 항목 존재"
    _cl_log "BLOCK" "=== 미완료 항목 목록 ==="
    if command -v jq &>/dev/null; then
      jq -r '.items[] | select(.done == false) | "  ☐ " + .label' "${CHECKLIST_FILE}" >&2
    else
      python3 - "${CHECKLIST_FILE}" <<'PYEOF' >&2
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
for i in data["items"]:
    if not i["done"]:
        print(f"  ☐ {i['label']}")
PYEOF
    fi
    return 1
  fi

  _cl_log "OK" "전체 ${total_count}/${total_count} 완료. 완료 선언 허용."
  return 0
}

# ═══════════════════════════════════════════════════════════════
# [공개] checklist_status — 현재 상태 출력
# ═══════════════════════════════════════════════════════════════
checklist_status() {
  if [[ ! -f "${CHECKLIST_FILE}" ]]; then
    _cl_log "INFO" "체크리스트 없음"
    return 0
  fi

  echo "─────────────────────────────────────────" >&2
  echo "${CL_LOG_PREFIX} 체크리스트 상태" >&2
  if command -v jq &>/dev/null; then
    jq -r '.items[] | if .done then "  ☑ " + .label else "  ☐ " + .label end' \
      "${CHECKLIST_FILE}" >&2
  else
    python3 - "${CHECKLIST_FILE}" <<'PYEOF' >&2
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
for i in data["items"]:
    mark = "☑" if i["done"] else "☐"
    print(f"  {mark} {i['label']}")
PYEOF
  fi
  echo "─────────────────────────────────────────" >&2
}

# ═══════════════════════════════════════════════════════════════
# [공개] checklist_reset — 체크리스트 초기화 (세션 종료 시)
# ═══════════════════════════════════════════════════════════════
checklist_reset() {
  if [[ -f "${CHECKLIST_FILE}" ]]; then
    rm -f "${CHECKLIST_FILE}"
    _cl_log "INFO" "체크리스트 삭제 완료 (세션: ${SESSION_ID})"
  fi
}

# ═══════════════════════════════════════════════════════════════
# 스크립트 직접 실행 시 CLI 인터페이스
# ═══════════════════════════════════════════════════════════════
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-help}"
  shift || true

  case "$cmd" in
    init)    checklist_init "$@" ;;
    done)    checklist_done "$@" ;;
    verify)  checklist_verify ;;
    status)  checklist_status ;;
    reset)   checklist_reset ;;
    help|*)
      cat >&2 <<HELP
사용법: $(basename "$0") <명령> [인자...]

  init  항목1 항목2 ...   체크리스트 초기화
  done  "항목 레이블"     항목 완료 표시 (부분 일치)
  verify                   전체 완료 검사 (exit 0/1)
  status                   현재 상태 출력
  reset                    체크리스트 삭제

환경 변수:
  CHECKLIST_SESSION_ID     세션 ID (기본: 현재 PID)
  JARVIS_STATE_DIR         상태 디렉터리 (기본: ~/jarvis/runtime/state)
HELP
      exit 0
      ;;
  esac
fi
