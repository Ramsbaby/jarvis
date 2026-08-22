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
DISCORD_VISUAL="${HOME}/jarvis/infra/scripts/discord-visual.mjs"

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

# === 그림자 경로 가드 (2026-06-22 도입 / 2026-07-25 원인 정정) ===
# 배경: 데이터가 정본이 아닌 그림자 폴더에 쌓여 RAG·감사에서 누락된 사고(ceo-digest 리포트 ~50개).
#       당시 원인을 "~/.jarvis 가 심링크라서"로 적었으나, 실측 결과 ~/.jarvis 는 독립 실제 폴더였다.
#       진짜 원인은 compat.sh 가 JARVIS_HOME 을 런타임 폴더로 정의해 "runtime" 이 중복된 것.
#       상세 판정 로직은 shadow-path-guard.sh 참조. 모델 검사와 독립 실행.
if SHADOW_REPORT=$(bash "${JARVIS_HOME}/infra/scripts/shadow-path-guard.sh" 2>&1); then
  _log "shadow-path PASS: 그림자 경로 오타 0건"
else
  _log "🚨 그림자 경로 오타 감지:"
  printf '%s\n' "$SHADOW_REPORT" | tee -a "$LOG_FILE"
  if [[ -f "$DISCORD_VISUAL" ]] && command -v discord_route_payload >/dev/null 2>&1; then
    SP=$(jq -nc --arg ts "$(date +'%Y-%m-%d %H:%M KST')" \
      --arg r "$(printf '%s\n' "$SHADOW_REPORT" | grep '⚠️' | head -3 | tr '\n' '|' | sed 's/|$//')" \
      '{title:"🚨 그림자 경로 감지", data:{"위반":($r|if .=="" then "(상세 로그 참조)" else . end), "조치":"shadow-path-guard.sh 출력의 A형/B형 안내 참조"}, timestamp:$ts}')
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

# 탐지 정규식은 SSoT(model-policy.json 의 deprecated[])에서 생성한다.
# 하드코딩하면 새 세대가 나올 때마다 규칙이 조용히 낡는다 — 실제로 예전 규칙의
# "claude-sonnet-4-[0-5]" 가 claude-sonnet-4-6 을 범위 밖으로 흘려보내
# 8주간(2026-06-27~08-17) 매주 "위반 0건" 오탐 PASS 를 냈다 (2026-08-22 정정).
# 앞으로는 model-policy.json 에 ID 한 줄만 추가하면 코드 스캔이 따라온다.
DEPRECATED_RE=$(printf '%s\n' "$DEPRECATED" | grep -v '^[[:space:]]*$' | paste -sd'|' -)
if [[ -z "$DEPRECATED_RE" ]]; then
  _log "ERROR: deprecated 목록이 비어 코드 스캔을 수행할 수 없다 — policy file 확인 필요"
  exit 1
fi

# ([^0-9]|$) — "claude-opus-4-5" 가 가상의 "claude-opus-4-50" 을 오탐하지 않게 하되,
# 줄 끝에 온 경우도 놓치지 않는다. *.bak 은 과거 스냅샷이므로 감사 대상에서 뺀다.
#
# 줄 끝에 ALLOW-DEPRECATED-MODEL 마커가 있으면 의도적 잔존으로 보고 넘긴다
# (구형 가격표·별칭 매핑·과거 비용 기록처럼 구형 ID 를 알아야만 동작하는 자리).
# 마커 없이 오탐을 방치하면 감사가 매주 같은 소음을 내고 결국 아무도 안 본다 —
# topology-guard 의 ALLOW-DOTJARVIS 와 같은 관례다.
CODE_HITS=$(grep -rEn "(${DEPRECATED_RE})([^0-9]|$)" \
  "${JARVIS_HOME}/infra/" "${JARVIS_HOME}/runtime/scripts/" 2>/dev/null \
  | grep -v "ALLOW-DEPRECATED-MODEL" \
  | grep -v "node_modules\|\.git/\|model-policy.json\|model-version-audit\|CLAUDE.md\|learned-mistakes\|README\|/docs/\|/wiki/\|/adr/\|tasks-index.json\|tasks.schema.json\|\.bak" \
  | cut -d: -f1 | sort -u \
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
