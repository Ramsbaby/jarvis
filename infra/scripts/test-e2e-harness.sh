#!/usr/bin/env bash
# test-e2e-harness.sh — e2e-test.sh 판정 도우미와 e2e-cron.sh 종료코드 처리의 재현 시험 (2026-09-26)
#
# 왜: 고정 경고 10건을 "은퇴는 SKIP, 살아 있는 잡만 요구"로 바꿨다. 경보를 느슨하게 한 것이므로
#     진짜 누락(켜진 태스크의 파일 없음·살아 있는 잡의 산출물 없음·태그 회귀)에서 여전히 우는지,
#     그리고 스위트가 중간에 죽으면 "통과"가 아니라 실패로 기록되는지 시험한다.
# 도우미는 e2e-test.sh 에서 **그대로 뽑아** 쓴다 — 사본을 시험하면 아무것도 증명하지 않는다.
# 외부 송출 없음: 임시 BOT_HOME·JARVIS_HOME, JARVIS_NO_EXTERNAL=1.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
E2E="$HERE/e2e-test.sh"
PASSED=0; FAILURES=0
ok()  { echo "  ok   $1"; PASSED=$((PASSED + 1)); }
bad() { echo "  FAIL $1"; FAILURES=$((FAILURES + 1)); }
expect() { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1 — got: $2"; }

TMP="$(mktemp -d /tmp/e2e-harness-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── 도우미 추출 ─────────────────────────────────────────────────────────────
PASS=0; WARN=0; SKIP=0; FAIL=0
green()  { printf '%s\n' "$1"; }
yellow() { printf '%s\n' "$1"; }
red()    { printf '%s\n' "$1"; }
skip()   { printf '⏭️  SKIP: %s\n' "$1"; }
for fn in sched_has _task_state _retired_note ctx_check out_check wiki_untagged; do
  body="$(sed -n "/^${fn}() {/,/^}/p" "$E2E")"
  [[ -n "$body" ]] || { bad "extract $fn"; continue; }
  eval "$body"
done

cat > "$TMP/tasks.json" <<'JSON'
{"tasks": [
  {"id": "live-task", "enabled": true},
  {"id": "old-task", "enabled": false, "_disabled_reason": "2026-09-10 dead-definition: 시험"},
  {"id": "quiet-task", "enabled": false}
]}
JSON
export E2E_TASKS_JSON="$TMP/tasks.json"
_SCHED_INVENTORY="jarvis-alive-job /bin/bash /x/alive.sh"
MISSING="$TMP/none.md"

echo "▶ ctx_check (컨텍스트 파일)"
expect "켜진 태스크 + 파일 없음 → WARN"       "$(ctx_check "c1" live-task test -f "$MISSING")" "⚠️  WARN: c1"
expect "끈 태스크 → SKIP + 사유"               "$(ctx_check "c2" old-task test -f "$MISSING")" "SKIP: c2 (tasks.json enabled:false — 2026-09-10 dead-definition: 시험)"
expect "사유 없이 끈 태스크 → SKIP"             "$(ctx_check "c3" quiet-task test -f "$MISSING")" "사유 미기재"
expect "tasks.json 에 없음 → SKIP(은퇴)"        "$(ctx_check "c4" gone-task test -f "$MISSING")" "tasks.json 정의 없음"
expect "파일 있으면 태스크 상태와 무관하게 PASS" "$(ctx_check "c5" old-task test -f "$E2E")" "✅ PASS: c5"

echo "▶ out_check (산출물)"
expect "활성 스케줄 + 산출물 없음 → WARN"        "$(out_check "o1" gone-task 'alive-job' test -f "$MISSING")" "⚠️  WARN: o1"
expect "tasks.json 켜짐 + 산출물 없음 → WARN"     "$(out_check "o2" live-task 'nomatch' test -f "$MISSING")" "⚠️  WARN: o2"
expect "스케줄도 없고 끔 → SKIP"                  "$(out_check "o3" old-task 'nomatch' test -f "$MISSING")" "SKIP: o3"
expect "tasks.json 없음 + 스케줄 없음 → SKIP"     "$(out_check "o4" gone-task 'nomatch' test -f "$MISSING")" "SKIP: o4"
expect "tasks.json 을 못 읽으면 산출물 검사는 WARN" \
  "$(E2E_TASKS_JSON=/nonexistent out_check "o5" live-task 'nomatch' test -f "$MISSING")" "⚠️  WARN: o5"
expect "tasks.json 을 못 읽으면 컨텍스트 검사도 WARN(은퇴로 넘기지 않음)" \
  "$(E2E_TASKS_JSON=/nonexistent ctx_check "c6" live-task test -f "$MISSING")" "⚠️  WARN: c6 — unreadable"

echo "▶ wiki_untagged (source 태그)"
mkdir -p "$TMP/wiki/ops" "$TMP/wiki2/ops"
printf '%s\n' "- [2026-04-14] 옛 조각" "- 날짜 없는 손 메모" "- [2026-09-09] [source:x] 정상" > "$TMP/wiki/ops/_facts.md"
out="$(wiki_untagged "$TMP/wiki")"; rc=$?
[[ $rc -eq 0 && "$out" == "recent=0 legacy=2" ]] && ok "도입 전 유산만 → 통과 ($out)" || bad "유산만 rc=$rc $out"
printf '%s\n' "- [2026-04-14] 옛 조각" "- [2026-09-20] 추출기가 태그를 빠뜨림" > "$TMP/wiki2/ops/_facts.md"
out="$(wiki_untagged "$TMP/wiki2")"; rc=$?
[[ $rc -eq 1 && "$out" == "recent=1 legacy=1" ]] && ok "도입 뒤 태그 누락 → 경고 ($out)" || bad "회귀 rc=$rc $out"

echo "▶ e2e-cron.sh 종료코드"
run_cron() {   # <가짜 e2e-test.sh 본문> → e2e-cron.sh 의 종료코드와 RESULT 줄
  local jh="$TMP/jh-$1" bh="$TMP/bh-$1"
  mkdir -p "$jh/infra/scripts" "$bh"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$jh/infra/scripts/e2e-test.sh"
  chmod +x "$jh/infra/scripts/e2e-test.sh"
  OPENCLAW_JOB=1 JARVIS_NO_EXTERNAL=1 BOT_HOME="$bh" JARVIS_HOME="$jh" bash "$HERE/e2e-cron.sh" >/dev/null 2>&1
  echo "rc=$? $(grep 'RESULT:' "$bh/logs/e2e-cron.log" | tail -1 | sed 's/^\[[^]]*\] //')"
}
expect "정상 종료 → 0"                        "$(run_cron ok 'echo "✅ PASS: a"; echo "  Results: 1 passed"; exit 0')" "rc=0 RESULT: 1/1 passed (exit: 0, suite rc=0)"
expect "실패 줄 있는 1 → 1(기존 경로)"         "$(run_cron fail 'echo "❌ FAIL: a"; echo "  Results: 0 passed"; exit 1')" "rc=1 RESULT: 0/1 passed, 1 FAILED (exit: 1, suite rc=1)"
expect "요약 전에 죽음 → 실패로 기록"          "$(run_cron abort 'echo "✅ PASS: a"; exit 3')" "rc=1 RESULT: 1/2 passed, 1 FAILED (exit: 1, suite rc=3)"
expect "실패 줄 없이 rc≠0 → 실패로 기록"       "$(run_cron silent 'echo "✅ PASS: a"; echo "  Results: 1 passed"; exit 2')" "rc=1 RESULT: 1/2 passed, 1 FAILED (exit: 1, suite rc=2)"

echo "▶ e2e-cron.sh 작업 트리 표식"
# 09-19~26 에 infra 미커밋 파일이 있는데도 매일 "clean" 이었다(.env 가 JARVIS_HOME 을 런타임으로 덮어써 git 실패 → 빈 목록).
#   JARVIS_HOME 을 git 이 아닌 곳으로 줘도 실제 저장소 상태를 써야 한다.
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
n_dirty=$(git -C "$REPO" status --porcelain -- infra | grep -c . || true)
tree=$(head -1 "$TMP"/bh-ok/results/e2e-health/*.txt 2>/dev/null)
if [[ "$n_dirty" -gt 0 ]]; then
  expect "미커밋 ${n_dirty}건이면 dirty" "$tree" "# TREE: dirty (${n_dirty})"
else
  expect "미커밋 0건이면 clean" "$tree" "# TREE: clean"
fi

echo ""
echo "PASSED=${PASSED} FAILURES=${FAILURES}"
exit $((FAILURES > 0 ? 1 : 0))
