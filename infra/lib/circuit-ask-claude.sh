#!/usr/bin/env bash
# circuit-ask-claude.sh — ask-claude.sh 회로차단 (OAuth race + 연속 실패 방어)
#
# 2026-05-23 Phase 3 신설 (Compound Engineering 복원 3호).
# 출처 사고: 2026-05-23 새벽 9건 LA (mistake-extractor 등) OAuth 회전 race로
# 동시에 invalid_grant → bot-cron.sh recovery stage 4까지 다 실패 후 exit 1.
#
# 회로 상태 3종 (`${BOT_HOME}/state/circuit-ask-claude.json`):
#   closed     — 정상 (claude 호출 허용)
#   open       — 차단 (사전 skip, 즉시 exit 99로 호출자가 graceful 처리 가능)
#   half_open  — 회복 시도 1회 허용 후 결과 따라 closed/open 분기
#
# 트리거:
#   - invalid_grant / OAuth 401 감지 → open 5분
#   - consecutive_fails >= 5 → open 30분
#   - half_open 호출 성공 → closed + fails=0
#
# 동시 다발성 LA(주인님 환경 122 task)에서 안전하도록 flock으로 원자 갱신.

CIRCUIT_FILE="${BOT_HOME:-${HOME}/jarvis/runtime}/state/circuit-ask-claude.json"
CIRCUIT_LEDGER="${BOT_HOME:-${HOME}/jarvis/runtime}/ledger/circuit-ask-claude.jsonl"

mkdir -p "$(dirname "$CIRCUIT_FILE")" "$(dirname "$CIRCUIT_LEDGER")" 2>/dev/null || true

# ─── 회로 상태 읽기 ───
circuit_read() {
  if [[ ! -f "$CIRCUIT_FILE" ]]; then
    echo '{"state":"closed","consecutive_fails":0,"opened_at":0,"expires_at":0}'
    return 0
  fi
  cat "$CIRCUIT_FILE" 2>/dev/null || echo '{"state":"closed","consecutive_fails":0,"opened_at":0,"expires_at":0}'
}

# ─── 회로 상태 쓰기 (temp file + atomic rename — macOS flock 부재 환경 호환) ───
# POSIX rename은 atomic이므로 partial write 방지. 동시 다발 시 last-writer-wins이지만
# 회로 상태는 self-healing(다음 호출에서 정정)이므로 충분히 안전.
circuit_write() {
  local new_state="$1"
  local tmp="${CIRCUIT_FILE}.tmp.$$"
  echo "$new_state" > "$tmp" || return 1
  mv -f "$tmp" "$CIRCUIT_FILE"
}

# ─── ledger append ───
circuit_log() {
  local event="$1" reason="${2:-}" task_id="${3:-?}"
  jq -cn \
    --arg ts "$(date -u +%FT%TZ)" \
    --arg event "$event" \
    --arg reason "$reason" \
    --arg task "$task_id" \
    '{ts:$ts, event:$event, reason:$reason, task:$task}' \
    >> "$CIRCUIT_LEDGER" 2>/dev/null || true
}

# ─── 호출 전 검사 — return 0(허용) / 99(차단) ───
circuit_check() {
  local task_id="${1:-?}"
  local now=$(date +%s)
  local state_json=$(circuit_read)
  local state=$(echo "$state_json" | jq -r '.state // "closed"')
  local expires_at=$(echo "$state_json" | jq -r '.expires_at // 0')

  case "$state" in
    closed)
      return 0
      ;;
    open)
      if (( now >= expires_at )); then
        # 만료 → half_open 전환
        local new=$(echo "$state_json" | jq --arg now "$now" '.state = "half_open" | .expires_at = ($now|tonumber)')
        circuit_write "$new"
        circuit_log "half_open_transition" "expires_at 도달" "$task_id"
        return 0
      else
        # 차단 유지
        local remain=$(( expires_at - now ))
        echo "[circuit] open — ${remain}s 남음 (task=$task_id) — 호출 차단" >&2
        circuit_log "blocked" "open_active" "$task_id"
        return 99
      fi
      ;;
    half_open)
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

# ─── 호출 후 결과 반영 ───
circuit_update() {
  local task_id="${1:-?}"
  local exit_code="${2:-0}"
  local stderr_sample="${3:-}"
  local now=$(date +%s)
  local state_json=$(circuit_read)
  local state=$(echo "$state_json" | jq -r '.state // "closed"')
  local fails=$(echo "$state_json" | jq -r '.consecutive_fails // 0')

  if (( exit_code == 0 )); then
    # 성공 → closed + fails 리셋
    if [[ "$state" != "closed" ]] || (( fails > 0 )); then
      local new=$(echo "$state_json" | jq '.state = "closed" | .consecutive_fails = 0 | .expires_at = 0 | .opened_at = 0')
      circuit_write "$new"
      circuit_log "closed" "success after fails=$fails" "$task_id"
    fi
    return 0
  fi

  # 실패 → 분기
  fails=$(( fails + 1 ))

  # invalid_grant / 401 감지
  if echo "$stderr_sample" | grep -qE "invalid_grant|401.*Unauthorized|OAuth.*expired|authentication.*failed"; then
    local expires=$(( now + 300 ))  # 5분
    local new=$(echo "$state_json" | jq --argjson now "$now" --argjson exp "$expires" --argjson f "$fails" \
      '.state = "open" | .opened_at = $now | .expires_at = $exp | .consecutive_fails = $f | .last_reason = "invalid_grant"')
    circuit_write "$new"
    circuit_log "open" "invalid_grant 감지 — 5min lockout" "$task_id"
    echo "[circuit] OPEN — invalid_grant 감지, 5분 차단" >&2
    return 0
  fi

  # rate_limit / overload 감지
  if echo "$stderr_sample" | grep -qE "rate_limit|overload|429"; then
    local expires=$(( now + 600 ))  # 10분
    local new=$(echo "$state_json" | jq --argjson now "$now" --argjson exp "$expires" --argjson f "$fails" \
      '.state = "open" | .opened_at = $now | .expires_at = $exp | .consecutive_fails = $f | .last_reason = "rate_limit"')
    circuit_write "$new"
    circuit_log "open" "rate_limit 감지 — 10min lockout" "$task_id"
    return 0
  fi

  # 일반 실패 → 카운트만 누적
  if (( fails >= 5 )); then
    local expires=$(( now + 1800 ))  # 30분
    local new=$(echo "$state_json" | jq --argjson now "$now" --argjson exp "$expires" --argjson f "$fails" \
      '.state = "open" | .opened_at = $now | .expires_at = $exp | .consecutive_fails = $f | .last_reason = "consecutive_5"')
    circuit_write "$new"
    circuit_log "open" "consecutive 5 fails — 30min lockout" "$task_id"
    echo "[circuit] OPEN — 연속 5 실패, 30분 차단" >&2
  else
    local new=$(echo "$state_json" | jq --argjson f "$fails" '.consecutive_fails = $f')
    circuit_write "$new"
    circuit_log "fail_count" "fails=$fails" "$task_id"
  fi
}
