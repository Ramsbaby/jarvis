#!/usr/bin/env bash
# test-coder-fail-closed.sh — 코더 검증 fail-closed 회귀 테스트 (SELF-HEAL-PLAN-2026-09.md 1c)
#
# 검증 대상:
#   verify-sprint-contract.sh : verifyCmd 없는 기준 → passed=false / unverified_no_verify_cmd, exit 1
#   verify-gate.sh            : enforce 에서 인프라 장애·파싱 실패·스냅샷 없음 → UNAVAILABLE_* return 1 / warn 은 SKIPPED_* return 0
#   coder-functions.sh        : UNAVAILABLE_* → 재시도 안 태우고 패치 보존 + 원복 + failed(verify_gate_unavailable)
#                               verifyCmd 없는 기준만 남음 판정(jq) → sprint_contract_needs_human
# 실행: bash ~/projects/jarvis/infra/scripts/test-coder-fail-closed.sh   (외부 송출 없음 — 임시 BOT_HOME, Discord 함수 mock)
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
INFRA="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d /var/tmp/coder-fc-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
PASSED=0; FAILURES=0
ok()   { PASSED=$((PASSED+1)); }
fail() { FAILURES=$((FAILURES+1)); echo "  ✗ $*"; }
expect_eq() { [[ "$2" == "$3" ]] && ok || fail "$1: expected [$3] got [$2]"; }

# ── 임시 BOT_HOME: git 저장소 + lib/scripts 는 infra 로 심링크
export BOT_HOME="$T/runtime"
export JARVIS_NO_EXTERNAL=1   # 이중 안전장치 — 모킹이 빠져도 실채널로 나가지 않는다 (1d)
export JARVIS_CODER_WORKTREE=0   # 이 테스트는 본체 직접 편집(옛 방식) 경로의 원복 규칙을 검증한다 — worktree 경로는 test-coder-worktree.sh
mkdir -p "$BOT_HOME"/{state/sprint-contracts,logs,config,bin,results}
ln -s "$INFRA/lib" "$BOT_HOME/lib"
ln -s "$INFRA/scripts" "$BOT_HOME/scripts"
echo '{"webhooks":{}}' > "$BOT_HOME/config/monitoring.json"
git -C "$BOT_HOME" init -q && git -C "$BOT_HOME" config user.email t@t && git -C "$BOT_HOME" config user.name t
echo "base" > "$BOT_HOME/tracked.txt"
# 원장·로그·상태는 diff 대상이 아니다 (실제 runtime/ 도 .gitignore)
printf 'ledger/\nlogs/\nstate/\nresults/\nlib\nscripts\n' > "$BOT_HOME/.gitignore"
# ask-claude mock (스냅샷에 포함 — 게이트의 의존파일 변조 감지 FAIL_GATE_TAMPER 회피): MOCK_MODE 에 따라 실패 / 쓰레기 / PASS / FAIL
cat > "$BOT_HOME/bin/ask-claude.sh" <<'EOF'
#!/usr/bin/env bash
case "${MOCK_MODE:-}" in
  error) exit 1 ;;
  garbage) echo "no verdict here" ;;
  pass) printf '판정\n```json_verdict\n{"verdict":"PASS","reasons":["ok"],"missing":[]}\n```\n' ;;
  fail) printf '판정\n```json_verdict\n{"verdict":"FAIL","reasons":["bad"],"missing":["x"]}\n```\n' ;;
esac
EOF
chmod +x "$BOT_HOME/bin/ask-claude.sh"
git -C "$BOT_HOME" add -A && git -C "$BOT_HOME" commit -qm snapshot
SNAP=$(git -C "$BOT_HOME" rev-parse HEAD)

echo "── verify-sprint-contract.sh"
cat > "$BOT_HOME/state/sprint-contracts/t-mixed.json" <<EOF
{"taskId":"t-mixed","status":"active","contract":{"objective":"x","maxIterations":3,"successCriteria":[
  {"id":1,"description":"auto ok","verifyCmd":"true","verified":false},
  {"id":2,"description":"manual","verifyCmd":"","verified":false},
  {"id":3,"description":"auto fail","verifyCmd":"false","verified":false}]},"iterations":[]}
EOF
OUT=$(bash "$INFRA/scripts/verify-sprint-contract.sh" t-mixed 2>/dev/null); RC=$?
expect_eq "exit code" "$RC" "1"
expect_eq "#1 passed" "$(jq -r '.[0].passed' <<<"$OUT")" "true"
expect_eq "#2 passed" "$(jq -r '.[1].passed' <<<"$OUT")" "false"
expect_eq "#2 reason" "$(jq -r '.[1].reason' <<<"$OUT")" "unverified_no_verify_cmd"
expect_eq "#3 passed" "$(jq -r '.[2].passed' <<<"$OUT")" "false"
cat > "$BOT_HOME/state/sprint-contracts/t-allauto.json" <<EOF
{"taskId":"t-allauto","status":"active","contract":{"objective":"x","maxIterations":3,"successCriteria":[
  {"id":1,"description":"a","verifyCmd":"true","verified":false},
  {"id":2,"description":"b","verifyCmd":"test -d /","verified":false}]},"iterations":[]}
EOF
bash "$INFRA/scripts/verify-sprint-contract.sh" t-allauto >/dev/null 2>&1; expect_eq "all-auto exit" "$?" "0"

echo "── manual-only 판정 (coder-functions 의 jq 식과 동일)"
JQ='if length > 0 and all(.[]; (.verifyCmd // "") == "") then "true" else "false" end'
expect_eq "manual only"  "$(jq -r "$JQ" <<<'[{"id":2,"verifyCmd":""},{"id":3}]')" "true"
expect_eq "mixed"        "$(jq -r "$JQ" <<<'[{"id":2,"verifyCmd":""},{"id":3,"verifyCmd":"false"}]')" "false"
expect_eq "empty list"   "$(jq -r "$JQ" <<<'[]')" "false"

echo "── verify-gate.sh (enforce)"
_coder_log() { echo "[log] $1" >> "$T/coder.log"; }
JARVIS_VERIFY_GATE=enforce
source "$INFRA/lib/verify-gate.sh"

run_verify_gate t1 "n" "p" ""; expect_eq "no snapshot rc" "$?" "1"
expect_eq "no snapshot verdict" "$VERIFY_GATE_VERDICT" "UNAVAILABLE_NO_SNAPSHOT"

echo "changed" > "$BOT_HOME/tracked.txt"   # diff 생성
MOCK_MODE=error run_verify_gate t2 "n" "p" "$SNAP"; expect_eq "ask-claude error rc" "$?" "1"
expect_eq "error verdict" "$VERIFY_GATE_VERDICT" "UNAVAILABLE_ERROR"
[[ "$VERIFY_GATE_FEEDBACK" == *"미검증은 통과가 아니다"* ]] && ok || fail "error feedback text: $VERIFY_GATE_FEEDBACK"
MOCK_MODE=garbage run_verify_gate t3 "n" "p" "$SNAP"; expect_eq "unparseable rc" "$?" "1"
expect_eq "unparseable verdict" "$VERIFY_GATE_VERDICT" "UNAVAILABLE_UNPARSEABLE"
MOCK_MODE=pass run_verify_gate t4 "n" "p" "$SNAP"; expect_eq "PASS rc" "$?" "0"
expect_eq "PASS verdict" "$VERIFY_GATE_VERDICT" "PASS"
MOCK_MODE=fail run_verify_gate t5 "n" "p" "$SNAP"; expect_eq "FAIL rc" "$?" "1"
expect_eq "FAIL verdict" "$VERIFY_GATE_VERDICT" "FAIL"
git -C "$BOT_HOME" checkout -q -- tracked.txt
MOCK_MODE=pass run_verify_gate t6 "n" "p" "$SNAP"; expect_eq "no-changes rc" "$?" "0"
expect_eq "no-changes verdict" "$VERIFY_GATE_VERDICT" "SKIPPED_NO_CHANGES"
LEDGER_N=$(grep -c '"verdict":"UNAVAILABLE_' "$BOT_HOME/ledger/verify-gate.jsonl" 2>/dev/null || echo 0)
expect_eq "ledger UNAVAILABLE entries" "$LEDGER_N" "3"

echo "── verify-gate.sh (warn → 종전대로 통과)"
JARVIS_VERIFY_GATE=warn
run_verify_gate w1 "n" "p" ""; expect_eq "warn no snapshot rc" "$?" "0"
expect_eq "warn verdict" "$VERIFY_GATE_VERDICT" "SKIPPED_NO_SNAPSHOT"
echo "changed" > "$BOT_HOME/tracked.txt"
MOCK_MODE=error run_verify_gate w2 "n" "p" "$SNAP"; expect_eq "warn error rc" "$?" "0"
expect_eq "warn error verdict" "$VERIFY_GATE_VERDICT" "SKIPPED_ERROR"
git -C "$BOT_HOME" checkout -q -- tracked.txt

echo "── coder-functions: UNAVAILABLE → 보류 (재시도 안 태움, 패치 보존, 원복)"
JARVIS_VERIFY_GATE=enforce
source "$INFRA/lib/coder-functions.sh"
# mock: 큐 전이·디스코드
QUEUE_LOG="$T/queue.log"; : > "$QUEUE_LOG"
update_queue() { echo "$1|$2|$(jq -c . <<<"$3")" >> "$QUEUE_LOG"; }
_discord_alert() { echo "ALERT: $1" >> "$T/discord.log"; }
_discord_ceo_notify() { echo "CEO: $1" >> "$T/discord.log"; }
verify_gate_escalate() { return 0; }

echo "coder edit" > "$BOT_HOME/tracked.txt"
echo "new file" > "$BOT_HOME/newfile.txt"
VERIFY_GATE_VERDICT="UNAVAILABLE_ERROR"; VERIFY_GATE_FEEDBACK="독립 검증을 수행하지 못했다(ERROR)"
_handle_verify_gate_fail t-hold 0 2 "$SNAP"
expect_eq "queue status" "$(cut -d'|' -f2 "$QUEUE_LOG")" "failed"
expect_eq "lastError" "$(cut -d'|' -f3- "$QUEUE_LOG" | jq -r .lastError)" "verify_gate_unavailable"
expect_eq "retries untouched" "$(cut -d'|' -f3- "$QUEUE_LOG" | jq -r '.retries // "absent"')" "absent"
PATCH=$(cut -d'|' -f3- "$QUEUE_LOG" | jq -r .patch_file)
[[ -s "$PATCH" ]] && ok || fail "patch file missing: $PATCH"
grep -q "coder edit" "$PATCH" && ok || fail "patch lacks tracked change"
grep -q "new file" "$PATCH" && ok || fail "patch lacks new file"
expect_eq "tracked reverted" "$(cat "$BOT_HOME/tracked.txt")" "base"
[[ -f "$BOT_HOME/newfile.txt" ]] && ok || fail "untracked new file must survive (잔존 > 삭제)"
grep -q "ALERT:.*사람 검토 보류" "$T/discord.log" && ok || fail "system-channel alert missing"
grep -q "HOLD_FOR_HUMAN: t-hold" "$BOT_HOME/logs/jarvis-coder.log" && ok || fail "coder log missing"

echo "── coder-functions: 명시적 FAIL 은 종전대로 재시도 (회귀 확인)"
: > "$QUEUE_LOG"; rm -f "$BOT_HOME/newfile.txt"
VERIFY_GATE_VERDICT="FAIL"; VERIFY_GATE_FEEDBACK="bad"
_handle_verify_gate_fail t-fail 0 2 "$SNAP"
expect_eq "FAIL → queued" "$(cut -d'|' -f2 "$QUEUE_LOG")" "queued"
expect_eq "FAIL retries=1" "$(cut -d'|' -f3- "$QUEUE_LOG" | jq -r .retries)" "1"

echo "── _sc_hold_for_human 이 contract 를 needs_human 으로 archive"
cat > "$BOT_HOME/state/sprint-contracts/t-arch.json" <<EOF
{"taskId":"t-arch","status":"active","contract":{"objective":"x","maxIterations":3,"successCriteria":[{"id":1,"description":"m","verifyCmd":"","verified":false}]},"iterations":[]}
EOF
: > "$QUEUE_LOG"
_sc_hold_for_human t-arch sprint_contract_needs_human "manual only" ""
expect_eq "archive status" "$(jq -r .status "$BOT_HOME"/state/sprint-contracts/archive/t-arch-*.json 2>/dev/null | head -1)" "needs_human"
[[ ! -f "$BOT_HOME/state/sprint-contracts/t-arch.json" ]] && ok || fail "contract not archived"
expect_eq "needs_human lastError" "$(cut -d'|' -f3- "$QUEUE_LOG" | jq -r .lastError)" "sprint_contract_needs_human"

echo "PASSED=$PASSED FAILURES=$FAILURES"
[[ $FAILURES -eq 0 ]]
