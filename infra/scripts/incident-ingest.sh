#!/usr/bin/env bash
# incident-ingest.sh — 센서 원장들을 훑어 사고 원장(incidents.jsonl)에 열린 사고를 만든다 (SELF-HEAL-PLAN 4a)
#
# 입력(모두 ${BOT_HOME} 기준, 없으면 건너뜀):
#   state/runtime-guard.jsonl            가드 차단 — kind·role·segment. cwd/segment 에 'canary' 가 있으면 시험 호출로 보고 무시
#   ledger/coder-review.jsonl            verdict=reject
#   ledger/coder-merge.jsonl             action ∈ blocked·rejected·reverted
#   ledger/tasks-integrity-audit.jsonl   integrity.level=critical · audit.missing_scripts · audit.policy_ghost
#     (ai_plist_failing 은 cron-failure-tracker 가 티켓으로 다루므로 여기서 이중 등록하지 않는다)
#   logs/cron.log                        센서 태스크 자체의 "FAILED (exit: N)" / "[FAILED:TIMEOUT]" 줄 (센서가 죽으면 위 원장엔 흔적이 없다)
#   소실 사건·사람이 본 사고는 incident-ctl.sh open --source loss|manual 로 직접 넣는다.
#
# 같은 key 는 한 번만 열린다(멱등). 닫힌 사고의 key 가 다시 나오면 '재발' 로 reopen 된다.
# 출력: 신규·재발이 있을 때만 요약(디스코드용). 없으면 무출력(allowEmptyResult).
#
#   incident-ingest.sh [--since <days>] [--dry-run] [--verbose]
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

BOT_HOME="${BOT_HOME:-$HOME/.openclaw-data/runtime}"
export BOT_HOME
INFRA_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/incident-ledger.sh
source "${INFRA_DIR}/lib/incident-ledger.sh"

SINCE_DAYS=14 DRY_RUN=0 VERBOSE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) SINCE_DAYS="${2:-14}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --verbose|-v) VERBOSE=1; shift ;;
        daily|"") shift ;;   # bot-cron.sh 는 scriptArgs 가 없으면 "daily" 를 넘긴다 — 무시
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac
done
[[ "$SINCE_DAYS" =~ ^[0-9]+$ ]] || { echo "--since 는 정수(일)" >&2; exit 1; }
CUTOFF=$(( $(date +%s) - SINCE_DAYS * 86400 ))
IGNORE_RE="${JARVIS_INCIDENT_IGNORE_RE:-canary}"

GUARD_LEDGER="${BOT_HOME}/state/runtime-guard.jsonl"
REVIEW_LEDGER="${BOT_HOME}/ledger/coder-review.jsonl"
MERGE_LEDGER="${BOT_HOME}/ledger/coder-merge.jsonl"
INTEGRITY_LEDGER="${BOT_HOME}/ledger/tasks-integrity-audit.jsonl"
CRON_LOG="${BOT_HOME}/logs/cron.log"

NEW=() RECUR=() SKIPPED=0
SEEN_KEYS=" "   # 이번 실행에서 이미 다룬 key — 같은 경보가 원장에 여러 행 있어도 한 번만 연다
log() { (( VERBOSE )) && echo "[$(date '+%H:%M:%S')] $*" >&2 || true; }

# open <source> <key> <title> <severity> <evidence_json> <event_ts> [cause]
open_one() {
    local source="$1" key="$2" title="$3" severity="$4" evidence="$5" event_ts="$6" cause="${7:-}" rc=0 id
    if [[ "$SEEN_KEYS" == *" $key "* ]]; then return 0; fi
    SEEN_KEYS+="$key "
    if (( DRY_RUN )); then
        local cur closed
        if cur=$(incident_find "$key"); then
            closed=$(jq -r '.closed_at // ""' <<<"$cur")
            if [[ -n "$closed" && "$event_ts" > "$closed" ]]; then RECUR+=("(dry) [$source/$severity] $title"); log "would-reopen $key"
            else SKIPPED=$((SKIPPED+1)); log "skip(exists) $key"; fi
        else NEW+=("(dry) [$source/$severity] $title"); log "would-open $key"; fi
        return 0
    fi
    id=$(incident_open "$source" "$key" "$title" "$severity" "$evidence" "$cause" "" "auto" "$event_ts") || rc=$?
    case "$rc" in
        0) NEW+=("$id [$source/$severity] $title"); log "opened $id $key" ;;
        3) SKIPPED=$((SKIPPED+1)); log "skip(open) $key" ;;
        4) RECUR+=("$id [$source/$severity] $title"); log "recurred $id $key" ;;
        *) echo "incident_open 실패 rc=$rc key=$key" >&2 ;;
    esac
}

# ts(ISO) → epoch. 파싱 실패면 0 (= 창 밖 취급 안 함, 포함)
ts_epoch() { jq -rn --arg t "$1" '($t | sub("\\.[0-9]+";"") | try fromdateiso8601 catch 0)'; }
sha8() { printf '%s' "$1" | shasum -a 256 | cut -c1-8; }
# 원장을 최신 행부터 읽는다 — 같은 key 의 여러 행 중 가장 최근 사건이 재발 여부를 결정해야 하므로 (tac 은 macOS 에 없다)
rev_lines() { awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' "$1"; }

# ── 1. 가드 차단 ─────────────────────────────────────────────────────────────
if [[ -f "$GUARD_LEDGER" ]]; then
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        ts=$(jq -r '.ts // ""' <<<"$row"); (( $(ts_epoch "$ts") >= CUTOFF )) || continue
        kind=$(jq -r '.kind // "unknown"' <<<"$row"); role=$(jq -r '.role // ""' <<<"$row")
        cwd=$(jq -r '.cwd // ""' <<<"$row"); seg=$(jq -r '.segment // ""' <<<"$row")
        # runtime-guard 훅은 role 을 남기지 않는다 — cwd 로 배치(bot-work) / 대화 세션을 가른다
        if [[ -z "$role" ]]; then role="session"; [[ "$cwd" == */bot-work/* ]] && role="batch"; fi
        if [[ "$cwd$seg" =~ $IGNORE_RE ]]; then log "ignore(canary) $kind $seg"; continue; fi
        case "$kind" in
            rm-root|rm-cwd-root|agent-launchctl|agent-crontab|agent-git-push|runtime-destructive) sev=high ;;
            agent-write-protected|agent-sqlite-write|rm-r-child) sev=med ;;
            *) sev=low ;;
        esac
        short=${seg:0:100}
        open_one "runtime-guard" "runtime-guard:${kind}:${role}:$(sha8 "$seg")" \
            "가드 차단 ${kind} (${role}): ${short}" "$sev" \
            "$(jq -nc --arg ts "$ts" --arg kind "$kind" --arg role "$role" --arg cwd "$cwd" --arg seg "$seg" \
                '{ts:$ts, kind:$kind, role:$role, cwd:$cwd, segment:$seg}')" "$ts"
    done < <(rev_lines "$GUARD_LEDGER")
fi

# ── 2. 코더 리뷰 reject ──────────────────────────────────────────────────────
if [[ -f "$REVIEW_LEDGER" ]]; then
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        [[ "$(jq -r '.verdict // ""' <<<"$row")" == "reject" ]] || continue
        ts=$(jq -r '.ts // ""' <<<"$row"); (( $(ts_epoch "$ts") >= CUTOFF )) || continue
        task=$(jq -r '.task // "?"' <<<"$row"); tip=$(jq -r '.tip // ""' <<<"$row")
        reasons=$(jq -r '(.reasons // []) | join(" / ")' <<<"$row")
        open_one "coder-review" "coder-review:${task}:${tip:0:12}" \
            "코더 리뷰 reject: ${task} — ${reasons:0:120}" "med" \
            "$(jq -c '{ts, task, branch, tip, reasons, risk, class}' <<<"$row")" "$ts" \
            "$reasons"
    done < <(rev_lines "$REVIEW_LEDGER")
fi

# ── 3. 코더 머지 차단·거절·되돌림 ────────────────────────────────────────────
if [[ -f "$MERGE_LEDGER" ]]; then
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        action=$(jq -r '.action // ""' <<<"$row")
        case "$action" in blocked|rejected|reverted) ;; *) continue ;; esac
        ts=$(jq -r '.ts // ""' <<<"$row"); (( $(ts_epoch "$ts") >= CUTOFF )) || continue
        task=$(jq -r '.task // "?"' <<<"$row"); reason=$(jq -r '.reason // ""' <<<"$row")
        sev=med; [[ "$action" == "reverted" ]] && sev=high
        open_one "coder-merge" "coder-merge:${action}:${task}:$(sha8 "$reason")" \
            "코더 머지 ${action}: ${task} — ${reason:0:120}" "$sev" \
            "$(jq -c '{ts, task, branch, action, class, gates, reason, approved_by}' <<<"$row")" "$ts"
    done < <(rev_lines "$MERGE_LEDGER")
fi

# ── 4. tasks.json 무결성 경보 ────────────────────────────────────────────────
if [[ -f "$INTEGRITY_LEDGER" ]]; then
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        ts=$(jq -r '.ts // ""' <<<"$row"); (( $(ts_epoch "$ts") >= CUTOFF )) || continue
        day=${ts:0:10}
        if [[ "$(jq -r '.integrity.level // ""' <<<"$row")" == "critical" ]]; then
            reasons=$(jq -r '(.integrity.reasons // []) | join(" / ")' <<<"$row")
            open_one "integrity" "integrity:critical:${day}:$(sha8 "$reasons")" \
                "tasks.json 무결성 🔴 ${day}: ${reasons:0:120}" "high" \
                "$(jq -c '{ts, integrity: (.integrity | {level, reasons, task_count, prev_count, count_delta, removed: (.removed // [])[0:10], sha256, prev_sha256})}' <<<"$row")" "$ts"
        fi
        while IFS= read -r m; do
            [[ -n "$m" ]] || continue
            mid=$(jq -r '.id' <<<"$m"); mscript=$(jq -r '.script // ""' <<<"$m")
            open_one "integrity" "integrity:missing-script:${mid}" \
                "누락 스크립트 (auto-disable 대상): ${mid} → ${mscript}" "high" \
                "$(jq -nc --arg ts "$ts" --argjson m "$m" '{ts:$ts} + $m')" "$ts"
        done < <(jq -c '.audit.missing_scripts[]? // empty' <<<"$row")
        while IFS= read -r g; do
            [[ -n "$g" ]] || continue
            glabel=$(jq -r '.label' <<<"$g")
            open_one "integrity" "integrity:ghost-plist:${glabel}" \
                "ghost plist (참조 스크립트 없음): ${glabel}" "med" \
                "$(jq -nc --arg ts "$ts" --argjson g "$g" '{ts:$ts} + $g')" "$ts"
        done < <(jq -c '.audit.policy_ghost[]? // empty' <<<"$row")
    done < <(rev_lines "$INTEGRITY_LEDGER")
fi

# ── 5. 센서 크론 자체의 실패 ──────────────────────────────────────────────────
# 센서(감사·ingest·리뷰)가 안 돌면 그 센서의 원장에 행이 안 남아 위 1~4 는 아무것도 못 본다.
# bot-cron.sh 가 logs/cron.log 에 남기는 "[task] FAILED (exit: N)" / "[FAILED:TIMEOUT]" 줄이 유일한 흔적이므로
# 여기서 그 줄을 직접 읽는다. 대상은 자가치유 센서 태스크만 — 일반 태스크 실패는 cron-failure-tracker 의 티켓 영역.
# (crontab 직행 크론 e2e-cron·mistake-recurrence-audit·mistake-promoter 는 cron.log 에 안 남는다 — 4c 생존 점검이 맡는다)
SENSOR_TASKS="${JARVIS_SENSOR_TASKS:-tasks-integrity-audit incident-ingest sensor-deadman-check coder-review mistake-extractor mistake-pattern-analyzer mistake-circuit-healthcheck cron-master-smoke launchagents-audit}"
# cron.log 의 로컬 시각 "YYYY-MM-DD HH:MM:SS" → epoch (macOS date -j / GNU date -d)
local_epoch() {
    date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null || echo 0
}
epoch_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
if [[ -f "$CRON_LOG" ]]; then
    fail_re='^\[([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2})\] \[([A-Za-z0-9_.-]+)\] (FAILED \(exit: ([0-9]+)\)|\[FAILED:TIMEOUT\] exit=([0-9]+))'
    while IFS= read -r line; do
        [[ "$line" =~ $fail_re ]] || continue
        day="${BASH_REMATCH[1]}" task="${BASH_REMATCH[3]}"
        [[ " $SENSOR_TASKS " == *" $task "* ]] || continue
        ep=$(local_epoch "${day} ${BASH_REMATCH[2]}"); (( ep >= CUTOFF )) || continue
        if [[ -n "${BASH_REMATCH[5]:-}" ]]; then code="${BASH_REMATCH[5]}" kind="exit"; else code="${BASH_REMATCH[6]}" kind="timeout"; fi
        open_one "cron-failed" "cron-failed:${task}:${day}" \
            "센서 크론 실패 ${day}: ${task} (${kind} ${code}) — 그날 이 센서가 보던 사고는 미검출" "high" \
            "$(jq -nc --arg ts "$(epoch_iso "$ep")" --arg task "$task" --arg kind "$kind" --arg code "$code" --arg line "$line" --arg log "$CRON_LOG" \
                '{ts:$ts, task:$task, kind:$kind, exit:($code|tonumber), line:$line, log:$log}')" \
            "$(epoch_iso "$ep")" \
            "센서 크론 자체가 실패 — 원장에 행이 없어 사고가 있어도 감지되지 않는다. 먼저 크론을 고치고, 그날 분을 수동 재실행한다"
    done < <({ grep -E 'FAILED' "$CRON_LOG" || true; } | rev_lines /dev/stdin)
fi

# ── 출력 ─────────────────────────────────────────────────────────────────────
OPEN_N=$(incident_open_count)
log "new=${#NEW[@]} recur=${#RECUR[@]} skipped=${SKIPPED} open=${OPEN_N}"
if (( ${#NEW[@]} == 0 && ${#RECUR[@]} == 0 )); then
    (( VERBOSE )) && echo "신규 사고 없음 — 미닫힘 ${OPEN_N}건"
    exit 0
fi
DRY_TAG=""; (( DRY_RUN )) && DRY_TAG=" (dry-run)"
echo "🧾 **사고 원장** $(date '+%m/%d')${DRY_TAG} — 신규 ${#NEW[@]}건 · 재발 ${#RECUR[@]}건 · 미닫힘 총 ${OPEN_N}건"
for l in ${RECUR[@]+"${RECUR[@]}"}; do echo "  🔁 재발 $l"; done
for l in ${NEW[@]+"${NEW[@]}"}; do echo "  • $l"; done
echo "  닫기: \`bash ~/projects/jarvis/infra/scripts/incident-ctl.sh close <id> --fix \"<커밋/티켓>\" --cause \"<가설>\"\` · 오탐: \`… discard <id> --reason \"…\"\`"
