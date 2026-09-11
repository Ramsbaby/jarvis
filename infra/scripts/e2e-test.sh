#!/usr/bin/env bash
set -uo pipefail

# Jarvis E2E Test Suite
# Usage: ~/.openclaw-data/jarvis/runtime/scripts/e2e-test.sh [--ntfy] (--ntfy sends test push notification)

# [2026-09-11] 기본값이 폐기된 옛 경로(~/jarvis)였다. 잡이 env 로 넘겨줄 때만 맞고
# 사람이 직접 돌리면 통째로 엉뚱한 곳을 검사한다.
#
# JARVIS_HOME 은 믿지 않는다 — runtime/.env 가 이 값을 `~/.jarvis`(= runtime 심링크)로
# 덮어쓴다. 그러면 트리 루트를 기대하는 검사가 runtime 을 보게 되고, 잡으로 돌릴 때만
# RAG 3건이 실패했다(손으로 돌리면 통과). **루트는 이 파일의 위치로 정한다** —
# 이 스크립트는 <root>/infra/scripts/ 에 있으므로 두 단계 위가 루트다. env 오염과 무관하다.
_E2E_SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
JARVIS_ROOT="$(cd -- "${_E2E_SELF}/../.." && pwd -P)"
export BOT_HOME="${BOT_HOME:-${JARVIS_ROOT}/runtime}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME:+${HOME}/.local/bin}:${PATH}"
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
  # [오픈클로 이식 2026-09-10] 디스코드를 전면 제거했다. 그 트리를 보는 검사 15건이 영구 FAIL 이 되고,
  # jarvis-auditor 가 FAIL 수만큼 매일 코더 티켓을 만든다(2026-09-10 FAIL 1 → 19 급증).
  # "없어서 실패"와 "일부러 없앰"을 가르지 않으면 감사 전체가 못 쓰게 된다.
  # 재개: rm ~/.openclaw-data/jarvis/runtime/state/stopped/discord-removed (검사도 함께 되살아난다)
  if [[ -f "${HOME}/.openclaw-data/jarvis/runtime/state/stopped/discord-removed" ]] && [[ "$* $name" == */discord/* || "$name" == *"discord"* || "$name" == *"Discord"* ]]; then
    skip "$name (디스코드 의도적 제거 — 2026-09-10)"
    return 0
  fi
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
# [2026-09-11] 기본값이 폐기된 옛 경로였다 — 실물은 ${JARVIS_HOME}/rag 에 있고 RAG 는 정상 가동 중인데
# 검사만 3건 영구 FAIL 이었다. BOT_HOME 과 같은 뿌리에서 유도해 다시 갈라지지 않게 한다.
JARVIS_RAG_HOME="${JARVIS_RAG_HOME:-${JARVIS_ROOT}/rag}"
check "RAG engine exists" test -f "$JARVIS_RAG_HOME/lib/rag-engine.mjs"
check "RAG query script exists" test -f "$JARVIS_RAG_HOME/lib/rag-query.mjs"
check "RAG indexer exists" test -f "$JARVIS_RAG_HOME/bin/rag-index.mjs"
check "ask-claude.sh exists" test -f "$BOT_HOME/bin/ask-claude.sh"
check "discord-bot.js exists" test -f "$BOT_HOME/discord/discord-bot.js"
check "tasks.json exists" test -f "$BOT_HOME/config/tasks.json"
ci_check "monitoring.json exists" test -f "$BOT_HOME/config/monitoring.json"

# --- Dependency Tests ---
echo ""
echo "▶ Dependencies"
check "LanceDB package installed" test -d "${HOME}/.openclaw-data/jarvis/rag/node_modules/@lancedb/lancedb"   # 2026-09-10: discord/ 제거로 경로 이동 — RAG 실제 설치 위치
check "OpenAI package installed" test -d "${HOME}/.openclaw-data/jarvis/infra/discord/node_modules/openai"   # 2026-09-10: runtime/discord 제거 후 infra/discord 잔존본이 실사용처
check "apache-arrow installed" test -d "${HOME}/.openclaw-data/jarvis/rag/node_modules/apache-arrow"   # 2026-09-10: RAG 실제 설치 위치
check "discord-bot.js syntax valid" node --check "$BOT_HOME/discord/discord-bot.js"
check "handlers.js syntax valid" node --check "$BOT_HOME/discord/lib/handlers.js"
check "handlers.js no-undef (ESLint)" bash -c "
  ESLINT=\$(command -v eslint 2>/dev/null \
    || ls '$BOT_HOME/discord/node_modules/.bin/eslint' 2>/dev/null \
    || echo '')
  [ -z \"\$ESLINT\" ] && { echo 'eslint not found'; exit 1; }
  \"\$ESLINT\" --no-eslintrc --no-ignore \
    --rule '{\"no-undef\": \"error\"}' \
    --env es2022,node \
    --parser-options '{\"ecmaVersion\":2022,\"sourceType\":\"module\"}' \
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
check "RAG query returns data" bash -c "
  for i in {1..3}; do
    result=\$(NODE_PATH=$BOT_HOME/discord/node_modules timeout 10 node $BOT_HOME/lib/rag-query.mjs 'system health' 2>&1 | grep -v '^[[:space:]]*\$' | grep -v '^\[rag-query\] ERROR' | head -1)
    if [[ -n \"\$result\" && \"\$result\" =~ [^[:space:]] ]]; then
      exit 0
    fi
    [[ \$i -lt 3 ]] && sleep 2
  done
  exit 1
"
warn_check "RAG deleted ratio < 40%" bash -c "
NODE_PATH=$BOT_HOME/discord/node_modules node --input-type=module <<'JSEOF'
import ldb from '$BOT_HOME/discord/node_modules/@lancedb/lancedb/dist/index.js';
try {
  const db = await ldb.connect('$BOT_HOME/rag/lancedb');
  const t = await db.openTable('documents').catch(() => null);
  if (!t) process.exit(0);
  const total = await t.countRows();
  if (total === 0) process.exit(0);
  const deleted = await t.countRows('deleted = true').catch(() => 0);
  const ratio = deleted / (total + deleted);
  process.exit(ratio < 0.4 ? 0 : 1);
} catch { process.exit(0); }
JSEOF
"

# --- State Files ---
echo ""
echo "▶ State Files"
ci_check "sessions.json valid" jq '.' "$BOT_HOME/state/sessions.json"
ci_check "rate-tracker.json valid" jq '.' "$BOT_HOME/state/rate-tracker.json"
warn_check "memory.md exists" test -f "$BOT_HOME/rag/memory.md"
warn_check "decisions weekly file exists" bash -c "ls \"$BOT_HOME/rag/decisions-\"*.md 2>/dev/null | grep -q ."

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
# [2026-09-11] crontab 만 보고 판정하던 검사 6건이 상시 FAIL 이었다.
# 오픈클로 이관으로 crontab 이 55줄 → 1줄로 줄었고, 스케줄 정의는 오픈클로 잡으로 옮겨갔다.
# 스케줄이 "등록돼 있는가"는 이제 두 층의 합집합이다. (2026-09-10 monitoring-pre-check 와 동일한 결함)
# grep -q 는 쓰지 않는다 — 첫 매칭에 파이프를 닫아 앞 명령이 SIGPIPE 로 죽고
# set -o pipefail 아래에서 거짓 실패가 된다. 출력을 변수로 받아 판정한다.
_SCHED_INVENTORY=""
_sched_load() {
  local cron_part="" openclaw_part=""
  cron_part="$(crontab -l 2>/dev/null | grep -v '^[[:space:]]*#')" || cron_part=""
  if [[ -x "${HOME}/bin/openclaw" ]]; then
    openclaw_part="$("${HOME}/bin/openclaw" cron list 2>/dev/null)" || openclaw_part=""
  fi
  _SCHED_INVENTORY="${cron_part}
${openclaw_part}"
}
sched_has() {   # sched_has <확장정규식>
  local n
  n="$(printf '%s\n' "$_SCHED_INVENTORY" | grep -Ec -- "$1")" || n=0
  [[ "${n:-0}" -gt 0 ]]
}
# tasks.json 에 그 id 가 있고 enabled:false 인가 = "일부러 껐다"
_sched_disabled_on_purpose() {   # <task-id>
  python3 - "$1" "${BOT_HOME}/config/tasks.json" <<'PY' 2>/dev/null
import json, sys
tid, path = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(1)
ts = d.get("tasks", d) if isinstance(d, dict) else d
if isinstance(ts, dict):
    ts = list(ts.values())
for t in ts:
    if str(t.get("id", "")) == tid:
        sys.exit(0 if t.get("enabled") is False else 1)
sys.exit(1)
PY
}
# 스케줄 검사는 3분기다 — 등록됨(PASS) · 일부러 껐음(SKIP) · 있어야 하는데 없음(FAIL).
# 셋을 안 가르면 의도적 비활성이 매일 FAIL 로 쌓이고 jarvis-auditor 가 그 수만큼 티켓을 만든다
# (2026-09-10 디스코드 제거 때 FAIL 1 → 19 로 터진 것과 같은 구조).
check_sched() {   # check_sched <표시명> <확장정규식> [tasks.json id]
  local name="$1" pattern="$2" tid="${3:-}"
  if sched_has "$pattern"; then
    green "✅ PASS: $name"; ((PASS++)); return 0
  fi
  if [[ -n "$tid" ]] && _sched_disabled_on_purpose "$tid"; then
    skip "$name (tasks.json enabled:false — 의도적 비활성)"; return 0
  fi
  red "❌ FAIL: $name"; ((FAIL++)); return 1
}
_sched_load

echo ""
echo "▶ Cron Jobs (crontab ∪ 오픈클로 잡)"
check_sched "RAG indexer cron exists" 'rag-index' 'rag-index'
check_sched "morning-standup cron exists" 'morning-standup|smart-standup' 'morning-standup'
check_sched "e2e-cron.sh registered" 'e2e-cron' 'e2e-cron'
# [2026-09-11] weekly-kpi 는 라이브 tasks.json·crontab·오픈클로 잡 어디에도 없다.
# 남은 흔적은 effective-tasks.json 백업(최신 2026-08-12)과 autonomy-levels.md 문서뿐이고,
# 스크립트(measure-kpi.sh)만 살아 있다. 폐지 기록이 없어 "없앴다"고 단정하지 않고 WARN 으로 남긴다.
warn_check "weekly-kpi cron exists" sched_has 'weekly-kpi'
check_sched "security-scan cron exists" 'security-scan' 'security-scan'
check_sched "rag-health cron exists" 'rag-health' 'rag-health'

# --- Phase 3~5 Tasks ---
echo ""
echo "▶ Phase 3~5 Context Files"
for task in weekly-kpi monthly-review security-scan rag-health profile-weekly cost-monitor; do
  warn_check "$task context exists" test -f "$BOT_HOME/context/$task.md"
done
check "autonomy-levels.md exists" test -f "$BOT_HOME/config/autonomy-levels.md"
ci_check "company-dna.md SSoT" test -f "$BOT_HOME/config/company-dna.md"
check "e2e-cron.sh executable" test -x "$BOT_HOME/scripts/e2e-cron.sh"

# --- Channel Routing ---
echo ""
echo "▶ Channel Routing"
ci_check "monitoring.json has webhooks" bash -c "jq -e '.webhooks' '$BOT_HOME/config/monitoring.json' > /dev/null 2>&1"
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
check "cron-catalog.md exists" test -f "${VAULT_DIR:-$HOME/vault}/01-system/cron-catalog.md"
warn_check "council reads shared-inbox" grep -q "shared-inbox" "$BOT_HOME/context/council-insight.md"
check "pending-tasks atomic write (renameSync)" grep -q "renameSync" "$BOT_HOME/discord/lib/handlers.js"
check "apology cooldown implemented" grep -q "apologyCooldownFile" "$BOT_HOME/discord/discord-bot.js"
check "active-session cleanup in finally" grep -q "active-session.*finally\|finally.*active-session\|activeProcesses.size === 0" "$BOT_HOME/discord/lib/handlers.js"
check "semaphore TOCTOU guard (stat fallback)" grep -q "stat.*2>/dev/null.*echo.*0\|2>/dev/null || echo" "$BOT_HOME/bin/semaphore.sh"
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
# Note: cron-catalog.md includes both tasks.json scheduled tasks AND actual crontab entries
TASKS_COUNT=$(python3 -c "
import json
try:
    with open('$BOT_HOME/config/tasks.json') as f:
        data = json.load(f)
    count = len([t for t in data['tasks'] if t.get('schedule', '').strip()])
    print(count)
except:
    print(0)
" 2>/dev/null)
# Catalog rows include header (2 rows) + data rows, so subtract 2 from total
CATALOG_DATA_COUNT=$(($(grep -c "^|" "${VAULT_DIR:-$HOME/vault}/01-system/cron-catalog.md" 2>/dev/null || echo 0) - 2))
if [[ "$CATALOG_DATA_COUNT" -ge "$TASKS_COUNT" ]]; then
  ci_check "cron-catalog matches tasks.json count" true
else
  ci_check "cron-catalog matches tasks.json count" false
fi

# --- LLM Output Quality Tests ---
echo ""
echo "▶ LLM Output Quality"

# 1. 최근 24시간 내 크론 결과물 존재 확인
check "cron results exist (last 24h)" bash -c "
  find '$BOT_HOME/results' -type f -name '*.md' -mmin -1440 2>/dev/null | grep -q .
"

# 2. 결과물 최소 크기 (10바이트 미만 = 빈 출력 = LLM 실패 가능성)
check "cron results min size (>=10B)" bash -c "
  tiny=0
  while IFS= read -r f; do
    sz=\$(wc -c < \"\$f\" 2>/dev/null || echo 0)
    if [[ \$sz -lt 10 ]]; then ((tiny++)); fi
  done < <(find '$BOT_HOME/results' -type f -name '*.md' -mmin -1440 2>/dev/null)
  [[ \$tiny -eq 0 ]]
"

# 3. 위키 팩트 중복 검사 (동일 문장 2회 이상 = 추출기 버그)
warn_check "wiki facts no duplicates" bash -c "
  dupes=0
  for f in '$BOT_HOME/wiki/'*/_facts.md; do
    [[ -f \"\$f\" ]] || continue
    # 빈 줄·헤더·메타 제외, 실제 팩트 행만 추출
    dup_count=\$(grep -E '^- ' \"\$f\" | sort | uniq -d | wc -l)
    dupes=\$((dupes + dup_count))
  done
  [[ \$dupes -eq 0 ]]
"

# 4. 위키 팩트 source 태그 존재 ([source:*] 없으면 감사 추적 불가)
warn_check "wiki facts have source tags" bash -c "
  missing=0
  for f in '$BOT_HOME/wiki/'*/_facts.md; do
    [[ -f \"\$f\" ]] || continue
    no_tag=\$(grep -E '^- ' \"\$f\" | grep -cv '\[source:' || true)
    missing=\$((missing + no_tag))
  done
  [[ \$missing -eq 0 ]]
"

# 5. bot-quality-check 최근 실행 (24시간 내 로그 갱신 확인)
warn_check "bot-quality-check ran (last 24h)" bash -c "
  log='$BOT_HOME/logs/bot-quality-check.log'
  [[ -f \"\$log\" ]] && find \"\$log\" -mmin -1440 | grep -q .
"

# 6. 크론 결과물 환각 키워드 검사 (LLM 자기반성 패턴 과다 = 품질 문제)
warn_check "cron results no hallucination patterns" bash -c "
  hits=0
  total=0
  while IFS= read -r f; do
    ((total++))
    if grep -qiE '죄송합니다|제가 잘못|오류가 있었습니다|실수했습니다|잘못된 정보|혼동을 드려|I apologize|my mistake' \"\$f\" 2>/dev/null; then
      ((hits++))
    fi
  done < <(find '$BOT_HOME/results' -type f -name '*.md' -mmin -1440 2>/dev/null)
  # 전체의 30% 이상이면 경고 (소수는 정상 범위)
  if [[ \$total -eq 0 ]]; then exit 0; fi
  threshold=\$(( (total * 30 + 99) / 100 ))
  [[ \$hits -lt \$threshold ]]
"

# --- Guard Test Suites (SELF-HEAL-PLAN 2e, 2026-09-04) ---
# 결정적 스위트만(LLM 호출 없음, 각 2분 상한). 마지막 "PASSED=N FAILURES=M" 줄이 있으면 그것으로, 없으면 exit code 로 판정.
# 스위트 내부 출력은 삼킨다 — e2e-cron.sh 가 ✅/❌ 줄 수를 세므로 여기 한 줄만 남긴다.
echo ""
echo "▶ Guard Test Suites"
_SUITE_TIMEOUT=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || true)
suite_check() {
  local name="$1" path="$2" out rc line
  if [[ ! -f "$path" ]]; then skip "$name (파일 없음: $path)"; return; fi
  if [[ -n "$_SUITE_TIMEOUT" ]]; then
    out=$(JARVIS_NO_EXTERNAL=1 "$_SUITE_TIMEOUT" 120 bash "$path" 2>&1); rc=$?
  else
    out=$(JARVIS_NO_EXTERNAL=1 bash "$path" 2>&1); rc=$?
  fi
  line=$(printf '%s\n' "$out" | grep -Eo 'PASSED=[0-9]+ FAILURES=[0-9]+' | tail -1)
  if [[ $rc -eq 0 && ( -z "$line" || "$line" == *"FAILURES=0" ) ]]; then
    green "✅ PASS: $name${line:+ ($line)}"
    ((PASS++))
  else
    red "❌ FAIL: $name (${line:-exit $rc})"
    ((FAIL++))
  fi
}
_HOOKS_DIR="${HOME}/.claude/hooks"
suite_check "coder fail-closed"            "$BOT_HOME/scripts/test-coder-fail-closed.sh"
suite_check "coder worktree isolation"     "$BOT_HOME/scripts/test-coder-worktree.sh"
suite_check "coder FSM ownership"          "$BOT_HOME/scripts/test-coder-fsm-ownership.sh"
suite_check "coder merge gate+autonomy"    "$BOT_HOME/scripts/test-coder-merge.sh"
suite_check "coder review+expiry"          "$BOT_HOME/scripts/test-coder-review.sh"
suite_check "incident ledger+ingest"       "$BOT_HOME/scripts/test-incident-ledger.sh"
suite_check "rule proposals+promoter"      "$BOT_HOME/scripts/test-rule-proposals.sh"
suite_check "sensor deadman switch"        "$BOT_HOME/scripts/test-sensor-deadman.sh"
suite_check "self-heal weekly retro"       "$BOT_HOME/scripts/test-self-heal-retro.sh"
suite_check "auditor e2e guard (dirty+cooldown)" "$BOT_HOME/scripts/test-auditor-e2e-guard.sh"
suite_check "cron-auditor DB judge+evidence" "$BOT_HOME/scripts/test-cron-auditor-judge.sh"
suite_check "JARVIS_NO_EXTERNAL egress"    "$BOT_HOME/scripts/test-no-external.sh"
suite_check "tasks.json integrity sensor"  "$BOT_HOME/scripts/test-tasks-json-integrity.sh"
suite_check "completion guard"             "$BOT_HOME/scripts/test-completion-guard.sh"
suite_check "compress analyzer"            "$BOT_HOME/scripts/test-compress-analyzer.sh"
suite_check "context-state gate"           "$BOT_HOME/scripts/test-context-state-gate.sh"
suite_check "hook canary"                  "$BOT_HOME/scripts/hook-canary-test.sh"
suite_check "agent write boundary hook"    "$_HOOKS_DIR/jarvis-agent-write-boundary.test.sh"
suite_check "runtime destruction guard"    "$_HOOKS_DIR/jarvis-runtime-guard.test.sh"

# --- Tasks Schema Validation ---
echo ""
echo "▶ Tasks Schema Validation"
VALIDATE_SCRIPT="${BOT_HOME}/infra/scripts/validate-tasks.sh"
if [[ -x "$VALIDATE_SCRIPT" ]]; then
  check "tasks.json schema lint" bash -c "'$VALIDATE_SCRIPT' 2>&1 | tail -1 | grep -q '✅'"
else
  skip "validate-tasks.sh not found"
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