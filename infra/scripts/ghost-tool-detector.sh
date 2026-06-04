#!/usr/bin/env bash
# ghost-tool-detector.sh — 자비스 stub/ghost 도구 자동 감지
#
# 2026-05-23 Phase 2 신설 (rule-hook 매핑 시스템 2호 hook).
# 트리거: LaunchAgent ai.jarvis.ghost-tool-detector (매주 월요일 03:35 KST)
#
# 사고 사례 (learned-mistakes.md 2026-05-23 메타 결함):
#   audit-la-cron-dry.sh가 2026-04-20 stub(exit 0)으로 대체 후 5주간 방치.
#   자비스 LA-cron 정합성 감사 무능 상태 → 84건 정리 위기로 이어짐.
#
# 감지 기준:
#   1) ~/jarvis/infra/scripts/*.sh, ~/jarvis/runtime/scripts/*.sh
#   2) line count < 5 (실질 내용 없음)
#   3) exec 권한 있음
#   4) mtime 7일 이상 미변경 (긴급 임시 stub은 제외)
#   5) 내용에 'STUB|exit 0$|no-op' 패턴 포함
#
# 동작: 발견 시 Discord critical + ledger 기록 + 30일 이상 stub은 graveyard 자동 이동 권고
set -euo pipefail

LOG="${HOME}/jarvis/runtime/logs/ghost-tool-detector.log"
LEDGER="${HOME}/jarvis/runtime/ledger/ghost-tool-detector.jsonl"
ALERT="${HOME}/jarvis/runtime/scripts/alert.sh"
GRAVEYARD="${HOME}/jarvis/runtime/state/.graveyard"

mkdir -p "$(dirname "${LEDGER}")" "${GRAVEYARD}"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*" | tee -a "${LOG}"; }
log "=== ghost-tool-detector 시작 ==="

# 1) 후보 디렉토리 스캔
SEARCH_DIRS=(
  "${HOME}/jarvis/infra/scripts"
  "${HOME}/jarvis/runtime/scripts"
  "${HOME}/jarvis/infra/bin"
)

DETECTED=0
> /tmp/ghost-tools-detail.txt

for dir in "${SEARCH_DIRS[@]}"; do
  [[ ! -d "$dir" ]] && continue
  while IFS= read -r script; do
    # 기본 필터
    [[ ! -x "$script" ]] && continue
    line_count=$(wc -l < "$script" | tr -d ' ')
    (( line_count >= 5 )) && continue

    # 7일 이상 변경 없음
    if [[ "$(uname)" == "Darwin" ]]; then
      mtime_epoch=$(stat -f %m "$script")
    else
      mtime_epoch=$(stat -c %Y "$script")
    fi
    now_epoch=$(date +%s)
    age_days=$(( (now_epoch - mtime_epoch) / 86400 ))
    (( age_days < 7 )) && continue

    # STUB/no-op 패턴 검사
    if grep -qE "STUB|no-op|exit 0$|placeholder" "$script" 2>/dev/null; then
      DETECTED=$((DETECTED + 1))
      echo "GHOST ${script} (${line_count}줄, ${age_days}일 미변경)" >> /tmp/ghost-tools-detail.txt
      log "🚨 GHOST 발견: ${script} (${line_count}줄, ${age_days}일 미변경)"
    fi
  done < <(find "$dir" -maxdepth 1 -type f -name "*.sh" 2>/dev/null)
done

log "총 GHOST 도구: ${DETECTED}건"

# 2) ledger 기록
printf '{"ts":"%s","detected":%d}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${DETECTED}" \
  >> "${LEDGER}"

# 3) 판정 + 알림
if (( DETECTED > 0 )); then
  DETAIL_FIRST=$(head -5 /tmp/ghost-tools-detail.txt | tr '\n' ' | ')
  if [[ -x "${ALERT}" ]]; then
    bash "${ALERT}" critical \
      "🚨 자비스 GHOST 도구 ${DETECTED}건 발견" \
      "stub/no-op 상태로 7일 이상 방치된 도구. 메타 결함의 직접 원인. 상세: ${DETAIL_FIRST}" \
      2>&1 | tee -a "${LOG}"
  fi
else
  log "✅ ghost 도구 0건 (정상)"
fi

log "=== ghost-tool-detector 종료 ==="
exit 0
