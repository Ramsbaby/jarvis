#!/usr/bin/env bash
# test-auditor-e2e-guard.sh — jarvis-auditor.sh e2e 경로의 두 가드 회귀 테스트 (2026-09-05)
#   ① `# TREE: dirty` 표식이 있는 e2e 결과의 FAIL 은 SUSPECT 로만 보고, 티켓 미생성
#   ② 같은 티켓을 코더가 쿨다운(TICKET_COOLDOWN_H) 안에 done/failed/skipped 로 끝냈으면 재큐하지 않음
#      (task-store enqueue 는 failed 를 queued 로 되돌리므로 Stop 훅마다 코더가 같은 티켓을 다시 받았다 —
#       2026-09-05 티켓 1건으로 코더 4회 실행, inc-20260905-8a26d2b6)
#   ③ e2e-cron.sh 가 결과 파일 첫 줄에 `# TREE: clean|dirty` 를 쓴다
# 실행: bash ~/projects/jarvis/infra/scripts/test-auditor-e2e-guard.sh   (외부 송출 없음 — 임시 BOT_HOME, bin/ 비움)
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
PASSED=0 FAILURES=0
ok() { PASSED=$((PASSED+1)); }
fail() { FAILURES=$((FAILURES+1)); echo "  ✗ $*"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok; else fail "$1: expected [$3] got [$2]"; fi; }
assert_has() { if grep -qF -- "$3" <<<"$2"; then ok; else fail "$1: missing [$3] in: $(printf '%s' "$2" | tail -3)"; fi; }
assert_not() { if grep -qF -- "$3" <<<"$2"; then fail "$1: unexpected [$3]"; else ok; fi; }

INFRA="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
AUDITOR="$INFRA/scripts/jarvis-auditor.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# 최소 BOT_HOME: lib 에는 task-store 만(심링크 — 실제 lib 을 통째로 걸면 감사가 실제 파일을 Tier1 자동수정한다),
# scripts/bin/discord 는 빈 디렉터리(스캔 0건, route-result.sh 없음 → Discord 송출 없음)
mkdir -p "$T/lib" "$T/scripts" "$T/bin" "$T/discord" "$T/config" "$T/state" "$T/logs" "$T/results/e2e-health"
ln -s "$INFRA/lib/task-store.mjs" "$T/lib/task-store.mjs"
echo '[]' > "$T/config/anti-patterns.json"
export BOT_HOME="$T"
TODAY=$(date +%F)
RESULT="$T/results/e2e-health/$TODAY.txt"
# slug: BSD sed 는 `-\+` 를 모르므로 ": " → "--" 가 그대로 남는다 (실제 티켓 id 와 동일한 형태)
TICKET="code-fix-e2e-test-failed--1-items-from-$TODAY"
FAIL_LINE="❌ FAIL: coder merge gate+autonomy (PASSED=81 FAILURES=25)"

run_auditor() { : > "$T/logs/auditor.log"; bash "$AUDITOR" >/dev/null 2>&1; cat "$T/logs/auditor.log"; }
# get 은 없는 id 에 rc=1·빈 stdout — "none" 으로 정규화
status_of() { local j; j=$(node "$T/lib/task-store.mjs" get "$1" 2>/dev/null || true); [[ -n "$j" ]] && jq -r '.status' <<<"$j" || echo "none"; }

echo "── ① dirty 트리 결과 → SUSPECT, 티켓 미생성"
printf '# TREE: dirty (2) — infra/scripts/a.sh infra/scripts/b.sh\n%s\n' "$FAIL_LINE" > "$RESULT"
LOG=$(run_auditor)
assert_has "SUSPECT 로그" "$LOG" "SUSPECT: e2e FAIL 1건은 편집 중 트리 검사 결과"
assert_not "enqueue 안 함" "$LOG" "ENQUEUED to tasks.db: E2E"
assert_eq "티켓 없음" "$(status_of "$TICKET")" "none"

echo "── ② clean 트리 결과 → 티켓 생성"
printf '# TREE: clean\n%s\n' "$FAIL_LINE" > "$RESULT"
LOG=$(run_auditor)
assert_has "ENQUEUED 로그" "$LOG" "ENQUEUED to tasks.db: E2E Test Failed: 1 items from $TODAY"
assert_eq "티켓 queued" "$(status_of "$TICKET")" "queued"

echo "── ③ 코더가 failed 로 끝낸 직후 → 쿨다운, 재큐 안 함"
node "$T/lib/task-store.mjs" transition "$TICKET" running test >/dev/null 2>&1
node "$T/lib/task-store.mjs" transition "$TICKET" failed test >/dev/null 2>&1
assert_eq "전제: failed" "$(status_of "$TICKET")" "failed"
LOG=$(run_auditor)
assert_has "COOLDOWN 로그" "$LOG" "COOLDOWN skip: $TICKET (코더 failed 0h 전, 쿨다운 72h)"
assert_not "enqueue 안 함" "$LOG" "ENQUEUED to tasks.db: E2E"
assert_eq "여전히 failed" "$(status_of "$TICKET")" "failed"
grep -q "재큐 안 함: \`$TICKET\`" "$T/results/auditor/$TODAY.md" && ok || fail "보고서에 재큐 안 함 표기 없음"

echo "── ④ skipped(오탐 기각) 도 쿨다운 대상"
# FSM: failed → skipped 직행은 없다 (failed → pending → skipped)
node "$T/lib/task-store.mjs" transition "$TICKET" pending test >/dev/null 2>&1
node "$T/lib/task-store.mjs" reject "$TICKET" "오탐: 테스트" >/dev/null 2>&1
assert_eq "전제: skipped" "$(status_of "$TICKET")" "skipped"
LOG=$(run_auditor)
assert_has "COOLDOWN 로그(skipped)" "$LOG" "COOLDOWN skip: $TICKET (코더 skipped 0h 전"
assert_eq "여전히 skipped" "$(status_of "$TICKET")" "skipped"

echo "── ⑤ 쿨다운 만료(TICKET_COOLDOWN_H=0) → 재큐"
LOG=$(TICKET_COOLDOWN_H=0 run_auditor)
assert_has "재큐 로그" "$LOG" "ENQUEUED to tasks.db: E2E Test Failed: 1 items from $TODAY"
assert_eq "다시 queued" "$(status_of "$TICKET")" "queued"

echo "── ⑥ pending(queued) 은 기존대로 already-pending skip"
LOG=$(run_auditor)
assert_has "already pending" "$LOG" "SKIP enqueue (already pending)"

echo "── ⑦ e2e-cron.sh 가 TREE 표식을 쓴다 (정적)"
CRON="$INFRA/scripts/e2e-cron.sh"
assert_has "clean 표식" "$(cat "$CRON")" 'TREE_LINE="# TREE: clean"'
assert_has "dirty 표식" "$(cat "$CRON")" 'TREE_LINE="# TREE: dirty (${DIRTY_COUNT})'
assert_has "표식이 첫 줄" "$(cat "$CRON")" '{ echo "$TREE_LINE"; echo "$OUTPUT"; } > "$RESULT_FILE"'
bash -n "$CRON" && ok || fail "e2e-cron.sh 문법"
bash -n "$AUDITOR" && ok || fail "jarvis-auditor.sh 문법"

echo "PASSED=$PASSED FAILURES=$FAILURES"
[[ $FAILURES -eq 0 ]]
