#!/usr/bin/env bash
set -uo pipefail

# claim-correction-tracker.sh — 자비스 단정→주인님 교정 루프 측정 (2026-06-22 신설)
# 목적: 단정 습관은 "고치는" 문제가 아니라 "측정하는" 문제. 룰 925건이 실패했으니,
#       먼저 "단정(claim)→교정(correction)" 루프를 수치화해 어떤 개입이 실제 효과 있는지 데이터로 본다.
# claim      = 자비스(assistant)의 완료/해결 단정 어휘
# correction = 주인님(user)의 "더 봐/틀렸/검증/표면" 교정 어휘
# ratio = corrections/claims. 높을수록 "단정이 자주 되돌려짐"(나쁨). 추세가 낮아지면 개선.

SESSION="${1:-$(ls -t "$HOME/.claude/projects/-Users-ramsbaby-jarvis"/*.jsonl 2>/dev/null | head -1)}"
LEDGER="$HOME/jarvis/runtime/state/claim-correction-ledger.jsonl"
mkdir -p "$(dirname "$LEDGER")"
[ -f "$SESSION" ] || { echo "no session transcript"; exit 1; }

claims=$(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' "$SESSION" 2>/dev/null \
  | grep -coE "완료(하였습니다|했습니다|입니다|함)|해결(했습니다|됐습니다|됐|함)|마무리(하|했|짓)|끝났습니다|입증(했|됐|됨)|건강합니다|정상입니다|문제( ?없|없)습니다" || true)

corrections=$(jq -r 'select(.type=="user") | (.message.content | if type=="string" then . else (.[]?|select(.type=="text")|.text) end)' "$SESSION" 2>/dev/null \
  | grep -vE "command-name|local-command|system-reminder|task-notification" \
  | grep -coE "모든게 해결|멈출 ?생각|멈추지|약한데|표면|더 ?(봐|파)|틀렸|제대로 ?(됐|했|해)|진짜\?|검증|대충|아닌가|안 ?된" || true)

sid=$(basename "$SESSION" .jsonl | cut -c1-8)
ratio="n/a"; [ "${claims:-0}" -gt 0 ] && ratio=$(awk -v c="${corrections:-0}" -v cl="${claims:-1}" 'BEGIN{printf "%.2f", c/cl}')
echo "[claim-correction] session=$sid claims=${claims:-0} corrections=${corrections:-0} ratio=$ratio"

# 세션당 1줄만 유지 (stop hook이 매 턴 호출해도 중복 방지 — 같은 세션은 최신값으로 갱신)
newline=$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$sid" \
  --argjson claims "${claims:-0}" --argjson corr "${corrections:-0}" \
  '{ts:$ts,session:$sid,claims:$claims,corrections:$corr}')
tmp=$(mktemp)
grep -v "\"session\":\"$sid\"" "$LEDGER" 2>/dev/null > "$tmp" || true
echo "$newline" >> "$tmp"
mv "$tmp" "$LEDGER"
