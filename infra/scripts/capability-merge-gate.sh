#!/usr/bin/env bash
# capability-merge-gate.sh — 능력 머지 게이트 (JARVIS-EVOLUTION-PROGRAM.md 산출물 2)
#
# Why 1줄: 자비스가 자기 완료를 자기가 채점하지 못하게 — 능력 PR/기능 머지 전 4조건을 강제한다.
#          2026-07-22 proactive "근본수정" 자가선언이 반쪽(불안정 키)이었고 독립감사가 CRITICAL 적발.
#          자기검증이었으면 통과됐을 것 → 게이트④(독립검증)가 존재 이유.
#
# 4조건:
#   ① 가역성 분류   비가역(외부송출·삭제·visibility·결제·크론일괄) → 주인님 결재 (사람 확인)
#   ② 원장 등재     변경을 append-only 원장에 기록 (사람 확인)
#   ③ 안정키 상태   변경 파일에 휘발성 키 패턴(md5(timestamp/전체라인)) 없어야 함 (자동 grep)
#   ④ 독립 검증     independent-verify.jsonl에 이 변경의 verdict=CONFIRMED 존재해야 함 (자동)
#                   ⚠️ 이 원장 판정값은 CONFIRMED/REFUTED/UNCERTAIN/VERIFY_FAILED — "PASS" 아님(감사 B1).
#
# 사용:
#   capability-merge-gate.sh <change-id> [changed-file ...]
#     change-id : 이 변경을 식별하는 토큰. independent-verify.jsonl의 task/claim에 이 토큰이 있어야 통과.
#
# 종료코드: 0=통과 / 2=차단(게이트 실패) / 3=사용법 오류
#   (precheck-dangerous.sh와 동일하게 exit 2를 "차단" 관례로 사용)

set -euo pipefail

LEDGER_DIR="${HOME}/jarvis/runtime/ledger"
IV_LEDGER="${LEDGER_DIR}/independent-verify.jsonl"
GATE_LEDGER="${LEDGER_DIR}/capability-merge-gate.jsonl"
TS_ISO="$(TZ=Asia/Seoul date +%Y-%m-%dT%H:%M:%S%z)"
mkdir -p "$LEDGER_DIR"

log() { echo "[$(TZ=Asia/Seoul date '+%H:%M:%S')] $*"; }

CHANGE_ID="${1:-}"
if [[ -z "$CHANGE_ID" ]]; then
  echo "Usage: $0 <change-id> [changed-file ...]" >&2
  exit 3
fi
shift || true
CHANGED_FILES=("$@")

FAIL=0
declare -a REASONS=()

# ── ③ 안정키 상태 — 변경 파일에 휘발성 키 패턴 grep (자동) ──────────────
# 휘발성 키 = 시간/타임스탬프/전체라인을 해시 입력에 넣는 dedup 키 (감사 R1 유형).
if (( ${#CHANGED_FILES[@]} > 0 )); then
  VOLATILE_HITS=""
  for f in "${CHANGED_FILES[@]}"; do
    [[ -f "$f" ]] || continue
    # md5/sha 해시 입력에 date/time/strftime/now/timestamp/전체 line이 섞인 라인
    hits="$(grep -nE '(md5|sha1|sha256|hexdigest)\(.*(date|time|now|strftime|timestamp|\bline\b)' "$f" 2>/dev/null || true)"
    if [[ -n "$hits" ]]; then
      VOLATILE_HITS+="$f:"$'\n'"$hits"$'\n'
    fi
  done
  if [[ -n "$VOLATILE_HITS" ]]; then
    FAIL=1
    REASONS+=("③ 안정키 위반: 휘발성 값이 dedup 키 해시 입력에 포함(감사 R1 유형)")
    log "❌ ③ 안정키 — 휘발성 키 패턴 발견:"
    printf '%s\n' "$VOLATILE_HITS" >&2
  else
    log "✅ ③ 안정키 — 변경 파일에 휘발성 키 패턴 없음"
  fi
else
  log "⚠️ ③ 안정키 — 변경 파일 미지정(grep 생략). 파일을 인자로 넘기면 자동 검사됨"
fi

# ── ④ 독립 검증 — independent-verify.jsonl에 CONFIRMED 존재? (자동) ──────
if [[ ! -f "$IV_LEDGER" ]]; then
  FAIL=1
  REASONS+=("④ 독립검증 원장 부재: $IV_LEDGER — VERA(/verify) 미실행")
  log "❌ ④ 독립검증 — 원장 파일 없음"
else
  # verdict=CONFIRMED 이고 task 또는 claim 에 change-id 토큰이 포함된 레코드 존재?
  CONFIRMED_HIT="$(grep -F "$CHANGE_ID" "$IV_LEDGER" 2>/dev/null | grep '"verdict":"CONFIRMED"' | tail -1 || true)"
  if [[ -n "$CONFIRMED_HIT" ]]; then
    log "✅ ④ 독립검증 — CONFIRMED 레코드 존재 (change-id=$CHANGE_ID)"
  else
    FAIL=1
    REASONS+=("④ 독립검증 미통과: '$CHANGE_ID' 관련 verdict=CONFIRMED 레코드 없음. VERA/verify로 CONFIRMED 받을 것 (PASS 아님)")
    log "❌ ④ 독립검증 — CONFIRMED 레코드 없음 (change-id=$CHANGE_ID)"
  fi
fi

# ── ①② 사람 확인 (BLOCKING 체크리스트 — 자동 판정 불가, 반드시 눈으로) ──
cat >&2 <<'CHECKLIST'

── ①② 사람 확인 필수 (BLOCKING) ─────────────────────────────
 ① 가역성 분류: 이 변경이 비가역(외부송출·삭제·repo visibility·결제·크론 일괄)인가?
    → 비가역이면 주인님 결재 없이 머지 금지 (Iron Law 3).
 ② 원장 등재: 변경을 append-only 원장에 기록했는가? (누가·무엇·왜·롤백 경로)
    → policy-fix-disable / disable-plist-with-ledger.sh 패턴.
─────────────────────────────────────────────────────────────
CHECKLIST

# ── 게이트 판정 원장 기록 (append-only) ─────────────────────────────────
if [[ "$FAIL" -eq 0 ]]; then verdict_str="pass"; else verdict_str="block"; fi
reason_join="$(printf '%s; ' "${REASONS[@]:-}")"
printf '{"ts":"%s","change_id":"%s","auto_verdict":"%s","reasons":"%s","files":%d}\n' \
  "$TS_ISO" "$CHANGE_ID" "$verdict_str" "${reason_join%; }" "${#CHANGED_FILES[@]}" >> "$GATE_LEDGER"

if [[ "$FAIL" -ne 0 ]]; then
  echo "" >&2
  log "🚫 MERGE 차단 — 자동 게이트(③④) 미통과:"
  for r in "${REASONS[@]}"; do echo "   - $r" >&2; done
  exit 2
fi

log "✅ 자동 게이트(③④) 통과. ①② 사람 확인 후 머지 진행."
exit 0
