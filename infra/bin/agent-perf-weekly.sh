#!/usr/bin/env bash
# weekly-perf-agent.sh — 주간 성과 분석 에이전트
#
# 데이터 수집 → LLM 분석 → Board 포스트 생성 → Discord 알림
#
# 데이터 소스:
#   - tasks.db (FSM: 완료/실패/지연 태스크)
#   - Langfuse (LLM 호출 비용/에러율)
#   - RAG quality log
#   - Board agent scores (개선 점수)
#
# Cron: 0 21 * * 0  (일요일 21:00, weekly-roi 이후)
# ADR: ADR-020 (Langfuse), ADR-018 (multi-agent orchestration)

set -euo pipefail
trap 'rm -f "$TMP_DATA" "$TMP_PROMPT" "$TMP_OUTPUT" 2>/dev/null' EXIT

BOT_HOME="${BOT_HOME:-${HOME}/.jarvis}"
TMP_DATA=$(mktemp /tmp/perf-agent-data-XXXXXX.json)
TMP_PROMPT=$(mktemp /tmp/perf-agent-prompt-XXXXXX.txt)
TMP_OUTPUT=$(mktemp /tmp/perf-agent-output-XXXXXX.json)
LOG="$BOT_HOME/logs/weekly-perf-agent.log"
TASK_ID="weekly-perf-agent"

source "$BOT_HOME/lib/log-utils.sh" 2>/dev/null || {
  log_info()  { echo "[perf-agent] $*" | tee -a "$LOG"; }
  log_error() { echo "[perf-agent] ERROR: $*" | tee -a "$LOG"; }
}

source "$BOT_HOME/discord/.env" 2>/dev/null || true
source "$BOT_HOME/lib/langfuse-trace.sh" 2>/dev/null || {
  lf_start_timer() { :; }
  lf_trace_generation() { :; }
}
source "$BOT_HOME/lib/llm-gateway.sh" 2>/dev/null || {
  log_error "llm-gateway.sh not found"
  exit 1
}

BOARD_URL="${BOARD_URL:-http://localhost:3000}"
AGENT_API_KEY="${AGENT_API_KEY:-}"
LANGFUSE_BASE_URL="${LANGFUSE_BASE_URL:-http://localhost:3200}"

WEEK=$(date +%Y-W%V)
WEEK_START=$(python3 -c "
import datetime
today = datetime.date.today()
monday = today - datetime.timedelta(days=today.weekday())
print(monday.isoformat())
")
WEEK_END=$(date +%Y-%m-%d)

log_info "=== 주간 성과 분석 시작 (${WEEK}) ==="

# ── 1. FSM 태스크 통계 수집 ────────────────────────────────────────────────
FSM_STATS=$(node --experimental-sqlite --no-warnings \
  "$BOT_HOME/lib/task-store.mjs" list 2>/dev/null \
  | python3 - <<'PYEOF'
import json, sys, datetime

tasks = json.load(sys.stdin)
week_ago = (datetime.datetime.utcnow() - datetime.timedelta(days=7)).isoformat()

done = [t for t in tasks if t.get('status') == 'done']
failed = [t for t in tasks if t.get('status') == 'failed']
skipped = [t for t in tasks if t.get('status') == 'skipped']

# Weekly completions (completedAt in last 7 days)
weekly_done = [
    t for t in done
    if t.get('meta', {}).get('completedAt', '') > week_ago
]

print(json.dumps({
    'total': len(tasks),
    'done': len(done),
    'failed': len(failed),
    'skipped': len(skipped),
    'weekly_done': len(weekly_done),
    'top_failed': [t['id'] for t in failed[:5]],
}))
PYEOF
2>/dev/null || echo '{"total":0,"done":0,"failed":0,"skipped":0,"weekly_done":0,"top_failed":[]}')

# ── 2. Langfuse LLM 비용/에러 통계 ────────────────────────────────────────
LF_STATS='{"total_calls":0,"error_rate":0,"total_cost":0,"avg_dur_ms":0}'
if [[ -n "${LANGFUSE_PUBLIC_KEY:-}" && -n "${LANGFUSE_SECRET_KEY:-}" ]]; then
  LF_RAW=$(curl -sf \
    -u "${LANGFUSE_PUBLIC_KEY}:${LANGFUSE_SECRET_KEY}" \
    "${LANGFUSE_BASE_URL}/api/public/generations?limit=500&fromStartTime=${WEEK_START}T00:00:00Z" \
    --max-time 10 2>/dev/null || echo '{"data":[]}')

  LF_STATS=$(echo "$LF_RAW" | python3 - <<'PYEOF'
import json, sys
data = json.load(sys.stdin)
gens = data.get('data', [])
total = len(gens)
errors = sum(1 for g in gens if g.get('level') == 'ERROR')
cost = sum(
    float((g.get('metadata') or {}).get('cost_usd', 0) or 0)
    for g in gens if isinstance(g.get('metadata'), dict)
)
durs = [
    float((g.get('metadata') or {}).get('duration_ms', 0) or 0)
    for g in gens if isinstance(g.get('metadata'), dict)
]
avg_dur = int(sum(durs)/len(durs)) if durs else 0
print(json.dumps({
    'total_calls': total,
    'error_rate': round(errors/total*100, 1) if total else 0,
    'total_cost': round(cost, 4),
    'avg_dur_ms': avg_dur,
}))
PYEOF
2>/dev/null || echo "$LF_STATS")
fi

# ── 3. RAG 품질 요약 ───────────────────────────────────────────────────────
RAG_HEALTH=$(cat "$BOT_HOME/state/health.json" 2>/dev/null \
  | python3 -c "
import json,sys
h=json.load(sys.stdin)
r=h.get('rag',{})
print(json.dumps({'chunks': r.get('chunks',0), 'last_index': r.get('last_index','?'), 'errors': r.get('errors',0)}))
" 2>/dev/null || echo '{"chunks":0,"last_index":"?","errors":0}')

# ── 4. Board 에이전트 점수 ─────────────────────────────────────────────────
BOARD_SCORES='[]'
if [[ -n "$AGENT_API_KEY" && -n "$BOARD_URL" ]]; then
  BOARD_SCORES=$(curl -sf \
    -H "x-agent-key: $AGENT_API_KEY" \
    "${BOARD_URL}/api/agents/scores" \
    --max-time 10 2>/dev/null \
    | python3 -c "
import json,sys
data=json.load(sys.stdin)
agents=data if isinstance(data,list) else data.get('agents',[])
top3=sorted(agents,key=lambda x:-x.get('improvement_score',0))[:3]
print(json.dumps([{'id':a.get('author'),'score':a.get('improvement_score',0)} for a in top3]))
" 2>/dev/null || echo '[]')
fi

# ── 5. 데이터 직렬화 ──────────────────────────────────────────────────────
python3 -c "
import json
print(json.dumps({
    'week': '${WEEK}',
    'period': '${WEEK_START} ~ ${WEEK_END}',
    'fsm': json.loads('${FSM_STATS}'),
    'llm': json.loads('${LF_STATS}'),
    'rag': json.loads('${RAG_HEALTH}'),
    'board_top_agents': json.loads('${BOARD_SCORES}'),
}, ensure_ascii=False, indent=2))
" > "$TMP_DATA"

log_info "데이터 수집 완료: $(wc -c < "$TMP_DATA") bytes"

# ── 6. LLM 프롬프트 작성 ──────────────────────────────────────────────────
cat > "$TMP_PROMPT" <<PROMPT
당신은 Jarvis 홈 AI 시스템의 주간 성과 분석가입니다.
아래 데이터를 분석하여 이번 주 성과 보고서를 작성하세요.

## 이번 주 데이터

$(cat "$TMP_DATA")

## 작성 규칙

1. **요약 (3줄 이내)**: 이번 주 핵심 성과를 한국어로.
2. **잘된 점** (bullet 2~3개): 구체적 수치 포함.
3. **문제점** (bullet 1~3개): 근본 원인 분석 포함.
4. **다음 주 개선 제안** (bullet 2~3개): 각 제안은 실행 가능한 구체적 태스크로.
5. **DEV_TASK 목록**: 개선 제안 중 Jarvis가 자동화할 수 있는 항목을 아래 형식으로:

\`\`\`dev_tasks
- title: "[자동화 항목 제목]"
  detail: "[구체적 실행 내용]"
  priority: high|medium|low
\`\`\`

분량: 400자 이내 (DEV_TASK 제외). 전문 용어 최소화.
PROMPT

# ── 7. LLM 분석 실행 ──────────────────────────────────────────────────────
log_info "LLM 분석 시작..."
lf_start_timer

export TASK_ID="$TASK_ID"
if ! llm_call \
  --prompt "$(cat "$TMP_PROMPT")" \
  --system "당신은 Jarvis 시스템 분석가입니다. 간결하고 실용적인 보고서를 작성합니다." \
  --timeout 180 \
  --output "$TMP_OUTPUT"; then
  log_error "LLM 분석 실패"
  exit 1
fi

lf_trace_generation \
  --task-id "$TASK_ID" \
  --name "weekly-perf-analysis" \
  --model "auto" \
  --provider "llm-gateway" \
  --output "$TMP_OUTPUT"

ANALYSIS=$(jq -r '.result // ""' "$TMP_OUTPUT" 2>/dev/null)
if [[ -z "$ANALYSIS" ]]; then
  log_error "LLM 결과 비어있음"
  exit 1
fi

log_info "LLM 분석 완료 (${#ANALYSIS}자)"

# ── 8. Board 포스트 생성 (P4-2: 자동 Board post) ─────────────────────────
if [[ -n "$AGENT_API_KEY" && -n "$BOARD_URL" ]]; then
  BOARD_CONTENT=$(python3 -c "
import json, sys
analysis = sys.argv[1]
week = '${WEEK}'
period = '${WEEK_START} ~ ${WEEK_END}'
content = f'''## 배경
{week} ({period}) 주간 자동 성과 분석 결과입니다.

{analysis}

---
*Jarvis weekly-perf-agent 자동 생성*
'''
print(json.dumps({
    'type': 'discussion',
    'title': f'[주간성과] {week} Jarvis 자동 분석 리포트',
    'content': content,
    'priority': 'medium',
    'author': 'jarvis-proposer',
    'author_display': 'Jarvis 🤖',
    'tags': ['weekly', 'performance', 'auto-generated'],
}, ensure_ascii=False))
" "$ANALYSIS" 2>/dev/null)

  POST_RESULT=$(curl -sf -X POST "${BOARD_URL}/api/posts" \
    -H "Content-Type: application/json" \
    -H "x-agent-key: $AGENT_API_KEY" \
    -d "$BOARD_CONTENT" \
    --max-time 15 2>/dev/null || echo '{}')

  POST_ID=$(echo "$POST_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
  if [[ -n "$POST_ID" ]]; then
    log_info "Board 포스트 생성: id=${POST_ID}"
  fi
fi

# ── 9. Discord 알림 ───────────────────────────────────────────────────────
FSM_DONE=$(echo "$FSM_STATS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('weekly_done',0))")
FSM_FAIL=$(echo "$FSM_STATS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('failed',0))")
LF_CALLS=$(echo "$LF_STATS"  | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_calls',0))")
LF_COST=$(echo "$LF_STATS"   | python3 -c "import json,sys; print(f\"\${json.load(sys.stdin).get('total_cost',0):.2f}\")")

cd ~ && node ~/.jarvis/scripts/discord-visual.mjs \
  --type stats \
  --data "{
    \"title\": \"📊 주간 성과 리포트 — ${WEEK}\",
    \"data\": {
      \"기간\": \"${WEEK_START} ~ ${WEEK_END}\",
      \"완료 태스크\": \"${FSM_DONE}개\",
      \"실패 태스크\": \"${FSM_FAIL}개\",
      \"LLM 호출\": \"${LF_CALLS}회\",
      \"LLM 비용\": \"\$${LF_COST}\",
      \"Board 포스트\": \"${POST_ID:-미생성}\"
    },
    \"timestamp\": \"$(date '+%Y-%m-%d %H:%M')\"
  }" \
  --channel jarvis-system 2>/dev/null || true

log_info "=== 주간 성과 분석 완료 (${WEEK}) ==="
