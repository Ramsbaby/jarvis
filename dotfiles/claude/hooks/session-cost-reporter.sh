#!/bin/bash
# session-cost-reporter.sh — Stop 훅: 세션 종료 시 비용 보고 + token-ledger.jsonl 통합 적재
#
# 2026-04-26 통합: Discord 봇과 동일한 ledger(${BOT_HOME}/state/token-ledger.jsonl)에 append.
#   - Discord 봇: ask-claude.sh가 task별로 적재
#   - CLI 세션: 본 hook이 세션 단위(turn 합계)로 적재
#   - 통합 효과: token-ledger-audit이 CLI 세션 누수도 함께 감사 가능
set -euo pipefail

SESSION_DIR="$HOME/.claude/projects"
BOT_HOME="${BOT_HOME:-$HOME/.openclaw-data/jarvis/runtime}"
LEDGER_FILE="${BOT_HOME}/state/token-ledger.jsonl"

# 가장 최근 수정된 JSONL 찾기
CURRENT_JSONL=""
LATEST_MOD=0
while IFS= read -r -d '' f; do
    mod=$(stat -f %m "$f" 2>/dev/null) || continue
    if [ "$mod" -gt "$LATEST_MOD" ]; then
        LATEST_MOD=$mod
        CURRENT_JSONL="$f"
    fi
done < <(find "$SESSION_DIR" -name "*.jsonl" -print0 2>/dev/null)

[ -z "$CURRENT_JSONL" ] && exit 0

# 비용·토큰·턴 집계 (Opus 4 가격 기준: in $3 / out $15 / cache_create $3.75 / cache_read $0.30 per 1M)
RESULT=$(node -e "
const fs = require('fs');
try {
    const lines = fs.readFileSync('$CURRENT_JSONL', 'utf8').split('\n').filter(Boolean);
    let cost = 0, turns = 0;
    let inSum = 0, outSum = 0, cacheReadSum = 0, cacheCreateSum = 0;
    let model = '';
    for (const line of lines) {
        try {
            const e = JSON.parse(line);
            if (e.type !== 'assistant' || !e.message?.usage) continue;
            const u = e.message.usage;
            const inT = u.input_tokens || 0;
            const outT = u.output_tokens || 0;
            const ccT = u.cache_creation_input_tokens || 0;
            const crT = u.cache_read_input_tokens || 0;
            inSum += inT; outSum += outT; cacheCreateSum += ccT; cacheReadSum += crT;
            cost += (inT*3 + outT*15 + ccT*3.75 + crT*0.3) / 1e6;
            turns++;
            if (e.message?.model) model = e.message.model;
        } catch(e) {}
    }
    console.log(JSON.stringify({
        cost: cost.toFixed(4),
        turns,
        input: inSum,
        output: outSum,
        cache_read: cacheReadSum,
        cache_creation: cacheCreateSum,
        model: model || 'unknown'
    }));
} catch(e) { console.log('{\"cost\":\"0\",\"turns\":0,\"input\":0,\"output\":0,\"cache_read\":0,\"cache_creation\":0,\"model\":\"unknown\"}'); }
" 2>/dev/null || echo '{"cost":"0","turns":0,"input":0,"output":0,"cache_read":0,"cache_creation":0,"model":"unknown"}')

# 필드 추출 (jq가 없을 수 있으므로 node로)
extract() {
    echo "$RESULT" | node -e "const j=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));console.log(j.$1||0)" 2>/dev/null || echo 0
}
COST=$(extract cost)
TURNS=$(extract turns)
INPUT=$(extract input)
OUTPUT=$(extract output)
CACHE_READ=$(extract cache_read)
CACHE_CREATION=$(extract cache_creation)
MODEL=$(echo "$RESULT" | node -e "const j=JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));console.log(j.model||'unknown')" 2>/dev/null || echo "unknown")

# 세션 ID (jsonl 파일명에서 추출)
SESSION_ID=$(basename "$CURRENT_JSONL" .jsonl)
PROJECT_DIR=$(basename "$(dirname "$CURRENT_JSONL")")

# 1) 기존 last-session.json 호환 유지 (budget-enforcer가 참조)
mkdir -p "$HOME/.jarvis/logs" 2>/dev/null || true
echo "{\"last_session_cost\": $COST, \"last_session_turns\": $TURNS, \"ts\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
    > "$HOME/.jarvis/logs/last-session.json" 2>/dev/null || true

# 2) token-ledger.jsonl 통합 적재 (Discord 봇 ledger와 동일 파일)
mkdir -p "$(dirname "$LEDGER_FILE")" 2>/dev/null || true
if command -v jq >/dev/null 2>&1; then
    jq -cn --arg ts "$(date -u +%FT%T.000Z)" \
           --arg task "cli-session-${SESSION_ID:0:8}" \
           --arg model "$MODEL" \
           --arg status "success" \
           --arg session_id "$SESSION_ID" \
           --arg project "$PROJECT_DIR" \
           --arg source "cli-session" \
           --argjson input "${INPUT:-0}" \
           --argjson output "${OUTPUT:-0}" \
           --argjson cache_read "${CACHE_READ:-0}" \
           --argjson cache_creation "${CACHE_CREATION:-0}" \
           --argjson cost_usd "${COST:-0}" \
           --argjson turns "${TURNS:-0}" \
           '{ts:$ts, task:$task, model:$model, status:$status, input:$input, output:$output, cache_read:$cache_read, cache_creation:$cache_creation, cost_usd:$cost_usd, turns:$turns, session_id:$session_id, project:$project, source:$source}' \
        >> "$LEDGER_FILE" 2>/dev/null || true
else
    # jq 없을 때 fallback (node로 직접 stringify)
    node -e "
const o = {
  ts: new Date().toISOString(),
  task: 'cli-session-${SESSION_ID:0:8}',
  model: '$MODEL',
  status: 'success',
  input: ${INPUT:-0},
  output: ${OUTPUT:-0},
  cache_read: ${CACHE_READ:-0},
  cache_creation: ${CACHE_CREATION:-0},
  cost_usd: ${COST:-0},
  turns: ${TURNS:-0},
  session_id: '$SESSION_ID',
  project: '$PROJECT_DIR',
  source: 'cli-session'
};
require('fs').appendFileSync('$LEDGER_FILE', JSON.stringify(o) + '\n');
" 2>/dev/null || true
fi

echo "$COST $TURNS"
