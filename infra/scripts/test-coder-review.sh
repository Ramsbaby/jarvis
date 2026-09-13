#!/usr/bin/env bash
# test-coder-review.sh — coder-review.sh(3a 리뷰 + 3d 만료) 회귀 테스트 (SELF-HEAL-PLAN, 2026-09-05)
#
# 검증 대상 (ask-claude 모킹, 임시 저장소·BOT_HOME, 외부 송출 없음):
#   merge 판정 + 정책 미달 → 사람 대기(브랜치 유지) / merge + 정책 충족 → --auto 머지 / reject → 대기(브랜치 유지)
#   needs_human / 게이트 실패면 merge 판정이어도 자동 머지 안 함 / LLM 실패·파싱 실패 → error + exit 1
#   같은 tip 재리뷰 스킵, --force 재리뷰 / 7일 넘은 브랜치 --expire 폐기 / --no-llm / --task 필터 / 브랜치 없음
# 실행: bash ~/projects/jarvis/infra/scripts/test-coder-review.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
INFRA="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d /var/tmp/coder-review-test.XXXXXX)
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
PASSED=0; FAILURES=0
ok()   { PASSED=$((PASSED+1)); }
fail() { FAILURES=$((FAILURES+1)); echo "  ✗ $*"; }
expect_eq() { [[ "$2" == "$3" ]] && ok || fail "$1: expected [$3] got [$2]"; }
NODE_SQLITE="node --experimental-sqlite --no-warnings"

MAIN="$T/main"
mkdir -p "$MAIN/infra/lib" "$MAIN/infra/scripts" "$MAIN/infra/docs" "$MAIN/runtime"/{bin,config,state,logs,ledger,results}
git -C "$MAIN" init -q -b main && git -C "$MAIN" config user.email t@t && git -C "$MAIN" config user.name t
printf '/runtime/*\nnode_modules/\n' > "$MAIN/.gitignore"
echo "base" > "$MAIN/tracked.txt"
printf '#!/usr/bin/env bash\necho tool\n' > "$MAIN/infra/scripts/tool.sh"
git -C "$MAIN" add -A && git -C "$MAIN" commit -qm "init"
export BOT_HOME="$MAIN/runtime"
ln -s "$INFRA/lib" "$BOT_HOME/lib"
ln -s "$INFRA/scripts" "$BOT_HOME/scripts"
echo '{"webhooks":{}}' > "$BOT_HOME/config/monitoring.json"
export JARVIS_NO_EXTERNAL=1 JARVIS_CODER_WT_ROOT="$T/wt" JARVIS_CODER_AUTONOMY_CONFIG="$INFRA/config/coder-autonomy.json"
unset JARVIS_CODER_WORKTREE JARVIS_CODER_REPO JARVIS_CODER_BASE_BRANCH
REVIEW="$INFRA/scripts/coder-review.sh"
RLEDGER="$BOT_HOME/ledger/coder-review.jsonl"
MLEDGER="$BOT_HOME/ledger/coder-merge.jsonl"

# ask-claude 모킹: MOCK_VERDICT 로 판정, MOCK_MODE=error 면 실패, garbage 면 파싱 불가. 프롬프트를 기록해 내용 검증
cat > "$BOT_HOME/bin/ask-claude.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$2" > "${BOT_HOME}/last-prompt.txt"
echo "$1 $7" >> "${BOT_HOME}/ask-calls.txt"
case "${MOCK_MODE:-ok}" in
  error) exit 1 ;;
  garbage) echo "no verdict here"; exit 0 ;;
esac
printf '검토했습니다.\n```json_verdict\n{"verdict":"%s","reasons":["r1","r2"],"risk":"low"}\n```\n' "${MOCK_VERDICT:-merge}"
EOF
chmod +x "$BOT_HOME/bin/ask-claude.sh"

source "$INFRA/lib/coder-worktree.sh"
source "$INFRA/lib/coder-autonomy.sh"
_coder_log() { :; }
make_branch() { # <task> <file> <content> [commit-date]
    local task="$1" file="$2" content="$3" cdate="${4:-}" wt
    wt=$(coder_worktree_ensure "$task") || { fail "worktree 생성 실패 $task"; return 1; }
    mkdir -p "$(dirname "$wt/$file")"; printf '%s\n' "$content" > "$wt/$file"
    git -C "$wt" add -A
    if [[ -n "$cdate" ]]; then GIT_AUTHOR_DATE="$cdate" GIT_COMMITTER_DATE="$cdate" git -C "$wt" commit -qm "coder: $task"; else git -C "$wt" commit -qm "coder: $task"; fi
    coder_worktree_remove "$task"
}
vg_pass() { printf '{"ts":"2026-09-04T00:00:00Z","task":"%s","verdict":"%s","mode":"enforce"}\n' "$1" "${2:-PASS}" >> "$BOT_HOME/ledger/verify-gate.jsonl"; }
last_review() { tail -1 "$RLEDGER" | jq -r "$1"; }
has_branch() { git -C "$MAIN" show-ref --verify --quiet "refs/heads/coder/$1"; }
enqueue_done() {
    $NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" enqueue --id "$1" --title "제목 $1" --prompt "요구사항 $1" >/dev/null 2>&1
    $NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" transition "$1" running bash >/dev/null 2>&1
    $NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" transition "$1" done bash '{"result":"r","merge_pending":true,"result_summary":"요약 '"$1"'"}' >/dev/null 2>&1
}

echo "── 브랜치 없음"
out=$(bash "$REVIEW" 2>/dev/null); rc=$?
expect_eq "rc" "$rc" "0"
[[ "$out" == *"브랜치 0개"* && "$out" == *"없음"* ]] && ok || fail "빈 요약: $out"

echo "── merge 판정 + scripts 정책 미달 → 사람 대기, 브랜치 유지"
enqueue_done a1
make_branch a1 infra/scripts/tool.sh $'#!/usr/bin/env bash\necho tool-a1'
vg_pass a1
HEAD0=$(git -C "$MAIN" rev-parse HEAD)
out=$(MOCK_VERDICT=merge bash "$REVIEW" 2>/dev/null); rc=$?
expect_eq "rc" "$rc" "0"
expect_eq "원장 verdict" "$(last_review .verdict)" "merge"
expect_eq "원장 action needs_human" "$(last_review .action)" "needs_human"
expect_eq "원장 class" "$(last_review .class)" "scripts"
expect_eq "원장 gates_rc 0" "$(last_review .gates_rc)" "0"
expect_eq "원장 gates.syntax" "$(last_review .gates.syntax)" "ok"
expect_eq "원장 verify_gate" "$(last_review .verify_gate)" "PASS"
expect_eq "원장 reasons" "$(last_review '.reasons|join(",")')" "r1,r2"
expect_eq "원장 model 기본" "$(last_review .model)" "claude-opus-5"
expect_eq "본체 HEAD 불변" "$(git -C "$MAIN" rev-parse HEAD)" "$HEAD0"
has_branch a1 && ok || fail "브랜치 유지돼야"
[[ "$out" == *"🟢"* && "$out" == *"coder-merge.sh a1"* ]] && ok || fail "사람 호출 명령이 요약에 있어야: $out"
[[ "$out" == *"사람대기 1"* ]] && ok || fail "카운트: $out"
[[ -d "$T/wt/a1" ]] && fail "리뷰 뒤 worktree 정리돼야" || ok
p=$(cat "$BOT_HOME/last-prompt.txt")
[[ "$p" == *"요구사항 a1"* && "$p" == *"요약 a1"* && "$p" == *"tool-a1"* && "$p" == *"class=scripts"* ]] && ok || fail "프롬프트에 요구·결과·diff·class 가 있어야"
expect_eq "ask-claude 모델 인자" "$(tail -1 "$BOT_HOME/ask-calls.txt")" "coder-review-a1 claude-opus-5"

echo "── 같은 tip 재리뷰 스킵 / --force 재리뷰"
n0=$(wc -l < "$RLEDGER" | tr -d ' ')
out=$(MOCK_VERDICT=merge bash "$REVIEW" 2>/dev/null)
expect_eq "원장 줄 수 불변" "$(wc -l < "$RLEDGER" | tr -d ' ')" "$n0"
[[ "$out" == *"이미리뷰 1"* ]] && ok || fail "스킵 카운트: $out"
out=$(MOCK_VERDICT=merge bash "$REVIEW" --force 2>/dev/null)
expect_eq "--force 로 한 줄 추가" "$(wc -l < "$RLEDGER" | tr -d ' ')" "$((n0+1))"

echo "── merge 판정 + docs 정책 충족 → --auto 머지"
for i in 1 2 3; do jq -nc '{class:"docs",action:"merged",approved_by:"human"}' >> "$MLEDGER"; done
enqueue_done d1
make_branch d1 infra/docs/NOTE.md "note-d1"
vg_pass d1
out=$(MOCK_VERDICT=merge bash "$REVIEW" --task d1 2>/dev/null); rc=$?
expect_eq "rc" "$rc" "0"
expect_eq "원장 action auto_merged" "$(last_review .action)" "auto_merged"
expect_eq "본체 NOTE.md" "$(cat "$MAIN/infra/docs/NOTE.md")" "note-d1"
has_branch d1 && fail "머지 뒤 브랜치 삭제돼야" || ok
expect_eq "머지 원장 merged/auto" "$(tail -1 "$MLEDGER" | jq -r '.action+"/"+.approved_by')" "merged/auto"
expect_eq "DB merged_by auto" "$($NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" get d1 | jq -r .meta.merged_by)" "auto"
[[ "$out" == *"자동머지 1"* && "$out" == *"✅"* ]] && ok || fail "요약: $out"
has_branch a1 && ok || fail "--task 필터: a1 은 건드리지 않아야"

echo "── merge 판정이어도 게이트 실패면 자동 머지 안 함"
for i in 1 2 3; do jq -nc '{class:"docs",action:"merged",approved_by:"human"}' >> "$MLEDGER"; done
make_branch d2 infra/docs/BAD.md "bad"
vg_pass d2 FAIL
out=$(MOCK_VERDICT=merge bash "$REVIEW" --task d2 2>/dev/null); rc=$?
expect_eq "rc" "$rc" "0"
expect_eq "원장 gates_rc 2" "$(last_review .gates_rc)" "2"
expect_eq "원장 gates.verify_gate FAIL" "$(last_review .gates.verify_gate)" "FAIL"
expect_eq "원장 action needs_human" "$(last_review .action)" "needs_human"
has_branch d2 && ok || fail "브랜치 유지"
[[ "$out" == *"게이트 rc=2"* ]] && ok || fail "요약에 게이트 rc: $out"

echo "── reject 판정 → 브랜치 유지 + 폐기 명령 안내"
make_branch r1 infra/scripts/rej.sh $'#!/usr/bin/env bash\necho rej'
vg_pass r1
out=$(MOCK_VERDICT=reject bash "$REVIEW" --task r1 2>/dev/null); rc=$?
expect_eq "rc" "$rc" "0"
expect_eq "원장 verdict reject" "$(last_review .verdict)" "reject"
has_branch r1 && ok || fail "reject 는 자동 삭제하지 않음"
[[ "$out" == *"🔴"* && "$out" == *"--reject"* && "$out" == *"reject 1"* ]] && ok || fail "요약: $out"

echo "── needs_human 판정"
make_branch h1 infra/scripts/h.sh $'#!/usr/bin/env bash\necho h'
vg_pass h1
out=$(MOCK_VERDICT=needs_human bash "$REVIEW" --task h1 2>/dev/null); rc=$?
expect_eq "rc" "$rc" "0"
expect_eq "원장 verdict" "$(last_review .verdict)" "needs_human"
[[ "$out" == *"🟡"* && "$out" == *"--dry-run"* ]] && ok || fail "요약: $out"

echo "── LLM 실패 → error + exit 1, 브랜치 유지"
make_branch e1 infra/scripts/e.sh $'#!/usr/bin/env bash\necho e'
vg_pass e1
out=$(MOCK_MODE=error bash "$REVIEW" --task e1 2>/dev/null); rc=$?
expect_eq "rc 1" "$rc" "1"
expect_eq "원장 verdict error" "$(last_review .verdict)" "error"
expect_eq "원장 llm_rc 1" "$(last_review .llm_rc)" "1"
has_branch e1 && ok || fail "브랜치 유지"
[[ "$out" == *"⚠️"* && "$out" == *"오류 1"* ]] && ok || fail "요약: $out"
out=$(MOCK_MODE=garbage bash "$REVIEW" --task e1 --force 2>/dev/null); rc=$?
expect_eq "파싱 불가 rc 1" "$rc" "1"
expect_eq "파싱 불가 llm_rc 0" "$(last_review .llm_rc)" "0"

echo "── 3d: 7일 넘은 브랜치 만료 폐기"
make_branch old1 infra/scripts/old.sh $'#!/usr/bin/env bash\necho old' "2026-08-20T00:00:00"
vg_pass old1
S0=$(coder_autonomy_streak scripts)
out=$(MOCK_VERDICT=merge bash "$REVIEW" --task old1 2>/dev/null); rc=$?
expect_eq "rc" "$rc" "0"
has_branch old1 && fail "만료 브랜치 삭제돼야" || ok
expect_eq "리뷰 원장 expired" "$(last_review .verdict)" "expired"
expect_eq "머지 원장 expired/auto" "$(tail -1 "$MLEDGER" | jq -r '.action+"/"+.approved_by')" "expired/auto"
expect_eq "만료는 스트릭 유지" "$(coder_autonomy_streak scripts)" "$S0"
[[ "$out" == *"⏳"* && "$out" == *"만료 1"* ]] && ok || fail "요약: $out"
grep -q 'coder-review-old1' "$BOT_HOME/ask-calls.txt" && fail "만료 브랜치는 LLM 을 부르지 않아야" || ok
make_branch old2 infra/scripts/old2.sh $'#!/usr/bin/env bash\necho old2' "$(date -v-6d +%FT%T 2>/dev/null || date -d '6 days ago' +%FT%T)"
vg_pass old2
out=$(MOCK_VERDICT=needs_human bash "$REVIEW" --task old2 2>/dev/null)
has_branch old2 && ok || fail "6일은 만료 아님"

echo "── 큐 running 브랜치는 건너뜀 (만료 대상이어도)"
$NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" enqueue --id run1 --title "t" --prompt "p" >/dev/null 2>&1
$NODE_SQLITE "$BOT_HOME/lib/task-store.mjs" transition run1 running bash >/dev/null 2>&1
make_branch run1 infra/scripts/run.sh $'#!/usr/bin/env bash\necho run' "2026-08-01T00:00:00"
calls0=$(wc -l < "$BOT_HOME/ask-calls.txt" | tr -d ' ')
out=$(MOCK_VERDICT=merge bash "$REVIEW" --task run1 2>/dev/null); rc=$?
expect_eq "rc" "$rc" "0"
has_branch run1 && ok || fail "running 브랜치는 만료시키지 않아야"
expect_eq "LLM 호출 없음" "$(wc -l < "$BOT_HOME/ask-calls.txt" | tr -d ' ')" "$calls0"
[[ "$out" == *"⏩"* && "$out" == *"실행 중"* ]] && ok || fail "요약: $out"

echo "── --no-llm"
make_branch n1 infra/scripts/n.sh $'#!/usr/bin/env bash\necho n'
vg_pass n1
calls0=$(wc -l < "$BOT_HOME/ask-calls.txt" | tr -d ' ')
n0=$(wc -l < "$RLEDGER" | tr -d ' ')
out=$(bash "$REVIEW" --task n1 --no-llm 2>/dev/null); rc=$?
expect_eq "rc" "$rc" "0"
expect_eq "LLM 호출 없음" "$(wc -l < "$BOT_HOME/ask-calls.txt" | tr -d ' ')" "$calls0"
expect_eq "리뷰 원장 무기록" "$(wc -l < "$RLEDGER" | tr -d ' ')" "$n0"
[[ "$out" == *"📋"* && "$out" == *"판정 생략"* ]] && ok || fail "요약: $out"

echo
echo "PASSED=$PASSED FAILURES=$FAILURES"
[[ $FAILURES -eq 0 ]]
