#!/usr/bin/env bash
# mistake-pattern-analyzer 재현 시험 — 10-09 자가 감사: 누적 총수>1500·크기>1500KB·30일>50 이 영구 참이라
#   status=WARN 이 열흘 넘게 '확인함'으로만 눌려 있었다. 경보는 '7일 전보다 지난 30일 건수가 늘었을 때'만.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
run() {   # run <지난30일 건수> <7일 전 기록값|''> → status
  local T; T="$(mktemp -d)"
  mkdir -p "$T/.openclaw-data/runtime/wiki/meta" "$T/.openclaw-data/runtime/state"
  local lm="$T/.openclaw-data/runtime/wiki/meta/learned-mistakes.md" d i
  d="$(date '+%Y-%m-%d')"
  for i in $(seq 1 1600); do echo "## 2025-01-01 — 옛 미확인 $i" >> "$lm"; done
  for i in $(seq 1 "$1"); do echo "## $d — 미확인 $i" >> "$lm"; done
  [[ -n "$2" ]] && printf '%s\t%s\n' "$(date -v-8d '+%Y-%m-%d')" "$2" > "$T/.openclaw-data/runtime/state/mistake-pattern-history.tsv"
  HOME="$T" BOT_HOME="$T/.openclaw-data/runtime" bash "$HERE/mistake-pattern-analyzer.sh" >/dev/null
  jq -r .status "$T/.openclaw-data/runtime/state/mistake-pattern-analysis.json"
  rm -rf "$T"
}
[[ "$(run 160 '')" == OK ]]   || { echo "FAIL 기록 없음(첫날)은 기준선 — 경보 아님"; exit 1; }
[[ "$(run 160 164)" == OK ]]  || { echo "FAIL 누적·30일 절대값만 높고 줄어드는 중 — 경보 아님"; exit 1; }
[[ "$(run 160 100)" == WARN ]] || { echo "FAIL 7일 전 100 → 160 증가는 경보"; exit 1; }
echo "PASS mistake-pattern-analyzer — 변화량 기준(첫날·감소 조용, 증가 경보)"
