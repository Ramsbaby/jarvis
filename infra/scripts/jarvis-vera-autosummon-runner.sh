#!/usr/bin/env bash
set -uo pipefail
# ==============================================================================
# jarvis-vera-autosummon-runner.sh — VERA 자동 소환 백그라운드 러너
# ------------------------------------------------------------------------------
# 무엇인가:
#   Stop 훅(stop-vera-autosummon.sh)이 "고위험 완료선언 + 실측도구 0건"을 감지하면
#   이 스크립트를 detached 백그라운드로 띄운다. 여기서 VERA 본체
#   (jarvis-verify-independent.sh)를 소환해 그 완료 주장을 격리 실측 검증하고,
#   판정을 vera-auto.jsonl 원장에 append한다. REFUTED면 다음 턴 Stop 훅이
#   이 원장을 읽어 stderr 경고를 주입한다.
#
# 왜 별도 파일인가:
#   VERA(=haiku)는 호출당 ~20~46초. Stop 훅은 timeout 5초라 동기 실행 불가.
#   훅은 이 러너를 nohup 백그라운드로 던지고 즉시 반환한다(비차단).
#
# 재귀 방지 (BLOCKING):
#   JARVIS_VERA_RUNNING=1 을 export 한다. 하위 claude(ask-claude → claude -p)가
#   혹시 Stop 훅을 재실행하더라도 이 env가 있으면 훅이 즉시 exit 0 한다.
#   (배치 모드 --setting-sources "" 로 훅 미로드가 1차 방어, 이 env가 2차 방어.)
#
# 사용법 (훅이 내부 호출 — 사람이 직접 부를 일 없음):
#   jarvis-vera-autosummon-runner.sh <SUMMON_ID> <SESSION_ID> <CLAIM> [CONTEXT]
#
# 원장: ~/jarvis/runtime/ledger/vera-auto.jsonl (append-only)
#   {ts, event:"verdict", summon_id, session_id, verdict, exit_code, claim, evidence}
# ==============================================================================

export HOME="${HOME:-$(eval echo ~"$(whoami)")}"
export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin"

# --- 재귀 가드 (2차 방어): 하위 claude 가 이 env 를 상속 ---
export JARVIS_VERA_RUNNING=1

SUMMON_ID="${1:?SUMMON_ID required}"
SESSION_ID="${2:?SESSION_ID required}"
CLAIM="${3:?CLAIM required}"
CONTEXT="${4:-}"

VERA="${HOME}/jarvis/infra/scripts/jarvis-verify-independent.sh"
LEDGER="${HOME}/jarvis/runtime/ledger/vera-auto.jsonl"
STATE_DIR="${HOME}/.jarvis/state/vera-auto"
LOCK="${STATE_DIR}/inflight-${SESSION_ID}.lock"

mkdir -p "$STATE_DIR" "$(dirname "$LEDGER")" 2>/dev/null || true

# 인플라이트 락 해제는 무슨 일이 있어도 (락이 남으면 세션 내 재소환 영구 차단됨)
trap 'rm -f "$LOCK" 2>/dev/null || true' EXIT

# --- VERA 본체 소환 (격리 실측 검증) ---
EXIT_CODE=0
OUT=""
if [[ -x "$VERA" ]]; then
  # 비용 캡: 자동소환은 결정론 실측(파일 존재·exit code·grep)만 필요 → 저비용 haiku 고정.
  # (VERA 기본 모델이 sonnet-5 로 드리프트해도 자동소환은 항상 haiku 로 저렴하게.)
  OUT=$("$VERA" "$CLAIM" --context "$CONTEXT" --task-id vera-auto \
        --model claude-haiku-4-5-20251001 --timeout 120 --budget 0.30 2>/dev/null) || EXIT_CODE=$?
else
  EXIT_CODE=127
fi

# --- exit code → 판정 매핑 (VERA 규약: 0=CONFIRMED 3=REFUTED 4=UNCERTAIN 1=VERIFY_FAILED) ---
case "$EXIT_CODE" in
  0) VERDICT="CONFIRMED" ;;
  3) VERDICT="REFUTED" ;;
  4) VERDICT="UNCERTAIN" ;;
  1) VERDICT="VERIFY_FAILED" ;;
  *) VERDICT="ERROR" ;;
esac

# --- 근거 발췌 (VERA 사람용 출력에서 판정 줄 부근) ---
EVIDENCE=$(printf '%s\n' "$OUT" | grep -iE 'EVIDENCE|판정|VERDICT' | head -3 | tr '\n' ' ' | head -c 500 || true)
[[ -z "$EVIDENCE" ]] && EVIDENCE=$(printf '%s' "$OUT" | head -c 300)

CLAIM_TRUNC=$(printf '%s' "$CLAIM" | head -c 400)

# --- 원장 기록 (append-only) ---
jq -cn \
  --arg ts "$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')" \
  --arg event "verdict" \
  --arg summon_id "$SUMMON_ID" \
  --arg session_id "$SESSION_ID" \
  --arg verdict "$VERDICT" \
  --argjson exit_code "$EXIT_CODE" \
  --arg claim "$CLAIM_TRUNC" \
  --arg evidence "$EVIDENCE" \
  '{ts:$ts, event:$event, summon_id:$summon_id, session_id:$session_id,
    verdict:$verdict, exit_code:$exit_code, claim:$claim, evidence:$evidence}' \
  >> "$LEDGER" 2>/dev/null || true

exit 0
