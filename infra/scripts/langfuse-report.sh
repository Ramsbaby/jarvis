#!/usr/bin/env bash
# langfuse-report.sh — Weekly LLM performance & cost report via Langfuse API
#
# Queries Langfuse for the past 7 days of trace/generation data,
# computes summary stats, and sends a Discord embed.
#
# Usage:
#   bash langfuse-report.sh              # last 7 days
#   bash langfuse-report.sh --days 14    # last 14 days
#   DISCORD_CHANNEL=jarvis-system bash langfuse-report.sh

set -euo pipefail
trap 'rm -f "$TMP_DATA" 2>/dev/null' EXIT

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
TMP_DATA=$(mktemp /tmp/langfuse-report-XXXXXX.json)
DAYS=7

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    *) shift ;;
  esac
done

LANGFUSE_BASE_URL="${LANGFUSE_BASE_URL:-http://localhost:3200}"
LANGFUSE_PUBLIC_KEY="${LANGFUSE_PUBLIC_KEY:-}"
LANGFUSE_SECRET_KEY="${LANGFUSE_SECRET_KEY:-}"

# Load keys from discord/.env if not in environment
if [[ -z "$LANGFUSE_PUBLIC_KEY" && -f "$BOT_HOME/discord/.env" ]]; then
  while IFS='=' read -r k v; do
    k=$(echo "$k" | xargs)
    if [[ -z "$k" || "$k" == \#* ]]; then continue; fi
    v=$(echo "$v" | sed "s/^[\"']//;s/[\"']$//")
    case "$k" in
      LANGFUSE_PUBLIC_KEY) LANGFUSE_PUBLIC_KEY="$v" ;;
      LANGFUSE_SECRET_KEY) LANGFUSE_SECRET_KEY="$v" ;;
      LANGFUSE_BASE_URL)   LANGFUSE_BASE_URL="$v"   ;;
    esac
  done < "$BOT_HOME/discord/.env"
fi

if [[ -z "$LANGFUSE_PUBLIC_KEY" || -z "$LANGFUSE_SECRET_KEY" ]]; then
  echo "ERROR: LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY not set" >&2
  exit 1
fi

FROM_DATE=$(python3 -c "
import datetime
d = datetime.datetime.utcnow() - datetime.timedelta(days=$DAYS)
print(d.strftime('%Y-%m-%dT00:00:00Z'))
")
TO_DATE=$(python3 -c "
import datetime
print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))
")

_lf_get() {
  local path="$1"
  curl -sf -u "${LANGFUSE_PUBLIC_KEY}:${LANGFUSE_SECRET_KEY}" \
    "${LANGFUSE_BASE_URL}${path}" \
    --max-time 10 \
    2>/dev/null
}

# Fetch usage stats from Langfuse metrics endpoint
echo "Fetching Langfuse data (${FROM_DATE} → ${TO_DATE})..."

GENERATIONS=$(_lf_get "/api/public/generations?limit=500&fromStartTime=${FROM_DATE}&toStartTime=${TO_DATE}" 2>/dev/null || echo '{"data":[]}')
echo "$GENERATIONS" > "$TMP_DATA"

STATS=$(python3 - <<'PYEOF'
import json, sys, math

with open(sys.argv[1]) as f:
    data = json.load(f)

gens = data.get('data', [])

total_calls   = len(gens)
total_input   = sum(g.get('usage', {}).get('input',  0) or 0 for g in gens)
total_output  = sum(g.get('usage', {}).get('output', 0) or 0 for g in gens)
total_cost    = sum(
    float(g.get('metadata', {}).get('cost_usd', 0) or 0) if isinstance(g.get('metadata'), dict) else 0
    for g in gens
)

# Error count
error_count = sum(1 for g in gens if g.get('level') == 'ERROR')

# Model distribution
models = {}
for g in gens:
    m = g.get('model') or 'unknown'
    models[m] = models.get(m, 0) + 1
top_models = sorted(models.items(), key=lambda x: -x[1])[:5]

# Duration stats (ms)
durations = []
for g in gens:
    meta = g.get('metadata') or {}
    if isinstance(meta, dict) and meta.get('duration_ms'):
        try:
            durations.append(float(meta['duration_ms']))
        except (ValueError, TypeError):
            pass

avg_dur = int(sum(durations) / len(durations)) if durations else 0
p95_dur = int(sorted(durations)[int(len(durations)*0.95)]) if durations else 0

result = {
    'total_calls':  total_calls,
    'total_input':  total_input,
    'total_output': total_output,
    'total_tokens': total_input + total_output,
    'total_cost':   round(total_cost, 4),
    'error_count':  error_count,
    'error_rate':   round(error_count / total_calls * 100, 1) if total_calls else 0,
    'avg_dur_ms':   avg_dur,
    'p95_dur_ms':   p95_dur,
    'top_models':   top_models,
}
print(json.dumps(result))
PYEOF
"$TMP_DATA")

# Parse stats
TOTAL_CALLS=$(echo "$STATS"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['total_calls'])")
TOTAL_TOKENS=$(echo "$STATS" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['total_tokens']:,}\")")
TOTAL_COST=$(echo "$STATS"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"\${d['total_cost']:.2f}\")")
ERROR_RATE=$(echo "$STATS"   | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d['error_rate']}%\")")
AVG_DUR=$(echo "$STATS"      | python3 -c "import json,sys; d=json.load(sys.stdin); ms=d['avg_dur_ms']; print(f'{ms/1000:.1f}s' if ms else 'N/A')")
P95_DUR=$(echo "$STATS"      | python3 -c "import json,sys; d=json.load(sys.stdin); ms=d['p95_dur_ms']; print(f'{ms/1000:.1f}s' if ms else 'N/A')")
TOP_MODELS=$(echo "$STATS"   | python3 -c "
import json,sys
d=json.load(sys.stdin)
lines = [f'{m}: {c}회' for m,c in d['top_models'][:3]]
print(', '.join(lines) or '-')
")

WEEK_LABEL=$(python3 -c "
import datetime
end = datetime.date.today()
start = end - datetime.timedelta(days=$DAYS-1)
print(f'{start.strftime(\"%m/%d\")} ~ {end.strftime(\"%m/%d\")}')
")

# Send Discord visual card
cd ~ && node ~/jarvis/runtime/scripts/discord-visual.mjs \
  --type stats \
  --data "{
    \"title\": \"📊 LLM 성과 리포트 (${WEEK_LABEL})\",
    \"data\": {
      \"총 LLM 호출\": \"${TOTAL_CALLS}회\",
      \"총 토큰\": \"${TOTAL_TOKENS}\",
      \"추정 비용\": \"${TOTAL_COST}\",
      \"에러율\": \"${ERROR_RATE}\",
      \"평균 응답\": \"${AVG_DUR}\",
      \"P95 응답\": \"${P95_DUR}\",
      \"주요 모델\": \"${TOP_MODELS}\",
      \"Langfuse UI\": \"http://localhost:3200\"
    },
    \"timestamp\": \"$(date '+%Y-%m-%d %H:%M')\"
  }" \
  --channel "${DISCORD_CHANNEL:-jarvis-system}" 2>/dev/null || true

echo "Report sent. Total calls: ${TOTAL_CALLS}, Tokens: ${TOTAL_TOKENS}, Cost: ${TOTAL_COST}"