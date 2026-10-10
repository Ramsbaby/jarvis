#!/usr/bin/env bash
# test-token-budget-cap-sources.sh — 배치용 일일 상한이 대화 비용에 막히지 않는지, 진짜 배치 폭주는 여전히 막는지 (2026-10-11)
#
# 왜: 10-03 예비 경로(anthropic 직통)가 생긴 뒤 오픈클로 대화 비용(source=openclaw)이 같은 원장에 찍혀
#     배치 일일 상한(10 USD)을 혼자 넘겼다 — skill-loop 채점이 10-05·07·08·09·11 다섯 밤 통째로 막혔다.
# 임시 BOT_HOME 에 가둔다: 진짜 원장·가드 로그를 건드리지 않는다.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GUARD="$HERE/../lib/token-budget-guard.mjs"
PASSED=0; FAILURES=0
ok()  { echo "  ok   $1"; PASSED=$((PASSED + 1)); }
bad() { echo "  FAIL $1"; FAILURES=$((FAILURES + 1)); }
expect_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 — got: $2 (want $3)"; }
expect()    { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1 — got: ${2:0:300}"; }

TMP="$(mktemp -d /tmp/token-budget-cap-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export BOT_HOME="$TMP/runtime"
unset JARVIS_DAILY_CAP_USD JARVIS_MAX_BUDGET_USD JARVIS_TOKENIZER_CORRECTION_FACTOR
mkdir -p "$BOT_HOME/state" "$BOT_HOME/logs"
LEDGER="$BOT_HOME/state/token-ledger.jsonl"

row() {   # <몇 시간 전> <source> <task> <cost_usd>
  node -e '
    const [h, source, task, cost] = process.argv.slice(1);
    const ts = new Date(Date.now() - Number(h) * 3600 * 1000).toISOString();
    console.log(JSON.stringify({ ts, task, model: "m", status: "success", input: 10, output: 10, cost_usd: Number(cost), source }));
  ' "$1" "$2" "$3" "$4" >> "$LEDGER"
}
check() { node "$GUARD" check --task skill-loop-score >/dev/null 2>&1; echo $?; }

echo "1. 대화 비용만 상한을 넘는 날 (10-11 03:50 실제 모양: 대화 14 USD, 배치 0)"
: > "$LEDGER"
row 6 openclaw "agent:main:subagent:aaaa" 6.85
row 7 openclaw "agent:main:subagent:bbbb" 4.28
row 8 openclaw "agent:main:subagent:cccc" 2.90
row 3 ask-claude skill-loop-score 0
expect_eq "배치는 막히지 않는다(exit 0)" "$(check)" "0"
total="$(node "$GUARD" daily-total)"
expect "뺀 금액이 보인다" "$total" '"dailyExcludedCostRawUsd":14.03'
expect "상한 집계는 0" "$total" '"dailyCostRawUsd":0,'

echo "2. 배치가 진짜로 폭주한 날 (stop-hook 9 USD × 보정 1.3 = 11.7 ≥ 10)"
: > "$LEDGER"
row 2 stop-hook mistake-extractor 5
row 4 stop-hook wiki-ingest-claude 4
expect_eq "여전히 막는다(exit 2)" "$(check)" "2"
expect "가드 로그에 이유가 남는다" "$(cat "$BOT_HOME/logs/token-budget-guard.log" 2>/dev/null)" "DAILY_CAP_EXCEEDED"

echo "3. 대화 20 USD + 배치 2 USD — 배치 몫만 센다"
: > "$LEDGER"
row 1 openclaw "agent:main:main" 20
row 2 ask-claude skill-loop-extract 2
expect_eq "통과(exit 0)" "$(check)" "0"
expect "배치 몫 2 USD 만 집계" "$(node "$GUARD" daily-total)" '"dailyCostRawUsd":2,'

echo "4. source 칸이 없는 옛 줄은 배치로 센다 (빼는 쪽으로 새지 않게)"
: > "$LEDGER"
node -e 'console.log(JSON.stringify({ts:new Date(Date.now()-3600e3).toISOString(),task:"old-task",cost_usd:9}))' >> "$LEDGER"
expect_eq "막는다(exit 2)" "$(check)" "2"

echo "5. 24시간 지난 줄은 세지 않는다"
: > "$LEDGER"
row 30 stop-hook mistake-extractor 50
expect_eq "통과(exit 0)" "$(check)" "0"

echo
echo "통과 $PASSED · 실패 $FAILURES"
[[ "$FAILURES" -eq 0 ]]
