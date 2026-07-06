#!/usr/bin/env bash
# session-diff-guard.sh — 신규 파일 생성 시 이전 세션 개선사항 미적용 항목 감지 가드
#
# 클러스터 ID  : cl-525648978b1b80de (최근 7일 재발 19건)
# 패턴         : 선행 해결책 미적용 → 신규 파일에 같은 문제 재발
#               (예: 이전 세션에서 "HTML 태그 완전 제거" 개선사항 기록됐으나
#                    신규 파일 생성 시 CSS 숨김만 적용하고 태그는 남김)
#
# 역할:
#   1. 이전 세션 개선사항 목록 조회 (~/jarvis/runtime/state/session-improvements.jsonl)
#   2. 신규 파일 생성 컨텍스트와 비교
#   3. 미적용 항목 발견 시 경고 출력 + exit 1
#   4. 모든 개선사항 적용 확인 시 exit 0
#
# 사용법:
#   source session-diff-guard.sh
#
#   # 개선사항 기록 (세션 완료 후)
#   session_improvement_record "HTML 태그 완전 제거 필요 (CSS 숨김 불충분)"
#   session_improvement_record "PDF 재생성 시 변경사항 구체값 명시"
#
#   # 신규 파일 생성 전 검사
#   session_diff_check "새파일.html"   # 파일 컨텍스트 전달 (선택)
#
#   # 개선사항 적용 확인 표시
#   session_improvement_applied "HTML 태그 완전 제거"

set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# 설정
# ═══════════════════════════════════════════════════════════════

JARVIS_STATE_DIR="${JARVIS_STATE_DIR:-${HOME}/jarvis/runtime/state}"
IMPROVEMENTS_FILE="${JARVIS_STATE_DIR}/session-improvements.jsonl"
APPLIED_FILE="${JARVIS_STATE_DIR}/session-improvements-applied.jsonl"

SDG_LOG_PREFIX="[session-diff-guard cl-525648978b1b80de]"

# 클러스터 관련 핵심 패턴 (이 패턴이 개선사항에 포함되어 있으면 우선 경고)
declare -a CLUSTER_CRITICAL_PATTERNS=(
  "HTML 태그"
  "CSS 숨김"
  "완전 제거"
  "구체값"
  "변경사항"
  "재생성"
  "미적용"
  "TTS"
  "딜레이"
  "파일 미실측"
)

# ═══════════════════════════════════════════════════════════════
# 내부 헬퍼
# ═══════════════════════════════════════════════════════════════

_sdg_log() {
  local level="$1"; shift
  echo "${SDG_LOG_PREFIX} [${level}] $*" >&2
}

_sdg_ensure_dir() {
  mkdir -p "${JARVIS_STATE_DIR}"
}

_sdg_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

_sdg_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  echo "$s"
}

# ═══════════════════════════════════════════════════════════════
# [공개] session_improvement_record — 개선사항 기록
# 인자: 개선사항 설명 문자열
# ═══════════════════════════════════════════════════════════════
session_improvement_record() {
  if [[ $# -eq 0 ]]; then
    _sdg_log "ERROR" "개선사항 설명을 인자로 전달하세요."
    return 1
  fi

  _sdg_ensure_dir

  local desc="$1"
  local escaped
  escaped="$(_sdg_json_escape "$desc")"
  local session_id="${CHECKLIST_SESSION_ID:-$(date +%Y%m%d%H%M%S)}"

  echo "{\"ts\":\"$(_sdg_now)\",\"session\":\"${session_id}\",\"description\":\"${escaped}\",\"applied\":false}" \
    >> "${IMPROVEMENTS_FILE}"

  _sdg_log "INFO" "개선사항 기록: ${desc}"
}

# ═══════════════════════════════════════════════════════════════
# [공개] session_improvement_applied — 개선사항 적용 표시
# 인자: 적용한 개선사항 레이블 (부분 일치)
# ═══════════════════════════════════════════════════════════════
session_improvement_applied() {
  if [[ $# -eq 0 ]]; then
    _sdg_log "ERROR" "적용 확인할 개선사항 레이블을 전달하세요."
    return 1
  fi

  _sdg_ensure_dir

  local label="$1"
  local escaped
  escaped="$(_sdg_json_escape "$label")"
  local session_id="${CHECKLIST_SESSION_ID:-$(date +%Y%m%d%H%M%S)}"

  echo "{\"ts\":\"$(_sdg_now)\",\"session\":\"${session_id}\",\"applied_label\":\"${escaped}\"}" \
    >> "${APPLIED_FILE}"

  _sdg_log "INFO" "개선사항 적용 확인: ${label}"

  # 기존 improvements 파일에서 해당 항목 applied 표시 (python 또는 jq)
  if [[ -f "${IMPROVEMENTS_FILE}" ]]; then
    if command -v python3 &>/dev/null; then
      python3 - "${IMPROVEMENTS_FILE}" "$label" "$(_sdg_now)" <<'PYEOF'
import sys, json
path, label, ts = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if label in obj.get("description", "") and not obj.get("applied", False):
                obj["applied"] = True
                obj["applied_at"] = ts
            lines.append(json.dumps(obj, ensure_ascii=False))
        except json.JSONDecodeError:
            lines.append(line)
with open(path, "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF
    fi
  fi
}

# ═══════════════════════════════════════════════════════════════
# [공개] session_diff_check — 신규 파일 생성 전 개선사항 미적용 검사
# 인자: [파일명] (선택, 컨텍스트용)
# 반환: 0 = 안전 / 1 = 미적용 개선사항 있음
# ═══════════════════════════════════════════════════════════════
session_diff_check() {
  local context_file="${1:-}"
  local ctx_label=""
  [[ -n "${context_file}" ]] && ctx_label=" (대상: ${context_file})"

  if [[ ! -f "${IMPROVEMENTS_FILE}" ]]; then
    _sdg_log "INFO" "이전 세션 개선사항 없음${ctx_label}. 검사 생략."
    return 0
  fi

  # 미적용 항목 수집
  local pending_items=()
  local critical_items=()

  if command -v python3 &>/dev/null; then
    # python으로 미적용 항목 읽기
    local pending_json
    pending_json=$(python3 - "${IMPROVEMENTS_FILE}" <<'PYEOF'
import sys, json
path = sys.argv[1]
results = []
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if not obj.get("applied", False):
                results.append(obj.get("description", ""))
        except json.JSONDecodeError:
            pass
import json as j
print(j.dumps(results, ensure_ascii=False))
PYEOF
)
    # bash 배열로 변환
    while IFS= read -r item; do
      [[ -n "$item" ]] && pending_items+=("$item")
    done < <(python3 - "$pending_json" <<'PYEOF'
import sys, json
items = json.loads(sys.argv[1])
for i in items:
    print(i)
PYEOF
)
  else
    # python 없으면 grep 폴백 (applied:false 패턴)
    while IFS= read -r line; do
      [[ -n "$line" ]] && pending_items+=("$line")
    done < <(grep '"applied":false' "${IMPROVEMENTS_FILE}" | \
      sed 's/.*"description":"\([^"]*\)".*/\1/' 2>/dev/null || true)
  fi

  if [[ ${#pending_items[@]} -eq 0 ]]; then
    _sdg_log "OK" "미적용 개선사항 없음${ctx_label}."
    return 0
  fi

  # 클러스터 핵심 패턴과 교차 확인
  for item in "${pending_items[@]}"; do
    for pattern in "${CLUSTER_CRITICAL_PATTERNS[@]}"; do
      if [[ "$item" == *"$pattern"* ]]; then
        critical_items+=("$item")
        break
      fi
    done
  done

  # 경고 출력
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  _sdg_log "WARN" "신규 파일 생성 전 미적용 개선사항 감지${ctx_label}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2

  if [[ ${#critical_items[@]} -gt 0 ]]; then
    _sdg_log "CRITICAL" "클러스터 핵심 패턴 미적용 항목:"
    for item in "${critical_items[@]}"; do
      echo "  ⚠ [CRITICAL] ${item}" >&2
    done
  fi

  _sdg_log "WARN" "전체 미적용 항목 (${#pending_items[@]}건):"
  for item in "${pending_items[@]}"; do
    echo "  ☐ ${item}" >&2
  done

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  _sdg_log "WARN" "개선사항 적용 후 session_improvement_applied \"<레이블>\" 로 확인하세요."

  return 1
}

# ═══════════════════════════════════════════════════════════════
# [공개] session_diff_list — 전체 개선사항 목록 출력
# ═══════════════════════════════════════════════════════════════
session_diff_list() {
  if [[ ! -f "${IMPROVEMENTS_FILE}" ]]; then
    _sdg_log "INFO" "기록된 개선사항 없음"
    return 0
  fi

  echo "─────────────────────────────────────────" >&2
  echo "${SDG_LOG_PREFIX} 세션 개선사항 전체 목록" >&2

  if command -v python3 &>/dev/null; then
    python3 - "${IMPROVEMENTS_FILE}" <<'PYEOF' >&2
import sys, json
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            mark = "☑" if obj.get("applied") else "☐"
            ts = obj.get("ts", "")[:10]
            desc = obj.get("description", "")
            print(f"  {mark} [{ts}] {desc}")
        except json.JSONDecodeError:
            print(f"  ? {line}")
PYEOF
  else
    cat "${IMPROVEMENTS_FILE}" >&2
  fi

  echo "─────────────────────────────────────────" >&2
}

# ═══════════════════════════════════════════════════════════════
# 스크립트 직접 실행 시 CLI 인터페이스
# ═══════════════════════════════════════════════════════════════
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-help}"
  shift || true

  case "$cmd" in
    record)   session_improvement_record "$@" ;;
    applied)  session_improvement_applied "$@" ;;
    check)    session_diff_check "$@" ;;
    list)     session_diff_list ;;
    help|*)
      cat >&2 <<HELP
사용법: $(basename "$0") <명령> [인자...]

  record  "개선사항 설명"   이전 세션 개선사항 기록
  applied "레이블"          개선사항 적용 확인 표시 (부분 일치)
  check   [파일명]          신규 파일 생성 전 미적용 항목 검사 (exit 0/1)
  list                      전체 개선사항 목록 출력

환경 변수:
  JARVIS_STATE_DIR     상태 디렉터리 (기본: ~/jarvis/runtime/state)
  CHECKLIST_SESSION_ID 세션 ID

개선사항 파일: ${IMPROVEMENTS_FILE}
HELP
      exit 0
      ;;
  esac
fi
