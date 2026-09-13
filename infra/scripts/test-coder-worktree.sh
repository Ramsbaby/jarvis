#!/usr/bin/env bash
# test-coder-worktree.sh — 코더 worktree 격리 실행 회귀 테스트 (SELF-HEAL-PLAN 1b)
#
# 검증 대상:
#   coder-worktree.sh   : 생성·재사용·제거·브랜치 재생성·잔재 복구·패치 내보내기·경로 치환·cd 실행
#   coder-functions.sh  : run_one_task 전 과정이 worktree 안에서만 일어나고 본체는 전후 동일
#                         (done → 브랜치+patch, 실행 실패 → 롤백, 검증 FAIL → 롤백, 검증 불가 → WIP 커밋+보류,
#                          worktree 못 만듦 → 보류, 옛 방식 스위치)
#   verify-sprint-contract.sh : JARVIS_CODER_REPO 가 있으면 verifyCmd 를 작업 사본에서 실행
#   쓰기 경계 훅        : scope 모드에서 worktree 안 쓰기 허용 / 본체 쓰기·본체 git 변조·runtime 보호경로 차단
# 실행: bash ~/projects/jarvis/infra/scripts/test-coder-worktree.sh   (외부 송출 없음 — 임시 저장소, retry-wrapper·ask-claude 모킹)
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
INFRA="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d /var/tmp/coder-wt-test.XXXXXX)
T=$(cd "$T" && pwd -P)   # /var/tmp → /private/var/tmp: git 은 실경로를 돌려준다
trap 'rm -rf "$T"' EXIT
PASSED=0; FAILURES=0
ok()   { PASSED=$((PASSED+1)); }
fail() { FAILURES=$((FAILURES+1)); echo "  ✗ $*"; }
expect_eq() { [[ "$2" == "$3" ]] && ok || fail "$1: expected [$3] got [$2]"; }

# ── 본체 흉내: git 저장소 + gitignore 된 runtime(BOT_HOME) + node_modules
MAIN="$T/main"
mkdir -p "$MAIN/infra/lib" "$MAIN/infra/node_modules" "$MAIN/runtime"/{bin,config,state/sprint-contracts,logs,ledger,results}
git -C "$MAIN" init -q -b main && git -C "$MAIN" config user.email t@t && git -C "$MAIN" config user.name t
printf '/runtime/*\nnode_modules/\n' > "$MAIN/.gitignore"
echo "base" > "$MAIN/tracked.txt"
echo 'echo dummy' > "$MAIN/infra/lib/dummy.sh"
echo "pkg" > "$MAIN/infra/node_modules/pkg.txt"
git -C "$MAIN" add -A && git -C "$MAIN" commit -qm "init"
export BOT_HOME="$MAIN/runtime"
ln -s "$INFRA/lib" "$BOT_HOME/lib"
ln -s "$INFRA/scripts" "$BOT_HOME/scripts"
echo '{"webhooks":{}}' > "$BOT_HOME/config/monitoring.json"
export JARVIS_NO_EXTERNAL=1 JARVIS_CODER_WT_ROOT="$T/wt" JARVIS_VERIFY_GATE=enforce
unset JARVIS_CODER_WORKTREE JARVIS_CODER_REPO JARVIS_AGENT_WRITE_SCOPE

# retry-wrapper 모킹: 코더 세션처럼 JARVIS_CODER_REPO 안에 파일을 만든다. 환경을 기록해 경계 전달을 검증한다.
cat > "$BOT_HOME/bin/retry-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
echo "SCOPE=${JARVIS_AGENT_WRITE_SCOPE:-} REPO=${JARVIS_CODER_REPO:-} TASK=$1" >> "${BOT_HOME}/rw-env.txt"
case "$1" in
  *-contract) exit 1 ;;                          # Sprint Contract 협상 실패 → legacy completionCheck 경로
  t-exec1)    exit 1 ;;                          # 실행 실패
  *) mkdir -p "${JARVIS_CODER_REPO:?}/infra"
     echo "echo new" > "${JARVIS_CODER_REPO}/infra/new.sh"
     echo "edited" > "${JARVIS_CODER_REPO}/tracked.txt"
     echo "done"; exit 0 ;;
esac
EOF
# ask-claude 모킹 (verify-gate 감사관): MOCK_MODE 로 판정
cat > "$BOT_HOME/bin/ask-claude.sh" <<'EOF'
#!/usr/bin/env bash
case "${MOCK_MODE:-pass}" in
  error) exit 1 ;;
  pass) printf '판정\n```json_verdict\n{"verdict":"PASS","reasons":["ok"],"missing":[]}\n```\n' ;;
  fail) printf '판정\n```json_verdict\n{"verdict":"FAIL","reasons":["bad"],"missing":["x"]}\n```\n' ;;
esac
EOF
chmod +x "$BOT_HOME/bin/"*.sh

MAIN_HEAD=$(git -C "$MAIN" rev-parse HEAD)
main_unchanged() { # <설명>
    expect_eq "$1: 본체 HEAD 불변" "$(git -C "$MAIN" rev-parse HEAD)" "$MAIN_HEAD"
    expect_eq "$1: 본체 status 깨끗" "$(git -C "$MAIN" status --porcelain | wc -l | tr -d ' ')" "0"
    expect_eq "$1: 본체 tracked.txt 원본" "$(cat "$MAIN/tracked.txt")" "base"
    [[ ! -e "$MAIN/infra/new.sh" ]] && ok || fail "$1: 본체에 new.sh 가 생기면 안 된다"
}

echo "── coder-worktree.sh: 생성"
source "$INFRA/lib/coder-worktree.sh"
_coder_log() { echo "[$(date '+%T')] $1" >> "$BOT_HOME/logs/jarvis-coder.log"; }
WT=$(coder_worktree_ensure t1); RC=$?
expect_eq "ensure rc" "$RC" "0"
expect_eq "경로" "$WT" "$T/wt/t1"
[[ -f "$WT/tracked.txt" && -f "$WT/infra/lib/dummy.sh" ]] && ok || fail "체크아웃 파일 없음"
expect_eq "브랜치" "$(git -C "$WT" symbolic-ref --short HEAD)" "coder/t1"
expect_eq "runtime 심링크" "$(readlink "$WT/runtime")" "$MAIN/runtime"
expect_eq "node_modules 심링크" "$(readlink "$WT/infra/node_modules")" "$MAIN/infra/node_modules"
expect_eq "worktree status 깨끗(심링크 exclude)" "$(git -C "$WT" status --porcelain | wc -l | tr -d ' ')" "0"
grep -qx '/runtime' "$MAIN/.git/info/exclude" && grep -qx '/infra/node_modules' "$MAIN/.git/info/exclude" && ok || fail "info/exclude 등록"
main_unchanged "생성 후"

echo "── 재사용(멱등) · exclude 중복 등록 없음"
expect_eq "ensure 재호출" "$(coder_worktree_ensure t1)" "$WT"
expect_eq "exclude 줄 수" "$(grep -c '^/runtime$' "$MAIN/.git/info/exclude")" "1"

echo "── 브랜치에 커밋 → 제거 → 브랜치에서 재생성"
echo "wt-commit" > "$WT/tracked.txt"; git -C "$WT" commit -qam "jarvis-coder: t1 iteration #1"
C1=$(git -C "$WT" rev-parse HEAD)
coder_worktree_remove t1
[[ ! -e "$WT" ]] && ok || fail "worktree 디렉터리 남음"
git -C "$MAIN" show-ref --verify --quiet refs/heads/coder/t1 && ok || fail "브랜치가 남아야 한다"
[[ -d "$MAIN/runtime/config" ]] && ok || fail "심링크 제거가 본체 runtime 을 따라가면 안 된다"
[[ -f "$MAIN/infra/node_modules/pkg.txt" ]] && ok || fail "본체 node_modules 보존"
expect_eq "git worktree list 에서 제거" "$(git -C "$MAIN" worktree list | grep -c 'wt/t1' || true)" "0"
WT=$(coder_worktree_ensure t1)
expect_eq "재생성 HEAD = 브랜치 커밋" "$(git -C "$WT" rev-parse HEAD)" "$C1"
expect_eq "재생성 내용" "$(cat "$WT/tracked.txt")" "wt-commit"

echo "── 패치 내보내기 (본체 기준선 대비)"
PF=$(coder_worktree_export_patch t1 "$WT")
expect_eq "patch 경로" "$PF" "$BOT_HOME/results/t1/patch.diff"
grep -q '^+wt-commit' "$PF" && ok || fail "patch 내용"

echo "── 잔재 복구: 디렉터리만 지워진 경우"
rm -rf "$WT"
WT=$(coder_worktree_ensure t1); expect_eq "잔재 복구 rc" "$?" "0"
[[ -f "$WT/tracked.txt" ]] && ok || fail "잔재 복구 후 파일"
coder_worktree_remove t1
main_unchanged "worktree 라이브러리 후"

echo "── 이름 정규화 · 경로 치환 · cd 실행"
expect_eq "name 공백/슬래시" "$(coder_worktree_name 'dev-abc 123/x')" "dev-abc-123-x"
expect_eq "name 선행 점" "$(coder_worktree_name '.hidden')" "hidden"
FW="$HOME/jarvis-worktrees/coder/x"
expect_eq "infra 경로" "$(coder_rewrite_cmd 'bash ~/projects/jarvis/infra/scripts/a.sh' "$FW")" "bash $FW/infra/scripts/a.sh"
expect_eq "runtime 코드 심링크" "$(coder_rewrite_cmd 'node $BOT_HOME/lib/x.mjs' "$FW")" "node $FW/infra/lib/x.mjs"
expect_eq "runtime 데이터 유지" "$(coder_rewrite_cmd 'cat ~/.openclaw-data/runtime/config/t.json' "$FW")" "cat $HOME/.openclaw-data/runtime/config/t.json"
expect_eq "cd 본체" "$(coder_rewrite_cmd 'cd ~/projects/jarvis && npm test' "$FW")" "cd $FW && npm test"
expect_eq "다른 저장소 무시" "$(coder_rewrite_cmd 'ls ~/jarvis-board/a' "$FW")" "ls ~/jarvis-board/a"
expect_eq "상대경로 그대로" "$(coder_rewrite_cmd 'bash infra/x.sh' "$FW")" "bash infra/x.sh"
WT=$(coder_worktree_ensure t-run)
expect_eq "coder_run_cmd cwd" "$(coder_run_cmd "$WT" 'pwd')" "$WT"
coder_run_cmd "$WT" 'test -f tracked.txt' && ok || fail "coder_run_cmd 상대경로"
coder_run_cmd "$WT" 'exit 7'; expect_eq "coder_run_cmd exit 전달" "$?" "7"
coder_worktree_remove t-run

echo "── verify-sprint-contract.sh: JARVIS_CODER_REPO 가 있으면 작업 사본에서 검사"
WT=$(coder_worktree_ensure t-sc); echo "x" > "$WT/infra/new.sh"
cat > "$BOT_HOME/state/sprint-contracts/t-sc.json" <<EOF
{"taskId":"t-sc","status":"active","contract":{"objective":"x","maxIterations":3,"successCriteria":[
  {"id":1,"description":"new.sh in repo","verifyCmd":"test -f infra/new.sh","verified":false}]},"iterations":[]}
EOF
OUT=$(cd "$MAIN" && JARVIS_CODER_REPO="$WT" bash "$INFRA/scripts/verify-sprint-contract.sh" t-sc 2>/dev/null)
expect_eq "worktree 에서 passed" "$(jq -r '.[0].passed' <<<"$OUT")" "true"
OUT=$(cd "$MAIN" && bash "$INFRA/scripts/verify-sprint-contract.sh" t-sc 2>/dev/null)
expect_eq "본체에서는 failed" "$(jq -r '.[0].passed' <<<"$OUT")" "false"
coder_worktree_remove t-sc; rm -f "$BOT_HOME/state/sprint-contracts/t-sc.json"

echo "── coder-functions: run_one_task 전 과정 (worktree 모드)"
source "$INFRA/lib/coder-functions.sh"
QUEUE_LOG="$T/queue.log"; DISCORD_LOG="$T/discord.log"
update_queue() { local x="${3:-}"; [[ -z "$x" ]] && x='{}'; echo "$1|$2|$(jq -c . <<<"$x")" >> "$QUEUE_LOG"; }
_discord_alert() { echo "ALERT: $1" >> "$DISCORD_LOG"; }
_discord_ceo_notify() { echo "CEO: $1" >> "$DISCORD_LOG"; }
verify_gate_escalate() { return 0; }
get_field() { case "$2" in name) echo "task $1";; prompt) echo "make infra/new.sh";; completionCheck) echo "test -f infra/new.sh";; *) echo "";; esac; }
last_q() { tail -1 "$QUEUE_LOG"; }
reset_logs() { : > "$QUEUE_LOG"; : > "$DISCORD_LOG"; : > "$BOT_HOME/rw-env.txt"; }

echo "   ▸ 성공 → 브랜치 + patch, 본체 불변"
reset_logs; export MOCK_MODE=pass
( cd "$MAIN" && run_one_task t-ok )
expect_eq "status done" "$(last_q | cut -d'|' -f2)" "done"
expect_eq "branch 필드" "$(last_q | cut -d'|' -f3- | jq -r .branch)" "coder/t-ok"
expect_eq "merge_pending" "$(last_q | cut -d'|' -f3- | jq -r .merge_pending)" "true"
PF=$(last_q | cut -d'|' -f3- | jq -r .patch_file)
[[ -s "$PF" ]] && grep -q 'new.sh' "$PF" && ok || fail "patch_file 내용: $PF"
expect_eq "changed_files" "$(last_q | cut -d'|' -f3- | jq -c '.changed_files|sort')" '["infra/new.sh","tracked.txt"]'
git -C "$MAIN" log --oneline coder/t-ok | grep 'jarvis-coder: t-ok 완료' >/dev/null && ok || fail "브랜치에 완료 커밋 없음: $(git -C "$MAIN" log --oneline coder/t-ok | tr '\n' ' ')"
expect_eq "브랜치 파일" "$(git -C "$MAIN" show coder/t-ok:infra/new.sh)" "echo new"
grep -q "SCOPE=$T/wt/t-ok REPO=$T/wt/t-ok TASK=t-ok" "$BOT_HOME/rw-env.txt" && ok || fail "코더 세션 환경(scope/repo) 미전달: $(cat "$BOT_HOME/rw-env.txt")"
grep -q 'CEO:.*브랜치 `coder/t-ok`' "$DISCORD_LOG" && ok || fail "CEO 알림에 브랜치 없음"
[[ ! -e "$T/wt/t-ok" ]] && ok || fail "실행 후 worktree 정리"
expect_eq "CODER_REPO 복귀" "$CODER_REPO" "$BOT_HOME"
[[ -z "${JARVIS_CODER_REPO:-}${JARVIS_AGENT_WRITE_SCOPE:-}" ]] && ok || fail "env 복귀: repo=${JARVIS_CODER_REPO:-} scope=${JARVIS_AGENT_WRITE_SCOPE:-}"
main_unchanged "done 후"
grep -q 'cwd=\|verdict":"PASS' "$BOT_HOME/ledger/verify-gate.jsonl" && ok || fail "verify-gate 원장에 PASS 없음"

echo "   ▸ 실행 실패 → worktree 롤백, 재큐, 본체 불변"
reset_logs
( cd "$MAIN" && run_one_task t-exec1 )
expect_eq "queued" "$(last_q | cut -d'|' -f2)" "queued"
expect_eq "lastError" "$(last_q | cut -d'|' -f3- | jq -r .lastError)" "exit_code=1"
expect_eq "브랜치 = 본체 HEAD (변경 없음)" "$(git -C "$MAIN" rev-parse coder/t-exec1)" "$MAIN_HEAD"
main_unchanged "실행 실패 후"

echo "   ▸ 검증 FAIL → worktree 하드 롤백 (잔존 알림 없음), 재큐"
reset_logs; export MOCK_MODE=fail
( cd "$MAIN" && run_one_task t-vfail )
expect_eq "queued" "$(last_q | cut -d'|' -f2)" "queued"
expect_eq "verify_gate_failed" "$(last_q | cut -d'|' -f3- | jq -r .lastError)" "verify_gate_failed"
expect_eq "브랜치 = 본체 HEAD" "$(git -C "$MAIN" rev-parse coder/t-vfail)" "$MAIN_HEAD"
! grep -q '변경이 남아 있습니다' "$DISCORD_LOG" && ok || fail "worktree 모드에선 잔존 알림이 없어야 한다"
main_unchanged "검증 FAIL 후"

echo "   ▸ 검증 불가(UNAVAILABLE) → WIP 커밋 + 패치 + 보류"
reset_logs; export MOCK_MODE=error
( cd "$MAIN" && run_one_task t-vunav )
expect_eq "failed" "$(last_q | cut -d'|' -f2)" "failed"
expect_eq "verify_gate_unavailable" "$(last_q | cut -d'|' -f3- | jq -r .lastError)" "verify_gate_unavailable"
PF=$(last_q | cut -d'|' -f3- | jq -r .patch_file); [[ -s "$PF" ]] && ok || fail "보류 패치 없음"
git -C "$MAIN" log --oneline coder/t-vunav | grep 'WIP (사람 검토 보류)' >/dev/null && ok || fail "브랜치에 WIP 커밋 없음: $(git -C "$MAIN" log --oneline coder/t-vunav | tr '\n' ' ')"
expect_eq "WIP 내용" "$(git -C "$MAIN" show coder/t-vunav:tracked.txt)" "edited"
main_unchanged "검증 불가 후"
export MOCK_MODE=pass

echo "   ▸ worktree 못 만듦 → 실행 없이 보류 (fail closed)"
reset_logs; touch "$T/notadir"
( cd "$MAIN" && JARVIS_CODER_WT_ROOT="$T/notadir" run_one_task t-nowt )
expect_eq "failed" "$(last_q | cut -d'|' -f2)" "failed"
expect_eq "worktree_unavailable" "$(last_q | cut -d'|' -f3- | jq -r .lastError)" "worktree_unavailable"
[[ ! -s "$BOT_HOME/rw-env.txt" ]] && ok || fail "worktree 없이 코더 세션이 돌면 안 된다"
main_unchanged "worktree 실패 후"

echo "   ▸ 사전 completionCheck 통과 → worktree 생성 안 함"
reset_logs; echo "x" > "$MAIN/infra/new.sh"
( cd "$MAIN" && run_one_task t-pre )
expect_eq "done(LLM 생략)" "$(last_q | cut -d'|' -f2)" "done"
! git -C "$MAIN" show-ref --verify --quiet refs/heads/coder/t-pre && ok || fail "사전 통과인데 브랜치가 생겼다"
rm -f "$MAIN/infra/new.sh"

echo "   ▸ 본체에 snapshot:/jarvis-coder: 커밋 0건"
expect_eq "본체 코더 커밋" "$(git -C "$MAIN" log --oneline main | grep -cE 'snapshot:|jarvis-coder:' || true)" "0"

echo "   ▸ JARVIS_CODER_WORKTREE=0 → 옛 방식 (CODER_REPO=BOT_HOME, worktree 없음)"
( JARVIS_CODER_WORKTREE=0 _coder_wt_activate t-legacy; expect_eq "legacy rc" "$?" "0"; expect_eq "legacy repo" "$CODER_REPO" "$BOT_HOME"; [[ -z "$CODER_WT" ]] && ok || fail "legacy 에서 CODER_WT 설정됨"; echo "PASSED=$PASSED FAILURES=$FAILURES" > "$T/sub.txt" )
eval "$(cat "$T/sub.txt")"

echo "── 쓰기 경계 훅 (scope 모드) — worktree 안 허용 / 본체·보호경로·본체 git 차단"
HOOK="$HOME/.claude/hooks/jarvis-agent-write-boundary.py"
WT=$(coder_worktree_ensure t-hook)
hk() { # <tool> <json tool_input> → kind 또는 빈 문자열
    printf '{"tool_name":"%s","tool_input":%s,"cwd":"%s"}' "$1" "$2" "$WT" \
      | JARVIS_AGENT_ROLE=coder JARVIS_AGENT_WRITE_SCOPE="$WT" BOT_HOME="$BOT_HOME" python3 "$HOOK" | jq -r '.kind // empty'
}
expect_eq "Write worktree 안" "$(hk Write "{\"file_path\":\"$WT/infra/a.sh\"}")" ""
expect_eq "Write 상대경로(cwd=wt)" "$(hk Write '{"file_path":"infra/b.sh"}')" ""
expect_eq "Write 본체" "$(hk Write "{\"file_path\":\"$MAIN/infra/a.sh\"}")" "agent-write-outside-scope"
expect_eq "Write wt/runtime/config (심링크 너머 보호)" "$(hk Write "{\"file_path\":\"$WT/runtime/config/x.json\"}")" "agent-write-protected"
expect_eq "Bash git commit (cwd=wt)" "$(hk Bash '{"command":"git add -A && git commit -m x"}')" ""
expect_eq "Bash git -C 본체 commit" "$(hk Bash "{\"command\":\"git -C $MAIN commit -am x\"}")" "agent-git-base"
expect_eq "Bash cd 본체 후 git reset" "$(hk Bash "{\"command\":\"cd $MAIN && git reset --hard\"}")" "agent-git-base"
expect_eq "Bash cp → 본체" "$(hk Bash "{\"command\":\"cp a.sh $MAIN/infra/a.sh\"}")" "agent-write-outside-scope"
expect_eq "Bash 리다이렉션 wt 안" "$(hk Bash '{"command":"echo x > infra/c.txt"}')" ""
expect_eq "Bash git push (worktree 안에서도 차단)" "$(hk Bash '{"command":"git push origin HEAD"}')" "agent-git-push"
coder_worktree_remove t-hook

echo "PASSED=$PASSED FAILURES=$FAILURES"
[[ $FAILURES -eq 0 ]]
