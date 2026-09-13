#!/usr/bin/env bash
# test-coder-merge.sh — coder-merge.sh(3b) + coder-autonomy.sh(3c) 회귀 테스트 (SELF-HEAL-PLAN, 2026-09-04)
#
# 검증 대상:
#   coder-autonomy.sh : 파일 분류(영구 수동·tests·docs·scripts), 혼합 변경은 가장 엄격한 쪽, 원장 연속 승인 카운트·리셋, --auto 허용 판정
#   coder-merge.sh    : 게이트 통과 → ff 머지 + 원장 merged + tasks.db meta + 브랜치 삭제 / 문법 실패 → exit 2 본체 불변
#                       / verify-gate PASS 아님 → exit 2 / --skip-gate-check / base 가 앞선 경우 rebase 후 ff / rebase 충돌 → exit 4
#                       / --auto 정책 차단 → exit 3 / --auto 문턱 충족 → 머지 / --reject → 브랜치 폐기 + rejected / --dry-run 무변경
#   task-store.mjs    : meta-patch 가 상태를 바꾸지 않고 meta 만 병합
# 실행: bash ~/projects/jarvis/infra/scripts/test-coder-merge.sh   (외부 송출 없음 — 임시 저장소·임시 BOT_HOME)
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
INFRA="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d /var/tmp/coder-merge-test.XXXXXX)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
PASSED=0; FAILURES=0
ok()   { PASSED=$((PASSED+1)); }
fail() { FAILURES=$((FAILURES+1)); echo "  ✗ $*"; }
expect_eq() { [[ "$2" == "$3" ]] && ok || fail "$1: expected [$3] got [$2]"; }
NODE_SQLITE="node --experimental-sqlite --no-warnings"

# ── 본체 흉내: git 저장소 + gitignore 된 runtime(BOT_HOME)
MAIN="$T/main"
mkdir -p "$MAIN/infra/lib" "$MAIN/infra/scripts" "$MAIN/infra/docs" "$MAIN/infra/node_modules" "$MAIN/runtime"/{bin,config,state,logs,ledger,results}
git -C "$MAIN" init -q -b main && git -C "$MAIN" config user.email t@t && git -C "$MAIN" config user.name t
printf '/runtime/*\nnode_modules/\n' > "$MAIN/.gitignore"
echo "base" > "$MAIN/tracked.txt"
printf '#!/usr/bin/env bash\necho lib\n' > "$MAIN/infra/lib/dummy.sh"
printf '#!/usr/bin/env bash\necho tool\n' > "$MAIN/infra/scripts/tool.sh"
# 관련 테스트: tool.sh 를 언급하고 PASSED/FAILURES 를 찍는다. MOCK_TEST_FAIL=1 이면 실패
cat > "$MAIN/infra/scripts/test-tool.sh" <<'EOF'
#!/usr/bin/env bash
# tests tool.sh
if [[ "${MOCK_TEST_FAIL:-0}" == "1" ]]; then echo "PASSED=0 FAILURES=1"; exit 1; fi
echo "PASSED=1 FAILURES=0"; exit 0
EOF
echo "pkg" > "$MAIN/infra/node_modules/pkg.txt"
git -C "$MAIN" add -A && git -C "$MAIN" commit -qm "init"
export BOT_HOME="$MAIN/runtime"
ln -s "$INFRA/lib" "$BOT_HOME/lib"
ln -s "$INFRA/scripts" "$BOT_HOME/scripts"
echo '{"webhooks":{}}' > "$BOT_HOME/config/monitoring.json"
export JARVIS_NO_EXTERNAL=1 JARVIS_CODER_WT_ROOT="$T/wt"
export JARVIS_CODER_AUTONOMY_CONFIG="$INFRA/config/coder-autonomy.json"
unset JARVIS_CODER_WORKTREE JARVIS_CODER_REPO JARVIS_CODER_BASE_BRANCH
MERGE="$INFRA/scripts/coder-merge.sh"
LEDGER="$BOT_HOME/ledger/coder-merge.jsonl"

source "$INFRA/lib/coder-worktree.sh"
source "$INFRA/lib/coder-autonomy.sh"
_coder_log() { echo "[$(date '+%T')] $1" >> "$BOT_HOME/logs/jarvis-coder.log"; }

# 브랜치 만들기: make_branch <task> <file> <content>
make_branch() {
    local task="$1" file="$2" content="$3" wt
    wt=$(coder_worktree_ensure "$task") || { fail "worktree 생성 실패 $task"; return 1; }
    mkdir -p "$(dirname "$wt/$file")"
    printf '%s\n' "$content" > "$wt/$file"
    git -C "$wt" add -A && git -C "$wt" commit -qm "coder: $task"
    coder_worktree_remove "$task"
}
vg_pass() { printf '{"ts":"2026-09-04T00:00:00Z","task":"%s","verdict":"%s","mode":"enforce"}\n' "$1" "${2:-PASS}" >> "$BOT_HOME/ledger/verify-gate.jsonl"; }
last_ledger() { tail -1 "$LEDGER" | jq -r "$1"; }
enqueue_done() { # <task> — done 행 + merge_pending:true
    $NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" enqueue --id "$1" --title "t $1" --prompt "p" >/dev/null 2>&1
    $NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" transition "$1" running bash >/dev/null 2>&1
    $NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" transition "$1" done bash '{"result":"r","merge_pending":true,"branch":"coder/'"$1"'"}' >/dev/null 2>&1
}

echo "── coder-autonomy.sh: 분류"
expect_eq "tasks.json 영구 수동" "$(coder_autonomy_classify_file runtime/config/tasks.json)" "manual_forever"
expect_eq "infra/lib 하위 영구 수동" "$(coder_autonomy_classify_file infra/lib/coder-functions.sh)" "manual_forever"
expect_eq "infra/bin 하위 영구 수동" "$(coder_autonomy_classify_file infra/bin/bot-cron.sh)" "manual_forever"
expect_eq "hooks 영구 수동" "$(coder_autonomy_classify_file infra/hooks/x.sh)" "manual_forever"
expect_eq ".claude 영구 수동" "$(coder_autonomy_classify_file .claude/hooks/y.sh)" "manual_forever"
expect_eq "plist 영구 수동" "$(coder_autonomy_classify_file infra/launchagents/a.plist)" "manual_forever"
expect_eq "test-*.sh → tests" "$(coder_autonomy_classify_file infra/scripts/test-foo.sh)" "tests"
expect_eq "docs → docs" "$(coder_autonomy_classify_file infra/docs/MAP.md)" "docs"
expect_eq "루트 md → docs" "$(coder_autonomy_classify_file README.md)" "docs"
expect_eq "scripts → scripts" "$(coder_autonomy_classify_file infra/scripts/tool.sh)" "scripts"
expect_eq "prompts 의 md → docs (order 상 docs 가 scripts 보다 먼저)" "$(coder_autonomy_classify_file infra/prompts/p.md)" "docs"
expect_eq "prompts 의 txt → scripts" "$(coder_autonomy_classify_file infra/prompts/p.txt)" "scripts"
expect_eq "미매치 → default" "$(coder_autonomy_classify_file somewhere/else.txt)" "scripts"
expect_eq "혼합: docs+scripts → scripts" "$(printf 'infra/docs/a.md\ninfra/scripts/b.sh\n' | coder_autonomy_classify_files)" "scripts"
expect_eq "혼합: scripts+lib → manual_forever" "$(printf 'infra/scripts/b.sh\ninfra/lib/c.sh\n' | coder_autonomy_classify_files)" "manual_forever"
expect_eq "혼합: tests+docs → tests(5>3)" "$(printf 'infra/scripts/test-a.sh\ninfra/docs/a.md\n' | coder_autonomy_classify_files)" "tests"
expect_eq "빈 입력 → default" "$(printf '' | coder_autonomy_classify_files)" "scripts"
expect_eq "threshold manual" "$(coder_autonomy_threshold manual_forever)" "null"
expect_eq "threshold scripts" "$(coder_autonomy_threshold scripts)" "10"

echo "── coder-autonomy.sh: 연속 승인 카운트"
expect_eq "원장 없음 → 0" "$(coder_autonomy_streak scripts)" "0"
mkdir -p "$(dirname "$LEDGER")"
for i in 1 2 3; do echo '{"class":"docs","action":"merged"}' >> "$LEDGER"; done
echo '{"class":"scripts","action":"merged"}' >> "$LEDGER"
echo '{"class":"docs","action":"dry_run"}' >> "$LEDGER"
expect_eq "docs 3연속 (dry_run 무시)" "$(coder_autonomy_streak docs)" "3"
expect_eq "scripts 1" "$(coder_autonomy_streak scripts)" "1"
coder_autonomy_allows_auto docs >/dev/null && ok || fail "docs 3/3 은 자동 허용이어야"
coder_autonomy_allows_auto scripts >/dev/null && fail "scripts 1/10 은 차단이어야" || ok
coder_autonomy_allows_auto manual_forever >/dev/null && fail "manual_forever 는 항상 차단" || ok
echo '{"class":"docs","action":"expired"}' >> "$LEDGER"
expect_eq "만료는 스트릭 유지" "$(coder_autonomy_streak docs)" "3"
echo '{"class":"docs","action":"rejected"}' >> "$LEDGER"
expect_eq "거절 → 0 리셋" "$(coder_autonomy_streak docs)" "0"
echo '{"class":"docs","action":"merged"}' >> "$LEDGER"
expect_eq "리셋 뒤 1" "$(coder_autonomy_streak docs)" "1"
rm -f "$LEDGER"

echo "── task-store meta-patch"
enqueue_done mp1
out=$($NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" meta-patch mp1 '{"merge_pending":false,"merged_at":"x","status":"queued"}' 2>&1); rc=$?
expect_eq "meta-patch rc" "$rc" "0"
row=$($NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" get mp1)
expect_eq "상태 불변(done)" "$(jq -r .status <<<"$row")" "done"
expect_eq "merge_pending false" "$(jq -r .meta.merge_pending <<<"$row")" "false"
expect_eq "merged_at 병합" "$(jq -r .meta.merged_at <<<"$row")" "x"
expect_eq "기존 branch 키 보존" "$(jq -r .meta.branch <<<"$row")" "coder/mp1"
$NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" meta-patch nope '{}' >/dev/null 2>&1 && fail "없는 태스크는 실패해야" || ok
$NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" meta-patch mp1 'not-json' >/dev/null 2>&1 && fail "깨진 JSON 은 실패해야" || ok

echo "── coder-merge.sh: 사용법·전제조건"
bash "$MERGE" >/dev/null 2>&1; expect_eq "인자 없음 rc" "$?" "1"
bash "$MERGE" ghost-task >/dev/null 2>&1; expect_eq "브랜치 없음 rc" "$?" "1"

echo "── coder-merge.sh: 정상 머지 (사람)"
enqueue_done m1
make_branch m1 infra/scripts/tool.sh $'#!/usr/bin/env bash\necho tool-v2'
vg_pass m1
HEAD0=$(git -C "$MAIN" rev-parse HEAD)
out=$(bash "$MERGE" m1 2>&1); rc=$?
expect_eq "머지 rc" "$rc" "0"
expect_eq "본체 tool.sh 갱신" "$(tail -1 "$MAIN/infra/scripts/tool.sh")" "echo tool-v2"
[[ "$(git -C "$MAIN" rev-parse HEAD)" != "$HEAD0" ]] && ok || fail "본체 HEAD 가 전진해야"
expect_eq "본체 status 깨끗" "$(git -C "$MAIN" status --porcelain | wc -l | tr -d ' ')" "0"
git -C "$MAIN" show-ref --verify --quiet refs/heads/coder/m1 && fail "머지 뒤 브랜치 삭제돼야" || ok
[[ -d "$T/wt/m1" ]] && fail "worktree 남으면 안 됨" || ok
expect_eq "원장 action" "$(last_ledger .action)" "merged"
expect_eq "원장 approved_by" "$(last_ledger .approved_by)" "human"
expect_eq "원장 class" "$(last_ledger .class)" "scripts"
expect_eq "원장 files" "$(last_ledger '.files|join(",")')" "infra/scripts/tool.sh"
expect_eq "원장 gates.syntax" "$(last_ledger .gates.syntax)" "ok"
expect_eq "원장 gates.tests (test-tool.sh 1/0)" "$(last_ledger .gates.tests | cut -d' ' -f1)" "1/0"
expect_eq "원장 gates.verify_gate" "$(last_ledger .gates.verify_gate)" "PASS"
expect_eq "원장 merged_commit = HEAD" "$(last_ledger .merged_commit)" "$(git -C "$MAIN" rev-parse --short HEAD)"
row=$($NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" get m1)
expect_eq "DB merge_pending false" "$(jq -r .meta.merge_pending <<<"$row")" "false"
expect_eq "DB merged_by human" "$(jq -r .meta.merged_by <<<"$row")" "human"
expect_eq "DB 상태 done 유지" "$(jq -r .status <<<"$row")" "done"
grep -q 'NO_EXTERNAL' "$BOT_HOME/logs/no-external.log" 2>/dev/null && ok || fail "디스코드 송출이 no-external 로그로 갔어야"

echo "── coder-merge.sh: 문법 실패 → exit 2, 본체 불변"
make_branch m2 infra/scripts/broken.sh $'#!/usr/bin/env bash\nif [[ x ]; then echo\n'
vg_pass m2
HEAD0=$(git -C "$MAIN" rev-parse HEAD)
bash "$MERGE" m2 >/dev/null 2>&1; expect_eq "문법 실패 rc" "$?" "2"
expect_eq "본체 HEAD 불변" "$(git -C "$MAIN" rev-parse HEAD)" "$HEAD0"
[[ -e "$MAIN/infra/scripts/broken.sh" ]] && fail "본체에 broken.sh 가 생기면 안 됨" || ok
expect_eq "원장 blocked" "$(last_ledger .action)" "blocked"
expect_eq "원장 gates.syntax fail" "$(last_ledger .gates.syntax)" "fail"
git -C "$MAIN" show-ref --verify --quiet refs/heads/coder/m2 && ok || fail "차단 시 브랜치는 남아야"

echo "── coder-merge.sh: 관련 테스트 실패 → exit 2"
make_branch m3 infra/scripts/tool.sh $'#!/usr/bin/env bash\necho tool-v3'
vg_pass m3
MOCK_TEST_FAIL=1 bash "$MERGE" m3 >/dev/null 2>&1; expect_eq "테스트 실패 rc" "$?" "2"
expect_eq "원장 gates.tests 0/1" "$(last_ledger .gates.tests | cut -d' ' -f1)" "0/1"
expect_eq "본체 tool.sh 그대로 v2" "$(tail -1 "$MAIN/infra/scripts/tool.sh")" "echo tool-v2"

echo "── coder-merge.sh: verify-gate PASS 아님 → exit 2, --skip-gate-check 로 통과"
make_branch m4 infra/docs/NOTE.md "note"
vg_pass m4 FAIL
bash "$MERGE" m4 >/dev/null 2>&1; expect_eq "verify FAIL rc" "$?" "2"
expect_eq "원장 gates.verify_gate FAIL" "$(last_ledger .gates.verify_gate)" "FAIL"
bash "$MERGE" m4 --skip-gate-check >/dev/null 2>&1; expect_eq "skip-gate-check rc" "$?" "0"
expect_eq "원장 verify_gate skipped" "$(last_ledger .gates.verify_gate | cut -d'(' -f1)" "skipped"
expect_eq "원장 class docs" "$(last_ledger .class)" "docs"
expect_eq "본체 NOTE.md" "$(cat "$MAIN/infra/docs/NOTE.md")" "note"

echo "── coder-merge.sh: verify-gate 기록 없음(NONE) → exit 2"
make_branch m4b infra/docs/NOTE2.md "note2"
bash "$MERGE" m4b >/dev/null 2>&1; expect_eq "NONE rc" "$?" "2"
expect_eq "원장 verify_gate NONE" "$(last_ledger .gates.verify_gate)" "NONE"

echo "── coder-merge.sh: base 가 앞선 경우 rebase 후 ff"
make_branch m5 infra/scripts/other.sh $'#!/usr/bin/env bash\necho other'
vg_pass m5
echo "moved" >> "$MAIN/tracked.txt" && git -C "$MAIN" commit -qam "main moves on"
bash "$MERGE" m5 >/dev/null 2>&1; expect_eq "rebase+ff rc" "$?" "0"
expect_eq "원장 gates.rebase" "$(last_ledger .gates.rebase)" "rebased"
[[ -f "$MAIN/infra/scripts/other.sh" ]] && ok || fail "rebase 뒤 other.sh 반영"
expect_eq "본체 tracked.txt 는 main 쪽 유지" "$(tail -1 "$MAIN/tracked.txt")" "moved"
expect_eq "선형 히스토리(머지 커밋 없음)" "$(git -C "$MAIN" log --merges --oneline | wc -l | tr -d ' ')" "0"

echo "── coder-merge.sh: rebase 충돌 → exit 4, 본체 불변"
make_branch m6 tracked.txt "coder-side"
vg_pass m6
echo "main-side" > "$MAIN/tracked.txt" && git -C "$MAIN" commit -qam "conflicting"
HEAD0=$(git -C "$MAIN" rev-parse HEAD)
bash "$MERGE" m6 >/dev/null 2>&1; expect_eq "충돌 rc" "$?" "4"
expect_eq "본체 HEAD 불변" "$(git -C "$MAIN" rev-parse HEAD)" "$HEAD0"
expect_eq "원장 gates.rebase conflict" "$(last_ledger .gates.rebase)" "conflict"
[[ -z "$(git -C "$T/wt/m6" status --porcelain 2>/dev/null | grep -v '^??')" ]] && ok || fail "충돌 worktree 는 abort 로 깨끗해야"

echo "── coder-merge.sh: --auto 정책"
make_branch m7 infra/scripts/tool.sh $'#!/usr/bin/env bash\necho tool-v7'
vg_pass m7
HEAD0=$(git -C "$MAIN" rev-parse HEAD)
bash "$MERGE" m7 --auto >/dev/null 2>&1; expect_eq "scripts 문턱 미달 rc" "$?" "3"
expect_eq "본체 HEAD 불변" "$(git -C "$MAIN" rev-parse HEAD)" "$HEAD0"
expect_eq "원장 blocked/auto" "$(last_ledger '.action+"/"+.approved_by')" "blocked/auto"
# docs 문턱(3) 채우기 — 사람 승인 3회를 원장에 시뮬레이션
for i in 1 2 3; do jq -nc '{class:"docs",action:"merged",approved_by:"human"}' >> "$LEDGER"; done
make_branch m8 infra/docs/AUTO.md "auto"
vg_pass m8
bash "$MERGE" m8 --auto >/dev/null 2>&1; expect_eq "docs 문턱 충족 --auto rc" "$?" "0"
expect_eq "원장 merged/auto" "$(last_ledger '.action+"/"+.approved_by')" "merged/auto"
expect_eq "본체 AUTO.md" "$(cat "$MAIN/infra/docs/AUTO.md")" "auto"
make_branch m9 infra/lib/dummy.sh $'#!/usr/bin/env bash\necho lib2'
vg_pass m9
bash "$MERGE" m9 --auto >/dev/null 2>&1; expect_eq "manual_forever --auto rc" "$?" "3"
bash "$MERGE" m9 >/dev/null 2>&1; expect_eq "manual_forever 사람 호출은 머지" "$?" "0"
expect_eq "본체 dummy.sh" "$(tail -1 "$MAIN/infra/lib/dummy.sh")" "echo lib2"

echo "── coder-merge.sh: --reject"
enqueue_done r1
make_branch r1 infra/scripts/rej.sh $'#!/usr/bin/env bash\necho rej'
bash "$MERGE" r1 --reject "쓸모없음" >/dev/null 2>&1; expect_eq "reject rc" "$?" "0"
git -C "$MAIN" show-ref --verify --quiet refs/heads/coder/r1 && fail "거절 브랜치는 삭제돼야" || ok
expect_eq "원장 rejected" "$(last_ledger .action)" "rejected"
expect_eq "원장 reason" "$(last_ledger .reason)" "쓸모없음"
row=$($NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" get r1)
expect_eq "DB discard_reason" "$(jq -r .meta.discard_reason <<<"$row")" "쓸모없음"
expect_eq "DB discard_action" "$(jq -r .meta.discard_action <<<"$row")" "rejected"
bash "$MERGE" r1 --reject >/dev/null 2>&1; expect_eq "사유 없는 reject rc" "$?" "1"

echo "── coder-merge.sh: --expire (3d)"
S0=$(coder_autonomy_streak scripts)
make_branch x1 infra/scripts/old.sh $'#!/usr/bin/env bash\necho old'
bash "$MERGE" x1 --expire "7일 미처리" >/dev/null 2>&1; expect_eq "expire rc" "$?" "0"
git -C "$MAIN" show-ref --verify --quiet refs/heads/coder/x1 && fail "만료 브랜치는 삭제돼야" || ok
expect_eq "원장 expired/auto" "$(last_ledger '.action+"/"+.approved_by')" "expired/auto"
expect_eq "만료는 scripts 스트릭을 깎지 않음" "$(coder_autonomy_streak scripts)" "$S0"
expect_eq "docs 스트릭 유지 (scripts 거절은 docs 와 무관: m4+시뮬3+m8)" "$(coder_autonomy_streak docs)" "5"

echo "── coder-merge.sh: --dry-run 무변경"
make_branch d1 infra/scripts/dry.sh $'#!/usr/bin/env bash\necho dry'
vg_pass d1
HEAD0=$(git -C "$MAIN" rev-parse HEAD)
bash "$MERGE" d1 --dry-run >/dev/null 2>&1; expect_eq "dry-run rc" "$?" "0"
expect_eq "본체 HEAD 불변" "$(git -C "$MAIN" rev-parse HEAD)" "$HEAD0"
git -C "$MAIN" show-ref --verify --quiet refs/heads/coder/d1 && ok || fail "dry-run 은 브랜치 유지"
[[ -d "$T/wt/d1" ]] && fail "dry-run 뒤 worktree 정리돼야" || ok
expect_eq "원장 dry_run" "$(last_ledger .action)" "dry_run"
expect_eq "dry_run 은 스트릭에 안 셈" "$(coder_autonomy_streak scripts)" "0"

echo "── coder-merge.sh: --dry-run 은 base 가 앞서도 브랜치를 다시 쓰지 않음"
make_branch d2 infra/scripts/dry2.sh $'#!/usr/bin/env bash\necho dry2'
vg_pass d2
echo "moved-again" >> "$MAIN/tracked.txt" && git -C "$MAIN" commit -qam "main moves again"
B0=$(git -C "$MAIN" rev-parse coder/d2)
bash "$MERGE" d2 --dry-run >/dev/null 2>&1; expect_eq "dry-run(rebase 필요) rc" "$?" "0"
expect_eq "브랜치 커밋 불변" "$(git -C "$MAIN" rev-parse coder/d2)" "$B0"
expect_eq "원장 gates.rebase needed" "$(last_ledger .gates.rebase)" "needed(dry-run)"

echo "── coder-merge.sh: 변경 없는 브랜치 → exit 2"
coder_worktree_ensure empty1 >/dev/null; coder_worktree_remove empty1
bash "$MERGE" empty1 >/dev/null 2>&1; expect_eq "빈 브랜치 rc" "$?" "2"

echo
echo "PASSED=$PASSED FAILURES=$FAILURES"
[[ $FAILURES -eq 0 ]]
