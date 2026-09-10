#!/usr/bin/env bash
# ssot-blocking-sync-audit.sh — 표면 간 규칙 문장 누락 감시
#
# 2026-08-14 전면 재작성.
#   옛 방식: 'BLOCKING' 이라는 단어가 붙은 절 제목을 세어 양쪽 개수를 비교했다.
#   실패한 이유 두 겹 —
#     ① 읽던 파일 jarvis-core.md 가 2026-08-02 삭제됐는데 경로가 그대로였다 (입력 상실)
#     ② 'BLOCKING' 표기 규칙 자체가 양쪽에서 사라져, 경로를 고쳐도 양쪽 0개 → 격차 영구 0
#   그 결과 "GAP 검출: 0건"을 로그에 찍은 뒤 jq 오류로 죽었다. 로그만 보면 건강해 보이는
#   거짓 합격이었고, 그래서 '쉽게 써라'가 넉 달간 사라진 것을 아무도 통보받지 못했다.
#
#   새 방식: infra/config/rule-covenant.json 에 등재된 문장이 각 표면에 실재하는지 본다.
#            개수가 아니라 문장 자체를 찾으므로, 표기 규칙이 바뀌어도 눈이 멀지 않는다.
#
# 출력 계약은 그대로 유지한다 (LaunchAgent·원장 형식 불변):
#   runtime/ledger/ssot-blocking-sync-audit.jsonl 에 한 줄 append, gap_count>0 이면 alert.sh critical

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

COVENANT="${HOME}/.openclaw-data/jarvis/infra/config/rule-covenant.json"
LEDGER="${HOME}/.openclaw-data/jarvis/runtime/ledger/ssot-blocking-sync-audit.jsonl"
LOG="${HOME}/.openclaw-data/jarvis/runtime/logs/ssot-blocking-sync-audit.log"

mkdir -p "$(dirname "$LEDGER")" "$(dirname "$LOG")"
log() { echo "[$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')] $*" | tee -a "${LOG}"; }

log "=== ssot-blocking-sync-audit 시작 ==="

if [ ! -f "$COVENANT" ]; then
  log "치명: 언약 파일 없음 — $COVENANT"
  log "  감시기가 입력을 잃으면 조용히 통과하지 않는다. 종료코드 1로 실패를 남긴다."
  exit 1
fi

# 표면 경로 해석 (~ 확장)
resolve() { echo "$1" | sed "s|^~|${HOME}|"; }

gaps=()
checked=0

# 언약 항목을 한 줄 TSV 로 뽑는다: id \t 문장 \t 적용표면(쉼표)
while IFS=$'\t' read -r cid sentence targets; do
  [ -z "$cid" ] && continue
  for surf in ${targets//,/ }; do
    path_raw=$(jq -r --arg s "$surf" '.surfaces[$s] // empty' "$COVENANT")
    [ -z "$path_raw" ] && { gaps+=("${cid}: 표면 '${surf}' 경로 미등재"); continue; }
    path=$(resolve "$path_raw")
    checked=$((checked+1))
    if [ ! -f "$path" ]; then
      gaps+=("${cid}: ${surf} 파일 없음 (${path_raw})")
      continue
    fi
    if ! grep -qF -- "$sentence" "$path"; then
      gaps+=("${cid}: ${surf} 에 없음 — \"${sentence}\"")
    fi
  done
done < <(jq -r '.covenant[] | [.id, .["문장"], (.["적용"] | join(","))] | @tsv' "$COVENANT")

gap_count=${#gaps[@]}
log "언약 문장 검사: ${checked}건 확인 / 누락 ${gap_count}건"

# 0건 검사는 통과가 아니라 실패다.
# 옛 감시기가 정확히 이 상태로 "GAP 0건"을 찍으며 넉 달을 침묵했다.
if (( checked == 0 )); then
  log "치명: 한 건도 검사하지 못했다 — 언약 파일을 못 읽었거나 비어 있다."
  log "  이 상태를 '이상 없음'으로 기록하지 않는다. 종료코드 1."
  jq -cn --arg ts "$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')" \
    '{ts:$ts, checked:0, gap_count:-1, status:"broken", gaps:["감시기가 입력을 읽지 못함"]}' >> "$LEDGER"
  exit 1
fi

if (( gap_count > 0 )); then
  for g in "${gaps[@]}"; do log "  ✗ $g"; done
else
  log "  전부 실재 — 표면 간 누락 없음"
fi

# ─── 원장 적재 (형식 불변) ───
gaps_json=$(printf '%s\n' "${gaps[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')
status="ok"; (( gap_count > 0 )) && status="critical"

jq -cn \
  --arg ts "$(TZ=Asia/Seoul date '+%Y-%m-%dT%H:%M:%S%z')" \
  --argjson checked "$checked" \
  --argjson gaps "$gap_count" \
  --arg status "$status" \
  --argjson gap_list "$gaps_json" \
  '{ts:$ts, checked:$checked, gap_count:$gaps, status:$status, gaps:$gap_list}' \
  >> "$LEDGER"

# ─── 경보 (누락 시에만) ───
if (( gap_count > 0 )); then
  ALERT_SCRIPT="${HOME}/.openclaw-data/jarvis/runtime/scripts/alert.sh"
  if [ -x "$ALERT_SCRIPT" ]; then
    title="🚨 규칙 문장 누락 ${gap_count}건 — 표면 간 동기화 깨짐"
    detail="언약(rule-covenant.json)에 등재된 문장이 일부 표면에서 사라졌습니다. 상세: ${LEDGER}"
    bash "$ALERT_SCRIPT" critical "$title" "$detail" 2>&1 | tee -a "$LOG" || true
  else
    log "  경보 스크립트 없음 — $ALERT_SCRIPT"
  fi
fi

log "=== 완료 (누락 ${gap_count}건) ==="
exit 0
