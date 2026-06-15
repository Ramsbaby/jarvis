#!/usr/bin/env bash
# rule-hook-coverage-audit.sh — 룰 ↔ Hook 매핑 갭 측정
#
# 2026-05-23 Phase 2 신설: 자비스 오답노트 2,265건 누적인데 코드 hook 매핑 0%.
# 룰은 텍스트로만 존재 → LLM 자가검열에 100% 의존 → 일 72건 재발의 직접 원인.
#
# 역할: learned-mistakes.md의 각 entry에 hook 매핑이 있는지 + 매핑된 hook이
#       실제 작동하는지 측정. 갭 발견 시 Discord critical.
#
# 5번째 필드 표준:
#   - **hook**: `<pattern type>` <regex or grep pattern>
#   - 예: **hook**: `response-grep` /완료하였습니다.*(?!검증)/
#   - 예: **hook**: `pre-tool` Agent 위임 직후 표본 검증 누락 감지
#   - 예: **hook**: `n/a` (LLM 자가검열만)
#
# 출력:
#   - severity=info: 정상 (전체 매핑 비율 ≥ 30%, 점진 개선 중)
#   - severity=warning: 매핑 비율 < 30% (현재 0%)
#   - severity=critical: 매핑 있다는데 hook 코드 실제 부재 (false-positive 매핑)
set -euo pipefail

LOG="${HOME}/jarvis/runtime/logs/rule-hook-coverage-audit.log"
RULES_MD="${HOME}/jarvis/runtime/wiki/meta/learned-mistakes.md"
HOOKS_DIR="${HOME}/.claude/hooks"
JARVIS_BIN="${HOME}/jarvis/infra/scripts"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*" | tee -a "${LOG}"; }
log "=== rule-hook-coverage-audit 시작 ==="

# 1) 총 룰 카운트
TOTAL=$(grep -c "^## " "${RULES_MD}" 2>/dev/null || true)
TOTAL=${TOTAL:-0}
log "총 룰 entry: ${TOTAL}건"

# 2) 4필드 표준 준수 카운트
F_PATTERN=$(grep -c "^- \*\*패턴\*\*:" "${RULES_MD}" 2>/dev/null || true)
F_ACTUAL=$(grep -c "^- \*\*실제\*\*:" "${RULES_MD}" 2>/dev/null || true)
F_EVIDENCE=$(grep -c "^- \*\*증거\*\*:" "${RULES_MD}" 2>/dev/null || true)
F_RESPONSE=$(grep -c "^- \*\*대응\*\*:" "${RULES_MD}" 2>/dev/null || true)
log "4필드 준수: 패턴=${F_PATTERN} 실제=${F_ACTUAL} 증거=${F_EVIDENCE} 대응=${F_RESPONSE}"

# 3) hook 매핑 필드 보유 카운트 (5번째 필드)
F_HOOK=$(grep -cE "^- \*\*hook\*\*:|^- \*\*Hook\*\*:" "${RULES_MD}" 2>/dev/null || true)
COVERAGE_PCT=0
if (( TOTAL > 0 )); then
  COVERAGE_PCT=$((F_HOOK * 100 / TOTAL))
fi
log "hook 매핑 필드: ${F_HOOK}/${TOTAL} (${COVERAGE_PCT}%)"

# 4) hook 매핑이 있는 entry에서 매핑 pattern 추출 + 실제 hook 존재 여부 검증
MAPPED_VALID=0
MAPPED_GHOST=0  # 매핑은 있는데 실제 hook 없음 (false-positive)
if (( F_HOOK > 0 )); then
  log "--- 매핑 유효성 검증 시작 ---"
  while IFS= read -r line; do
    # 매핑 pattern 추출 (backtick 안의 type, 또는 자유 텍스트)
    # 2026-06-12 수정: 백틱 없는 hook 표기(자유 텍스트 경로)에서 grep 실패 → pipefail+set -e 즉사.
    #   5/23 이후 매주 이 지점에서 침묵 사망 = ledger 3주 공백의 근본 원인. || true로 생존 보장.
    hook_type=$(echo "$line" | grep -oE "\`[a-z-]+\`" | head -1 | tr -d '`' || true)
    if [[ -z "$hook_type" || "$hook_type" == "n/a" ]]; then
      continue
    fi
    # hook_type별 hook 디렉토리 검사
    if ls "${HOOKS_DIR}"/${hook_type}*.sh 2>/dev/null | head -1 > /dev/null \
       || ls "${JARVIS_BIN}"/${hook_type}*.sh 2>/dev/null | head -1 > /dev/null; then
      MAPPED_VALID=$((MAPPED_VALID + 1))
    else
      MAPPED_GHOST=$((MAPPED_GHOST + 1))
      log "  GHOST 매핑: '$line' → hook type '$hook_type' 코드 부재"
    fi
  done < <(grep -E "^- \*\*hook\*\*:|^- \*\*Hook\*\*:" "${RULES_MD}")
fi
log "매핑 유효: ${MAPPED_VALID}, 매핑 GHOST (코드 부재): ${MAPPED_GHOST}"

# 5) 활성 hook 인벤토리
ACTIVE_HOOKS=$(ls "${HOOKS_DIR}"/*.sh 2>/dev/null | grep -v "\.bak" | wc -l | tr -d ' ')
log "활성 hook (~/.claude/hooks/): ${ACTIVE_HOOKS}건"

# 6) 판정 + 알림
SEVERITY="info"
TITLE="✅ Rule-Hook 매핑 정상"
DETAIL="총 ${TOTAL}건 룰, hook 매핑 ${F_HOOK}건 (${COVERAGE_PCT}%), 활성 hook ${ACTIVE_HOOKS}건"

if (( MAPPED_GHOST > 0 )); then
  SEVERITY="critical"
  TITLE="🚨 Rule-Hook 매핑 GHOST 발견"
  DETAIL="${MAPPED_GHOST}건 룰이 hook 매핑은 표기됐으나 실제 hook 코드 부재. false-positive 매핑은 학습 사이클 파괴."
elif (( COVERAGE_PCT < 30 )); then
  SEVERITY="warning"
  TITLE="⚠️ Rule-Hook 매핑 갭 ${COVERAGE_PCT}%"
  DETAIL="총 ${TOTAL}건 룰 중 hook 매핑 ${F_HOOK}건 (${COVERAGE_PCT}%). 목표 30%↑. Compound Engineering 사이클 강화 필요."
fi

log "판정: severity=${SEVERITY} ${TITLE}"
log "상세: ${DETAIL}"

# 7) Discord 알림 (warning/critical만)
if [[ "${SEVERITY}" != "info" ]]; then
  ALERT="${HOME}/jarvis/runtime/scripts/alert.sh"
  if [[ -x "${ALERT}" ]]; then
    bash "${ALERT}" "${SEVERITY}" "${TITLE}" "${DETAIL}" 2>&1 | tee -a "${LOG}"
  fi
fi

# 8) 결과 ledger 저장 (시계열 추세 관측용)
LEDGER="${HOME}/jarvis/runtime/ledger/rule-hook-coverage.jsonl"
mkdir -p "$(dirname "${LEDGER}")"
printf '{"ts":"%s","total":%d,"hook_mapped":%d,"coverage_pct":%d,"mapped_valid":%d,"mapped_ghost":%d,"active_hooks":%d,"severity":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${TOTAL}" "${F_HOOK}" "${COVERAGE_PCT}" "${MAPPED_VALID}" "${MAPPED_GHOST}" "${ACTIVE_HOOKS}" "${SEVERITY}" \
  >> "${LEDGER}"
log "ledger 기록 완료"

log "=== rule-hook-coverage-audit 종료 ==="
exit 0
