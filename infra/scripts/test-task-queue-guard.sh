#!/usr/bin/env bash
# test-task-queue-guard.sh — 개발 큐 생산 관문(lib/task-queue-guard.mjs) 회귀 테스트 (2026-10-03)
#
# 배경: 소비자 잡 jarvis-dev-task-runner 가 2026-09-10 부터 꺼져 있는데 생산자가 tasks.db 에 계속 넣었다
#       (10-03 pending 81 · queued 21). 관문이 꺼져 있으면 생산자는 태스크만 넣지 않고 나머지 산출물은 그대로 쓴다.
# 검증 대상 (임시 HOME·BOT_HOME + 가짜 게이트웨이 DB·가짜 llm-gateway/discord-route — LLM 호출·외부 송출 없음):
#   A. 관문 판정 — 강제값 1/0 · 소비자 잡 enabled 1/0 · 미등록 · DB 없음 · 표 없음(모르면 끔) · CLI 종료코드 0/3
#   B. insight-extractor actionRouter — 꺼짐: addTask 없음 + memory.md·owner profile 은 씀 / 켜짐: pending 태스크 생성
#   C. mistake-promoter tier_b — 꺼짐: enqueue 없음 + ledger proposed_dev_queue(dev_queue_action=skip-queue-off)
#                                켜짐: queued 태스크 생성 + dev_queue_action=enqueued
#   (jarvis-auditor 는 test-auditor-e2e-guard.sh ⑥-b 에서 본다)
# 실행: bash ~/projects/jarvis/infra/scripts/test-task-queue-guard.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
INFRA="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d /var/tmp/task-queue-guard-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
PASSED=0; FAILURES=0
ok()   { PASSED=$((PASSED+1)); }
fail() { FAILURES=$((FAILURES+1)); echo "  ✗ $*"; }
expect_eq()  { [[ "$2" == "$3" ]] && ok || fail "$1: expected [$3] got [$2]"; }
expect_has() { grep -qF -- "$3" <<<"$2" && ok || fail "$1: [$3] 없음 in: $(head -c 400 <<<"$2")"; }
expect_not() { grep -qF -- "$3" <<<"$2" && fail "$1: 있으면 안 되는 [$3]" || ok; }

# 진짜 ~/.openclaw · ~/.claude-bot · runtime 을 읽거나 쓰지 않게 가둔다
export HOME="$T/home"; mkdir -p "$HOME"
export BOT_HOME="$T/runtime"; mkdir -p "$BOT_HOME"/{config,state,ledger,logs,rag,wiki/meta}   # rag/ 는 운영에 늘 있다(memory.md 는 디렉터리를 만들지 않는다)
export JARVIS_NO_EXTERNAL=1
export CLAUDE_CODE_OAUTH_TOKEN=test-dummy   # insight-extractor 가 모듈 적재 때 토큰 파일을 읽지 않게
unset JARVIS_TASK_QUEUE_ENABLED JARVIS_TASK_QUEUE_CONSUMER OPENCLAW_STATE_DB PROMOTER_WRITE_RULES
GUARD="$INFRA/lib/task-queue-guard.mjs"
GW="$T/gw.sqlite"
fake_gateway() { rm -f "$GW"; sqlite3 "$GW" "CREATE TABLE cron_jobs(name TEXT, enabled INTEGER); INSERT INTO cron_jobs VALUES('jarvis-dev-task-runner',$1),('jarvis-insight-extractor',1);"; }
count_src() { [[ -f "$BOT_HOME/state/tasks.db" ]] || { echo 0; return; }; sqlite3 "$BOT_HOME/state/tasks.db" "SELECT COUNT(*) FROM tasks WHERE source='$1';"; }
status_of() { [[ -f "$BOT_HOME/state/tasks.db" ]] || { echo none; return; }; local s; s=$(sqlite3 "$BOT_HOME/state/tasks.db" "SELECT status FROM tasks WHERE id='$1';"); echo "${s:-none}"; }
guard_json() { node --input-type=module -e "import { taskQueueStatus } from '$GUARD'; console.log(JSON.stringify(taskQueueStatus()));"; }

echo "== A. 관문 판정"
expect_eq "강제값 1" "$(JARVIS_TASK_QUEUE_ENABLED=1 guard_json | jq -r .enabled)" "true"
expect_eq "강제값 on" "$(JARVIS_TASK_QUEUE_ENABLED=on guard_json | jq -r .enabled)" "true"
fake_gateway 1
expect_eq "강제값 0 이 소비자 켜짐을 이김" "$(JARVIS_TASK_QUEUE_ENABLED=0 OPENCLAW_STATE_DB="$GW" guard_json | jq -r .enabled)" "false"
expect_eq "소비자 켜짐 → 켬" "$(OPENCLAW_STATE_DB="$GW" guard_json | jq -r .enabled)" "true"
fake_gateway 0
expect_eq "소비자 꺼짐 → 끔" "$(OPENCLAW_STATE_DB="$GW" guard_json | jq -r .enabled)" "false"
expect_has "소비자 꺼짐 사유" "$(OPENCLAW_STATE_DB="$GW" guard_json)" "소비자 잡 jarvis-dev-task-runner 꺼짐"
expect_eq "다른 소비자 이름 지정" "$(OPENCLAW_STATE_DB="$GW" JARVIS_TASK_QUEUE_CONSUMER=jarvis-insight-extractor guard_json | jq -r .enabled)" "true"
expect_has "미등록 소비자 → 끔" "$(OPENCLAW_STATE_DB="$GW" JARVIS_TASK_QUEUE_CONSUMER=nope guard_json)" '"enabled":false,"reason":"소비자 잡 nope 미등록"'
expect_has "DB 없음 → 끔" "$(OPENCLAW_STATE_DB="$T/none.sqlite" guard_json)" '"enabled":false,"reason":"소비자 상태 확인 불가'
sqlite3 "$T/empty.sqlite" "CREATE TABLE other(x);"
expect_has "표 없음 → 끔" "$(OPENCLAW_STATE_DB="$T/empty.sqlite" guard_json)" '"enabled":false,"reason":"소비자 상태 확인 불가'
expect_has "기본 경로 = HOME/.openclaw/state" "$(guard_json)" "$HOME/.openclaw/state/openclaw.sqlite 없음"
OPENCLAW_STATE_DB="$GW" node "$GUARD" >/dev/null 2>&1; expect_eq "CLI 꺼짐 rc" "$?" "3"
JARVIS_TASK_QUEUE_ENABLED=1 node "$GUARD" >/dev/null 2>&1; expect_eq "CLI 켜짐 rc" "$?" "0"
# 심링크 경로(runtime/lib → infra/lib)로 불러도 CLI 로 동작해야 한다
ln -s "$INFRA/lib" "$T/linklib"
expect_has "CLI 심링크 경로" "$(OPENCLAW_STATE_DB="$GW" node "$T/linklib/task-queue-guard.mjs" 2>/dev/null)" '"enabled":false'

echo "== B. insight-extractor — actionRouter"
echo '{"large":"fake-model"}' > "$BOT_HOME/config/models.json"
IE="$INFRA/lib/insight-extractor.mjs"
run_router() {   # $1 = 날짜(memory.md 블록 키) $2 = high 항목 문구
  IE="$IE" D="$1" ITEM="$2" node --input-type=module -e "
const m = await import(process.env.IE);
await m.actionRouter({
  decisions: [{ date: process.env.D, project: 'p', decision: '결정 ' + process.env.D, reason: 'r' }],
  open_items: [{ item: process.env.ITEM, context: 'ctx', priority: 'high' }, { item: 'low item', priority: 'low' }],
  patterns: [{ pattern: '패턴 ' + process.env.D, frequency: '2회' }],
}, process.env.D);" 2>&1
}
fake_gateway 0
out=$(OPENCLAW_STATE_DB="$GW" run_router 2026-10-01 "queue off item alpha"); rc=$?
expect_eq "꺼짐 rc" "$rc" "0"
expect_has "꺼짐 로그" "$out" "dev-queue 등록 생략 1건 — 개발 큐 꺼짐 (소비자 잡 jarvis-dev-task-runner 꺼짐)"
expect_not "꺼짐 → 등록 로그 없음" "$out" "자동 등록"
expect_eq "꺼짐 → tasks.db 행 0" "$(count_src insight-extractor)" "0"
expect_has "꺼짐 → memory.md 는 씀" "$(cat "$BOT_HOME/rag/memory.md" 2>/dev/null)" "<!-- synth:2026-10-01 -->"
expect_has "꺼짐 → memory.md high 항목" "$(cat "$BOT_HOME/rag/memory.md" 2>/dev/null)" "queue off item alpha"
expect_has "꺼짐 → owner profile 은 씀" "$(cat "$BOT_HOME/rag/user-insights/owner/profile.md" 2>/dev/null)" "결정 2026-10-01"
out=$(JARVIS_TASK_QUEUE_ENABLED=1 run_router 2026-10-02 "queue on item beta"); rc=$?
expect_eq "켜짐 rc" "$rc" "0"
expect_has "켜짐 로그" "$out" "dev-queue에 1건 자동 등록"
expect_eq "켜짐 → insight-extractor 행 1" "$(count_src insight-extractor)" "1"
expect_eq "켜짐 → pending" "$(status_of synth-queue-on-item-beta)" "pending"
expect_has "켜짐 → memory.md 도 씀" "$(cat "$BOT_HOME/rag/memory.md")" "<!-- synth:2026-10-02 -->"
fake_gateway 1
out=$(OPENCLAW_STATE_DB="$GW" run_router 2026-10-03 "consumer on item gamma")
expect_eq "소비자 켜짐 → pending" "$(status_of synth-consumer-on-item-gamma)" "pending"
expect_eq "직접 실행이 아니면 main 안 돎(인사이트 파일 없음)" "$(ls "$BOT_HOME/rag/auto-insights" 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "== C. mistake-promoter — tier_b"
FAKE="$T/infra"; mkdir -p "$FAKE/lib"
ln -s "$INFRA/lib/task-store.mjs" "$FAKE/lib/task-store.mjs"
export JARVIS_INFRA_HOME="$FAKE" PROMOTER_RULES_FILE="$T/rules/autolearn.md" FAKE_JUDGE_FILE="$T/judge.json"
cat > "$FAKE/lib/llm-gateway.sh" <<'EOF'
llm_call() {
  local output=""
  while [[ $# -gt 0 ]]; do case "$1" in --output) output="$2"; shift 2;; --prompt|--system|--timeout|--model) shift 2;; *) shift;; esac; done
  python3 -c 'import json,sys; print(json.dumps({"result":open(sys.argv[1]).read(),"cost_usd":0}))' "$FAKE_JUDGE_FILE" > "$output"
}
EOF
cat > "$FAKE/lib/discord-route.sh" <<'EOF'
discord_route() { :; }
EOF
NOW=$(node -e 'console.log(new Date(Date.now()+9*3600e3).toISOString().replace(/\.\d+Z$/,"+09:00"))')
cat > "$BOT_HOME/state/mistake-recurrence.json" <<EOF
{"generated_at":"$NOW","window_days":7,"threshold":3,"top_clusters":[{"seed":"큐 관문 시험 시드","size":5,"members":["큐 관문 시험 시드"]}]}
EOF
CL=$(node -e 'const {createHash}=require("crypto");console.log("cl-"+createHash("sha256").update(process.argv[1],"utf-8").digest("hex").slice(0,16))' "큐 관문 시험 시드")
echo "[{\"id\":\"$CL\",\"tier\":\"tier_b\",\"title\":\"큐 관문 시험\",\"reason\":\"x\",\"proposal\":\"가드\"}]" > "$FAKE_JUDGE_FILE"
PLEDGER="$BOT_HOME/ledger/promoter-ledger.jsonl"
PROMOTER="$INFRA/scripts/mistake-promoter.mjs"
fake_gateway 0
out=$(OPENCLAW_STATE_DB="$GW" node "$PROMOTER" 2>&1); rc=$?
expect_eq "꺼짐 rc" "$rc" "0"
expect_has "꺼짐 로그" "$out" "dev-queue enqueue 생략: mistake-promoter-$CL — 개발 큐 꺼짐"
expect_eq "꺼짐 → tasks.db 행 0" "$(count_src mistake-promoter)" "0"
expect_eq "꺼짐 → ledger 상태 유지" "$(jq -r --arg c "$CL" 'select(.type=="cluster" and .cluster_id==$c) | .status' "$PLEDGER")" "proposed_dev_queue"
expect_eq "꺼짐 → dev_queue_action" "$(jq -r --arg c "$CL" 'select(.type=="cluster" and .cluster_id==$c) | .dev_queue_action' "$PLEDGER")" "skip-queue-off"
expect_eq "꺼짐 → run_metrics 기록" "$(jq -r 'select(.type=="run_metrics") | .dev_queue' "$PLEDGER" | tail -1)" "1"
rm -f "$PLEDGER"
out=$(JARVIS_TASK_QUEUE_ENABLED=1 node "$PROMOTER" 2>&1); rc=$?
expect_eq "켜짐 rc" "$rc" "0"
expect_has "켜짐 로그" "$out" "tier_b dev-queue 제안 (enqueued): $CL"
expect_eq "켜짐 → queued" "$(status_of "mistake-promoter-$CL")" "queued"
expect_eq "켜짐 → dev_queue_action" "$(jq -r --arg c "$CL" 'select(.type=="cluster" and .cluster_id==$c) | .dev_queue_action' "$PLEDGER")" "enqueued"

echo
echo "결과: PASS $PASSED / FAIL $FAILURES"
[[ $FAILURES -eq 0 ]]
