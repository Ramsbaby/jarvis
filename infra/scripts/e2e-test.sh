#!/usr/bin/env bash
set -uo pipefail

# Jarvis E2E Test Suite
# Usage: ~/.openclaw-data/runtime/scripts/e2e-test.sh [--ntfy] (--ntfy sends test push notification)

# [2026-09-11] 기본값이 폐기된 옛 경로(~/jarvis)였다. 잡이 env 로 넘겨줄 때만 맞고
# 사람이 직접 돌리면 통째로 엉뚱한 곳을 검사한다.
#
# JARVIS_HOME 은 믿지 않는다 — runtime/.env 가 이 값을 `~/.jarvis`(= runtime 심링크)로
# 덮어쓴다. 그러면 트리 루트를 기대하는 검사가 runtime 을 보게 되고, 잡으로 돌릴 때만
# RAG 3건이 실패했다(손으로 돌리면 통과). **루트는 이 파일의 위치로 정한다** —
# 이 스크립트는 <root>/infra/scripts/ 에 있으므로 두 단계 위가 루트다. env 오염과 무관하다.
_E2E_SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
JARVIS_ROOT="$(cd -- "${_E2E_SELF}/../.." && pwd -P)"
# [2026-09-14 정정] 위 9/11 수정은 "런타임은 코드 루트 밑에 있다"를 전제했다.
#   회차 8(9/12)이 런타임을 밖으로 빼면서 그 전제가 깨졌다 — ${JARVIS_ROOT}/runtime 은
#   이제 읽기전용 장벽 파일이라, 잡은 BOT_HOME 을 넘겨줘서 멀쩡한데 **손으로 돌리면 8건이 무더기 실패**했다.
#   이틀 전에 고친 병을 방향만 바꿔 내가 다시 만든 것이다.
#   런타임 위치는 코드 루트에서 유도하지 않는다 — 데이터와 코드는 다른 트리에 산다.
export BOT_HOME="${BOT_HOME:-${JARVIS_RUNTIME:-$HOME/.openclaw-data/runtime}}"
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
  # [2026-10-10] 여기 있던 "디스코드 제거 플래그가 있으면 이름·명령에 discord 가 든 검사를 SKIP" 글롭을 없앴다.
  #   디스코드 봇 전용 검사 16건은 아래에서 통째로 뺐고(대상이 영구히 없다), 글롭은 그 뒤에도 살아 있는 검사
  #   "RAG query returns data"(명령 문자열에 /discord/ 경로가 있었다)를 09-10 부터 조용히 SKIP 시키고 있었다 —
  #   건너뛴 점검이 '실패 없음'으로 읽혀 91개 중 26개가 아무것도 재지 않은 채 "65/91 passed" 로 보고됐다.
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
check "tasks.json exists" test -f "$BOT_HOME/config/tasks.json"
ci_check "monitoring.json exists" test -f "$BOT_HOME/config/monitoring.json"

# --- Dependency Tests ---
echo ""
echo "▶ Dependencies"
check "LanceDB package installed" test -d "${HOME}/projects/jarvis/rag/node_modules/@lancedb/lancedb"   # 2026-09-10: discord/ 제거로 경로 이동 — RAG 실제 설치 위치
check "apache-arrow installed" test -d "${HOME}/projects/jarvis/rag/node_modules/apache-arrow"   # 2026-09-10: RAG 실제 설치 위치

# --- RAG Tests ---
echo ""
echo "▶ RAG Engine"

check "LanceDB directory exists" test -d "$BOT_HOME/rag/lancedb"
# [2026-10-10] 이 검사는 $BOT_HOME/discord/node_modules·$BOT_HOME/lib/rag-query.mjs(둘 다 없다)를 읽어 영구 FAIL 이 될 것이었는데,
#   위 check() 의 discord 글롭에 걸려 09-10 부터 SKIP 으로만 남았다 — 살아 있는 RAG 질의를 한 번도 못 쟀다.
#   실제 엔진 위치(${JARVIS_RAG_HOME})로 옮기고, "문서를 한 건이라도 돌려줬는가"(### From: 줄)로 판정한다 —
#   머리말만 있는 빈 결과는 통과가 아니다.
#   env -u: RAG 엔진은 JARVIS_RAG_HOME 을 '데이터 폴더'로 읽는데 이 스크립트는 같은 이름을 '코드 폴더'로 쓴다(이름 충돌).
#   자식에게 새어 나가면 엉뚱한 폴더를 보고 빈 결과가 나온다(10-10 시험에서 실측) — 데이터 위치는 BOT_HOME/rag 로 찾게 둔다.
check "RAG query returns data" bash -c "
  T=\$(command -v gtimeout || command -v timeout || true)
  for i in 1 2 3; do
    out=\$(env -u JARVIS_RAG_HOME \$T 20 node '$JARVIS_RAG_HOME/lib/rag-query.mjs' 'system health' 2>/dev/null)
    if printf '%s\n' \"\$out\" | grep -q '^### From:'; then exit 0; fi
    [[ \$i -lt 3 ]] && sleep 2
  done
  exit 1
"
# [2026-09-26] 모듈을 $BOT_HOME/discord/node_modules 에서 읽었는데 그 트리는 2026-09-10 디스코드 제거로 없다 —
#   import 가 매번 죽어 09-13 부터 "not yet generated" WARN 으로 고정됐다(실측 비율은 335/111402 = 0.3%).
#   RAG 가 실제로 쓰는 설치 위치(위 "LanceDB package installed" 와 같은 곳)로 옮기고,
#   예외·테이블 없음을 조용한 통과(exit 0)로 삼키지 않는다 — 측정을 못 했으면 못 했다고 운다.
warn_check "RAG deleted ratio < 40%" bash -c "
node --input-type=module <<'JSEOF'
import ldb from '${JARVIS_ROOT}/rag/node_modules/@lancedb/lancedb/dist/index.js';
try {
  const db = await ldb.connect('$BOT_HOME/rag/lancedb');
  const t = await db.openTable('documents').catch(() => null);
  if (!t) process.exit(1);
  const total = await t.countRows();
  if (total === 0) process.exit(0);
  const deleted = await t.countRows('deleted = true').catch(() => 0);
  const ratio = deleted / (total + deleted);
  process.exit(ratio < 0.4 ? 0 : 1);
} catch { process.exit(1); }
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
  # [2026-09-26] 표 출력(`cron list`)은 이름을 24자에서 자른다(`jarvis-automation-bro...`) — 긴 이름은 영영 안 맞는다.
  #   JSON 으로 받아 이름 + 실행 명령을 한 줄씩 편다. 기본 필터가 "켜진 잡만"이다(107건 중 꺼진 것 0 실측).
  if [[ -x "${HOME}/bin/openclaw" ]]; then
    openclaw_part="$("${HOME}/bin/openclaw" cron list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
for j in (d if isinstance(d, list) else d.get("jobs", [])):
    if j.get("enabled", True) is False:
        continue
    p = j.get("payload") or {}
    cmd = p.get("argv") or p.get("command") or ""
    print(j.get("name", ""), " ".join(cmd) if isinstance(cmd, list) else cmd)
' 2>/dev/null)" || openclaw_part=""
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

# [2026-09-26] "not yet generated" 경고 10건이 09-13 부터 매일 똑같았다. 가려 보니 죽은 잡은 0건이고
#   7건은 은퇴(09-09 미등록 고아 정리·09-10 디스코드 중지), 1건은 스크립트 잡으로 이관, 2건은 검사 자체가 깨져 있었다.
#   고정된 경고는 경고가 아니다 — 진짜 누락이 생겨도 같은 줄에 묻힌다. 그래서 "살아 있는 잡의 산출물만" 요구한다.
#   은퇴 목록을 여기에 박지 않는다. tasks.json 과 활성 스케줄이 정본이고, 되살리면 검사도 저절로 돌아온다.
_task_state() {   # <task-id> → "enabled" | "disabled::사유" | "absent" | "unreadable"
  python3 - "$1" "${E2E_TASKS_JSON:-${BOT_HOME}/config/tasks.json}" <<'PY' 2>/dev/null || echo unreadable
import json, sys
tid, path = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    print("unreadable")   # 정본을 못 읽으면 "은퇴"로 넘기지 않는다
    sys.exit(0)
ts = d.get("tasks", d) if isinstance(d, dict) else d
if isinstance(ts, dict):
    ts = list(ts.values())
for t in ts:
    if str(t.get("id", "")) == tid:
        if t.get("enabled") is False:
            print("disabled::" + str(t.get("_disabled_reason") or "사유 미기재"))
        else:
            print("enabled")
        sys.exit(0)
print("absent")
PY
}
_retired_note() {   # <task-id> <state> → SKIP 사유
  case "$2" in
    disabled*) printf 'tasks.json enabled:false — %s' "${2#disabled::}" ;;
    *)         printf 'tasks.json 정의 없음 · 활성 스케줄 없음 — 은퇴 (docs/plan/capability-ledger.md)' ;;
  esac
}
# ctx_check <표시명> <task-id> <명령...> — 컨텍스트 파일은 옛 실행기(bot-cron.sh)가 tasks.json 의 켜진 태스크에만 읽는다.
#   오픈클로 잡은 이 파일을 읽지 않는다(rag-health 는 2026-09-10 스크립트 잡으로 이관). 켜진 태스크인데 없으면 WARN.
ctx_check() {
  local name="$1" tid="$2" state; shift 2
  if "$@" >/dev/null 2>&1; then green "✅ PASS: $name"; ((PASS++)); return 0; fi
  state="$(_task_state "$tid")"
  if [[ "$state" == "enabled" || "$state" == "unreadable" ]]; then
    yellow "⚠️  WARN: $name — ${state/enabled/켜진 태스크(tasks.json $tid)인데 없다}"; ((WARN++)); return 1
  fi
  skip "$name ($(_retired_note "$tid" "$state"))"
}
# out_check <표시명> <task-id> <스케줄 정규식> <명령...> — 산출물은 어느 실행기든 살아 있으면 요구한다.
out_check() {
  local name="$1" tid="$2" pattern="$3" state; shift 3
  if "$@" >/dev/null 2>&1; then green "✅ PASS: $name"; ((PASS++)); return 0; fi
  state="$(_task_state "$tid")"
  if [[ "$state" == "enabled" || "$state" == "unreadable" ]] || sched_has "$pattern"; then
    yellow "⚠️  WARN: $name — 살아 있는 잡인데 산출물이 없다"; ((WARN++)); return 1
  fi
  skip "$name ($(_retired_note "$tid" "$state"))"
}
_sched_load

echo ""
echo "▶ Cron Jobs (crontab ∪ 오픈클로 잡)"
check_sched "RAG indexer cron exists" 'rag-index' 'rag-index'
# [2026-10-10] morning-standup·weekly-kpi 은퇴 점검 삭제 — tasks.json 에서 꺼졌고(enabled:false) 오픈클로 잡도 없다(measure-kpi 잡은 꺼짐).
#   은퇴한 것을 매일 "건너뜀"으로 세면 재지 않은 점검이 통과처럼 읽힌다. 되살릴 때는 이 자리에 check_sched 한 줄을 다시 넣는다.
check_sched "e2e-cron.sh registered" 'e2e-cron' 'e2e-cron'
check_sched "security-scan cron exists" 'security-scan' 'security-scan'
check_sched "rag-health cron exists" 'rag-health' 'rag-health'

# --- Phase 3~5 Tasks ---
echo ""
echo "▶ Phase 3~5 Context Files"
# [2026-10-10] 컨텍스트 파일은 옛 실행기(bot-cron.sh)가 tasks.json 의 켜진 태스크에만 읽는다. weekly-kpi·monthly-review·rag-health·
#   profile-weekly·cost-monitor 는 전부 꺼졌거나 오픈클로 잡으로 옮겨가 파일을 읽는 쪽이 없어 매일 SKIP 이었다 → 삭제.
#   살아 있는 security-scan 만 남긴다.
ctx_check "security-scan context exists" security-scan test -f "$BOT_HOME/context/security-scan.md"
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
check "semaphore TOCTOU guard (stat fallback)" grep -q "stat.*2>/dev/null.*echo.*0\|2>/dev/null || echo" "$BOT_HOME/bin/semaphore.sh"
check "watchdog active_ts validation" grep -q "active_ts.*\^.*0-9" "$BOT_HOME/scripts/watchdog.sh"
check "tasks.json disk-alert has allowEmptyResult" bash -c "jq -e '.tasks[] | select(.id==\"disk-alert\") | .allowEmptyResult' '$BOT_HOME/config/tasks.json' > /dev/null 2>&1"
# [2026-10-10] 디스코드 봇 전용 검사 삭제: "pending-tasks atomic write"·"apology cooldown"·"active-session cleanup"·"streaming GC hint"
#   (봇 소스 파일 grep — 봇은 09-10 제거) · "handleMessage error rate OK (smoke)"(logs/discord-bot.jsonl 이 없으면 `except: sys.exit(0)` 로
#   무조건 통과하던 빈 점검 — 통과 65개 중 하나가 아무것도 안 재고 있었다).

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
# [2026-09-26] 태그는 2026-04-15 에 도입됐다(그날 줄이 섞여 있다). 그 전 날짜 줄 109개(ops, 04-14~15 디스코드 조각)와
#   날짜 없는 손 메모 7줄(career)이 전체를 영구 WARN 으로 붙잡아, 추출기가 태그를 빠뜨리는 회귀가 나도 안 보였다.
#   추출기는 항상 "- [YYYY-MM-DD] [source:…]" 로 쓴다 → **도입 뒤 날짜인데 태그 없는 줄만** 회귀로 센다.
#   유산 줄 수는 통과 줄에 적어 둔다(없어진 게 아니라 알고 넘기는 것이다).
wiki_untagged() {   # <wiki-dir> → "recent=N legacy=M", recent>0 이면 1
  python3 - "$1" <<'PY'
import glob, os, re, sys
recent = legacy = 0
for f in glob.glob(os.path.join(sys.argv[1], "*", "_facts.md")):
    for line in open(f, encoding="utf-8", errors="ignore"):
        if not line.startswith("- ") or "[source:" in line:
            continue
        m = re.match(r"- \[(\d{4}-\d{2}-\d{2})\]", line)
        if m and m.group(1) > "2026-04-15":
            recent += 1
        else:
            legacy += 1
print(f"recent={recent} legacy={legacy}")
sys.exit(1 if recent else 0)
PY
}
if _wt="$(wiki_untagged "$BOT_HOME/wiki")"; then
  green "✅ PASS: wiki facts have source tags (도입 뒤 누락 0 · 도입 전 유산 ${_wt#*legacy=}줄)"; ((PASS++))
else
  yellow "⚠️  WARN: wiki facts have source tags — 도입(2026-04-15) 뒤 태그 없는 줄 ${_wt%% *} · 추출기 회귀 의심"; ((WARN++))
fi

# 5. (삭제 2026-10-10) bot-quality-check 최근 실행 — 디스코드 봇 로그 의존 잡이라 봇 제거(09-10)로 분석 대상이 사라졌다. 매일 SKIP 이었다.

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
suite_check "e2e harness (retired/abort)"  "$BOT_HOME/scripts/test-e2e-harness.sh"

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
  # 선택 시험(--ntfy)을 요청하지 않은 것은 '건너뛴 점검'이 아니다 — SKIP 으로 세면 매일 건너뜀 1건이 고정된다.
  echo "  ℹ️  ntfy 송신 시험은 --ntfy 로만 돌린다(이번 실행엔 요청 없음 — 건너뜀으로 세지 않음)"
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