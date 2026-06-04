#!/usr/bin/env bash
# env-key-emptiness-check.sh — .env 파일 빈 값 KEY silent fail 방어
#
# 2026-05-25 신설 — 오답노트 "외부 API key 빈 문자열 silent fail 무알람" 영구 가드.
# 사고 사례: DEEPSEEK_API_KEY가 3개 .env 모두 0자 → deepseek-client.mjs 즉시 fail →
#            bot-cron.sh RECOVERY가 매시간 stage 3 다운그레이드로 우회 → 8시간+ 누구도 인지 못 함.
#            진단은 회로차단 ledger 시계열 패턴 분석으로 우연 발견.
#
# 트리거: LaunchAgent ai.jarvis.env-key-emptiness-check (매일 09:00 KST)
#
# 동작:
#   1) 검사 대상 .env 파일 4개 (~/jarvis/runtime/.env, ~/jarvis/runtime/.env, ~/jarvis-board/.env, ~/.env)
#   2) symlink 정규화로 동일 파일 중복 검사 회피
#   3) `^[A-Z][A-Z0-9_]*=$` 패턴 (값이 빈 문자열인 KEY) 추출
#   4) whitelist 제외 (env-key-emptiness-whitelist.txt 있으면 그 안의 KEY는 정상으로 인정)
#   5) 발견 시 Discord critical alert + ledger 적재
#   6) 정상이면 silent (cron 알람 spam 방지)
#
# 안전:
#   - 키 값은 절대 출력 안 함 (Iron Law 4)
#   - 빈 값 KEY 이름만 보고에 노출

set -euo pipefail

LOG="${HOME}/jarvis/runtime/logs/env-key-emptiness-check.log"
LEDGER="${HOME}/jarvis/runtime/ledger/env-key-emptiness-check.jsonl"
WHITELIST="${HOME}/jarvis/runtime/config/env-key-emptiness-whitelist.txt"

mkdir -p "$(dirname "$LEDGER")" "$(dirname "$LOG")"

log() { echo "[$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')] $*" | tee -a "${LOG}"; }
log "=== env-key-emptiness-check 시작 ==="

# ─── 검사 대상 .env (symlink 정규화 — macOS bash 3.2 호환) ───
env_paths=()
seen_reals=""
for candidate in "$HOME/jarvis/runtime/.env" "$HOME/jarvis/runtime/.env" "$HOME/jarvis/runtime/discord/.env" "$HOME/jarvis-board/.env" "$HOME/.env"; do
  [ -f "$candidate" ] || continue
  # realpath 표준 — macOS coreutils 부재 시 python3 fallback
  if command -v realpath >/dev/null 2>&1; then
    real=$(realpath "$candidate")
  else
    real=$(python3 -c "import os, sys; print(os.path.realpath(sys.argv[1]))" "$candidate" 2>/dev/null || echo "$candidate")
  fi
  # 중복 체크: 일반 변수에 newline 구분으로 누적
  if ! echo "$seen_reals" | grep -qFx "$real"; then
    seen_reals="${seen_reals}${real}
"
    env_paths+=("$candidate")
  fi
done

log "검사 대상 (symlink 정규화 후): ${#env_paths[@]}개"

# ─── whitelist 로드 (있으면) ───
whitelist_keys=""
if [ -f "$WHITELIST" ]; then
  whitelist_keys=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$WHITELIST" 2>/dev/null | tr '\n' '|' | sed 's/|$//')
fi

# ─── 검사 ───
empty_keys_total=0
declare -a findings
for env_file in "${env_paths[@]}"; do
  empties=$(grep -E "^[A-Z][A-Z0-9_]*=$" "$env_file" 2>/dev/null | cut -d= -f1 || true)
  [ -z "$empties" ] && continue
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    # whitelist 매칭
    if [ -n "$whitelist_keys" ] && echo "$key" | grep -qE "^(${whitelist_keys})$"; then
      continue
    fi
    findings+=("$(basename $(dirname "$env_file"))/$(basename "$env_file"):${key}")
    empty_keys_total=$((empty_keys_total + 1))
  done <<< "$empties"
done

# ─── 판정 + 출력 ───
if (( empty_keys_total == 0 )); then
  log "✅ 빈 값 KEY 0건 — 정상"
  jq -cn \
    --arg ts "$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')" \
    --argjson scanned "${#env_paths[@]}" \
    --argjson empty 0 \
    --arg status "ok" \
    '{ts:$ts, scanned_files:$scanned, empty_keys:$empty, status:$status, findings:[]}' \
    >> "$LEDGER"
  log "=== env-key-emptiness-check 종료 ==="
  exit 0
fi

log "🚨 빈 값 KEY ${empty_keys_total}건 발견"
for finding in "${findings[@]}"; do
  log "  • $finding"
done

# ─── ledger 적재 ───
findings_json=$(printf '%s\n' "${findings[@]}" | jq -R . | jq -sc .)
jq -cn \
  --arg ts "$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')" \
  --argjson scanned "${#env_paths[@]}" \
  --argjson empty "$empty_keys_total" \
  --arg status "critical" \
  --argjson findings "$findings_json" \
  '{ts:$ts, scanned_files:$scanned, empty_keys:$empty, status:$status, findings:$findings}' \
  >> "$LEDGER"

# ─── Discord critical alert ───
ALERT_SCRIPT="${HOME}/jarvis/runtime/scripts/alert.sh"
if [ -x "$ALERT_SCRIPT" ]; then
  title="🚨 .env 빈 값 KEY ${empty_keys_total}건 (silent fail 위험)"
  detail="검사 ${#env_paths[@]}개 파일 중 빈 값 KEY ${empty_keys_total}건 발견. 외부 API silent fail 가능 — 즉시 채우거나 의도적 빈 값이면 whitelist 등재. 상세: ${LEDGER}"
  bash "$ALERT_SCRIPT" critical "$title" "$detail" 2>&1 | tee -a "$LOG" || true
fi

log "=== env-key-emptiness-check 종료 ==="
exit 0
