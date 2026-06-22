#!/usr/bin/env bash
# model-version-audit.sh — Jarvis 모델 사용 정책 자동 검증
# SSoT: ~/jarvis/runtime/context/model-policy.json
# 정책 위반 발견 시 Discord #jarvis-system 알림 + 로그
#
# 매주 월 09:00 KST 자동 실행 (ai.jarvis.model-version-audit LaunchAgent)
# 수동 실행: bash ~/jarvis/infra/scripts/model-version-audit.sh

set -euo pipefail

JARVIS_HOME="${JARVIS_HOME:-$HOME/jarvis}"
SSOT_REGISTRY="${JARVIS_HOME}/runtime/context/ssot-registry.json"
TASKS_FILE="${JARVIS_HOME}/runtime/config/tasks.json"
LOG_FILE="${JARVIS_HOME}/runtime/logs/model-version-audit.log"
DISCORD_VISUAL="${HOME}/.jarvis/scripts/discord-visual.mjs"

# SSoT Registry에서 model-policy 경로 단일 참조 (권고 ③ 통합 — 2026-05-08)
POLICY_FILE_RAW=$(jq -r '.operationalPolicy[]? | select(.name=="model-policy") | .path' "$SSOT_REGISTRY" 2>/dev/null || echo "")
if [[ -n "$POLICY_FILE_RAW" ]]; then
  POLICY_FILE="${POLICY_FILE_RAW/#~/$HOME}"
else
  # Fallback (registry 부재 시)
  POLICY_FILE="${JARVIS_HOME}/runtime/context/model-policy.json"
fi

mkdir -p "$(dirname "$LOG_FILE")"
[ -f "$JARVIS_HOME/infra/lib/discord-route.sh" ] && source "$JARVIS_HOME/infra/lib/discord-route.sh"
_log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Single-instance lock (cascade 차단)
# shellcheck source=/dev/null
[ -f "$JARVIS_HOME/infra/lib/single-instance.sh" ] && source "$JARVIS_HOME/infra/lib/single-instance.sh" && single_instance "model-version-audit"

if [[ ! -f "$POLICY_FILE" ]]; then
  _log "ERROR: policy file not found: $POLICY_FILE"
  exit 1
fi

DEPRECATED=$(jq -r '.deprecated[]' "$POLICY_FILE")
LATEST_OPUS=$(jq -r '.currentLatest.opus' "$POLICY_FILE")
LATEST_SONNET=$(jq -r '.currentLatest.sonnet' "$POLICY_FILE")
LATEST_HAIKU=$(jq -r '.currentLatest.haiku' "$POLICY_FILE")

_log "audit start — latest: opus=$LATEST_OPUS sonnet=$LATEST_SONNET haiku=$LATEST_HAIKU"

# === 그림자 경로 오타 가드 (2026-06-22 — ~/.jarvis/runtime/ → runtime/runtime/ 누설 재발 방지) ===
# 배경: ~/.jarvis 가 ~/jarvis/runtime 심링크라, 설정에 ~/.jarvis/runtime/ 적으면 그림자 폴더에 데이터가 샘.
#       ceo-digest 경영 리포트 ~50개가 그림자에만 쌓인 사고 후 주간 감사에 통합. 모델 검사와 독립 실행.
if SHADOW_REPORT=$(bash "${JARVIS_HOME}/infra/scripts/shadow-path-guard.sh" 2>&1); then
  _log "shadow-path PASS: 그림자 경로 오타 0건"
else
  _log "🚨 그림자 경로 오타 감지:"
  printf '%s\n' "$SHADOW_REPORT" | tee -a "$LOG_FILE"
  if [[ -f "$DISCORD_VISUAL" ]] && command -v discord_route_payload >/dev/null 2>&1; then
    SP=$(jq -nc --arg ts "$(date +'%Y-%m-%d %H:%M KST')" \
      --arg r "$(printf '%s\n' "$SHADOW_REPORT" | grep '⚠️' | head -3 | tr '\n' '|' | sed 's/|$//')" \
      '{title:"🚨 그림자 경로 오타 감지", data:{"위반":($r|if .=="" then "(상세 로그 참조)" else . end), "조치":"~/.jarvis/runtime/ → ~/jarvis/runtime/ 교정"}, timestamp:$ts}')
    discord_route_payload info "$SP" 2>&1 | tee -a "$LOG_FILE" || true
  fi
fi

VIOLATIONS_TASKS=""
VIOLATIONS_CODE=""
TOTAL_VIOLATIONS=0

for dep in $DEPRECATED; do
  TASK_HITS=$(jq -r --arg m "$dep" '[.tasks[] | select(.model==$m) | .id] | join(",")' "$TASKS_FILE")
  if [[ -n "$TASK_HITS" ]]; then
    VIOLATIONS_TASKS="${VIOLATIONS_TASKS}${dep}: ${TASK_HITS}\n"
    COUNT=$(echo "$TASK_HITS" | tr ',' '\n' | wc -l | tr -d ' ')
    TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + COUNT))
  fi
done

CODE_HITS=$(grep -rEln "claude-opus-4-[0-6][^0-9]|claude-sonnet-4-[0-5][^0-9]|claude-haiku-(3-5|4-0)" \
  "${JARVIS_HOME}/infra/" "${JARVIS_HOME}/runtime/scripts/" 2>/dev/null \
  | grep -v "node_modules\|\.git/\|model-policy.json\|model-version-audit\|CLAUDE.md\|learned-mistakes\|README\|/docs/\|/wiki/\|tasks-index.json\|tasks.schema.json" \
  || true)

if [[ -n "$CODE_HITS" ]]; then
  CODE_COUNT=$(echo "$CODE_HITS" | wc -l | tr -d ' ')
  VIOLATIONS_CODE="$CODE_HITS"
  TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + CODE_COUNT))
fi

if [[ $TOTAL_VIOLATIONS -eq 0 ]]; then
  _log "PASS: 모델 정책 위반 0건"
  exit 0
fi

_log "FAIL: 정책 위반 ${TOTAL_VIOLATIONS}건 발견"
[[ -n "$VIOLATIONS_TASKS" ]] && _log "tasks.json:" && printf "%b" "$VIOLATIONS_TASKS" | tee -a "$LOG_FILE"
[[ -n "$VIOLATIONS_CODE" ]] && _log "code:" && echo "$VIOLATIONS_CODE" | tee -a "$LOG_FILE"

if [[ -x "$DISCORD_VISUAL" || -f "$DISCORD_VISUAL" ]]; then
  TS=$(date +"%Y-%m-%d %H:%M KST")
  TASK_SUMMARY=$(printf "%b" "$VIOLATIONS_TASKS" | head -3 | tr '\n' '|' | sed 's/|$//')
  CODE_SUMMARY=$(echo "$VIOLATIONS_CODE" | head -3 | tr '\n' '|' | sed 's/|$//')
  PAYLOAD=$(jq -nc \
    --arg ts "$TS" \
    --arg total "$TOTAL_VIOLATIONS" \
    --arg tasks "${TASK_SUMMARY:-(없음)}" \
    --arg code "${CODE_SUMMARY:-(없음)}" \
    --arg latest "opus=$LATEST_OPUS, sonnet=$LATEST_SONNET, haiku=$LATEST_HAIKU" \
    '{title: "🚨 모델 정책 위반 감지", data: {"위반 총계": $total, "tasks.json": $tasks, "code": $code, "최신 정책": $latest}, timestamp: $ts}')
  discord_route_payload info "$PAYLOAD" 2>&1 | tee -a "$LOG_FILE" || true
fi

exit 1
