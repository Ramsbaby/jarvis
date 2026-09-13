#!/usr/bin/env bash
# test-self-heal-retro.sh — 주간 자기치유 회고(4d) 회귀 테스트: self-heal-weekly-retro.sh
#
# 검증 (임시 BOT_HOME, 시각은 JARVIS_RETRO_NOW 로 고정, 외부 송출 없음):
#   지표 5개가 각 원장·로그에서 정확히 계산되는가 / 창(7일) 밖은 제외되는가 / 표본 0 처리
#   원장 행 기록·dry-run 무기록 / 전주 비교 ▲▼ / 정책표 제안이 수치로만 나오는가 / 질문 ≤3 / 빈 환경에서도 지표가 나오는가
# 실행: bash ~/projects/jarvis/infra/scripts/test-self-heal-retro.sh
set -uo pipefail
PASSED=0 FAILURES=0
ok() { PASSED=$((PASSED+1)); }
fail() { FAILURES=$((FAILURES+1)); echo "  ✗ $*"; }
expect_eq() { [[ "$2" == "$3" ]] && ok || fail "$1: expected [$3] got [$2]"; }
expect_has() { [[ "$2" == *"$3"* ]] && ok || fail "$1: [$3] 없음 ← $2"; }
expect_not() { [[ "$2" != *"$3"* ]] && ok || fail "$1: [$3] 있으면 안 됨 ← $2"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export BOT_HOME="$T/runtime"
mkdir -p "$BOT_HOME/logs" "$BOT_HOME/ledger" "$BOT_HOME/results/task-outcomes" "$BOT_HOME/state" "$BOT_HOME/wiki/meta"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$HERE/self-heal-weekly-retro.sh"
CTL="$HERE/incident-ctl.sh"
LEDGER="$BOT_HOME/ledger/self-heal-retro.jsonl"
export JARVIS_NO_EXTERNAL=1

ep() { date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null || date -d "$1" +%s; }
NOW=$(ep '2026-09-14 12:00:00')   # 월요일 정오
export JARVIS_RETRO_NOW=$NOW

echo "== 0. 빈 환경 — 원장·로그가 하나도 없어도 지표 5개는 나온다"
out=$(bash "$SCRIPT" --dry-run daily 2>&1); rc=$?
expect_eq "빈 환경 rc" "$rc" "0"
expect_has "① 표본 0" "$out" "① 오탐 티켓 비율 표본 0"
expect_has "② 표본 0" "$out" "② 코더 리뷰 통과율 표본 0"
expect_has "③ 무한" "$out" "③ 설정 변조 감지 시간 무한 (감사 미실행)"
expect_has "④ 표본 0" "$out" "④ 사고 닫힘률 표본 0"
expect_has "⑤ 표본 0" "$out" "⑤ 크론 성공률 표본 0"
expect_has "감시자 없음" "$out" "🫀 감시자: 생존 0 · 침묵 0 · 보류 0"
expect_has "질문 없음" "$out" "❓ 주인님께 여쭐 것 없음"
[[ ! -f "$LEDGER" ]] && ok || fail "dry-run 이 원장을 썼다"

echo "== 1. 픽스처 — 창 안 7일 + 창 밖(8일 전) 데이터"
# cron.log: 창 안 START 10 · SUCCESS 8 · FAILED 2(줄 3개) / 창 밖 START 5 SUCCESS 0
{
    for i in 1 2 3 4 5; do echo "[2026-09-05 10:0${i}:00] [old-$i] START"; echo "[2026-09-05 10:0${i}:30] [old-$i] FAILED (exit: 1)"; done
    for i in 1 2 3 4 5 6 7 8; do echo "[2026-09-1$((i % 4)) 10:0${i}:00] [t-$i] START"; echo "[2026-09-1$((i % 4)) 10:0${i}:30] [t-$i] SUCCESS (duration=3s)"; done
    echo "[2026-09-12 11:00:00] [bad-1] START"; echo "[2026-09-12 11:00:20] [bad-1] [FAILED:TIMEOUT] exit=1 retries=3"
    echo "[2026-09-13 11:00:00] [bad-2] START"; echo "[2026-09-13 11:00:20] [bad-2] [FAILED:BUDGET_EXCEEDED] exit=1 retries=3"; echo "[2026-09-13 11:00:21] [bad-2] FAILED (exit: 1)"
} > "$BOT_HOME/logs/cron.log"
# tracker: 창 안 신규 티켓 3 · 창 밖 2
{
    echo "[2026-09-05 23:20:00] 신규 티켓 생성: debug-cron-old-1"; echo "[2026-09-05 23:20:01] 신규 티켓 생성: debug-cron-old-2"
    echo "[2026-09-10 23:20:00] 신규 티켓 생성: debug-cron-a"; echo "[2026-09-11 23:20:00] 기존 티켓 유지: debug-cron-a"
    echo "[2026-09-12 23:20:00] 신규 티켓 생성: debug-cron-b"; echo "[2026-09-13 23:20:00] 신규 티켓 생성: debug-cron-c"
} > "$BOT_HOME/logs/cron-failure-tracker.log"
# auditor: 마지막 요약의 mismatch 만 (이전 실행 값 4 는 무시)
printf '## [요약]\n  DB-로그 불일치(mismatch): 4  — 옛 값\n## [요약]\n  OK: 60  /  ISSUE: 9\n  DB-로그 불일치(mismatch): 2  — 감사 판정 오탐 지표\n' > "$BOT_HOME/logs/cron-auditor.log"
# 코더 결과: 창 안 오탐 1 · 정상 1 · 창 밖 오탐 1 · contract/verify 파일은 제외
mk_outcome() { jq -nc --arg id "$1" --arg ts "$2" --arg r "$3" '{task_id:$id, timestamp:$ts, status:"done", result_content:$r}' > "$BOT_HOME/results/task-outcomes/$4"; }
mk_outcome debug-cron-a "2026-09-11T01:00:00Z" $'오탐: stale-watcher 가 성공한 태스크를 failed 로 찍음\n근거…' "2026-09-11-debug-cron-a.json"
mk_outcome debug-cron-b "2026-09-13T01:00:00Z" $'# Task\n원인: 스크립트 경로 오타 수정' "2026-09-13-debug-cron-b.json"
mk_outcome debug-cron-old-1 "2026-09-05T01:00:00Z" $'오탐: 옛날 것' "2026-09-05-debug-cron-old-1.json"
mk_outcome debug-cron-a "2026-09-11T01:10:00Z" $'오탐: 계약 파일' "2026-09-11-debug-cron-a-contract.json"
mk_outcome verify-debug-cron-a "2026-09-11T01:20:00Z" $'오탐: 검증 파일' "2026-09-11-verify-debug-cron-a.json"
# 리뷰 원장: 창 안 merge 3 · reject 1(사유) · needs_human 1 · expired(무시) / 창 밖 reject 1
{
    echo '{"ts":"2026-09-05T22:30:00Z","task":"old","verdict":"reject","reasons":["옛 반려"]}'
    echo '{"ts":"2026-09-10T22:30:00Z","task":"r1","verdict":"merge","reasons":[]}'
    echo '{"ts":"2026-09-11T22:30:00Z","task":"r2","verdict":"merge","reasons":[]}'
    echo '{"ts":"2026-09-12T22:30:00Z","task":"r3","verdict":"merge","reasons":[]}'
    echo '{"ts":"2026-09-12T22:31:00Z","task":"r4","verdict":"reject","reasons":["테스트 없음","범위 밖 파일 수정"]}'
    echo '{"ts":"2026-09-13T22:30:00Z","task":"r5","verdict":"needs_human","reasons":["정책표 manual_forever"]}'
    echo '{"ts":"2026-09-13T22:31:00Z","task":"r6","verdict":"expired","reasons":[]}'
} > "$BOT_HOME/ledger/coder-review.jsonl"
# 무결성 감사: 창 안 3회(9/11 01:07, 9/12 01:07, 9/13 01:07), 9/12 행이 mtime 9/11 20:00(로컬) 변경을 감지 → 지연 5.1h
tz_off=$(date +%z | awk '{s=substr($1,1,1)=="-"?-1:1; printf "%d", s*(substr($1,2,2)*3600+substr($1,4,2)*60)}')
mk_audit() { jq -nc --arg ts "$1" --argjson u "$(jq -n --arg t "$1" '$t|fromdateiso8601')" --argjson d "$2" --arg m "$3" --argjson miss "$4" \
    '{ts:$ts, ts_unix:$u, audit:{missing_scripts:$miss, policy_ghost:[]}, integrity:{count_delta:$d, mtime:$m, changed:[], added:[], removed:[]}}'; }
local_m=$(date -r $(( $(jq -n '"2026-09-11T20:00:00Z"|fromdateiso8601') - 0 )) +'%Y-%m-%d %H:%M:%S' 2>/dev/null)
# 로컬 mtime 문자열은 UTC 2026-09-11T20:00:00Z 를 로컬로 표현한 것 — 스크립트가 오프셋을 빼서 다시 UTC 로 돌린다
{
    mk_audit "2026-09-04T01:07:00Z" 0 "2026-09-01 00:00:00" '[]'
    mk_audit "2026-09-11T01:07:00Z" 0 "2026-09-01 00:00:00" '[]'
    mk_audit "2026-09-12T01:07:00Z" 2 "$local_m" '["x.sh"]'
    mk_audit "2026-09-13T01:07:00Z" 0 "$local_m" '[]'
} > "$BOT_HOME/ledger/tasks-integrity-audit.jsonl"
# 사고 원장: 창 안 열림 4 (닫힘 2 · 폐기 1 · 미닫힘 high 1) / 창 밖 열림 1 미닫힘
_inc() { local at="$1"; shift; JARVIS_INCIDENT_NOW="$at" bash "$CTL" "$@" >/dev/null 2>&1 || { echo "  ! incident-ctl 실패: $*"; return 1; }; }
_inc 2026-09-04T00:00:00Z open --source manual --key old-1 --title "옛 사고" --severity low
_inc 2026-09-10T00:00:00Z open --source manual --key w-1 --title "닫힐 사고 1" --severity med
_inc 2026-09-11T00:00:00Z open --source manual --key w-2 --title "닫힐 사고 2" --severity low
_inc 2026-09-12T00:00:00Z open --source manual --key w-3 --title "폐기될 사고" --severity low
_inc 2026-09-13T00:00:00Z open --source manual --key w-4 --title "미닫힘 high" --severity high
_inc 2026-09-10T12:00:00Z close w-1 --fix abc1234 --cause "원인 1"
_inc 2026-09-11T12:00:00Z close w-2 --fix abc1235 --cause "원인 2"
_inc 2026-09-12T12:00:00Z discard w-3 --reason "시험"
# 데드맨 마지막 행 · 자동 머지 원장(docs merged 2 → 스트릭 2/3)
echo '{"ts":"2026-09-14T02:30:00Z","alive":10,"dead":["hook-canary"],"unknown":["x-1"],"opened":["inc-1"]}' > "$BOT_HOME/ledger/sensor-deadman.jsonl"
{
    echo '{"ts":"2026-09-10T00:00:00Z","task":"d1","action":"merged","class":"docs","approved_by":"human"}'
    echo '{"ts":"2026-09-11T00:00:00Z","task":"d2","action":"merged","class":"docs","approved_by":"human"}'
    echo '{"ts":"2026-09-11T00:00:00Z","task":"s1","action":"dry_run","class":"scripts","approved_by":"human"}'
} > "$BOT_HOME/ledger/coder-merge.jsonl"

echo "== 2. 지표 계산"
out=$(bash "$SCRIPT" --dry-run 2>&1); rc=$?
expect_eq "rc" "$rc" "0"
expect_has "머리" "$out" "🪞 **주간 자기치유 회고** 09-14 — 지난 7일 (09-07~09-14) (dry-run)"
expect_has "① = (2+1)/(3+2)" "$out" "① 오탐 티켓 비율 3/5 = 60% — mismatch 2 · 코더 '오탐:' 1 · 신규 티켓 3 · 사고 폐기 1"
expect_has "② = 3/5, 반려 사유" "$out" "② 코더 리뷰 통과율 3/5 = 60% — merge 3 · reject 1 · needs_human 1 · 반려 사유: 범위 밖 파일 수정 / 테스트 없음"
expect_has "③ 감지 지연 5.1h, 감사 3회" "$out" "③ 설정 변조 감지 시간 5.1h (변경 1건 감지, 감사 3회 · 최대 간격 "
expect_has "④ = 2/3 (폐기 제외)" "$out" "④ 사고 닫힘률 2/3 = 66% — 이번 주 열림 3 · 닫힘 2 · 재발 0"
expect_has "⑤ = 8/10, 실패 표식 3줄" "$out" "⑤ 크론 성공률 8/10 = 80% — SUCCESS 8 / START 10 (실패 표식 3줄)"
expect_has "미닫힘 첫 줄" "$out" "🚨 미닫힘 사고 2건 (high 1"
expect_has "규칙 제안 줄" "$out" "📜 규칙 제안 대기 0건"
expect_has "감시자" "$out" "🫀 감시자: 생존 10 · 침묵 1 (hook-canary) · 보류 1 — 마지막 판정 2026-09-14T02:30:00Z"
expect_has "정책표 스트릭" "$out" "docs 2/3"
expect_has "정책표 제안은 수치로만" "$out" "변경 없음 — 근거 미달: ①오탐율(표본 5) ②리뷰(표본 5) ④닫힘률"
expect_has "질문 1 high 사고" "$out" "1. high 미닫힘 사고 1건"
expect_has "질문 2 침묵 센서" "$out" "2. 침묵 센서 1개(hook-canary)"
expect_has "질문 3 needs_human" "$out" "3. 코더 리뷰 needs_human 1건"
expect_not "질문은 3개까지" "$out" "  4. "

echo "== 3. 원장 행 + --json"
row=$(bash "$SCRIPT" --json); rc=$?
expect_eq "json rc" "$rc" "0"
expect_eq "원장 1행" "$(wc -l < "$LEDGER" | tr -d ' ')" "1"
expect_eq "json fp" "$(echo "$row" | jq -c '.metrics.false_positive | [.num,.den,.pct,.tickets,.mismatch,.coder_false,.discarded]')" "[3,5,60,3,2,1,1]"
expect_eq "json review" "$(echo "$row" | jq -c '.metrics.review | [.merge,.reject,.needs_human,.pct]')" "[3,1,1,60]"
expect_eq "json audit" "$(echo "$row" | jq -c '.metrics.config_detect | [.runs,.changes,.max_detect_h,.critical]')" "[3,1,5.1,1]"
expect_eq "json incidents" "$(echo "$row" | jq -c '.metrics.incidents | [.opened,.closed,.discarded,.open_high,.pct]')" "[3,2,1,1,66]"
expect_eq "json cron" "$(echo "$row" | jq -c '.metrics.cron | [.start,.success,.failed_lines,.pct]')" "[10,8,3,80]"
expect_eq "json gate_ok" "$(echo "$row" | jq '.gate_ok')" "false"
expect_eq "json questions 3" "$(echo "$row" | jq '.questions|length')" "3"
expect_eq "json autonomy docs" "$(echo "$row" | jq -c '.autonomy.docs')" '{"streak":2,"threshold":3}'

echo "== 4. 전주 비교 — 다음 주 실행이 직전 행과 비교해 ▲▼ 를 붙인다"
NEXT=$(( NOW + 7 * 86400 ))
{
    for i in 1 2 3 4 5 6 7 8 9; do echo "[2026-09-1$((5 + i % 5)) 10:0${i}:00] [n-$i] START"; echo "[2026-09-1$((5 + i % 5)) 10:0${i}:30] [n-$i] SUCCESS (duration=3s)"; done
    echo "[2026-09-19 11:00:00] [n-bad] START"; echo "[2026-09-19 11:00:20] [n-bad] FAILED (exit: 1)"
} >> "$BOT_HOME/logs/cron.log"
out=$(JARVIS_RETRO_NOW=$NEXT bash "$SCRIPT" --dry-run 2>&1)
expect_has "⑤ 90% ▲ (전주 80%)" "$out" "⑤ 크론 성공률 9/10 = 90% — SUCCESS 9 / START 10 (실패 표식 1줄)  [목표 ≥95%] (전주 80% ▲)"
expect_has "① 다음 주는 mismatch 만 남음 (전주 60% ▲)" "$out" "① 오탐 티켓 비율 2/2 = 100% — mismatch 2 · 코더 '오탐:' 0 · 신규 티켓 0 · 사고 폐기 0  [목표 <10%] (전주 60% ▲)"
expect_has "④ 표본 0 → 비교 없음" "$out" "④ 사고 닫힘률 표본 0"
expect_not "표본 0 에 화살표 없음" "$out" "④ 사고 닫힘률 표본 0 — 이번 주 열림 0 · 닫힘 0 · 재발 0  [목표 ≥80%] (전주"
expect_eq "dry-run 은 원장 그대로 1행" "$(wc -l < "$LEDGER" | tr -d ' ')" "1"

echo "== 5. 정책표 제안 — 조건 충족 주는 '다음 주도 충족하면', 2주 연속이면 완화 권고"
# 조건: ① <10% 표본≥10, ② ≥80% 표본≥5, ④ ≥80%. 원장을 조건 충족 상태로 바꾼다.
printf '## [요약]\n  DB-로그 불일치(mismatch): 0\n' > "$BOT_HOME/logs/cron-auditor.log"
: > "$BOT_HOME/logs/cron-failure-tracker.log"
for i in $(seq 1 12); do echo "[2026-09-1$((i % 4)) 23:20:00] 신규 티켓 생성: debug-cron-g$i" >> "$BOT_HOME/logs/cron-failure-tracker.log"; done
rm -f "$BOT_HOME/results/task-outcomes/2026-09-11-debug-cron-a.json"
{
    for i in 1 2 3 4 5; do echo "{\"ts\":\"2026-09-1$((i % 4))T22:30:00Z\",\"task\":\"g$i\",\"verdict\":\"merge\",\"reasons\":[]}"; done
} > "$BOT_HOME/ledger/coder-review.jsonl"
_inc 2026-09-13T12:00:00Z close w-4 --fix abc1236 --cause "원인 4"
out=$(bash "$SCRIPT" --dry-run 2>&1)
expect_has "① 0/12 = 0%" "$out" "① 오탐 티켓 비율 0/12 = 0%"
expect_has "② 5/5" "$out" "② 코더 리뷰 통과율 5/5 = 100%"
expect_has "④ 3/3" "$out" "④ 사고 닫힘률 3/3 = 100%"
expect_has "이번 주 충족 → 다음 주 보자" "$out" "변경 없음 — 이번 주 조건 충족, 다음 주도 충족하면 완화 제안"
bash "$SCRIPT" --json >/dev/null   # 충족 행을 원장에 남긴다
expect_eq "원장 2행" "$(wc -l < "$LEDGER" | tr -d ' ')" "2"
expect_eq "gate_ok true" "$(tail -1 "$LEDGER" | jq '.gate_ok')" "true"
out=$(bash "$SCRIPT" --dry-run 2>&1)
expect_has "2주 연속 → 완화 권고(승인 후)" "$out" "권고: 2주 연속 조건 충족 — tests·docs 문턱 1 완화 검토(주인님 승인 후 coder-autonomy.json 편집)"
expect_has "질문은 침묵 센서만 남음" "$out" "1. 침묵 센서 1개(hook-canary)"
expect_not "high 질문은 사라짐" "$out" "high 미닫힘 사고"

echo "== 6. 옵션"
out=$(bash "$SCRIPT" --bogus 2>&1); rc=$?
expect_eq "모르는 옵션 rc 1" "$rc" "1"
expect_has "모르는 옵션 메시지" "$out" "알 수 없는 옵션: --bogus"
out=$(bash "$SCRIPT" --dry-run --window-days 1 2>&1)
expect_has "창 1일 머리" "$out" "지난 1일 (09-13~09-14)"

echo
echo "PASSED=$PASSED FAILURES=$FAILURES"
[[ $FAILURES -eq 0 ]]
