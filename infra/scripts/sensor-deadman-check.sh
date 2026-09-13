#!/usr/bin/env bash
# sensor-deadman-check.sh — 감시자의 침묵을 감지하는 데드맨 스위치 (SELF-HEAL-PLAN 4c)
#
# 왜 있나: crontab 직행 크론(월 09:xx 자기평가 클러스터, 05:00 e2e-cron, 03:30 실수 재발 감사 …)은
#   실패해도 logs/cron.log 에 안 남고, 아예 안 돌면 어떤 원장에도 흔적이 없다.
#   "아무 경보가 없다" 는 정상이 아니라 감시자가 죽었다는 뜻일 수 있다 — 그 침묵을 사고로 만든다.
#
# 무엇을 보나: 각 센서가 남기는 파일(로그·원장)의 mtime 을 기대 실행 시각과 비교한다.
#   expect "<요일|*> HH:MM" — 마지막 기대 실행 시각(유예 GRACE 분 뒤)에 파일이 갱신됐어야 한다
#   age <시간>              — 불규칙 갱신 파일: 마지막 갱신이 N시간을 넘기면 죽은 것
#   FLOOR 이전은 판단 보류(unknown) — 9/2 소실·9/3 복원으로 그 이전 증거는 없다. 죽었다고 단정하지 않는다.
#
# 결과: 죽은 센서 → 사고 원장 open (source deadman, key deadman:<name>, high). 회복은 사람이 원인을 적고 close.
#   ledger/sensor-deadman.jsonl 에 매 실행 한 행. 출력은 죽음·보류·회복이 있을 때와 월요일(생존 확인 보고)만.
#
#   sensor-deadman-check.sh [--report] [--dry-run] [--verbose]
#   환경: JARVIS_DEADMAN_LIST(감시 목록 파일: name|path|kind|spec|note, # 주석)
#         JARVIS_DEADMAN_FLOOR(ISO, 기본 2026-09-03T00:00:00+09:00) · JARVIS_DEADMAN_GRACE_MIN(기본 90)
#         JARVIS_DEADMAN_NOW(epoch, 테스트용)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

BOT_HOME="${BOT_HOME:-$HOME/.openclaw-data/runtime}"
export BOT_HOME
INFRA_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/incident-ledger.sh
source "${INFRA_DIR}/lib/incident-ledger.sh"

REPORT=0 DRY_RUN=0 VERBOSE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --report) REPORT=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --verbose|-v) VERBOSE=1; shift ;;
        daily|"") shift ;;   # bot-cron.sh 는 scriptArgs 가 없으면 "daily" 를 넘긴다 — 무시
        *) echo "알 수 없는 옵션: $1" >&2; exit 1 ;;
    esac
done
log() { (( VERBOSE )) && echo "[$(date '+%H:%M:%S')] $*" >&2 || true; }

NOW="${JARVIS_DEADMAN_NOW:-$(date +%s)}"
GRACE_S=$(( ${JARVIS_DEADMAN_GRACE_MIN:-90} * 60 ))
FLOOR_ISO="${JARVIS_DEADMAN_FLOOR:-2026-09-03T00:00:00+09:00}"
# ISO(+HH:MM 또는 Z) → epoch. jq 는 오프셋을 못 읽으므로 떼어내고 직접 뺀다
iso_epoch() {
    local iso="$1" base off=0
    if [[ "$iso" =~ ^(.*)([+-])([0-9]{2}):([0-9]{2})$ ]]; then
        base="${BASH_REMATCH[1]}Z"; off=$(( 10#${BASH_REMATCH[3]} * 3600 + 10#${BASH_REMATCH[4]} * 60 ))
        [[ "${BASH_REMATCH[2]}" == "-" ]] && off=$(( -off ))
    else base="$iso"; fi
    jq -rn --arg t "$base" --argjson off "$off" '($t | sub("\\.[0-9]+";"") | try fromdateiso8601 catch 0) - $off'
}
FLOOR=$(iso_epoch "$FLOOR_ISO")
# 로컬 시각대 오프셋(초). KST 는 +09:00 고정(서머타임 없음)
_tz=$(date +%z); TZ_OFF=$(( 10#${_tz:1:2} * 3600 + 10#${_tz:3:2} * 60 )); [[ "${_tz:0:1}" == "-" ]] && TZ_OFF=$(( -TZ_OFF ))
LEDGER="${BOT_HOME}/ledger/sensor-deadman.jsonl"

# 기본 감시 목록 — 파일 경로는 BOT_HOME 기준. 요일 1=월 … 7=일
DEFAULT_LIST=$(cat <<'LIST'
weekly-mistake-heatmap|logs/weekly-mistake-heatmap.log|expect|1 09:00|crontab 월 09:00 — 주간 실수 히트맵
cron-master-smoke|logs/cron-master-smoke.log|expect|1 09:15|crontab 월 09:15 — 크론 마스터 스모크
north-star-audit|logs/north-star-audit.log|expect|1 09:20|crontab 월 09:20 — 북극성 감사(주간 자기평가)
rule-effectiveness-audit|logs/rule-effectiveness.log|expect|1 09:20|crontab 월 09:20 — 규칙 효과 감사
self-evolution-weekly|logs/self-evolution-weekly.log|expect|1 09:30|crontab 월 09:30 — 자기진화 주간
interview-diversity-audit|logs/interview-diversity-audit.log|expect|1 09:40|crontab 월 09:40 — 면접 STAR 다양성 감사
hook-canary|logs/hook-canary.log|expect|1 09:50|crontab 월 09:50 — 훅 카나리
e2e-cron|logs/e2e-cron.log|expect|* 05:00|crontab 매일 05:00 — E2E 자가진단(가드 스위트 16종)
mistake-recurrence-audit|logs/mistake-recurrence.log|expect|* 03:30|crontab 매일 03:30 — 실수 재발 감사(클러스터)
mistake-promoter|logs/mistake-promoter.log|expect|* 04:10|crontab 매일 04:10 — 규칙 승격 제안
tasks-integrity-audit|ledger/tasks-integrity-audit.jsonl|expect|* 10:07|tasks.json 매일 10:07 — 무결성 감사 원장(9/5 크론 exit 2 로 하루 공백)
scorecard-enforcer|logs/scorecard-enforcer.log|expect|* 23:20|launchd 매일 23:20 — 스코어카드
LIST
)
if [[ -n "${JARVIS_DEADMAN_LIST:-}" ]]; then
    [[ -f "$JARVIS_DEADMAN_LIST" ]] || { echo "감시 목록 없음: $JARVIS_DEADMAN_LIST" >&2; exit 1; }
    LIST_TEXT=$(cat "$JARVIS_DEADMAN_LIST")
else
    LIST_TEXT="$DEFAULT_LIST"
fi

file_mtime() { [[ -e "$1" ]] && { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; } || echo 0; }
epoch_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
epoch_local() { date -r "$1" '+%m-%d %H:%M' 2>/dev/null || date -d "@$1" '+%m-%d %H:%M'; }
# 마지막 기대 실행 시각(epoch, UTC): 유예를 뺀 지금 이전의 가장 최근 "<요일|*> HH:MM"
last_expected() {
    jq -n --argjson now "$NOW" --argjson off "$TZ_OFF" --argjson grace "$GRACE_S" --arg dow "$1" --arg hhmm "$2" '
      ($hhmm | split(":") | map(tonumber)) as [$H,$M]
      | ($now - $grace + $off) as $lt
      | ($lt | gmtime) as $g
      | ($lt - ($g[3]*3600 + $g[4]*60 + ($g[5]|floor))) as $midnight
      | ($midnight + $H*3600 + $M*60) as $cand0
      | (if $dow == "*" then $cand0
         else $cand0 - ((($g[6] - (($dow|tonumber) % 7) + 7) % 7) * 86400) end) as $cand1
      | (if $cand1 > $lt then $cand1 - (if $dow == "*" then 86400 else 604800 end) else $cand1 end) as $cand
      | ($cand - $off) | floor'
}
human_age() { local s=$(( NOW - $1 )); if (( s < 3600 )); then echo "$(( s / 60 ))분"; elif (( s < 172800 )); then echo "$(( s / 3600 ))시간"; else echo "$(( s / 86400 ))일"; fi; }

DEAD=() UNKNOWN=() ALIVE=() RECOVERED=() OPENED=() ROWS=()
while IFS='|' read -r name path kind spec note; do
    [[ -n "$name" && "$name" != \#* ]] || continue
    [[ "$path" == /* || "$path" == ~* ]] || path="${BOT_HOME}/${path}"
    path="${path/#\~/$HOME}"
    mtime=$(file_mtime "$path")
    status="" expected=0 detail=""
    case "$kind" in
        expect)
            dow="${spec%% *}" hhmm="${spec##* }"
            expected=$(last_expected "$dow" "$hhmm")
            if (( mtime >= expected )); then status="alive"
            elif (( expected < FLOOR && mtime < FLOOR )); then status="unknown"
            else status="dead"; fi
            detail="기대 $(epoch_local "$expected")"
            ;;
        age)
            # FLOOR 이전 mtime 은 생존 증거가 아니다 — FLOOR 부터 허용 시간이 지날 때까지는 보류, 지나면 죽음
            if (( mtime >= FLOOR )); then
                if (( NOW - mtime <= spec * 3600 )); then status="alive"; else status="dead"; fi
            elif (( NOW - FLOOR <= spec * 3600 )); then status="unknown"
            else status="dead"; fi
            expected=$(( NOW - spec * 3600 )); detail="허용 ${spec}시간"
            ;;
        *) echo "알 수 없는 kind: $kind ($name)" >&2; continue ;;
    esac
    if (( mtime > 0 )); then last="마지막 $(epoch_local "$mtime") ($(human_age "$mtime") 전)"; else last="파일 없음"; fi
    log "$status $name $last $detail"
    ROWS+=("$(jq -nc --arg n "$name" --arg s "$status" --arg p "$path" --argjson m "$mtime" --argjson e "$expected" '{name:$n, status:$s, path:$p, mtime:$m, expected:$e}')")
    case "$status" in
        alive)
            ALIVE+=("$name")
            # 열린 데드맨 사고가 있는데 살아났으면 회복 — 원인을 적고 닫는 건 사람
            if cur=$(incident_find "deadman:${name}") && [[ "$(jq -r '.closed_at // ""' <<<"$cur")" == "" && "$(jq -r '.discarded // false' <<<"$cur")" != "true" ]]; then
                RECOVERED+=("$(jq -r .id <<<"$cur") ${name} — ${last}")
            fi ;;
        unknown) UNKNOWN+=("${name}: ${last} · ${detail} — 소실 구간(${FLOOR_ISO:0:10} 이전) 이라 판단 보류") ;;
        dead)
            DEAD+=("${name}: ${last} · ${detail} — ${note}")
            if (( DRY_RUN )); then OPENED+=("(dry) deadman:${name}")
            else
                rc=0
                id=$(incident_open "deadman" "deadman:${name}" \
                    "감시자 침묵: ${name} — ${last}, ${detail}" "high" \
                    "$(jq -nc --arg p "$path" --argjson m "$mtime" --argjson e "$expected" --arg note "$note" --arg mi "$( (( mtime > 0 )) && epoch_iso "$mtime" || echo "")" --arg ei "$(epoch_iso "$expected")" \
                        '{path:$p, mtime:$m, mtime_iso:$mi, expected:$e, expected_iso:$ei, note:$note}')" \
                    "센서 크론이 안 돌았거나(crontab 삭제·기계 꺼짐·PATH·권한) 출력 경로가 바뀜. 침묵은 성공이 아니다 — 크론 줄과 로그 경로를 먼저 확인" \
                    "" "auto" "$(epoch_iso "$expected")") || rc=$?
                case "$rc" in
                    0) OPENED+=("$id deadman:${name}") ;;
                    3) log "already-open deadman:${name}" ;;
                    4) OPENED+=("$id deadman:${name} (재발)") ;;
                    *) echo "incident_open 실패 rc=$rc deadman:${name}" >&2 ;;
                esac
            fi ;;
    esac
done <<<"$LIST_TEXT"

if (( ! DRY_RUN )); then
    mkdir -p "$(dirname "$LEDGER")"
    printf '%s\n' "$(jq -nc --arg ts "$(epoch_iso "$NOW")" --argjson floor "$FLOOR" \
        --argjson rows "$(printf '%s\n' "${ROWS[@]:-}" | jq -cs 'map(select(. != null))')" \
        --argjson opened "$(printf '%s\n' "${OPENED[@]:-}" | jq -R . | jq -cs 'map(select(. != ""))')" \
        '{ts:$ts, floor:$floor, alive:([$rows[] | select(.status=="alive")] | length),
          dead:[$rows[] | select(.status=="dead") | .name], unknown:[$rows[] | select(.status=="unknown") | .name],
          opened:$opened, rows:$rows}')" >> "$LEDGER"
fi

DOW=$(date -r "$NOW" +%u 2>/dev/null || date -d "@$NOW" +%u)
# 보류(unknown)만 있는 날은 조용히 — 판단할 수 없다는 말을 매일 반복하면 경보가 무뎌진다. 월요일 보고엔 싣는다
if (( ${#DEAD[@]} + ${#RECOVERED[@]} == 0 && REPORT == 0 && DOW != 1 )); then
    log "죽음·회복 없음 (생존 ${#ALIVE[@]} · 보류 ${#UNKNOWN[@]}) — 무출력"
    exit 0
fi
tag=""; (( DRY_RUN )) && tag=" (dry-run)"
echo "🫀 **감시자 생존 점검** $(epoch_local "$NOW")${tag} — 생존 ${#ALIVE[@]} · 침묵 ${#DEAD[@]} · 보류 ${#UNKNOWN[@]} · 회복 ${#RECOVERED[@]}"
for d in "${DEAD[@]:-}"; do [[ -n "$d" ]] && echo "  💀 $d"; done
for u in "${UNKNOWN[@]:-}"; do [[ -n "$u" ]] && echo "  ❔ $u"; done
for r in "${RECOVERED[@]:-}"; do [[ -n "$r" ]] && echo "  💚 회복 $r → 원인 적고 close: \`bash ~/projects/jarvis/infra/scripts/incident-ctl.sh close <id> --fix \"<커밋/원인>\"\`"; done
if (( DOW == 1 || REPORT )); then
    echo "  생존: $(printf '%s, ' "${ALIVE[@]:-}" | sed 's/, $//')"
fi
if (( ${#OPENED[@]} )); then
    echo "  사고 등재: $(printf '%s; ' "${OPENED[@]}" | sed 's/; $//')"
fi
