#!/usr/bin/env bash
# log-size-audit.sh — 로그 파일 크기 감사 (폭주 로그 조기 감지)
#
# 목적:
#   webhook-listener.err.log 가 2.9MB 까지 자라는 동안 아무도 몰랐던 사건의 재발 방지.
#   실행 실패 중인 LaunchAgent 는 감사로 잡히지만, "실행되지만 에러 로그를 계속 뱉는" 케이스는
#   별도 감지가 필요. 디스크 고갈 예방 + 정상성 cross-check.
#
# 감지 대상:
#   ~/jarvis/runtime/logs/*.log (err/out 모두)
#   /tmp/jarvis-*.log (있으면)
#
# 임계값:
#   WARN  = 10 MB  (정상적으로 커도 이 선을 넘는 로그는 rotate 전략 필요)
#   CRIT  = 100 MB (디스크 고갈 위험 / crash loop 의심)
#
# 원장: ~/jarvis/runtime/ledger/log-size-audit.jsonl
# 알림: jarvis-system 웹훅 (CRIT 또는 WARN N개 이상일 때만)
# 원칙: 감사 실행 자체는 항상 exit 0. violation 은 ledger + throttled alert.

set -euo pipefail

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
LEDGER_DIR="${BOT_HOME}/ledger"
LEDGER="${LEDGER_DIR}/log-size-audit.jsonl"
CONFIG_FILE="${BOT_HOME}/config/monitoring.json"
THROTTLE_DIR="${BOT_HOME}/state/log-size-audit-throttle"
TS_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EPOCH=$(date +%s)

mkdir -p "$LEDGER_DIR" "$THROTTLE_DIR"

WARN_BYTES=$((10 * 1024 * 1024))     # 10 MB
CRIT_BYTES=$((100 * 1024 * 1024))    # 100 MB

# 감사 경로 수집
PATHS=()
[[ -d "${HOME}/jarvis/runtime/logs" ]] && while IFS= read -r -d '' f; do
  PATHS+=("$f")
done < <(find "${HOME}/jarvis/runtime/logs" -maxdepth 2 -type f -name "*.log" -print0 2>/dev/null)

shopt -s nullglob
for f in /tmp/jarvis-*.log; do
  [[ -f "$f" ]] && PATHS+=("$f")
done
shopt -u nullglob

warnings=()
crits=()

for f in "${PATHS[@]}"; do
  size=$(stat -f "%z" "$f" 2>/dev/null || echo 0)
  [[ "$size" -lt "$WARN_BYTES" ]] && continue
  mb=$((size / 1024 / 1024))
  printf '{"ts":"%s","path":"%s","bytes":%d,"mb":%d,"level":"%s"}\n' \
    "$TS_ISO" "$f" "$size" "$mb" \
    "$([[ $size -ge $CRIT_BYTES ]] && echo crit || echo warn)" >> "$LEDGER"
  if [[ "$size" -ge "$CRIT_BYTES" ]]; then
    crits+=("${f}|${mb}MB")
  else
    warnings+=("${f}|${mb}MB")
  fi
done

# Discord alert (CRIT 1건+ 또는 WARN 3건+) — 24h throttle per signature
total_warn=${#warnings[@]}
total_crit=${#crits[@]}

should_alert=false
(( total_crit > 0 )) && should_alert=true
(( total_warn >= 3 )) && should_alert=true

if $should_alert; then
  # 시그니처: WARN/CRIT 종류별. 경로 목록이 바뀌면 재알림 (throttle 키에 paths 해시 포함).
  sig=$(printf '%s\n' "${crits[@]}" "${warnings[@]}" | shasum -a 1 | awk '{print $1}')
  marker="${THROTTLE_DIR}/${sig}"
  last=0
  [[ -f "$marker" ]] && last=$(cat "$marker" 2>/dev/null || echo 0)
  if (( EPOCH - last >= 86400 )); then
    WEBHOOK=$(jq -r '.webhooks["jarvis-system"] // .webhooks["jarvis"] // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "${WEBHOOK:-}" ]]; then
      msg="📏 **log-size-audit** — WARN=${total_warn} CRIT=${total_crit}"$'\n'
      if (( total_crit > 0 )); then
        msg+=$'\n'"🔴 **CRIT (≥100MB, rotate/중단 필요):**"$'\n'
        for entry in "${crits[@]}"; do
          msg+="  • \`${entry%|*}\` (${entry##*|})"$'\n'
        done
      fi
      if (( total_warn > 0 )); then
        msg+=$'\n'"🟡 **WARN (≥10MB):**"$'\n'
        for entry in "${warnings[@]:0:5}"; do
          msg+="  • \`${entry%|*}\` (${entry##*|})"$'\n'
        done
      fi
      payload=$(jq -n --arg m "$msg" '{content: $m, allowed_mentions: {parse: []}}')
      curl -sS -X POST "$WEBHOOK" -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 || true
      echo "$EPOCH" > "$marker"
    fi
  fi
fi

echo "log-size-audit: ${total_warn} warn / ${total_crit} crit (paths=${#PATHS[@]})"
# 원칙: 감사 실행 자체는 성공 → exit 0. violation 은 ledger + throttled alert.
exit 0
