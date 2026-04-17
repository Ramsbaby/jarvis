#!/usr/bin/env bash
set -uo pipefail

# validate-tasks.sh — tasks.json 스키마 린터 (파일시스템 레벨)
#
# 검증 항목:
#   1. script 필드 → 파일 실제 존재 여부 (~ → $HOME 변환)
#   2. schedule 필드 → 유효한 5자리 cron expression
#   3. id 필드 → 고유성 (중복 없음)
#   4. 필수 필드(id, schedule 또는 event_trigger) 존재 여부
#   5. disabled + enabled 동시 존재 모순
#   6. script 경로에 ~ 사용 시 경고 (절대경로 권장)
#
# 종료 코드:
#   0 — 검증 통과
#   1 — 검증 실패
#
# Usage:
#   ~/jarvis/runtime/scripts/validate-tasks.sh
#   ~/jarvis/runtime/scripts/validate-tasks.sh /path/to/tasks.json

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"

# tasks.json 경로: 인자 > effective-tasks.json > tasks.json
TASKS_FILE="${1:-}"
if [[ -z "$TASKS_FILE" ]]; then
  if [[ -f "${BOT_HOME}/config/effective-tasks.json" ]]; then
    TASKS_FILE="${BOT_HOME}/config/effective-tasks.json"
  elif [[ -f "${BOT_HOME}/config/tasks.json" ]]; then
    TASKS_FILE="${BOT_HOME}/config/tasks.json"
  else
    echo "  ❌ tasks.json / effective-tasks.json 둘 다 없음"
    exit 1
  fi
fi

if [[ ! -f "$TASKS_FILE" ]]; then
  echo "  ❌ 파일 없음: $TASKS_FILE"
  exit 1
fi

ERRORS=0
WARNS=0
PASS_COUNT=0

err() {
  echo "  ❌ ERROR: $1"
  ((ERRORS++))
}

warn() {
  echo "  ⚠️  WARN: $1"
  ((WARNS++))
}

pass() {
  ((PASS_COUNT++))
}

# ── JSON 파싱 유효성 ─────────────────────────────────────────────────
if ! jq empty "$TASKS_FILE" 2>/dev/null; then
  err "JSON 파싱 실패 — 문법 오류"
  echo ""
  echo "Results: 0 passed, 1 failed, 0 warnings"
  exit 1
fi

TASK_COUNT=$(jq '.tasks | length' "$TASKS_FILE")
if [[ "$TASK_COUNT" -eq 0 ]]; then
  err "tasks 배열이 비어 있음"
  echo ""
  echo "Results: 0 passed, 1 failed, 0 warnings"
  exit 1
fi

echo "  ℹ️  대상: $(basename "$TASKS_FILE") (${TASK_COUNT}개 태스크)"

# ── 1. 필수 필드(id) 존재 여부 ────────────────────────────────────────
MISSING_ID=$(jq -r '[.tasks | to_entries[] | select(.value.id == null or .value.id == "") | .key] | join(",")' "$TASKS_FILE")
if [[ -n "$MISSING_ID" ]]; then
  err "id 필드 누락: 인덱스 [$MISSING_ID]"
else
  pass
fi

# ── 2. id 고유성 검사 ─────────────────────────────────────────────────
DUPES=$(jq -r '[.tasks[].id] | group_by(.) | map(select(length > 1)) | map(.[0]) | join(", ")' "$TASKS_FILE")
if [[ -n "$DUPES" ]]; then
  err "id 중복: $DUPES"
else
  pass
fi

# ── 3. schedule 또는 event_trigger 중 하나 필요 ───────────────────────
NO_TRIGGER=$(jq -r '.tasks[] | select(
  (.schedule == null or .schedule == "") and
  (.event_trigger == null or .event_trigger == "") and
  (.script == null or .script == "")
) | .id' "$TASKS_FILE")
if [[ -n "$NO_TRIGGER" ]]; then
  while IFS= read -r tid; do
    warn "[$tid] schedule/event_trigger/script 모두 없음 — 실행 방법 불명"
  done <<< "$NO_TRIGGER"
else
  pass
fi

# ── 4. schedule 유효성 (5자리 cron expression) ────────────────────────
# 유효한 cron 필드: *, 숫자, 숫자-숫자, */숫자, 쉼표 구분, 요일 이름
CRON_FIELD='(\*|[0-9]{1,2}(-[0-9]{1,2})?)([,]((\*|[0-9]{1,2}(-[0-9]{1,2})?))){0,}(\/[0-9]{1,2})?'
SCHEDULE_ERRORS=0

while IFS=$'\t' read -r tid schedule; do
  [[ -z "$schedule" ]] && continue

  # 필드 개수 확인 (5자리)
  field_count=$(echo "$schedule" | awk '{print NF}')
  if [[ "$field_count" -ne 5 ]]; then
    err "[$tid] schedule '$schedule' — 5자리가 아님 (${field_count}자리)"
    ((SCHEDULE_ERRORS++))
  fi
done < <(jq -r '.tasks[] | select(.schedule != null and .schedule != "") | [.id, .schedule] | @tsv' "$TASKS_FILE")

if [[ "$SCHEDULE_ERRORS" -eq 0 ]]; then
  pass
fi

# ── 5. script 파일 존재 여부 (핵심: 오늘 버그의 root cause) ─────────
SCRIPT_ERRORS=0
TILDE_WARNS=0

while IFS=$'\t' read -r tid script_path; do
  [[ -z "$script_path" ]] && continue

  # ~ → $HOME, $BOT_HOME → 실제 경로 변환 (Node.js existsSync가 못하는 것을 셸에서 수행)
  resolved="${script_path/#\~/$HOME}"
  resolved="${resolved/\$BOT_HOME/$BOT_HOME}"
  resolved="${resolved/\$\{BOT_HOME\}/$BOT_HOME}"

  # 경고: ~ 사용 시 절대경로 권장
  if [[ "$script_path" == "~"* ]]; then
    warn "[$tid] script에 '~' 사용: $script_path (절대경로 또는 \$BOT_HOME 권장)"
    ((TILDE_WARNS++))
  fi

  # 파일 존재 확인
  if [[ ! -f "$resolved" ]]; then
    err "[$tid] script 파일 없음: $script_path (resolved: $resolved)"
    ((SCRIPT_ERRORS++))
  else
    # 실행 권한 확인
    if [[ ! -x "$resolved" ]]; then
      warn "[$tid] script 실행 권한 없음: $resolved"
    fi
    pass
  fi
done < <(jq -r '.tasks[] | select(.script != null and .script != "") | select(.enabled != false) | [.id, .script] | @tsv' "$TASKS_FILE")

if [[ "$SCRIPT_ERRORS" -eq 0 && "$TILDE_WARNS" -eq 0 ]]; then
  pass
fi

# ── 6. disabled + enabled 동시 존재 모순 ──────────────────────────────
CONTRADICTIONS=$(jq -r '.tasks[] | select(
  (.disabled != null) and (.enabled != null)
) | "\(.id): disabled=\(.disabled), enabled=\(.enabled)"' "$TASKS_FILE")
if [[ -n "$CONTRADICTIONS" ]]; then
  while IFS= read -r line; do
    warn "$line — disabled/enabled 동시 존재 (하나만 사용 권장)"
  done <<< "$CONTRADICTIONS"
else
  pass
fi

# ── 7. depends 참조 유효성 ────────────────────────────────────────────
ALL_IDS=$(jq -r '[.tasks[].id] | .[]' "$TASKS_FILE")
DEPS_ERRORS=0

while IFS=$'\t' read -r tid deps_csv; do
  [[ -z "$deps_csv" ]] && continue
  for dep in $(echo "$deps_csv" | tr ',' ' '); do
    dep=$(echo "$dep" | tr -d '[:space:]"[]')
    [[ -z "$dep" ]] && continue
    if ! echo "$ALL_IDS" | grep -qx "$dep"; then
      err "[$tid] depends '$dep' — 존재하지 않는 태스크 ID"
      ((DEPS_ERRORS++))
    fi
  done
done < <(jq -r '.tasks[] | select(.depends != null and (.depends | length) > 0) | [.id, (.depends | join(","))] | @tsv' "$TASKS_FILE")

if [[ "$DEPS_ERRORS" -eq 0 ]]; then
  pass
fi

# ── 8. prompt_file 존재 여부 ──────────────────────────────────────────
PROMPT_FILE_ERRORS=0

while IFS=$'\t' read -r tid pfile; do
  [[ -z "$pfile" ]] && continue
  resolved="${BOT_HOME}/context/${pfile}"
  if [[ ! -f "$resolved" ]]; then
    warn "[$tid] prompt_file '$pfile' 없음: $resolved"
    ((PROMPT_FILE_ERRORS++))
  else
    pass
  fi
done < <(jq -r '.tasks[] | select(.prompt_file != null and .prompt_file != "") | [.id, .prompt_file] | @tsv' "$TASKS_FILE")

# ── 요약 ─────────────────────────────────────────────────────────────
echo ""
echo "  Results: $PASS_COUNT passed, $ERRORS errors, $WARNS warnings"

if [[ "$ERRORS" -gt 0 ]]; then
  echo "  ❌ 검증 실패 — $ERRORS개 오류 수정 필요"
  exit 1
fi

if [[ "$WARNS" -gt 0 ]]; then
  echo "  ⚠️  경고 있음 — 즉시 실패는 아니지만 개선 권장"
fi

echo "  ✅ 검증 통과"
exit 0