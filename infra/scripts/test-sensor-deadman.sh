#!/usr/bin/env bash
# test-sensor-deadman.sh — 데드맨 스위치(4c) 회귀 테스트: sensor-deadman-check.sh
#
# 검증 (임시 BOT_HOME, 시각은 JARVIS_DEADMAN_NOW 로 고정, 외부 송출 없음):
#   주간(요일 HH:MM)·매일(* HH:MM)·age 판정 / 유예(grace) / 파일 없음 = 죽음 / FLOOR 이전은 보류(사고 없음)
#   죽음 → 사고 1건(멱등, 재실행 중복 없음) / 회복 표시(자동 close 없음) / dry-run 무기록 / 월요일·--report 는 전부 생존이어도 출력
# 실행: bash ~/projects/jarvis/infra/scripts/test-sensor-deadman.sh
set -uo pipefail
PASSED=0 FAILURES=0
ok() { PASSED=$((PASSED+1)); }
fail() { FAILURES=$((FAILURES+1)); echo "  ✗ $*"; }
expect_eq() { [[ "$2" == "$3" ]] && ok || fail "$1: expected [$3] got [$2]"; }
expect_has() { [[ "$2" == *"$3"* ]] && ok || fail "$1: [$3] 없음 ← $2"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export BOT_HOME="$T/runtime"
mkdir -p "$BOT_HOME/logs" "$BOT_HOME/ledger"
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/sensor-deadman-check.sh"
CTL="$(dirname "$SCRIPT")/incident-ctl.sh"
LEDGER="$BOT_HOME/ledger/sensor-deadman.jsonl"
INC="$BOT_HOME/ledger/incidents.jsonl"

ep() { date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null || date -d "$1" +%s; }
set_mtime() { local f="$1" e="$2"; : > "$f"; touch -t "$(date -r "$e" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$e" +%Y%m%d%H%M.%S)" "$f"; }
LIST="$T/list.txt"
export JARVIS_DEADMAN_LIST="$LIST" JARVIS_DEADMAN_FLOOR="1970-01-01T00:00:00Z" JARVIS_DEADMAN_GRACE_MIN=90
WED=$(ep '2026-09-09 12:00:00')   # 수요일 정오
export JARVIS_DEADMAN_NOW=$WED

echo "== 1. 주간·매일·age 판정"
cat > "$LIST" <<EOF
# name|path|kind|spec|note
wk-ok|logs/wk-ok.log|expect|1 09:20|월 09:20 산 것
wk-dead|logs/wk-dead.log|expect|1 09:20|월 09:20 죽은 것
dy-ok|logs/dy-ok.log|expect|* 05:00|매일 05:00 산 것
dy-dead|logs/dy-dead.log|expect|* 05:00|매일 05:00 어제만
missing|logs/none.log|expect|* 05:00|파일 없음
age-ok|ledger/age-ok.jsonl|age|36|36시간 이내
age-dead|ledger/age-dead.jsonl|age|36|40시간 전
EOF
set_mtime "$BOT_HOME/logs/wk-ok.log"   "$(ep '2026-09-07 09:25:00')"
set_mtime "$BOT_HOME/logs/wk-dead.log" "$(ep '2026-08-31 09:25:00')"
set_mtime "$BOT_HOME/logs/dy-ok.log"   "$(ep '2026-09-09 05:03:00')"
set_mtime "$BOT_HOME/logs/dy-dead.log" "$(ep '2026-09-08 05:03:00')"
set_mtime "$BOT_HOME/ledger/age-ok.jsonl"   $(( WED - 10 * 3600 ))
set_mtime "$BOT_HOME/ledger/age-dead.jsonl" $(( WED - 40 * 3600 ))
out=$(bash "$SCRIPT" --dry-run); rc=$?
expect_eq "dry-run rc" "$rc" "0"
expect_has "요약" "$out" "생존 3 · 침묵 4 · 보류 0"
expect_has "주간 죽음 기대 시각" "$out" "wk-dead: 마지막 08-31 09:25 (9일 전) · 기대 09-07 09:20"
expect_has "매일 죽음" "$out" "dy-dead: 마지막 09-08 05:03"
expect_has "파일 없음" "$out" "missing: 파일 없음 · 기대 09-09 05:00"
expect_has "age 죽음" "$out" "age-dead: 마지막 09-07 20:00 (40시간 전) · 허용 36시간"
[[ "$out" != *"wk-ok:"* && "$out" != *"dy-ok:"* && "$out" != *"age-ok:"* ]] && ok || fail "산 것이 목록에: $out"
[[ ! -f "$LEDGER" && ! -f "$INC" ]] && ok || fail "dry-run 이 원장을 썼다"
expect_has "dry 사고 예고" "$out" "(dry) deadman:wk-dead"

echo "== 2. 유예(grace): 기대 시각 직후엔 전날 실행을 본다"
out=$(JARVIS_DEADMAN_NOW=$(ep '2026-09-09 05:30:00') bash "$SCRIPT" --dry-run --report)
expect_has "05:30 엔 dy-dead 도 생존(기대 09-08 05:00)" "$out" "생존: "
[[ "$out" != *"dy-dead:"* ]] && ok || fail "유예 안 먹음: $out"
out=$(JARVIS_DEADMAN_NOW=$(ep '2026-09-09 06:31:00') bash "$SCRIPT" --dry-run)
expect_has "06:31 엔 오늘 05:00 기대 → dy-dead 죽음" "$out" "dy-dead: 마지막 09-08 05:03 (25시간 전) · 기대 09-09 05:00"

echo "== 3. 실제 실행 — 사고 open + 원장 행"
out=$(bash "$SCRIPT"); rc=$?
expect_eq "rc" "$rc" "0"
expect_has "사고 등재 줄" "$out" "사고 등재: inc-"
expect_eq "사고 4건 open" "$(bash "$CTL" count)" "4"
st=$(bash "$CTL" list --json)
expect_eq "source deadman" "$(jq -r '[.[] | .source] | unique | join(",")' <<<"$st")" "deadman"
expect_eq "severity high" "$(jq -r '[.[] | .severity] | unique | join(",")' <<<"$st")" "high"
expect_eq "key 형식" "$(jq -r '[.[] | .key] | sort | join(",")' <<<"$st")" "deadman:age-dead,deadman:dy-dead,deadman:missing,deadman:wk-dead"
expect_eq "기대 시각 evidence(UTC)" "$(jq -r '.[] | select(.key=="deadman:wk-dead") | .evidence.expected_iso' <<<"$st")" "2026-09-07T00:20:00Z"
expect_eq "파일 없음 mtime 0" "$(jq -r '.[] | select(.key=="deadman:missing") | .evidence.mtime' <<<"$st")" "0"
[[ "$(jq -r '.[] | select(.key=="deadman:wk-dead") | .title' <<<"$st")" == "감시자 침묵: wk-dead — 마지막 08-31 09:25"* ]] && ok || fail "제목"
expect_eq "원장 1행" "$(wc -l < "$LEDGER" | tr -d ' ')" "1"
expect_eq "원장 dead 목록" "$(jq -r '.dead | join(",")' "$LEDGER")" "wk-dead,dy-dead,missing,age-dead"
expect_eq "원장 alive 수" "$(jq -r '.alive' "$LEDGER")" "3"
expect_eq "원장 rows 7" "$(jq '.rows | length' "$LEDGER")" "7"

echo "== 4. 재실행 = 사고 중복 없음, 원장 행만 누적"
out=$(bash "$SCRIPT")
expect_eq "여전히 4건" "$(bash "$CTL" count)" "4"
[[ "$out" != *"사고 등재"* ]] && ok || fail "재실행에 등재 줄: $out"
expect_eq "원장 2행" "$(wc -l < "$LEDGER" | tr -d ' ')" "2"

echo "== 5. 회복 — 파일이 다시 갱신되면 회복 표시, 자동 close 는 없다"
set_mtime "$BOT_HOME/logs/wk-dead.log" "$(ep '2026-09-09 11:00:00')"
out=$(bash "$SCRIPT")
expect_has "회복 줄" "$out" "💚 회복 inc-"
expect_has "회복 이름" "$out" "wk-dead — 마지막 09-09 11:00"
expect_has "닫는 법 안내" "$out" "incident-ctl.sh close"
expect_eq "자동 close 없음(아직 4건)" "$(bash "$CTL" count)" "4"
bash "$CTL" close "deadman:wk-dead" --fix "crontab 복구 abc1234" >/dev/null
expect_eq "사람이 닫음" "$(bash "$CTL" count)" "3"
out=$(bash "$SCRIPT" --report)
[[ "$out" != *"💚 회복"* ]] && ok || fail "닫힌 뒤엔 회복 표시 안 함: $out"
# 닫힌 뒤 다시 침묵하면 재발
set_mtime "$BOT_HOME/logs/wk-dead.log" "$(ep '2026-08-31 09:25:00')"
out=$(JARVIS_DEADMAN_NOW=$(ep '2026-09-16 12:00:00') bash "$SCRIPT")
expect_has "재발 등재" "$out" "deadman:wk-dead (재발)"
expect_eq "recurrences 1" "$(bash "$CTL" show "deadman:wk-dead" | jq -r .recurrences)" "1"

echo "== 6. FLOOR — 소실 구간 이전은 보류(사고 없음)"
rm -f "$INC" "$LEDGER"
cat > "$LIST" <<EOF
wk-old|logs/wk-old.log|expect|1 09:20|복원 전
age-old|ledger/age-old.jsonl|age|36|복원 전
EOF
set_mtime "$BOT_HOME/logs/wk-old.log" "$(ep '2026-08-17 09:25:00')"
set_mtime "$BOT_HOME/ledger/age-old.jsonl" "$(ep '2026-08-17 09:25:00')"
out=$(JARVIS_DEADMAN_FLOOR="2026-09-08T00:00:00+09:00" bash "$SCRIPT")
expect_eq "보류만 있는 날은 무출력" "$out" ""
out=$(JARVIS_DEADMAN_FLOOR="2026-09-08T00:00:00+09:00" bash "$SCRIPT" --report)
expect_has "보류 2" "$out" "생존 0 · 침묵 0 · 보류 2"
expect_has "보류 사유" "$out" "❔ wk-old: 마지막 08-17 09:25 (23일 전) · 기대 09-07 09:20 — 소실 구간(2026-09-08 이전) 이라 판단 보류"
expect_eq "보류는 사고 아님" "$(bash "$CTL" count)" "0"
expect_eq "원장 unknown(무출력 실행도 행을 남긴다)" "$(tail -1 "$LEDGER" | jq -r '.unknown | join(",")')" "wk-old,age-old"
expect_eq "원장 2행" "$(wc -l < "$LEDGER" | tr -d ' ')" "2"
# FLOOR 이후 기대 시각을 넘기면 죽음으로 바뀐다
out=$(JARVIS_DEADMAN_FLOOR="2026-09-08T00:00:00+09:00" JARVIS_DEADMAN_NOW=$(ep '2026-09-14 12:00:00') bash "$SCRIPT")
expect_has "다음 월요일 지나면 죽음" "$out" "💀 wk-old: 마지막 08-17 09:25 (28일 전) · 기대 09-14 09:20"
expect_has "age 는 FLOOR 부터 센다(9/8 + 36h 지남)" "$out" "💀 age-old:"
expect_eq "사고 2건" "$(bash "$CTL" count)" "2"

echo "== 7. 전부 생존이면 침묵, 월요일·--report 는 출력"
rm -f "$INC" "$LEDGER"
cat > "$LIST" <<EOF
dy-ok|logs/dy-ok.log|expect|* 05:00|산 것
EOF
out=$(bash "$SCRIPT"); rc=$?
expect_eq "무출력 rc" "$rc" "0"; expect_eq "무출력" "$out" ""
expect_eq "무출력이어도 원장 행" "$(wc -l < "$LEDGER" | tr -d ' ')" "1"
out=$(bash "$SCRIPT" --report)
expect_has "--report 요약" "$out" "생존 1 · 침묵 0 · 보류 0 · 회복 0"
expect_has "--report 생존 목록" "$out" "생존: dy-ok"
set_mtime "$BOT_HOME/logs/dy-ok.log" "$(ep '2026-09-07 05:03:00')"
out=$(JARVIS_DEADMAN_NOW=$(ep '2026-09-07 11:30:00') bash "$SCRIPT")
expect_has "월요일은 전부 생존이어도 보고" "$out" "감시자 생존 점검** 09-07 11:30 — 생존 1"
expect_has "월요일 생존 목록" "$out" "생존: dy-ok"

echo "== 8. 잘못된 입력"
cat > "$LIST" <<EOF
bad|logs/x.log|weird|1|?
dy-ok|logs/dy-ok.log|expect|* 05:00|산 것
EOF
set_mtime "$BOT_HOME/logs/dy-ok.log" "$(ep '2026-09-09 05:03:00')"
out=$(bash "$SCRIPT" --report 2>"$T/err"); rc=$?
expect_eq "모르는 kind 는 건너뛰고 계속" "$rc" "0"
expect_has "kind 경고" "$(cat "$T/err")" "알 수 없는 kind: weird (bad)"
expect_has "나머지는 판정" "$out" "생존: dy-ok"
JARVIS_DEADMAN_LIST="$T/nope.txt" bash "$SCRIPT" >/dev/null 2>&1; expect_eq "목록 파일 없음 rc" "$?" "1"
bash "$SCRIPT" --bogus >/dev/null 2>&1; expect_eq "미지 옵션 rc" "$?" "1"

echo
echo "PASSED=$PASSED FAILURES=$FAILURES"
