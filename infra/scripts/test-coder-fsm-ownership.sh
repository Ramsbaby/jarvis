#!/usr/bin/env bash
# test-coder-fsm-ownership.sh — 코더 태스크의 FSM 은 coder-functions 가 소유한다 (실제 tasks.db 로 검증)
#
# 2026-09-04 카나리아(canary-worktree-1b)에서 실측: ask-claude.sh 의 완료 워크플로우가 검증 전에 done 을 찍어
#   (1) 코더의 done 갱신이 done→done 으로 거부돼 branch/patch_file 이 큐에 남지 않았고
#   (2) 검증 실패 재큐가 done→queued 로 거부됐다 — jarvis-coder.log 누적 30건 = 검증 실패가 done 으로 남은 건수.
# 이 테스트는 임시 BOT_HOME 의 실제 SQLite 로 다음을 고정한다:
#   A. JARVIS_FSM_OWNER=coder 면 워크플로우가 결과만 저장하고 running 을 유지한다
#   B. 미설정(크론 태스크)이면 예전처럼 done 으로 전이한다
#   C. 코더 update_queue done 은 result 를 채워 RESULT_REQUIRED 를 통과하고 branch 등 extra 가 남는다
#   D. A 뒤 update_queue queued (검증 실패 재큐) 가 성공한다
set -uo pipefail
INFRA="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
T=$(mktemp -d /var/tmp/coder-fsm-test.XXXXXX)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
PASSED=0; FAILURES=0
ok() { PASSED=$((PASSED+1)); }
fail() { FAILURES=$((FAILURES+1)); echo "  ✗ $*"; }
expect_eq() { [[ "$2" == "$3" ]] && ok || fail "$1: expected [$3] got [$2]"; }

export BOT_HOME="$T/runtime"
mkdir -p "$BOT_HOME"/{config,state,logs,ledger,results,rag}
ln -s "$INFRA/lib" "$BOT_HOME/lib"
ln -s "$INFRA/scripts" "$BOT_HOME/scripts"
echo '{"tasks":[]}' > "$BOT_HOME/config/tasks.json"
echo '{"webhooks":{}}' > "$BOT_HOME/config/monitoring.json"
export JARVIS_NO_EXTERNAL=1
unset JARVIS_FSM_OWNER JARVIS_AGENT_ROLE BOARD_URL AGENT_API_KEY
TS="node --experimental-sqlite --no-warnings $BOT_HOME/lib/task-store.mjs"
WF="$INFRA/scripts/task-completion-workflow.sh"

mk_running() {  # <id> — bot-cron 소스는 enqueue 시 이벤트를 쏘지 않는다
  $TS enqueue --id "$1" --title "task $1" --source bot-cron >/dev/null
  $TS transition "$1" running test '{}' >/dev/null
}
status_of() { $TS field "$1" status; }
meta_of() { $TS get "$1" | jq -r ".meta.$2 // empty"; }

echo "── A. JARVIS_FSM_OWNER=coder → 워크플로우는 running 을 유지"
mk_running t-coder
JARVIS_FSM_OWNER=coder bash "$WF" t-coder "결과 본문" ask-claude >"$T/wf-a.log" 2>&1; rc=$?
expect_eq "워크플로우 exit" "$rc" "0"
expect_eq "status 유지" "$(status_of t-coder)" "running"
grep -q 'FSM 전이 생략' "$T/wf-a.log" && ok || fail "생략 로그 없음: $(cat "$T/wf-a.log")"
ls "$BOT_HOME/results/task-outcomes/"*-t-coder.json >/dev/null 2>&1 && ok || fail "결과 파일 저장은 그대로 해야 한다"

echo "── B. 미설정(크론 태스크) → 예전처럼 done"
mk_running t-cron
bash "$WF" t-cron "결과 본문" bot-cron/complete >"$T/wf-b.log" 2>&1; rc=$?
expect_eq "워크플로우 exit" "$rc" "0"
expect_eq "status done" "$(status_of t-cron)" "done"
expect_eq "meta.result" "$(meta_of t-cron result)" "결과 본문"

echo "── C. 코더 update_queue done — result 자동 채움 + extra 보존"
source "$INFRA/lib/coder-functions.sh"
_discord_alert() { echo "ALERT: $1" >> "$T/discord.log"; }
update_queue t-coder done '{"result_summary":"t-coder 완료","branch":"coder/t-coder","patch_file":"/x/patch.diff","merge_pending":true}'; rc=$?
expect_eq "update_queue exit" "$rc" "0"
expect_eq "status done" "$(status_of t-coder)" "done"
expect_eq "meta.result = result_summary" "$(meta_of t-coder result)" "t-coder 완료"
expect_eq "meta.branch" "$(meta_of t-coder branch)" "coder/t-coder"
expect_eq "meta.merge_pending" "$(meta_of t-coder merge_pending)" "true"
[[ ! -f "$T/discord.log" ]] && ok || fail "update_queue 가 알림을 냈다: $(cat "$T/discord.log")"

echo "── C'. result 가 이미 있으면 덮어쓰지 않는다"
mk_running t-keep
update_queue t-keep done '{"result":"명시 결과","result_summary":"요약"}' >/dev/null 2>&1
expect_eq "meta.result 유지" "$(meta_of t-keep result)" "명시 결과"

echo "── D. A 뒤 검증 실패 재큐 (running → queued) 가 거부되지 않는다"
mk_running t-requeue
JARVIS_FSM_OWNER=coder bash "$WF" t-requeue "결과 본문" ask-claude >/dev/null 2>&1
update_queue t-requeue queued '{"lastError":"verify FAIL"}'; rc=$?
expect_eq "update_queue exit" "$rc" "0"
expect_eq "status queued" "$(status_of t-requeue)" "queued"
expect_eq "retries 증가" "$($TS field t-requeue retries)" "1"

echo "── E. ask-claude.sh 는 JARVIS_AGENT_ROLE=coder 일 때 JARVIS_FSM_OWNER=coder 를 export 한다 (정적)"
grep -q 'JARVIS_AGENT_ROLE:-}" == "coder" ]]; then export JARVIS_FSM_OWNER=coder' "$INFRA/bin/ask-claude.sh" && ok || fail "ask-claude.sh 에 export 분기 없음"

echo "PASSED=$PASSED FAILURES=$FAILURES"
[[ $FAILURES -eq 0 ]]
