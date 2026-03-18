#!/usr/bin/env bash
set -uo pipefail

# Jarvis E2E Test Suite
# Usage: ~/.jarvis/scripts/e2e-test.sh [--ntfy] (--ntfy sends test push notification)

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export BOT_HOME="${BOT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PASS=0
FAIL=0
SKIP=0
WARN=0
SEND_NTFY="${1:-}"
CI_MODE="${GITHUB_ACTIONS:-false}"

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$1"; }

check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    green "✅ PASS: $name"
    ((PASS++))
  else
    red "❌ FAIL: $name"
    ((FAIL++))
  fi
}

skip() {
  yellow "⏭️  SKIP: $1"
  ((SKIP++))
}

# warn_check: runtime-generated files (not present on first install, created by crons)
warn_check() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    green "✅ PASS: $name"
    ((PASS++))
  else
    yellow "⚠️  WARN: $name — not yet generated (run crons once to create)"
    ((WARN++))
  fi
}

# ci_check: runtime-only checks (bot running, crontab, state files)
# In CI (GITHUB_ACTIONS=true): treated as WARN (expected not to exist)
# Locally: treated as hard FAIL
ci_check() {
  if [[ "$CI_MODE" == "true" ]]; then
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
      green "✅ PASS: $name"
      ((PASS++))
    else
      yellow "⚠️  WARN(CI): $name — expected in CI environment"
      ((WARN++))
    fi
  else
    check "$@"
  fi
}

echo "═══════════════════════════════════════════"
echo "  Jarvis E2E Test Suite"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════"
echo ""

# --- Process Tests ---
echo "▶ Process Health"
ci_check "Discord bot running" bash -c 'pgrep -f "discord-bot.js|orchestrator.mjs" > /dev/null 2>&1'

# --- File Structure Tests ---
echo ""
echo "▶ File Structure"
check "RAG engine exists" test -f "$BOT_HOME/lib/rag-engine.mjs"
check "RAG query script exists" test -f "$BOT_HOME/lib/rag-query.mjs"
check "RAG indexer exists" test -f "$BOT_HOME/bin/rag-index.mjs"
check "ask-claude.sh exists" test -f "$BOT_HOME/bin/ask-claude.sh"
check "discord-bot.js exists" test -f "$BOT_HOME/discord/discord-bot.js"
check "tasks.json exists" test -f "$BOT_HOME/config/tasks.json"
check "monitoring.json exists" test -f "$BOT_HOME/config/monitoring.json"

# --- Dependency Tests ---
echo ""
echo "▶ Dependencies"
check "LanceDB package installed" test -d "$BOT_HOME/discord/node_modules/@lancedb/lancedb"
check "OpenAI package installed" test -d "$BOT_HOME/discord/node_modules/openai"
check "apache-arrow installed" test -d "$BOT_HOME/discord/node_modules/apache-arrow"
check "discord-bot.js syntax valid" node --check "$BOT_HOME/discord/discord-bot.js"
check "handlers.js syntax valid" node --check "$BOT_HOME/discord/lib/handlers.js"
check "handlers.js no-undef (ESLint)" bash -c "
  ESLINT=\$(command -v eslint 2>/dev/null || echo '')
  [ -z \"\$ESLINT\" ] && { echo 'eslint not found'; exit 1; }
  \"\$ESLINT\" --no-eslintrc \
    --rule '{\"no-undef\": \"error\"}' \
    --env es2022,node \
    --parser-options '{\"sourceType\":\"script\"}' \
    '$BOT_HOME/discord/lib/handlers.js' 2>&1 | grep -q ' error ' && exit 1 || exit 0
"

# --- RAG Tests ---
echo ""
echo "▶ RAG Engine"

# Run initial index if LanceDB directory doesn't exist
if [[ ! -d "$BOT_HOME/rag/lancedb" ]]; then
  echo "  ℹ️  Running initial RAG index..."
  NODE_PATH="$BOT_HOME/discord/node_modules" node "$BOT_HOME/bin/rag-index.mjs" 2>/dev/null || true
fi

check "LanceDB directory exists" test -d "$BOT_HOME/rag/lancedb"
check "RAG query returns data" bash -c "NODE_PATH=$BOT_HOME/discord/node_modules node $BOT_HOME/lib/rag-query.mjs 'system health' 2>&1 | grep -v '^[[:space:]]*$' | grep -v '^\[rag-query\] ERROR' | head -1 | grep -q ."

# --- State Files ---
echo ""
echo "▶ State Files"
ci_check "sessions.json valid" jq '.' "$BOT_HOME/state/sessions.json"
ci_check "rate-tracker.json valid" jq '.' "$BOT_HOME/state/rate-tracker.json"
ci_check "memory.md exists" test -f "$BOT_HOME/rag/memory.md"
ci_check "decisions weekly file exists" bash -c "ls \"$BOT_HOME/rag/decisions-\"*.md 2>/dev/null | grep -q ."

# --- ask-claude.sh RAG Integration ---
echo ""
echo "▶ ask-claude.sh Integration"
check "ask-claude.sh has RAG integration" grep -q "rag-query.mjs" "$BOT_HOME/lib/context-loader.sh"
check "ask-claude.sh has fallback" grep -q "Fallback" "$BOT_HOME/lib/llm-gateway.sh"

# --- Discord Bot Features ---
echo ""
echo "▶ Discord Bot Features"
check "ntfy integration" grep -q "sendNtfy" "$BOT_HOME/discord/discord-bot.js"
check "RAG context injection" grep -q "ragContext" "$BOT_HOME/discord/lib/claude-runner.js"
check "/search command" grep -q "'search'" "$BOT_HOME/discord/discord-bot.js"
check "/threads command" grep -q "'threads'" "$BOT_HOME/discord/discord-bot.js"
check "/alert command" grep -q "'alert'" "$BOT_HOME/discord/discord-bot.js"

# --- Cron Tests ---
echo ""
echo "▶ Cron Jobs"
ci_check "RAG indexer cron exists" bash -c "crontab -l 2>/dev/null | grep -q 'rag-index'"
ci_check "morning-standup cron exists" bash -c "crontab -l 2>/dev/null | grep -qE 'morning-standup|smart-standup'"
ci_check "e2e-cron.sh registered" bash -c "crontab -l 2>/dev/null | grep -q 'e2e-cron'"
ci_check "weekly-kpi cron exists" bash -c "crontab -l 2>/dev/null | grep -q 'weekly-kpi'"
ci_check "security-scan cron exists" bash -c "crontab -l 2>/dev/null | grep -q 'security-scan'"
ci_check "rag-health cron exists" bash -c "crontab -l 2>/dev/null | grep -q 'rag-health'"

# --- Phase 3~5 Tasks ---
echo ""
echo "▶ Phase 3~5 Context Files"
for task in weekly-kpi monthly-review security-scan rag-health career-weekly cost-monitor; do
  warn_check "$task context exists" test -f "$BOT_HOME/context/$task.md"
done
check "autonomy-levels.md exists" test -f "$BOT_HOME/config/autonomy-levels.md"
check "company-dna.md SSoT" test -f "$BOT_HOME/config/company-dna.md"
check "e2e-cron.sh executable" test -x "$BOT_HOME/scripts/e2e-cron.sh"

# --- Channel Routing ---
echo ""
echo "▶ Channel Routing"
check "monitoring.json has webhooks" bash -c "jq -e '.webhooks' '$BOT_HOME/config/monitoring.json' > /dev/null 2>&1"
check "route-result.sh supports channel arg" bash -c "grep -q 'CHANNEL' '$BOT_HOME/bin/route-result.sh'"
check "bot-cron.sh passes channel" bash -c "grep -q 'DISCORD_CHANNEL' '$BOT_HOME/bin/bot-cron.sh'"

# --- Document Consistency Tests ---
echo ""
echo "▶ Document Consistency (DocDD)"
check "ADR index exists" test -f "$BOT_HOME/adr/ADR-INDEX.md"
check "ADR-001 exists" test -f "$BOT_HOME/adr/ADR-001.md"
check "tasks.json has depends field" bash -c "jq -e '.tasks[0].depends' '$BOT_HOME/config/tasks.json' > /dev/null 2>&1"
check "ask-claude.sh has cross-team context" grep -q "Cross-team Context" "$BOT_HOME/lib/context-loader.sh"
check "ask-claude.sh has insight filter" grep -q "system-health|rate-limit-check" "$BOT_HOME/lib/insight-recorder.sh"
check "gen-inventory.sh exists" test -x "$BOT_HOME/scripts/gen-inventory.sh"
ci_check "cron-catalog.md exists" test -f "$HOME/Jarvis-Vault/01-system/cron-catalog.md"
warn_check "council reads shared-inbox" grep -q "shared-inbox" "$BOT_HOME/context/council-insight.md"
check "pending-tasks atomic write (renameSync)" grep -q "renameSync" "$BOT_HOME/discord/lib/handlers.js"
check "apology cooldown implemented" grep -q "apologyCooldownFile" "$BOT_HOME/discord/discord-bot.js"
check "active-session cleanup in finally" grep -q "active-session.*finally\|finally.*active-session\|activeProcesses.size === 0" "$BOT_HOME/discord/lib/handlers.js"
check "semaphore TOCTOU guard (stat fallback)" grep -q "stat.*2>/dev/null.*echo.*0\|2>/dev/null || echo" "$BOT_HOME/bin/semaphore.sh"
check "market-holiday-guard has hours check" grep -q "UTC_MINS" "$BOT_HOME/scripts/market-holiday-guard.sh"
check "watchdog active_ts validation" grep -q "active_ts.*\^.*0-9" "$BOT_HOME/scripts/watchdog.sh"
check "tasks.json disk-alert has allowEmptyResult" bash -c "jq -e '.tasks[] | select(.id==\"disk-alert\") | .allowEmptyResult' '$BOT_HOME/config/tasks.json' > /dev/null 2>&1"
check "streaming GC hint in finalize" grep -q "this\.buffer = ''" "$BOT_HOME/discord/lib/streaming.js"
check "handleMessage error rate OK (smoke)" bash -c "
  python3 - <<'PYEOF'
import json, sys
from datetime import datetime, timezone, timedelta
cutoff = datetime.now(timezone.utc) - timedelta(hours=1)
errors = total = 0
try:
    with open('$BOT_HOME/logs/discord-bot.jsonl') as f:
        for line in f:
            try:
                d = json.loads(line)
                ts = d.get('ts', '')
                if not ts: continue
                t = datetime.fromisoformat(ts.replace('Z', '+00:00'))
                if t < cutoff: continue
                msg = d.get('msg', '')
                if msg == 'handleMessage error': errors += 1
                elif msg in ('Starting Claude session', 'Session summary pre-injected for resume safety'): total += 1
            except: pass
except: sys.exit(0)
if errors >= 5 and total > 0 and errors / max(total, 1) > 0.5:
    print(f'handleMessage errors: {errors}/{max(total,1)} ({errors/max(total,1)*100:.0f}%)')
    sys.exit(1)
sys.exit(0)
PYEOF
"

# Cron-catalog vs actual crontab consistency
TASKS_COUNT=$(jq '[.tasks[] | select(.schedule != null and .schedule != "")] | length' "$BOT_HOME/config/tasks.json" 2>/dev/null || echo 0)
CATALOG_COUNT=$(grep -c "^|" "$HOME/Jarvis-Vault/01-system/cron-catalog.md" 2>/dev/null || echo 0)
if [[ "$CATALOG_COUNT" -ge "$TASKS_COUNT" ]]; then
  ci_check "cron-catalog matches tasks.json count" true
else
  ci_check "cron-catalog matches tasks.json count" false
fi

# --- ntfy Test (optional) ---
echo ""
echo "▶ ntfy Push Notification"
if [[ "$SEND_NTFY" == "--ntfy" ]]; then
  check "ntfy test send" curl -sf -o /dev/null \
    -H "Title: Jarvis E2E Test" \
    -H "Priority: low" \
    -H "Tags: test_tube" \
    -d "E2E test passed at $(date '+%H:%M:%S')" \
    "https://ntfy.sh/${NTFY_TOPIC:-test-topic}"
else
  skip "ntfy test send (use --ntfy flag to test)"
fi

# --- Summary ---
echo ""
echo "═══════════════════════════════════════════"
TOTAL=$((PASS + FAIL + SKIP + WARN))
echo "  Results: $(green "$PASS passed"), $(red "$FAIL failed"), $(yellow "$WARN warned"), $(yellow "$SKIP skipped") / $TOTAL total"
if [[ $WARN -gt 0 ]]; then
  yellow "  ℹ️  Warnings = runtime files not yet generated. Run crons once to clear."
fi
echo "═══════════════════════════════════════════"

exit $((FAIL > 0 ? 1 : 0))
