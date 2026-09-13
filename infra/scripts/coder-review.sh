#!/usr/bin/env bash
# coder-review.sh — 코더 브랜치 일일 리뷰 + 7일 만료 (SELF-HEAL-PLAN 3a·3d, 2026-09-05)
#
# 매일 07:30 (tasks.json `coder-review`). coder/* 브랜치마다:
#   1. 브랜치 tip 이 이미 리뷰됐으면 건너뜀 (원장 coder-review.jsonl 의 {task, tip})
#   2. 3d: tip 이 expiry_days(정책표, 기본 7일) 넘게 방치됐으면 `coder-merge.sh <task> --expire` 로 폐기하고 끝
#   3. 자료: 큐 행(제목·프롬프트·result_summary·verify_feedback) · verify-gate 마지막 verdict ·
#      `coder-merge.sh --dry-run` 게이트 결과 · class/스트릭 · diff(상한 내)
#   4. 상위 모델(Read 전용)에게 merge / reject / needs_human 판정을 받아 원장에 남긴다
#   5. merge 이고 정책(3c)이 허용하면 `coder-merge.sh <task> --auto`. 아니면 사람 호출 명령을 낸다
# 출력(stdout)이 bot-cron 을 거쳐 jarvis-system 채널로 간다 — 여기서 직접 송출하지 않는다.
#
# 사용: bash ~/projects/jarvis/infra/scripts/coder-review.sh [--force] [--task <id>] [--no-llm]
#   --force   tip 이 같아도 다시 리뷰   --task   한 브랜치만   --no-llm   자료 수집·만료만 (판정 생략)
# 환경: JARVIS_CODER_REVIEW_MODEL(기본 claude-opus-5) · JARVIS_CODER_REVIEW_TIMEOUT(300) · JARVIS_CODER_REVIEW_BUDGET(0.60)
#       JARVIS_CODER_REVIEW_MAX_DIFF_LINES(400)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"

BOT_HOME="${BOT_HOME:-${HOME}/.openclaw-data/runtime}"
INFRA_HOME="${JARVIS_INFRA_HOME:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
export BOT_HOME
# shellcheck source=../lib/coder-worktree.sh
source "${INFRA_HOME}/lib/coder-worktree.sh"
# shellcheck source=../lib/coder-autonomy.sh
source "${INFRA_HOME}/lib/coder-autonomy.sh"

MERGE_SH="${INFRA_HOME}/scripts/coder-merge.sh"
ASK_CLAUDE="${BOT_HOME}/bin/ask-claude.sh"
LEDGER="${BOT_HOME}/ledger/coder-review.jsonl"
MERGE_LEDGER=$(coder_autonomy_ledger)
LOG_FILE="${BOT_HOME}/logs/coder-review.log"
NODE_SQLITE="node --experimental-sqlite --no-warnings"
MODEL="${JARVIS_CODER_REVIEW_MODEL:-claude-opus-5}"
TIMEOUT="${JARVIS_CODER_REVIEW_TIMEOUT:-300}"
BUDGET="${JARVIS_CODER_REVIEW_BUDGET:-0.60}"
MAX_DIFF_LINES="${JARVIS_CODER_REVIEW_MAX_DIFF_LINES:-400}"
EXPIRY_DAYS=$(jq -r '.expiry_days // 7' "$(coder_autonomy_config)" 2>/dev/null || echo 7)

FORCE=0; ONLY_TASK=""; NO_LLM=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=1 ;;
        --task) ONLY_TASK="${2:-}"; shift ;;
        --no-llm) NO_LLM=1 ;;
        daily|"") ;;   # bot-cron.sh 는 scriptArgs 가 없으면 "daily" 를 넘긴다 — 무시
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac; shift
done

log() { local line; line="[$(date '+%F %T')] $*"; echo "$line" >&2; mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null && echo "$line" >> "$LOG_FILE" 2>/dev/null || true; }
MAIN=$(coder_worktree_main_repo) || { echo "BOT_HOME(${BOT_HOME}) 이 git 저장소 안이 아닙니다" >&2; exit 1; }
[[ -x "$MERGE_SH" ]] || { echo "coder-merge.sh 없음: ${MERGE_SH}" >&2; exit 1; }
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true

ledger_write() { # <task> <branch> <tip> <verdict> <reasons_json> <extra_json>
    jq -nc --arg ts "$(date -u +%FT%TZ)" --arg task "$1" --arg branch "$2" --arg tip "$3" --arg verdict "$4" \
        --argjson reasons "$5" --argjson extra "$6" --arg model "$MODEL" \
        '{ts:$ts, task:$task, branch:$branch, tip:$tip, verdict:$verdict, reasons:$reasons, model:$model} + $extra' >> "$LEDGER"
}
already_reviewed() { # <task> <tip>
    [[ -f "$LEDGER" ]] || return 1
    grep -F "\"task\":\"$1\"" "$LEDGER" 2>/dev/null | grep -qF "\"tip\":\"$2\""
}

# ── 브랜치 순회 ───────────────────────────────────────────────────────────────
BRANCHES=$(git -C "$MAIN" for-each-ref --format='%(refname:short)' 'refs/heads/coder/*' 2>/dev/null || true)
[[ -z "$ONLY_TASK" ]] || BRANCHES=$(printf '%s\n' "$BRANCHES" | grep -Fx "coder/${ONLY_TASK}" || true)
N_TOTAL=$(printf '%s\n' "$BRANCHES" | grep -c . || true)

SUMMARY=(); n_merged=0; n_needs=0; n_reject=0; n_expired=0; n_skipped=0; n_error=0
NOW=$(date +%s)

while IFS= read -r branch; do
    [[ -n "$branch" ]] || continue
    task="${branch#coder/}"
    tip=$(git -C "$MAIN" rev-parse "$branch")
    tip_short=${tip:0:8}
    tip_ts=$(git -C "$MAIN" log -1 --format=%ct "$branch")
    age_days=$(( (NOW - tip_ts) / 86400 ))

    # 코더가 지금 작업 중인 브랜치(큐 running)는 건드리지 않는다 — 만료도 리뷰도 다음 날
    row=$($NODE_SQLITE "${BOT_HOME}/lib/task-store.mjs" get "$task" 2>/dev/null || echo "")
    queue_status=$(jq -r '.status // "none"' <<<"${row:-null}" 2>/dev/null || echo none)
    if [[ "$queue_status" == "running" ]]; then
        SUMMARY+=("⏩ \`${task}\` 코더 실행 중 — 건너뜀"); n_skipped=$((n_skipped+1)); continue
    fi

    # 3d: 만료
    if (( age_days >= EXPIRY_DAYS )); then
        if out=$(JARVIS_NO_EXTERNAL="${JARVIS_NO_EXTERNAL:-0}" bash "$MERGE_SH" "$task" --expire "${EXPIRY_DAYS}일 미처리 자동 만료 (tip ${tip_short}, ${age_days}일 경과)" 2>&1); then
            ledger_write "$task" "$branch" "$tip" "expired" '[]' "$(jq -nc --argjson d "$age_days" '{age_days:$d, action:"expired"}')"
            SUMMARY+=("⏳ \`${task}\` ${age_days}일 방치 → 브랜치 폐기 (3d)")
            n_expired=$((n_expired+1))
        else
            log "만료 폐기 실패 ${task}: ${out:0:200}"
            SUMMARY+=("⚠️ \`${task}\` 만료 폐기 실패 — ${out:0:120}")
            n_error=$((n_error+1))
        fi
        continue
    fi

    if (( ! FORCE )) && already_reviewed "$task" "$tip"; then
        n_skipped=$((n_skipped+1)); continue
    fi

    # 자료 수집 — worktree 를 리뷰 동안만 두고, 원래 없었으면 끝에 지운다
    wt_existed=0; [[ -f "$(coder_worktree_path "$task")/.git" ]] && wt_existed=1
    wt=$(coder_worktree_ensure "$task" 2>/dev/null) || wt=""
    base_commit=$(git -C "$MAIN" merge-base "$(coder_worktree_base_branch)" "$branch" 2>/dev/null || echo "")
    changed=$(git -C "$MAIN" diff --name-only "$base_commit" "$branch" 2>/dev/null || true)
    n_files=$(printf '%s\n' "$changed" | grep -c . || true)
    cls=$(printf '%s\n' "$changed" | coder_autonomy_classify_files)
    streak=$(coder_autonomy_streak "$cls"); thr=$(coder_autonomy_threshold "$cls")
    diff_stat=$(git -C "$MAIN" diff --stat "$base_commit" "$branch" 2>/dev/null | tail -5 || true)
    diff_body=$(git -C "$MAIN" diff "$base_commit" "$branch" 2>/dev/null | head -n "$MAX_DIFF_LINES" || true)
    diff_total=$(git -C "$MAIN" diff "$base_commit" "$branch" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
    title=$(jq -r '.name // .meta.title // ""' <<<"${row:-null}" 2>/dev/null || true)
    prompt_text=$(jq -r '.prompt // ""' <<<"${row:-null}" 2>/dev/null | head -c 2000 || true)
    result_summary=$(jq -r '.meta.result_summary // .meta.result // ""' <<<"${row:-null}" 2>/dev/null | head -c 800 || true)
    verify_feedback=$(jq -r '.meta.verify_feedback // ""' <<<"${row:-null}" 2>/dev/null | head -c 800 || true)
    vg=$(grep -F "\"task\":\"${task}\"" "${BOT_HOME}/ledger/verify-gate.jsonl" 2>/dev/null | tail -1 | jq -r '.verdict // "NONE"' 2>/dev/null || echo NONE)

    # 게이트 dry-run (브랜치 무변경)
    gates_out=$(JARVIS_NO_EXTERNAL=1 bash "$MERGE_SH" "$task" --dry-run 2>&1) && gates_rc=0 || gates_rc=$?
    gates_json=$(tail -1 "$MERGE_LEDGER" 2>/dev/null | jq -c 'select(.task=="'"$task"'" and .action=="dry_run") | .gates' 2>/dev/null || echo '{}')
    [[ -n "$gates_json" ]] || gates_json='{}'
    gates_line=$(printf '%s\n' "$gates_out" | grep -E '게이트|dry-run' | sed 's/^\[[^]]*\] //' | tr '\n' ' ' | cut -c1-600)

    if (( NO_LLM )); then
        SUMMARY+=("📋 \`${task}\` ${n_files}파일 class=${cls} 게이트 rc=${gates_rc} verify=${vg} — 판정 생략(--no-llm)")
        (( wt_existed )) || coder_worktree_remove "$task"
        continue
    fi

    # ── 판정 요청 (Read 전용 상위 모델)
    review_prompt="당신은 Jarvis 코더 브랜치의 독립 리뷰어입니다. 아래 브랜치를 본체(main)에 머지할지 판정하십시오. 도구는 Read 만 있고, 파일을 더 봐야 하면 worktree 경로 아래를 읽으십시오: ${wt:-없음}

## 태스크
- id: ${task}  (큐 상태 ${queue_status}, tip ${tip_short}, ${age_days}일 전, 변경 ${n_files}파일, class=${cls}, 연속 승인 ${streak}/${thr})
- 제목: ${title}
- 요구(프롬프트):
${prompt_text:-(큐 행 없음)}
- 코더가 보고한 결과: ${result_summary:-(없음)}
- 검증 피드백: ${verify_feedback:-(없음)}

## 기계 게이트 (coder-merge.sh --dry-run, rc=${gates_rc})
${gates_line}
gates=${gates_json}
verify-gate 마지막 verdict: ${vg}

## 변경 파일
${changed}

## diff (${diff_total}줄 중 ${MAX_DIFF_LINES}줄까지)
${diff_stat}
\`\`\`diff
${diff_body}
\`\`\`

## 판정 기준
- merge: 요구를 이행하고, 명백한 결함·기존 기능 파괴·범위 밖 변경이 없으며, 기계 게이트가 통과(rc=0)했다.
- reject: 요구와 다르거나 결함이 있거나 범위 밖 파일을 건드렸거나 빈 껍데기다. 사람이 고쳐 쓸 가치가 없다.
- needs_human: 판단에 사람의 맥락이 필요하다(정책·비용·외부 영향·이 파일이 왜 바뀌어야 하는지 불명). 기계 게이트 실패도 여기.
과잉 엄격 금지: 문체·취향은 사유가 아니다. 근거는 diff 의 구체적 위치를 가리키십시오.

## 출력 형식 (응답 마지막에 반드시 이 JSON 블록)
\`\`\`json_verdict
{\"verdict\": \"merge 또는 reject 또는 needs_human\", \"reasons\": [\"근거 1\", \"근거 2\"], \"risk\": \"low|medium|high\"}
\`\`\`"

    t0=$(date +%s)
    llm_out=$("$ASK_CLAUDE" "coder-review-${task}" "$review_prompt" "Read" "$TIMEOUT" "$BUDGET" "7" "$MODEL" 2>>"$LOG_FILE") && llm_rc=0 || llm_rc=$?
    t1=$(date +%s)
    verdict_json=$(printf '%s\n' "$llm_out" | awk '
        /```json_verdict/{f=1;buf="";next}
        /```/{if(f){f=0;last=buf}}
        f{buf=buf $0 "\n"}
        END{printf "%s", last}' | jq -c . 2>/dev/null || true)
    verdict=$(jq -r '.verdict // empty' <<<"${verdict_json:-null}" 2>/dev/null | grep -oE 'merge|reject|needs_human' | head -1 || true)
    reasons=$(jq -c '.reasons // []' <<<"${verdict_json:-null}" 2>/dev/null || echo '[]')
    [[ "$reasons" == \[* ]] || reasons='[]'
    risk=$(jq -r '.risk // "unknown"' <<<"${verdict_json:-null}" 2>/dev/null || echo unknown)

    if [[ $llm_rc -ne 0 || -z "$verdict" ]]; then
        ledger_write "$task" "$branch" "$tip" "error" '[]' "$(jq -nc --argjson rc "$llm_rc" --arg o "${llm_out:0:300}" --argjson g "$gates_json" '{llm_rc:$rc, output_head:$o, gates:$g, action:"none"}')"
        SUMMARY+=("⚠️ \`${task}\` 리뷰 실패 (ask-claude rc=${llm_rc}, verdict 파싱 ${verdict:-없음}) — 사람 확인: \`bash ~/projects/jarvis/infra/scripts/coder-merge.sh ${task} --dry-run\`")
        n_error=$((n_error+1))
        (( wt_existed )) || coder_worktree_remove "$task"
        continue
    fi

    reason_line=$(jq -r 'join(" / ")' <<<"$reasons" 2>/dev/null | cut -c1-300)
    action="none"
    case "$verdict" in
        merge)
            if (( gates_rc == 0 )) && policy=$(coder_autonomy_allows_auto "$cls"); then
                if merge_out=$(bash "$MERGE_SH" "$task" --auto 2>&1); then
                    action="auto_merged"; n_merged=$((n_merged+1))
                    SUMMARY+=("✅ \`${task}\` merge → 자동 머지 (${policy}) — ${reason_line}")
                else
                    action="auto_merge_failed"; n_needs=$((n_needs+1))
                    SUMMARY+=("🟡 \`${task}\` merge 판정이나 자동 머지 실패 — $(printf '%s\n' "$merge_out" | tail -1 | cut -c1-160). 사람: \`bash ~/projects/jarvis/infra/scripts/coder-merge.sh ${task}\`")
                fi
            else
                action="needs_human"; n_needs=$((n_needs+1))
                why="${policy:-게이트 rc=${gates_rc}}"
                SUMMARY+=("🟢 \`${task}\` merge 판정 — ${why}. 사람: \`bash ~/projects/jarvis/infra/scripts/coder-merge.sh ${task}\` — ${reason_line}")
            fi ;;
        reject)
            action="needs_human"; n_reject=$((n_reject+1))
            SUMMARY+=("🔴 \`${task}\` reject 판정 (risk=${risk}) — ${reason_line}. 폐기: \`bash ~/projects/jarvis/infra/scripts/coder-merge.sh ${task} --reject \"사유\"\` (미처리 시 ${EXPIRY_DAYS}일 뒤 자동 만료)") ;;
        needs_human)
            action="needs_human"; n_needs=$((n_needs+1))
            SUMMARY+=("🟡 \`${task}\` needs_human (risk=${risk}, 게이트 rc=${gates_rc}) — ${reason_line}. 확인: \`bash ~/projects/jarvis/infra/scripts/coder-merge.sh ${task} --dry-run\`") ;;
    esac
    ledger_write "$task" "$branch" "$tip" "$verdict" "$reasons" "$(jq -nc --arg risk "$risk" --arg cls "$cls" --argjson g "$gates_json" --argjson grc "$gates_rc" --arg vg "$vg" --arg a "$action" --argjson age "$age_days" --argjson nf "$n_files" --argjson sec "$((t1 - t0))" \
        '{risk:$risk, class:$cls, gates:$g, gates_rc:$grc, verify_gate:$vg, action:$a, age_days:$age, n_files:$nf, llm_seconds:$sec}')"
    log "${task}: verdict=${verdict} action=${action} class=${cls} gates_rc=${gates_rc} (${reason_line:0:120})"
    (( wt_existed )) || coder_worktree_remove "$task"
done <<<"$BRANCHES"

# ── 요약 (stdout → bot-cron → 디스코드) ──────────────────────────────────────
echo "🔍 **coder-review** $(date '+%m/%d') — 브랜치 ${N_TOTAL}개: 자동머지 ${n_merged} · 사람대기 ${n_needs} · reject ${n_reject} · 만료 ${n_expired} · 이미리뷰 ${n_skipped} · 오류 ${n_error}"
for line in "${SUMMARY[@]:-}"; do [[ -n "$line" ]] && echo "• $line"; done
if (( N_TOTAL == 0 )); then echo "• 대기 중인 coder/* 브랜치 없음"; fi
(( n_error == 0 )) || exit 1
exit 0
