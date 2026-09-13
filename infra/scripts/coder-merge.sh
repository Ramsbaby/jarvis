#!/usr/bin/env bash
# coder-merge.sh — 코더 브랜치(coder/<task>)를 본체에 반영하는 유일한 통로 (SELF-HEAL-PLAN 3b, 2026-09-04)
#
# 사용:
#   bash ~/projects/jarvis/infra/scripts/coder-merge.sh <task>                 게이트 통과 시 fast-forward 머지 (사람 호출)
#   bash ~/projects/jarvis/infra/scripts/coder-merge.sh <task> --dry-run       게이트만 돌리고 아무것도 바꾸지 않음
#   bash ~/projects/jarvis/infra/scripts/coder-merge.sh <task> --auto          3a 리뷰가 부른다 — 자율성 정책(3c)이 허용할 때만 머지
#   bash ~/projects/jarvis/infra/scripts/coder-merge.sh <task> --reject "사유"  브랜치·worktree 폐기 + 원장 기록 (사람 판단)
#   bash ~/projects/jarvis/infra/scripts/coder-merge.sh <task> --expire "사유"  같은 폐기지만 action=expired (3d 자동 만료 — 승인 스트릭을 깎지 않음)
#   옵션: --keep-branch  머지 후 브랜치 보존   --no-rebase  base 위로 rebase 생략   --skip-gate-check  verify-gate PASS 요구 생략
#
# 게이트(전부 통과해야 머지): 변경 파일 문법(bash -n/node --check/jq/py_compile) → shellcheck -S error(있을 때)
#   → 관련 test-*.sh → validate-tasks.mjs(ERROR 만 차단) → verify-gate 원장 마지막 verdict PASS → base 위 rebase → --ff-only.
# 결과: 원장 ${BOT_HOME}/ledger/coder-merge.jsonl 한 줄, tasks.db meta {merge_pending:false, merged_at, merged_commit},
#   worktree 제거·브랜치 삭제(--keep-branch 아니면), jarvis-system 채널 한 줄(JARVIS_NO_EXTERNAL=1 이면 파일만).
#
# 종료코드: 0 머지(또는 dry-run 게이트 통과)  1 사용법·전제조건  2 게이트 실패  3 자율성 정책 차단  4 rebase 충돌·비FF
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"

BOT_HOME="${BOT_HOME:-${HOME}/.openclaw-data/runtime}"
INFRA_HOME="${JARVIS_INFRA_HOME:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
export BOT_HOME
export JARVIS_NO_EXTERNAL="${JARVIS_NO_EXTERNAL:-0}"

# shellcheck source=../lib/coder-worktree.sh
source "${INFRA_HOME}/lib/coder-worktree.sh"
# shellcheck source=../lib/coder-autonomy.sh
source "${INFRA_HOME}/lib/coder-autonomy.sh"

LOG_FILE="${BOT_HOME}/logs/coder-merge.log"
LEDGER=$(coder_autonomy_ledger)
NODE_SQLITE="node --experimental-sqlite --no-warnings"
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)

log() { local line; line="[$(date '+%F %T')] $*"; echo "$line"; mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null && echo "$line" >> "$LOG_FILE" 2>/dev/null || true; }
die() { log "❌ $*"; exit "${2:-1}"; }

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }

# ── 인자 ────────────────────────────────────────────────────────────────────
TASK=""; MODE="human"; DRY_RUN=0; KEEP_BRANCH=0; NO_REBASE=0; SKIP_GATE_CHECK=0; REJECT_REASON=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --auto) MODE="auto" ;;
        --reject) MODE="reject"; REJECT_REASON="${2:-}"; [[ -n "$REJECT_REASON" ]] || die "--reject 에는 사유가 필요합니다"; shift ;;
        --expire) MODE="expire"; REJECT_REASON="${2:-}"; [[ -n "$REJECT_REASON" ]] || die "--expire 에는 사유가 필요합니다"; shift ;;
        --keep-branch) KEEP_BRANCH=1 ;;
        --no-rebase) NO_REBASE=1 ;;
        --skip-gate-check) SKIP_GATE_CHECK=1 ;;
        -h|--help) usage ;;
        -*) die "알 수 없는 옵션: $1" ;;
        *) [[ -z "$TASK" ]] || die "태스크는 하나만"; TASK="$1" ;;
    esac
    shift
done
[[ -n "$TASK" ]] || usage

MAIN=$(coder_worktree_main_repo) || die "BOT_HOME(${BOT_HOME}) 이 git 저장소 안이 아닙니다"
BRANCH=$(coder_worktree_branch "$TASK")
BASE=$(coder_worktree_base_branch)
TS=$(date -u +%FT%TZ)

git -C "$MAIN" show-ref --verify --quiet "refs/heads/$BRANCH" || die "브랜치 없음: ${BRANCH} (git -C ${MAIN} branch --list 'coder/*' 로 확인)"

# 큐 행 (없어도 진행 — 브랜치가 사실이고 DB 는 표식일 뿐)
ROW_JSON=$($NODE_SQLITE "${BOT_HOME}/lib/task-store.mjs" get "$TASK" 2>/dev/null || echo "")
ROW_STATUS=$(jq -r '.status // "none"' <<<"${ROW_JSON:-null}" 2>/dev/null || echo none)
MERGE_PENDING=$(jq -r '.meta.merge_pending // "none"' <<<"${ROW_JSON:-null}" 2>/dev/null || echo none)

# ── 원장 ────────────────────────────────────────────────────────────────────
GATES_JSON='{}'
gate_set() { GATES_JSON=$(jq -c --arg k "$1" --arg v "$2" '.[$k]=$v' <<<"$GATES_JSON"); }
ledger_write() {
    # $1 action  $2 approved_by  $3 reason  $4 merged_commit
    local action="$1" by="$2" reason="$3" commit="${4:-}"
    mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true
    jq -nc --arg ts "$TS" --arg task "$TASK" --arg branch "$BRANCH" --arg base "$BASE" \
        --arg action "$action" --arg cls "${CLASS:-}" --arg by "$by" --arg reason "$reason" \
        --arg commit "$commit" --arg base_commit "${BASE_COMMIT:-}" --arg status "$ROW_STATUS" \
        --argjson files "${FILES_JSON:-[]}" --argjson gates "$GATES_JSON" \
        '{ts:$ts, task:$task, branch:$branch, base:$base, action:$action, class:$cls, approved_by:$by,
          files:$files, gates:$gates, base_commit:$base_commit, merged_commit:$commit, queue_status:$status, reason:$reason}' \
        >> "$LEDGER"
}
notify() {
    local msg="$1"
    if [[ -f "${INFRA_HOME}/lib/discord-route.sh" ]]; then
        # shellcheck source=../lib/discord-route.sh
        source "${INFRA_HOME}/lib/discord-route.sh" 2>/dev/null || return 0
        discord_route_raw jarvis-system "$msg" >/dev/null 2>&1 || true
    fi
}
meta_patch() {
    [[ "$ROW_STATUS" != "none" ]] || return 0
    $NODE_SQLITE "${BOT_HOME}/lib/task-store.mjs" meta-patch "$TASK" "$1" >/dev/null 2>&1 \
        || log "⚠️ tasks.db meta 갱신 실패 (task=${TASK}) — 원장은 기록됨"
}

# ── 변경 파일 + 분류 (3c) ─────────────────────────────────────────────────────
BASE_COMMIT=$(git -C "$MAIN" merge-base "$BASE" "$BRANCH" 2>/dev/null || true)
[[ -n "$BASE_COMMIT" ]] || die "merge-base 계산 실패 (${BASE}…${BRANCH})"
CHANGED=$(git -C "$MAIN" diff --name-only "$BASE_COMMIT" "$BRANCH" 2>/dev/null || true)
FILES_JSON=$(printf '%s\n' "$CHANGED" | { grep -v '^$' || true; } | jq -Rsc 'split("\n") | map(select(length>0))')
CLASS=$(printf '%s\n' "$CHANGED" | coder_autonomy_classify_files)
N_FILES=$(jq 'length' <<<"$FILES_JSON")

DRY_TAG=""; (( DRY_RUN )) && DRY_TAG=" (dry-run)"
log "━━ coder-merge ${TASK} ━━ 브랜치 ${BRANCH} → ${BASE} | 모드 ${MODE}${DRY_TAG} | 큐 ${ROW_STATUS}/merge_pending=${MERGE_PENDING} | 변경 ${N_FILES}개 · class=${CLASS}"

# ── 거절·만료 모드 ─────────────────────────────────────────────────────────────
if [[ "$MODE" == "reject" || "$MODE" == "expire" ]]; then
    action="rejected"; by="human"; label="거절"; icon="🗑️"
    if [[ "$MODE" == "expire" ]]; then action="expired"; by="auto"; label="만료 폐기"; icon="⏳"; fi
    if (( DRY_RUN )); then log "dry-run: ${label} 시 브랜치 ${BRANCH} 와 worktree 를 폐기하고 원장에 ${action} 를 남깁니다"; exit 0; fi
    coder_worktree_remove "$TASK"
    git -C "$MAIN" branch -D "$BRANCH" >/dev/null 2>&1 || log "⚠️ 브랜치 삭제 실패: ${BRANCH}"
    ledger_write "$action" "$by" "$REJECT_REASON"
    meta_patch "$(jq -nc --arg ts "$TS" --arg r "$REJECT_REASON" --arg a "$action" '{merge_pending:false, discarded_at:$ts, discard_action:$a, discard_reason:$r}')"
    notify "${icon} **coder-merge** \`${TASK}\` ${label} — ${REJECT_REASON:0:200} (브랜치 ${BRANCH} 폐기)"
    log "✅ ${label} 처리 완료: ${BRANCH} 폐기, 원장 기록(${action})"
    exit 0
fi

(( N_FILES > 0 )) || die "브랜치에 변경이 없습니다 (${BASE_COMMIT:0:8}…${BRANCH}) — 머지할 것이 없음. --reject 로 폐기하십시오" 2

# ── 자율성 정책 (--auto 만) ────────────────────────────────────────────────────
if [[ "$MODE" == "auto" ]]; then
    if policy_msg=$(coder_autonomy_allows_auto "$CLASS"); then
        log "정책: ${policy_msg}"
    else
        log "정책 차단: ${policy_msg}"
        gate_set policy "blocked"
        (( DRY_RUN )) || ledger_write blocked auto "$policy_msg"
        (( DRY_RUN )) || notify "🟡 **coder-merge** \`${TASK}\` 자동 머지 보류 — ${policy_msg}. 사람 호출: \`bash ~/projects/jarvis/infra/scripts/coder-merge.sh ${TASK}\`"
        exit 3
    fi
fi

# ── worktree 확보 + rebase ─────────────────────────────────────────────────────
WT_EXISTED=0; [[ -f "$(coder_worktree_path "$TASK")/.git" ]] && WT_EXISTED=1
WT=$(coder_worktree_ensure "$TASK") || die "worktree 생성 실패 (${TASK})"
git -C "$WT" checkout -q "$BRANCH" 2>/dev/null || die "worktree 가 ${BRANCH} 를 체크아웃하지 못함"

if (( ! NO_REBASE )); then
    if git -C "$WT" merge-base --is-ancestor "$BASE" "$BRANCH"; then
        gate_set rebase "already-on-base"
    elif (( DRY_RUN )); then
        # dry-run 은 브랜치를 다시 쓰지 않는다 — 필요 여부만 알린다
        gate_set rebase "needed(dry-run)"; log "base(${BASE}) 가 앞서 있음 — 실제 실행 시 rebase 함 (dry-run 은 브랜치 무변경)"
    else
        log "base(${BASE}) 가 앞서 있음 — worktree 에서 rebase"
        if ! rebase_out=$(git -C "$WT" rebase "$BASE" 2>&1); then
            git -C "$WT" rebase --abort >/dev/null 2>&1 || true
            gate_set rebase "conflict"
            (( DRY_RUN )) || ledger_write blocked "$MODE" "rebase 충돌: ${rebase_out:0:300}"
            (( DRY_RUN )) || meta_patch "$(jq -nc --arg ts "$TS" '{merge_needs_human:true, merge_block_reason:"rebase conflict", merge_blocked_at:$ts}')"
            (( DRY_RUN )) || notify "🔴 **coder-merge** \`${TASK}\` rebase 충돌 — 사람이 봐야 합니다 (worktree ${WT})"
            die "rebase 충돌 — needs_human. worktree: ${WT}" 4
        fi
        gate_set rebase "rebased"
        BASE_COMMIT=$(git -C "$MAIN" merge-base "$BASE" "$BRANCH")
        CHANGED=$(git -C "$MAIN" diff --name-only "$BASE_COMMIT" "$BRANCH" 2>/dev/null || true)
        FILES_JSON=$(printf '%s\n' "$CHANGED" | { grep -v '^$' || true; } | jq -Rsc 'split("\n") | map(select(length>0))')
    fi
fi

# ── 게이트 1: 문법 ─────────────────────────────────────────────────────────────
syntax_fail=0
while IFS= read -r f; do
    [[ -n "$f" && -f "$WT/$f" ]] || continue
    case "$f" in
        *.sh|*.bash)
            bash -n "$WT/$f" 2>/tmp/coder-merge-syntax.$$ || { syntax_fail=1; log "  문법 실패 ${f}: $(head -2 /tmp/coder-merge-syntax.$$ | tr '\n' ' ')"; }
            if command -v shellcheck >/dev/null 2>&1; then
                shellcheck -S error "$WT/$f" >/tmp/coder-merge-syntax.$$ 2>&1 || { syntax_fail=1; log "  shellcheck(error) ${f}: $(grep -m1 'SC[0-9]' /tmp/coder-merge-syntax.$$ || head -1 /tmp/coder-merge-syntax.$$)"; }
            fi ;;
        *.mjs|*.js|*.cjs) node --check "$WT/$f" 2>/tmp/coder-merge-syntax.$$ || { syntax_fail=1; log "  문법 실패 ${f}: $(head -2 /tmp/coder-merge-syntax.$$ | tr '\n' ' ')"; } ;;
        *.json) jq empty "$WT/$f" 2>/tmp/coder-merge-syntax.$$ || { syntax_fail=1; log "  JSON 실패 ${f}: $(head -1 /tmp/coder-merge-syntax.$$)"; } ;;
        *.py) if command -v python3 >/dev/null 2>&1; then python3 -m py_compile "$WT/$f" 2>/tmp/coder-merge-syntax.$$ || { syntax_fail=1; log "  py_compile 실패 ${f}"; }; fi ;;
    esac
done <<<"$CHANGED"
rm -f /tmp/coder-merge-syntax.$$
if (( syntax_fail )); then gate_set syntax fail; else gate_set syntax ok; log "게이트 문법: OK (${N_FILES}개)"; fi

# ── 게이트 2: 관련 테스트 ───────────────────────────────────────────────────────
declare -a TESTS=()
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    base=$(basename "$f")
    case "$base" in test-*.sh) [[ -f "$WT/$f" ]] && TESTS+=("$f") ;; esac
    while IFS= read -r t; do [[ -n "$t" ]] && TESTS+=("${t#"$WT"/}"); done < <(grep -lF -- "$base" "$WT"/infra/scripts/test-*.sh 2>/dev/null || true)
done <<<"$CHANGED"
# 중복 제거 (mapfile 은 bash 3.2 에 없다)
if (( ${#TESTS[@]} > 0 )); then
    _uniq=(); while IFS= read -r _t; do [[ -n "$_t" ]] && _uniq+=("$_t"); done < <(printf '%s\n' "${TESTS[@]}" | awk '!seen[$0]++')
    TESTS=("${_uniq[@]}")
fi
t_pass=0; t_fail=0; t_names=""
for t in "${TESTS[@]:-}"; do
    [[ -n "$t" ]] || continue
    if [[ -n "$TIMEOUT_BIN" ]]; then
        t_out=$(cd "$WT" && JARVIS_NO_EXTERNAL=1 "$TIMEOUT_BIN" 180 bash "$WT/$t" 2>&1) && t_rc=0 || t_rc=$?
    else
        t_out=$(cd "$WT" && JARVIS_NO_EXTERNAL=1 bash "$WT/$t" 2>&1) && t_rc=0 || t_rc=$?
    fi
    t_line=$(printf '%s\n' "$t_out" | grep -Eo 'PASSED=[0-9]+ FAILURES=[0-9]+' | tail -1 || true)
    if [[ $t_rc -eq 0 && ( -z "$t_line" || "$t_line" == *"FAILURES=0" ) ]]; then
        t_pass=$((t_pass+1)); log "  테스트 PASS $(basename "$t")${t_line:+ ($t_line)}"
    else
        t_fail=$((t_fail+1)); log "  테스트 FAIL $(basename "$t") (${t_line:-exit $t_rc}): $(printf '%s\n' "$t_out" | grep -m2 -E 'FAIL|Error|❌' | tr '\n' ' ' | cut -c1-200)"
    fi
    t_names="${t_names}${t_names:+,}$(basename "$t")"
done
gate_set tests "${t_pass}/${t_fail}${t_names:+ [$t_names]}"
if (( ${#TESTS[@]} == 0 )); then log "게이트 테스트: 관련 test-*.sh 없음 (통과로 간주 — 원장에 0/0 기록)"; else log "게이트 테스트: ${t_pass} 통과 / ${t_fail} 실패"; fi

# ── 게이트 3: validate-tasks ───────────────────────────────────────────────────
if [[ -f "$WT/infra/scripts/validate-tasks.mjs" ]]; then
    v_out=$(node "$WT/infra/scripts/validate-tasks.mjs" 2>&1) && v_rc=0 || v_rc=$?
    v_err=$(printf '%s\n' "$v_out" | grep -c 'ERROR' || true)
    if (( v_rc != 0 || v_err > 0 )); then gate_set validate_tasks "fail(rc=${v_rc},errors=${v_err})"; log "게이트 validate-tasks: 실패 — $(printf '%s\n' "$v_out" | grep -m1 ERROR || printf '%s' "$v_out" | tail -1)"; else gate_set validate_tasks ok; log "게이트 validate-tasks: OK"; fi
else
    gate_set validate_tasks "skipped(no script)"
fi

# ── 게이트 4: verify-gate 원장 마지막 verdict ────────────────────────────────────
VG_LEDGER="${BOT_HOME}/ledger/verify-gate.jsonl"
if (( SKIP_GATE_CHECK )); then
    gate_set verify_gate "skipped(--skip-gate-check)"; log "게이트 verify-gate: 생략 (--skip-gate-check)"
elif [[ -f "$VG_LEDGER" ]]; then
    vg=$(grep -F "\"task\":\"${TASK}\"" "$VG_LEDGER" 2>/dev/null | tail -1 | jq -r '.verdict // "NONE"' 2>/dev/null || echo NONE)
    gate_set verify_gate "$vg"
    if [[ "$vg" == "PASS" ]]; then log "게이트 verify-gate: PASS"; else log "게이트 verify-gate: ${vg} (PASS 아님 — 코더 검증이 통과하지 않은 브랜치)"; fi
else
    gate_set verify_gate "NONE"; log "게이트 verify-gate: 원장 없음"
fi

# ── 판정 ──────────────────────────────────────────────────────────────────────
GATE_FAIL=0
[[ "$(jq -r .syntax <<<"$GATES_JSON")" == "ok" ]] || GATE_FAIL=1
(( t_fail == 0 )) || GATE_FAIL=1
[[ "$(jq -r .validate_tasks <<<"$GATES_JSON")" == ok* || "$(jq -r .validate_tasks <<<"$GATES_JSON")" == skipped* ]] || GATE_FAIL=1
vg_v=$(jq -r .verify_gate <<<"$GATES_JSON"); [[ "$vg_v" == "PASS" || "$vg_v" == skipped* ]] || GATE_FAIL=1

if (( GATE_FAIL )); then
    log "❌ 게이트 실패 — 머지하지 않음: $(jq -c . <<<"$GATES_JSON")"
    if (( DRY_RUN )); then
        ledger_write dry_run "$MODE" "게이트 실패: $(jq -c . <<<"$GATES_JSON")"
        (( WT_EXISTED )) || coder_worktree_remove "$TASK"
    else
        ledger_write blocked "$MODE" "게이트 실패: $(jq -c . <<<"$GATES_JSON")"
        meta_patch "$(jq -nc --arg ts "$TS" --arg g "$GATES_JSON" '{merge_needs_human:true, merge_block_reason:("gate: "+$g), merge_blocked_at:$ts}')"
        notify "🔴 **coder-merge** \`${TASK}\` 게이트 실패 — $(jq -c . <<<"$GATES_JSON" | cut -c1-300). worktree: ${WT}"
    fi
    exit 2
fi

if (( DRY_RUN )); then
    log "✅ dry-run: 게이트 전부 통과 — 실제 머지는 \`bash ~/projects/jarvis/infra/scripts/coder-merge.sh ${TASK}\` (class=${CLASS}, $(coder_autonomy_allows_auto "$CLASS" || true))"
    ledger_write dry_run "$MODE" "게이트 통과"
    (( WT_EXISTED )) || coder_worktree_remove "$TASK"
    exit 0
fi

# ── fast-forward ──────────────────────────────────────────────────────────────
if ! git -C "$MAIN" merge-base --is-ancestor "$(git -C "$MAIN" rev-parse "$BASE")" "$BRANCH"; then
    ledger_write blocked "$MODE" "비FF: rebase 뒤에도 base 가 브랜치의 조상이 아님"
    die "fast-forward 불가 (--no-rebase 였다면 빼고 다시)" 4
fi
main_branch=$(git -C "$MAIN" symbolic-ref --short HEAD 2>/dev/null || echo "")
[[ "$main_branch" == "$BASE" ]] || die "본체 HEAD 가 ${BASE} 가 아닙니다 (현재 ${main_branch:-detached}) — 체크아웃 뒤 다시"
if ! ff_out=$(git -C "$MAIN" merge --ff-only "$BRANCH" 2>&1); then
    ledger_write blocked "$MODE" "ff 실패: ${ff_out:0:300}"
    die "git merge --ff-only 실패: ${ff_out:0:300}" 4
fi
MERGED=$(git -C "$MAIN" rev-parse --short HEAD)
log "✅ 머지 완료: ${BASE} ← ${BRANCH} @ ${MERGED}"

ledger_write merged "$MODE" "게이트 통과" "$MERGED"
meta_patch "$(jq -nc --arg ts "$TS" --arg c "$MERGED" --arg by "$MODE" '{merge_pending:false, merged_at:$ts, merged_commit:$c, merged_by:$by, merge_needs_human:false}')"

coder_worktree_remove "$TASK"
if (( KEEP_BRANCH )); then
    log "브랜치 보존: ${BRANCH} (--keep-branch)"
else
    git -C "$MAIN" branch -d "$BRANCH" >/dev/null 2>&1 && log "브랜치 삭제: ${BRANCH}" || log "⚠️ 브랜치 삭제 실패(미머지 커밋?): ${BRANCH}"
fi

streak=$(coder_autonomy_streak "$CLASS"); thr=$(coder_autonomy_threshold "$CLASS")
notify "✅ **coder-merge** \`${TASK}\` 머지 @ ${MERGED} (${MODE}) — class=${CLASS} 연속 승인 ${streak}/${thr}, 파일 ${N_FILES}개, 테스트 ${t_pass}/${t_fail}"
log "자율성: class=${CLASS} 연속 승인 ${streak}/${thr}"
exit 0
