#!/usr/bin/env bash

# [오픈클로 이식 2026-09-10] P — 스케줄 등록 정합성 감사는 오픈클로가 대체. 자비스 크론이 비면 존재 이유도 소멸
# 재개: rm ~/.openclaw-data/runtime/state/stopped/cron-registration-gap-check
if [[ -f "${HOME}/.openclaw-data/runtime/state/stopped/cron-registration-gap-check" ]] && [[ "${OPENCLAW_JOB:-}" != "1" ]]; then
    echo "[cron-registration-gap-check] 중지 플래그 있음"
    exit 0
fi

# cron-registration-gap-check.sh — 감시류 스크립트 crontab/tasks.json 등록 공백 주간 점검
#
# cl-ca6f13767447d65a: 감시 스크립트 크론 미등록으로 월 단위 무감지 (최근 7일 재발 2건)
#
# 목적: infra/scripts(및 심링크 runtime/scripts) 안의 감시·검사류 스크립트
#       (*-monitor.sh, *-check.sh, *-watch.sh, *-watcher.sh, *-audit.sh, *-auditor.sh)를
#       전수 스캔해 실제 crontab -l 과 tasks.json 어디에도 등록되지 않은 "고아" 스크립트를
#       매주 리포트한다. gen-inventory.sh(자산 목록 생성)와 cron-auditor.sh(등록된 것의
#       건강 점검)는 있었지만 "존재하지만 아무 데도 등록 안 된 것"을 잡는 층은 없었다 —
#       이 공백이 반복 재발의 원인.
#
# 등록 판정: crontab -l 원문 또는 tasks.json 원문(문자열 전체 — script 필드·prompt 내
#            bash 호출 모두 포함) 어딘가에 스크립트 basename이 나타나면 "등록됨"으로 간주.
#
# bash 3.2 주의: macOS 기본 /bin/bash는 3.2라 declare -A(연관 배열)를 지원하지 않고,
#   set -u 상태에서 빈 인덱스 배열을 "${arr[@]}"로 펼치면 "unbound variable"로 죽는다
#   (cron-auditor.sh가 배열 대신 임시 파일로 카운트를 세는 이유와 동일). 그래서 이 스크립트는
#   set -u를 쓰지 않고, 배열 확장 전에 항상 개수를 먼저 확인한다.
#
# 실행: 항상 exit 0 (감시 스크립트 자신이 죽어서 감시 공백을 만드는 사태 방지).
#       공백 발견 시에만 discord_route info로 보고한다 (매주 소음 방지).
#
# crontab 등록: 0 6 * * 1 /bin/bash /Users/ramsbaby/.openclaw-data/runtime/scripts/cron-registration-gap-check.sh >> /Users/ramsbaby/.openclaw-data/runtime/logs/cron-registration-gap-check.log 2>&1

set -o pipefail

# JARVIS_HOME을 env에서 그대로 믿지 않는다: 이 셸 환경에 실측된 사례로,
# JARVIS_HOME이 ~/.jarvis(=~/.openclaw-data/runtime 심링크)로 오염되어 있으면
# "$JARVIS_HOME/infra/scripts"·"$JARVIS_RUNTIME/scripts"가 각각
# 존재하지 않는 경로/runtime/runtime 그림자 폴더로 풀려 tasks.json도
# 그림자 사본(구버전)을 읽는 조용한 오탐이 난다 — compat.sh가 이미 경고한
# 루트/런타임 혼동과 동일 계열의 문제. 대신 이 스크립트 자신의 실제
# 디스크 위치(심링크 관통 후 물리 경로)에서 두 단계 위를 저장소 루트로 삼는다.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
JARVIS_HOME="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd -P)"
JARVIS_RUNTIME="${JARVIS_RUNTIME:-${BOT_HOME:-$HOME/.openclaw-data/runtime}}"  # 회차8: 런타임은 코드 루트 밑이 아니다
[[ -z "$JARVIS_HOME" ]] && JARVIS_HOME="$HOME/projects/jarvis"
BOT_HOME="${BOT_HOME:-$JARVIS_RUNTIME}"
TASKS_JSON="${BOT_HOME}/config/tasks.json"
LOG_DIR="${BOT_HOME}/logs"
REPORT_FILE="${LOG_DIR}/cron-registration-gap-check-$(date '+%Y%m%d').jsonl"

mkdir -p "$LOG_DIR" 2>/dev/null || true

# shellcheck source=/dev/null
source "$JARVIS_HOME/infra/lib/discord-route.sh" 2>/dev/null || true

_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cron-registration-gap-check] $*"; }

# ── 1. 감시류 스크립트 자산 목록 수집 (infra/scripts·runtime/scripts 심링크 중복 제거) ──
SEEN_DIRS=""
scripts=()
for dir in "$JARVIS_HOME/infra/scripts" "$JARVIS_RUNTIME/scripts"; do
  [[ -d "$dir" ]] || continue
  real_dir="$(cd "$dir" 2>/dev/null && pwd -P)"
  [[ -z "$real_dir" ]] && continue
  case " $SEEN_DIRS " in
    *" $real_dir "*) continue ;;
  esac
  SEEN_DIRS="$SEEN_DIRS $real_dir"
  while IFS= read -r -d '' f; do
    scripts+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f \
    \( -name "*-monitor.sh" -o -name "*-check.sh" -o -name "*-watch.sh" \
       -o -name "*-watcher.sh" -o -name "*-audit.sh" -o -name "*-auditor.sh" \) \
    -print0 2>/dev/null)
done

TOTAL=${#scripts[@]}

# ── 2. 등록 소스 스냅샷 (crontab 원문 + tasks.json 원문) ──
CRONTAB_OUT="$(crontab -l 2>/dev/null || true)"
TASKS_RAW=""
[[ -f "$TASKS_JSON" ]] && TASKS_RAW="$(cat "$TASKS_JSON" 2>/dev/null || true)"

is_registered() {
  local base="$1"
  if [[ -n "$CRONTAB_OUT" ]] && printf '%s\n' "$CRONTAB_OUT" | grep -qF -- "$base"; then
    return 0
  fi
  if [[ -n "$TASKS_RAW" ]] && printf '%s\n' "$TASKS_RAW" | grep -qF -- "$base"; then
    return 0
  fi
  return 1
}

# ── 3. 대조 ──
unregistered=()
if [[ $TOTAL -gt 0 ]]; then
  for f in "${scripts[@]}"; do
    base="$(basename "$f")"
    if ! is_registered "$base"; then
      unregistered+=("$base")
    fi
  done
fi

GAP_COUNT=${#unregistered[@]}
SUMMARY="OK"
[[ $GAP_COUNT -gt 0 ]] && SUMMARY="GAP"

# ── 4. JSON 리포트 ──
UNREG_JSON="[]"
if [[ $GAP_COUNT -gt 0 ]] && command -v jq >/dev/null 2>&1; then
  UNREG_JSON="$(printf '%s\n' "${unregistered[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')"
fi

REPORT_JSON=$(cat <<EOF
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "cluster": "cl-ca6f13767447d65a",
  "result": "$SUMMARY",
  "total_scanned": $TOTAL,
  "unregistered_count": $GAP_COUNT,
  "unregistered": $UNREG_JSON
}
EOF
)

echo "$REPORT_JSON" | tee -a "$REPORT_FILE" 2>/dev/null || echo "$REPORT_JSON"

# ── 5. 콘솔 리포트 ──
if [[ "$SUMMARY" == "OK" ]]; then
  _log "✅ 감시류 스크립트 전수 등록 확인 (${TOTAL}개 스캔, 미등록 0)"
else
  _log "🔴 미등록 감시류 스크립트 ${GAP_COUNT}개 발견 (전수 ${TOTAL}개)"
  for u in "${unregistered[@]}"; do
    _log "  - $u"
  done
fi

# ── 6. 공백 발견 시에만 Discord 보고 (monitoring.json 직접 curl 금지 — discord_route 함수만 사용) ──
if [[ $GAP_COUNT -gt 0 ]] && command -v discord_route >/dev/null 2>&1; then
  list_str=""
  for u in "${unregistered[@]}"; do
    list_str="${list_str}${u}, "
  done
  list_str="${list_str%, }"
  discord_route info "감시 스크립트 크론 미등록 공백 발견" \
    "미등록=${GAP_COUNT}개,전수=${TOTAL}개,목록=${list_str}" \
    2>/dev/null || _log "[WARN] discord_route 전송 실패 — 로그로만 기록"
fi

exit 0
