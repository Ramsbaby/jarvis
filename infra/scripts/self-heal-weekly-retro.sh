#!/usr/bin/env bash
# self-heal-weekly-retro.sh — 주간 자기치유 회고 (SELF-HEAL-PLAN 4d)
#
# 왜 있나: "발전했다" 는 느낌이 아니라 수치다. 계획서 3절의 지표 5개를 매주 같은 방법으로 재고,
#   지난주 행과 비교해 방향(▲▼)을 붙인다. 자동 머지 정책표(3c)의 문턱 변경은 이 수치로만 제안한다.
#   회고 출력에 지표가 빠지면 실패다 — 서술만 남은 회고는 exit 1 로 죽여 크론 실패로 드러낸다.
#
# 지표 (지난 7일, 계획서 3절):
#   ① 오탐 티켓 비율  = (감사 mismatch + 코더 결과 '오탐:') / (신규 티켓 + mismatch)      목표 <10%
#   ② 코더 리뷰 통과율 = merge / (merge+reject+needs_human)   반려 사유 분류                 측정 시작
#   ③ 설정 변조 감지 시간 = 감사 행 ts − tasks.json mtime (변경 있던 행), 없으면 감사 최대 간격  ≤24h
#   ④ 사고 닫힘률      = 닫힘 / (이번 주 열린 사고 − 폐기)                                  ≥80%
#   ⑤ 크론 성공률      = SUCCESS / START (logs/cron.log)                                  ≥95%
# 부록: 미닫힘 사고 첫 줄(incident-ctl summary) · 규칙 제안(rule-proposal-ctl summary) · 데드맨 마지막 판정
#       · 자동 머지 정책표 class 별 스트릭/문턱 + 변경 제안 · 주인님께 묻는 것 최대 3개
#
# 원장: ledger/self-heal-retro.jsonl (실행마다 1행, --dry-run 은 안 씀). 전주 비교는 이 원장의 직전 행.
#
#   self-heal-weekly-retro.sh [--dry-run] [--window-days N] [--json]
#   환경: JARVIS_RETRO_NOW(epoch, 테스트용) · JARVIS_RETRO_WINDOW_DAYS(기본 7)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

BOT_HOME="${BOT_HOME:-$HOME/.openclaw-data/runtime}"
export BOT_HOME
INFRA_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
export JARVIS_INFRA_HOME="${JARVIS_INFRA_HOME:-$INFRA_DIR}"

DRY_RUN=0; AS_JSON=0
WINDOW_DAYS="${JARVIS_RETRO_WINDOW_DAYS:-7}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --json) AS_JSON=1; shift ;;
        --window-days) WINDOW_DAYS="$2"; shift 2 ;;
        daily|"") shift ;;   # bot-cron.sh 는 scriptArgs 가 없으면 "daily" 를 넘긴다 — 무시
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac
done

NOW="${JARVIS_RETRO_NOW:-$(date +%s)}"
SINCE=$(( NOW - WINDOW_DAYS * 86400 ))
epoch_utc()   { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
epoch_local() { date -r "$1" +"$2" 2>/dev/null || date -d "@$1" +"$2"; }
SINCE_ISO=$(epoch_utc "$SINCE")
SINCE_LOCAL=$(epoch_local "$SINCE" '%Y-%m-%d %H:%M:%S')
NOW_LOCAL=$(epoch_local "$NOW" '%Y-%m-%d %H:%M:%S')

LEDGER="${BOT_HOME}/ledger/self-heal-retro.jsonl"
CRON_LOG="${BOT_HOME}/logs/cron.log"
TRACKER_LOG="${BOT_HOME}/logs/cron-failure-tracker.log"
AUDITOR_LOG="${BOT_HOME}/logs/cron-auditor.log"
OUTCOMES_DIR="${BOT_HOME}/results/task-outcomes"
REVIEW_LEDGER="${BOT_HOME}/ledger/coder-review.jsonl"
INTEGRITY_LEDGER="${BOT_HOME}/ledger/tasks-integrity-audit.jsonl"
DEADMAN_LEDGER="${BOT_HOME}/ledger/sensor-deadman.jsonl"
INCIDENT_CTL="${INFRA_DIR}/scripts/incident-ctl.sh"
PROPOSAL_CTL="${INFRA_DIR}/scripts/rule-proposal-ctl.mjs"
AUTONOMY_LIB="${INFRA_DIR}/lib/coder-autonomy.sh"

pct() { # <분자> <분모> → "n/d = p%" 또는 "표본 0"
    if (( $2 == 0 )); then echo "표본 0"; else echo "$1/$2 = $(( $1 * 100 / $2 ))%"; fi
}
# 로컬 "[YYYY-MM-DD HH:MM:SS]" 로그에서 창 안의 줄만 — 고정 폭이라 문자열 비교로 충분
log_window() { awk -v s="$1" 'substr($0,1,1)=="[" && substr($0,2,19) >= s' "$2" 2>/dev/null || true; }

# ── ① 오탐 티켓 비율 ────────────────────────────────────────────────────────
TICKETS=$(log_window "$SINCE_LOCAL" "$TRACKER_LOG" | grep -c '신규 티켓 생성' || true)
MISMATCH=$(grep -oE 'DB-로그 불일치\(mismatch\): [0-9]+' "$AUDITOR_LOG" 2>/dev/null | tail -1 | grep -oE '[0-9]+$' || echo 0)
MISMATCH="${MISMATCH:-0}"
coder_false_count() { # 창 안의 코더 티켓 결과 중 첫 줄이 '오탐:' 인 것 (계약·독립검증 파일 제외)
    local f n=0 c
    for f in "$OUTCOMES_DIR"/*debug-cron-*.json; do
        [[ -f "$f" ]] || continue
        case "$f" in
            *-contract.json|*/*verify-debug-cron-*) continue ;;
        esac
        c=$(jq -r --arg since "$SINCE_ISO" 'select((.timestamp // "") >= $since) | (.result_content // "" | tostring)' "$f" 2>/dev/null \
            | grep -c '^오탐:' || true)
        n=$(( n + ${c:-0} ))
    done
    echo "$n"
}
CODER_FALSE=0
[[ -d "$OUTCOMES_DIR" ]] && CODER_FALSE=$(coder_false_count)
INCIDENTS_JSON=$(bash "$INCIDENT_CTL" list --json --all 2>/dev/null || echo '[]')
DISCARDED=$(echo "$INCIDENTS_JSON" | jq --arg s "$SINCE_ISO" '[.[] | select(.discarded == true and (.closed_at // "") >= $s)] | length')
FP_NUM=$(( MISMATCH + CODER_FALSE )); FP_DEN=$(( TICKETS + MISMATCH ))
M1="$(pct "$FP_NUM" "$FP_DEN")"

# ── ② 코더 리뷰 통과율 ──────────────────────────────────────────────────────
REVIEW_STATS='{"merge":0,"reject":0,"needs_human":0,"other":0,"reasons":[]}'
if [[ -f "$REVIEW_LEDGER" ]]; then
    REVIEW_STATS=$(jq -cs --arg s "$SINCE_ISO" '
        map(select(type=="object" and (.ts // "") >= $s and (.verdict|IN("merge","reject","needs_human","error"))))
        | {merge: (map(select(.verdict=="merge"))|length),
           reject: (map(select(.verdict=="reject"))|length),
           needs_human: (map(select(.verdict=="needs_human"))|length),
           other: (map(select(.verdict=="error"))|length),
           reasons: (map(select(.verdict=="reject") | .reasons[]? | tostring | .[0:60]) | unique)}' "$REVIEW_LEDGER" 2>/dev/null \
        || echo '{"merge":0,"reject":0,"needs_human":0,"other":0,"reasons":[]}')
fi
R_MERGE=$(echo "$REVIEW_STATS" | jq '.merge'); R_REJECT=$(echo "$REVIEW_STATS" | jq '.reject'); R_HUMAN=$(echo "$REVIEW_STATS" | jq '.needs_human')
R_DEN=$(( R_MERGE + R_REJECT + R_HUMAN ))
M2="$(pct "$R_MERGE" "$R_DEN")"
R_REASONS=$(echo "$REVIEW_STATS" | jq -r '.reasons | join(" / ")')

# ── ③ 설정 변조 감지 시간 ───────────────────────────────────────────────────
AUDIT_STATS='{"runs":0,"max_gap_h":null,"changes":0,"max_detect_h":null,"critical":0}'
if [[ -f "$INTEGRITY_LEDGER" ]]; then
    # 감사 행의 mtime 은 로컬 "YYYY-MM-DD HH:MM:SS" — 행 ts(UTC) 와 맞추려 로컬 오프셋을 뺀다
    TZ_OFF_S=$(date +%z | awk '{s=substr($1,1,1)=="-"?-1:1; printf "%d", s*(substr($1,2,2)*3600+substr($1,4,2)*60)}')
    AUDIT_STATS=$(jq -cs --arg s "$SINCE_ISO" --argjson now "$NOW" --argjson off "$TZ_OFF_S" '
        map(select(type=="object" and (.ts // "") >= $s)) | sort_by(.ts) as $rows
        | ($rows | map(.ts_unix // (.ts|fromdateiso8601))) as $t
        | ($t | length) as $n
        | ([range(1; $n) as $i | $t[$i] - $t[$i-1]] + (if $n > 0 then [$now - $t[$n-1]] else [] end)) as $gaps
        | ($rows | map(select((.integrity.count_delta // 0) != 0 or ((.integrity.changed // []) | length) > 0
                              or ((.integrity.added // []) | length) > 0 or ((.integrity.removed // []) | length) > 0))) as $chg
        | ($chg | map(
              (.integrity.mtime // "" | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$")
                 then ((sub(" "; "T") + "Z") | fromdateiso8601) - $off else null end) as $m
              | if $m == null then null else ((.ts_unix // (.ts|fromdateiso8601)) - $m) end) | map(select(. != null))) as $lags
        | {runs: $n,
           max_gap_h: (if ($gaps|length) > 0 then (($gaps|max) / 3600 * 10 | round / 10) else null end),
           changes: ($chg|length),
           max_detect_h: (if ($lags|length) > 0 then (($lags|max) / 3600 * 10 | round / 10) else null end),
           critical: ($rows | map(((.audit.missing_scripts // []) | length) + ((.audit.policy_ghost // []) | length)) | add // 0)}' \
        "$INTEGRITY_LEDGER" 2>/dev/null || echo "$AUDIT_STATS")
fi
A_RUNS=$(echo "$AUDIT_STATS" | jq '.runs'); A_GAP=$(echo "$AUDIT_STATS" | jq -r '.max_gap_h // "∞"')
A_CHG=$(echo "$AUDIT_STATS" | jq '.changes'); A_DETECT=$(echo "$AUDIT_STATS" | jq -r '.max_detect_h // "-"')
if (( A_RUNS == 0 )); then M3="무한 (감사 미실행)"
elif [[ "$A_DETECT" != "-" ]]; then M3="${A_DETECT}h (변경 ${A_CHG}건 감지, 감사 ${A_RUNS}회 · 최대 간격 ${A_GAP}h)"
else M3="≤${A_GAP}h (변경 0건, 감사 ${A_RUNS}회 · 최대 간격 ${A_GAP}h)"; fi

# ── ④ 사고 닫힘률 ───────────────────────────────────────────────────────────
INC_STATS=$(echo "$INCIDENTS_JSON" | jq -c --arg s "$SINCE_ISO" '
    map(select((.opened_at // "") >= $s)) as $w
    | {opened: ($w | map(select(.discarded != true)) | length),
       closed: ($w | map(select(.discarded != true and .closed_at != null)) | length),
       discarded: ($w | map(select(.discarded == true)) | length),
       open_high: (map(select(.closed_at == null and .severity == "high")) | length),
       open_total: (map(select(.closed_at == null)) | length),
       recurrences: ($w | map(.recurrences // 0) | add // 0)}')
I_OPENED=$(echo "$INC_STATS" | jq '.opened'); I_CLOSED=$(echo "$INC_STATS" | jq '.closed')
I_OPEN_HIGH=$(echo "$INC_STATS" | jq '.open_high'); I_OPEN_TOTAL=$(echo "$INC_STATS" | jq '.open_total')
M4="$(pct "$I_CLOSED" "$I_OPENED")"

# ── ⑤ 크론 성공률 ───────────────────────────────────────────────────────────
C_START=$(log_window "$SINCE_LOCAL" "$CRON_LOG" | grep -cE '\] START$' || true)
C_SUCCESS=$(log_window "$SINCE_LOCAL" "$CRON_LOG" | grep -cE '\] SUCCESS' || true)
C_FAILED=$(log_window "$SINCE_LOCAL" "$CRON_LOG" | grep -cE '\] (FAILED \(exit|\[FAILED:)' || true)
M5="$(pct "$C_SUCCESS" "$C_START")"

# ── 부록 ────────────────────────────────────────────────────────────────────
INC_SUMMARY_LINE=$(bash "$INCIDENT_CTL" summary 2>/dev/null | head -1 || echo "사고 원장 없음")
RP_SUMMARY_LINE=$(node "$PROPOSAL_CTL" summary 2>/dev/null | head -1 || echo "규칙 제안 원장 없음")
RP_PENDING=$(echo "$RP_SUMMARY_LINE" | grep -oE '대기 [0-9]+건' | grep -oE '[0-9]+' || echo 0)
RP_PENDING="${RP_PENDING:-0}"
DEADMAN_LAST='{"ts":null,"alive":0,"dead":[],"unknown":[]}'
[[ -f "$DEADMAN_LEDGER" ]] && DEADMAN_LAST=$(tail -1 "$DEADMAN_LEDGER" | jq -c '{ts, alive, dead, unknown}' 2>/dev/null || echo "$DEADMAN_LAST")
D_ALIVE=$(echo "$DEADMAN_LAST" | jq '.alive // 0'); D_DEAD=$(echo "$DEADMAN_LAST" | jq '.dead | length')
D_UNKNOWN=$(echo "$DEADMAN_LAST" | jq '.unknown | length'); D_TS=$(echo "$DEADMAN_LAST" | jq -r '.ts // "없음"')
D_DEAD_NAMES=$(echo "$DEADMAN_LAST" | jq -r '.dead | join(", ")')

# 자동 머지 정책표 — class 별 스트릭/문턱. 제안은 수치로만: 2주 연속 ①<10%(표본≥10) ∧ ②≥80%(표본≥5) ∧ ④≥80%
AUTONOMY_JSON='{}'
if [[ -f "$AUTONOMY_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$AUTONOMY_LIB"
    AUTONOMY_JSON=$(for cls in $(jq -r '.order[]' "$(coder_autonomy_config)" 2>/dev/null); do
        t=$(coder_autonomy_threshold "$cls"); [[ "$t" == "null" ]] && continue
        s=$(coder_autonomy_streak "$cls")
        jq -nc --arg c "$cls" --argjson t "$t" --argjson s "$s" '{($c): {streak: $s, threshold: $t}}'
    done | jq -cs 'add // {}')
fi
AUTONOMY_LINE=$(echo "$AUTONOMY_JSON" | jq -r 'to_entries | map("\(.key) \(.value.streak)/\(.value.threshold)") | join(" · ")')
[[ -z "$AUTONOMY_LINE" ]] && AUTONOMY_LINE="정책표 없음"
FP_OK=0; (( FP_DEN >= 10 && FP_NUM * 100 < FP_DEN * 10 )) && FP_OK=1
RV_OK=0; (( R_DEN >= 5 && R_MERGE * 100 >= R_DEN * 80 )) && RV_OK=1
CL_OK=0; (( I_OPENED > 0 && I_CLOSED * 100 >= I_OPENED * 80 )) && CL_OK=1
THIS_WEEK_OK=$(( FP_OK && RV_OK && CL_OK ))
PREV_ROW='null'
[[ -f "$LEDGER" ]] && PREV_ROW=$(tail -1 "$LEDGER" 2>/dev/null || echo null)
[[ -z "$PREV_ROW" ]] && PREV_ROW=null
PREV_OK=$(echo "$PREV_ROW" | jq -r 'if type=="object" then (.gate_ok // false) else false end')
if (( THIS_WEEK_OK )) && [[ "$PREV_OK" == "true" ]]; then
    AUTONOMY_PROPOSAL="권고: 2주 연속 조건 충족 — tests·docs 문턱 1 완화 검토(주인님 승인 후 coder-autonomy.json 편집)"
elif (( THIS_WEEK_OK )); then
    AUTONOMY_PROPOSAL="변경 없음 — 이번 주 조건 충족, 다음 주도 충족하면 완화 제안"
else
    why=""
    (( FP_OK )) || why="${why}①오탐율(표본 ${FP_DEN}) "
    (( RV_OK )) || why="${why}②리뷰(표본 ${R_DEN}) "
    (( CL_OK )) || why="${why}④닫힘률 "
    AUTONOMY_PROPOSAL="변경 없음 — 근거 미달: ${why% }"
fi

# 주인님께 묻는 것 — 최대 3개, 결정이 필요한 것만
QUESTIONS=()
(( RP_PENDING > 0 )) && QUESTIONS+=("규칙 제안 ${RP_PENDING}건 결정 — node infra/scripts/rule-proposal-ctl.mjs list → promote --to / reject --reason")
(( I_OPEN_HIGH > 0 )) && QUESTIONS+=("high 미닫힘 사고 ${I_OPEN_HIGH}건 — bash infra/scripts/incident-ctl.sh list 에서 사람 조치 대기분 처리")
(( D_DEAD > 0 )) && QUESTIONS+=("침묵 센서 ${D_DEAD}개(${D_DEAD_NAMES}) — 살릴지 폐기할지")
(( R_HUMAN > 0 )) && QUESTIONS+=("코더 리뷰 needs_human ${R_HUMAN}건 — coder-merge.sh <task> 또는 --reject")
(( ${#QUESTIONS[@]} > 3 )) && QUESTIONS=("${QUESTIONS[@]:0:3}")

# ── 전주 비교 ───────────────────────────────────────────────────────────────
delta() { # <지표 키> <이번 값(정수 %)> → " (전주 p% ▲/▼/=)" 또는 ""
    local prev; prev=$(echo "$PREV_ROW" | jq -r --arg k "$1" 'if type=="object" then (.metrics[$k].pct // empty) else empty end')
    [[ -z "$prev" || "$2" == "-" ]] && { echo ""; return; }
    local arrow="="; (( $2 > prev )) && arrow="▲"; (( $2 < prev )) && arrow="▼"
    echo " (전주 ${prev}% ${arrow})"
}
p_of() { (( $2 == 0 )) && echo "-" || echo $(( $1 * 100 / $2 )); }
P1=$(p_of "$FP_NUM" "$FP_DEN"); P2=$(p_of "$R_MERGE" "$R_DEN"); P4=$(p_of "$I_CLOSED" "$I_OPENED"); P5=$(p_of "$C_SUCCESS" "$C_START")

# ── 지표 누락 = 실패 ────────────────────────────────────────────────────────
for v in "$M1" "$M2" "$M3" "$M4" "$M5"; do
    [[ -n "$v" ]] || { echo "회고 실패: 지표가 비었다 — 서술만 남은 회고는 실패다" >&2; exit 1; }
done

# ── 원장 ───────────────────────────────────────────────────────────────────
ROW=$(jq -nc --arg ts "$(epoch_utc "$NOW")" --argjson days "$WINDOW_DAYS" \
    --argjson fp_num "$FP_NUM" --argjson fp_den "$FP_DEN" --argjson tickets "$TICKETS" --argjson mismatch "$MISMATCH" \
    --argjson coder_false "$CODER_FALSE" --argjson discarded "$DISCARDED" \
    --argjson review "$REVIEW_STATS" --argjson audit "$AUDIT_STATS" --argjson inc "$INC_STATS" \
    --argjson c_start "$C_START" --argjson c_success "$C_SUCCESS" --argjson c_failed "$C_FAILED" \
    --arg p1 "$P1" --arg p2 "$P2" --arg p4 "$P4" --arg p5 "$P5" \
    --argjson rp_pending "$RP_PENDING" --argjson deadman "$DEADMAN_LAST" --argjson autonomy "$AUTONOMY_JSON" \
    --argjson gate_ok "$THIS_WEEK_OK" --arg proposal "$AUTONOMY_PROPOSAL" \
    --argjson questions "$(printf '%s\n' "${QUESTIONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')" '
    def p($s): if $s == "-" then null else ($s|tonumber) end;
    {ts: $ts, window_days: $days,
     metrics: {
       false_positive: {num: $fp_num, den: $fp_den, pct: p($p1), tickets: $tickets, mismatch: $mismatch, coder_false: $coder_false, discarded: $discarded},
       review: ($review + {pct: p($p2)}),
       config_detect: $audit,
       incidents: ($inc + {pct: p($p4)}),
       cron: {start: $c_start, success: $c_success, failed_lines: $c_failed, pct: p($p5)}},
     proposals_pending: $rp_pending, deadman: $deadman, autonomy: $autonomy,
     gate_ok: ($gate_ok == 1), autonomy_proposal: $proposal, questions: $questions}')
if (( ! DRY_RUN )); then mkdir -p "$(dirname "$LEDGER")"; echo "$ROW" >> "$LEDGER"; fi
if (( AS_JSON )); then echo "$ROW"; exit 0; fi

# ── 출력 ───────────────────────────────────────────────────────────────────
echo "🪞 **주간 자기치유 회고** $(epoch_local "$NOW" '%m-%d') — 지난 ${WINDOW_DAYS}일 ($(epoch_local "$SINCE" '%m-%d')~$(epoch_local "$NOW" '%m-%d'))$( (( DRY_RUN )) && echo ' (dry-run)')"
echo "① 오탐 티켓 비율 ${M1} — mismatch ${MISMATCH} · 코더 '오탐:' ${CODER_FALSE} · 신규 티켓 ${TICKETS} · 사고 폐기 ${DISCARDED}  [목표 <10%]$(delta false_positive "$P1")"
echo "② 코더 리뷰 통과율 ${M2} — merge ${R_MERGE} · reject ${R_REJECT} · needs_human ${R_HUMAN}$( [[ -n "$R_REASONS" ]] && echo " · 반려 사유: ${R_REASONS}")  [측정 시작]$(delta review "$P2")"
echo "③ 설정 변조 감지 시간 ${M3}  [목표 ≤24h]"
echo "④ 사고 닫힘률 ${M4} — 이번 주 열림 ${I_OPENED} · 닫힘 ${I_CLOSED} · 재발 $(echo "$INC_STATS" | jq '.recurrences')  [목표 ≥80%]$(delta incidents "$P4")"
echo "⑤ 크론 성공률 ${M5} — SUCCESS ${C_SUCCESS} / START ${C_START} (실패 표식 ${C_FAILED}줄)  [목표 ≥95%]$(delta cron "$P5")"
echo "🚨 ${INC_SUMMARY_LINE}"
echo "📜 ${RP_SUMMARY_LINE}"
echo "🫀 감시자: 생존 ${D_ALIVE} · 침묵 ${D_DEAD}$( [[ -n "$D_DEAD_NAMES" ]] && echo " (${D_DEAD_NAMES})") · 보류 ${D_UNKNOWN} — 마지막 판정 ${D_TS}"
echo "🔐 자동 머지 정책표(연속 승인/문턱): ${AUTONOMY_LINE} → ${AUTONOMY_PROPOSAL}"
if (( ${#QUESTIONS[@]} > 0 )); then
    echo "❓ 주인님께 (최대 3):"
    i=0; for q in "${QUESTIONS[@]}"; do i=$((i+1)); echo "  ${i}. ${q}"; done
else
    echo "❓ 주인님께 여쭐 것 없음"
fi
