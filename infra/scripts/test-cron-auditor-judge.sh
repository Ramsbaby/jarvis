#!/usr/bin/env bash
# test-cron-auditor-judge.sh — cron-auditor 판정이 tasks.db 전이·results 파일·exit code 를 근거로 내려지는지 (SELF-HEAL-PLAN 2a)
#
# 2026-09-04 실측 배경:
#   bot-cron 의 done 전이가 result 없이 호출돼 RESULT_REQUIRED 에 조용히 거부됐고(7/22 이후), 성공한 script-path
#   태스크 전부가 running 에 남아 stale-watcher 가 failed 로 찍었다 (하루 93건, cron.log 는 전부 SUCCESS).
#   예전 judge 는 cron.log 만 봐서 이를 못 봤고, DB 만 보면 전부 FAIL 로 오탐한다. 그래서 judge_db 는
#   DB 와 로그를 교차해 반대면 SUSPECT(티켓 보류) 로 내리고 요약에 mismatch 를 센다.
# 이 테스트는 임시 BOT_HOME 의 실제 SQLite 로 고정한다:
#   A. bot-cron 방식 done(result 포함) → OK, evidence 에 db:done·exit=0
#   B. failed(exit_code=1) → FAIL, evidence 에 exit=1·err
#   C. DB 기록 없음 → 예전 로그 판정으로 폴백, evidence=db:none
#   D. done 이지만 주기×5 경과 → STALE
#   E. DB failed(stale-watcher) vs 로그 SUCCESS 같은 실행 → SUSPECT + mismatch 집계, tracker 는 티켓 안 냄
#   E'. 로그 결과가 이전 실행 것이면(매달린 실행) DB 를 믿어 FAIL
#   F. tracker dry-run 이 evidence 를 티켓 설명에 싣는다
#   G. ensure 7번째 인자 evidence 저장·갱신, 빈 위치 인자는 기본값 유지 / enqueue --evidence
#   H. ensure 가 FSM 밖 상태('completed') 를 queued 로 복구한다
#   I. 정적: bot-cron.sh done 전이가 result 를 싣는다 / coder-functions 가 evidence 를 프롬프트에 주입한다
set -uo pipefail
INFRA="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
T=$(mktemp -d /var/tmp/cron-judge-test.XXXXXX)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
PASSED=0; FAILURES=0
ok() { PASSED=$((PASSED+1)); }
fail() { FAILURES=$((FAILURES+1)); echo "  ✗ $*"; }
expect_eq() { [[ "$2" == "$3" ]] && ok || fail "$1: expected [$3] got [$2]"; }
expect_has() { [[ "$2" == *"$3"* ]] && ok || fail "$1: [$3] 없음 — $2"; }

export BOT_HOME="$T/runtime"
mkdir -p "$BOT_HOME"/{config,state,logs,results/task-outcomes,results/t-done}
ln -s "$INFRA/lib" "$BOT_HOME/lib"
ln -s "$INFRA/scripts" "$BOT_HOME/scripts"
export JARVIS_NO_EXTERNAL=1
unset JARVIS_FSM_OWNER JARVIS_AGENT_ROLE
TS="node --experimental-sqlite --no-warnings $BOT_HOME/lib/task-store.mjs"
AUD="$INFRA/scripts/cron-auditor.sh"
# auditor 섹션 2 는 `crontab -l` 을 읽는다 — 실제 crontab 이 새지 않게 빈 crontab 을 PATH 앞에 둔다
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/crontab"; chmod +x "$T/bin/crontab"; export PATH="$T/bin:$PATH"
now_s=$(date +%s)
ts_at() { date -r "$1" '+%Y-%m-%d %H:%M:%S'; }   # epoch → cron.log 표기
set_updated() { sqlite3 "$BOT_HOME/state/tasks.db" "UPDATE task_transitions SET created_at=$2 WHERE task_id='$1' AND to_status='$3';"; }

cat > "$BOT_HOME/config/tasks.json" <<'EOF'
{"tasks":[
 {"id":"t-done","schedule":"*/10 * * * *","enabled":true},
 {"id":"t-fail","schedule":"*/10 * * * *","enabled":true},
 {"id":"t-nodb","schedule":"*/10 * * * *","enabled":true},
 {"id":"t-old","schedule":"*/10 * * * *","enabled":true},
 {"id":"t-suspect","schedule":"*/10 * * * *","enabled":true},
 {"id":"t-hung","schedule":"*/10 * * * *","enabled":true}
]}
EOF

# ── DB 상태 만들기 (bot-cron 이 하는 그대로: ensure → running → done/failed) ──
mk_run() { $TS ensure "$1" "$1" bot-cron >/dev/null; $TS transition "$1" running bot-cron '{}' >/dev/null; }
mk_run t-done;    $TS transition t-done "done" bot-cron '{"result":"SUCCESS (duration=1s)","exitCode":0,"durationSec":1}' >/dev/null
echo '{"ok":true}' > "$BOT_HOME/results/t-done/out.json"
mk_run t-fail;    $TS transition t-fail failed bot-cron '{"lastError":"exit_code=1","consecutiveFails":1}' >/dev/null
mk_run t-old;     $TS transition t-old "done" bot-cron '{"result":"SUCCESS (duration=1s)","exitCode":0}' >/dev/null
old_ms=$(( (now_s - 3600) * 1000 ))            # 60분 전 — 10분 주기 ×5 = 50분 초과
set_updated t-old "$old_ms" running; set_updated t-old "$old_ms" "done"
mk_run t-suspect; $TS transition t-suspect failed stale-watcher '{"lastError":"stale: running 17min without completion"}' >/dev/null
set_updated t-suspect "$(( (now_s - 61) * 1000 ))" running   # 실제 순서: running 전이 → START → SUCCESS 로그 (60초 전) → 17분 뒤 stale
mk_run t-hung     # running 인 채로 이전 실행 SUCCESS 로그만 있다
prev_ms=$(( (now_s - 1200) * 1000 )); set_updated t-hung "$prev_ms" running
$TS transition t-hung failed stale-watcher '{"lastError":"stale: running 20min without completion"}' >/dev/null

# ── cron.log ──
{
  echo "[$(ts_at $((now_s-120)))] [t-done] START"
  echo "[$(ts_at $((now_s-119)))] [t-done] SUCCESS (duration=1s)"
  echo "[$(ts_at $((now_s-119)))] [t-done] DONE"
  echo "[$(ts_at $((now_s-100)))] [t-fail] START"
  echo "[$(ts_at $((now_s-99)))] [t-fail] FAILED: exit=1"
  echo "[$(ts_at $((now_s-90)))] [t-nodb] START"
  echo "[$(ts_at $((now_s-89)))] [t-nodb] SUCCESS (duration=1s)"
  echo "[$(ts_at $((now_s-3600)))] [t-old] SUCCESS (duration=1s)"
  echo "[$(ts_at $((now_s-60)))] [t-suspect] START"
  echo "[$(ts_at $((now_s-59)))] [t-suspect] SUCCESS (duration=0s)"
  echo "[$(ts_at $((now_s-59)))] [t-suspect] DONE"
  echo "[$(ts_at $((now_s-1800)))] [t-hung] SUCCESS (duration=0s)"   # 이전 실행 (running 전이 20분 전보다 앞)
  echo "[$(ts_at $((now_s-1200)))] [t-hung] START"
} > "$BOT_HOME/logs/cron.log"

OUT=$(bash "$AUD" 2>&1)
line() { echo "$OUT" | grep -E "^  $1 " | head -1; }
status_of() { line "$1" | awk '{print $2}'; }
ev_of() { line "$1" | grep -oE 'evidence=[^ ]+' | sed 's/^evidence=//'; }

echo "── A. done(result 포함) → OK, 근거에 DB 종결 전이·exit·results"
expect_eq "t-done 상태" "$(status_of t-done)" "OK"
expect_has "t-done db" "$(ev_of t-done)" "db:done;last:done@"
expect_has "t-done by" "$(ev_of t-done)" "/bot-cron"
expect_has "t-done exit" "$(ev_of t-done)" ";exit=0"
expect_has "t-done results" "$(ev_of t-done)" ";results:0min"
expect_has "t-done log" "$(ev_of t-done)" ";log:DONE@"
[[ "$(ev_of t-done)" != *mismatch* ]] && ok || fail "t-done 에 mismatch 가 붙음"

echo "── B. failed(exit_code=1) → FAIL, 근거에 exit=1·err"
expect_eq "t-fail 상태" "$(status_of t-fail)" "FAIL"
expect_has "t-fail exit" "$(ev_of t-fail)" ";exit=1"
expect_has "t-fail err" "$(ev_of t-fail)" ";err=exit_code=1"
expect_has "t-fail log" "$(ev_of t-fail)" ";log:FAILED@"

echo "── C. DB 기록 없음 → 로그 폴백"
expect_eq "t-nodb 상태" "$(status_of t-nodb)" "OK"
expect_has "t-nodb db:none" "$(ev_of t-nodb)" "db:none;log:SUCCESS@"

echo "── D. done 이지만 60분 전(주기 10분×5 초과) → STALE"
expect_eq "t-old 상태" "$(status_of t-old)" "STALE"
expect_has "t-old ago" "$(line t-old)" "ago=60min"

echo "── E. DB failed(stale-watcher) vs 로그 SUCCESS 같은 실행 → SUSPECT + mismatch"
expect_eq "t-suspect 상태" "$(status_of t-suspect)" "SUSPECT"
expect_has "t-suspect by" "$(ev_of t-suspect)" "/stale-watcher"
expect_has "t-suspect mismatch" "$(ev_of t-suspect)" ";mismatch"
expect_has "요약 mismatch 집계" "$OUT" "DB-로그 불일치(mismatch): 1"

echo "── E'. 로그 결과가 이전 실행 것(매달림) → DB 를 믿어 FAIL"
expect_eq "t-hung 상태" "$(status_of t-hung)" "FAIL"
[[ "$(ev_of t-hung)" != *mismatch* ]] && ok || fail "t-hung 은 mismatch 가 아니어야 한다: $(ev_of t-hung)"

echo "── F. tracker dry-run — FAIL/STALE 만 집고 evidence 를 싣는다, SUSPECT 는 보류"
TR=$(DRY_RUN=true bash "$INFRA/scripts/cron-failure-tracker.sh" --dry-run 2>&1)
[[ "$TR" != *"e2e-cron.sh"* ]] && ok || fail "실제 crontab 이 테스트에 새어 들어왔다 (가짜 crontab 미적용)"
expect_has "t-fail 티켓" "$TR" "[FAIL] t-fail → 티켓 예정: debug-cron-t-fail · 근거: db:failed"
expect_has "t-old 티켓" "$TR" "[STALE] t-old → 티켓 예정: debug-cron-t-old"
[[ "$TR" != *"debug-cron-t-suspect"* ]] && ok || fail "SUSPECT 에 티켓을 냈다"
expect_has "불일치 요약" "$TR" "DB-로그 불일치(SUSPECT, 티켓 보류): 1건"

echo "── G. ensure 7번째 인자 evidence / 빈 위치 인자 기본값 / enqueue --evidence"
$TS ensure debug-cron-x "desc" infra "desc" "" "" "db:failed;exit=1" >/dev/null
expect_eq "ensure evidence" "$($TS field debug-cron-x evidence)" "db:failed;exit=1"
expect_eq "allowedTools 기본값 유지" "$($TS field debug-cron-x allowedTools)" "Bash,Read,Write,Edit"
$TS transition debug-cron-x running test '{}' >/dev/null; $TS transition debug-cron-x failed test '{"lastError":"x"}' >/dev/null
$TS ensure debug-cron-x "desc" infra "desc" "" "" "db:failed;exit=2" >/dev/null
expect_eq "재큐 시 evidence 갱신" "$($TS field debug-cron-x evidence)" "db:failed;exit=2"
expect_eq "재큐 상태" "$($TS field debug-cron-x status)" "queued"
$TS enqueue --id code-fix-y --title "y" --source jarvis-auditor --evidence "node --check → SyntaxError line 3" >/dev/null
expect_eq "enqueue evidence" "$($TS field code-fix-y evidence)" "node --check → SyntaxError line 3"

echo "── H. ensure 가 FSM 밖 상태('completed') 를 복구한다"
$TS ensure t-frozen t-frozen bot-cron >/dev/null
sqlite3 "$BOT_HOME/state/tasks.db" "UPDATE tasks SET status='completed' WHERE id='t-frozen';"
$TS transition t-frozen running bot-cron '{}' >/dev/null 2>&1; rc=$?
expect_eq "completed 에서 전이는 거부" "$rc" "1"
$TS ensure t-frozen t-frozen bot-cron >/dev/null
expect_eq "ensure 뒤 queued" "$($TS field t-frozen status)" "queued"
expect_eq "복구 전이 기록" "$(sqlite3 "$BOT_HOME/state/tasks.db" "SELECT triggered_by FROM task_transitions WHERE task_id='t-frozen' AND from_status='completed';")" "bot-cron/ensure-repair"
$TS transition t-frozen running bot-cron '{}' >/dev/null 2>&1 && ok || fail "복구 뒤 running 전이 실패"

echo "── I. 정적 — bot-cron done 전이에 result / 코더 프롬프트에 evidence 주입"
grep -qF '_fsm_transition "$TASK_ID" "done" \' "$INFRA/bin/bot-cron.sh" && grep -qF '\"result\":\"SUCCESS (duration=${_TASK_DURATION}s)\"' "$INFRA/bin/bot-cron.sh" && ok || fail "bot-cron.sh done 전이에 result 없음"
grep -q '\[감사 근거 — 무엇을 보고 고장이라 판단했나\]' "$INFRA/lib/coder-functions.sh" && ok || fail "coder-functions.sh 에 evidence 주입 없음"
grep -q '근거(evidence): ${evidence:-없음}' "$INFRA/scripts/jarvis-auditor.sh" && ok || fail "jarvis-auditor.sh 프롬프트에 evidence 없음"

echo "PASSED=$PASSED FAILURES=$FAILURES"
[[ $FAILURES -eq 0 ]]
