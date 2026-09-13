#!/usr/bin/env bash
# test-incident-ledger.sh — 사고 원장(4a) 회귀 테스트: incident-ledger.sh · incident-ctl.sh · incident-ingest.sh
#
# 검증 대상 (임시 BOT_HOME, 외부 송출 없음):
#   open 멱등(같은 key 1건) / close 는 --fix 없이는 거부 / 닫힌 key 재등장 → 재발(reopen, recurrences+1)
#   update 는 id·key·closed_at 을 못 바꿈 / discard 는 닫힘으로 세지 않음 / list·count·summary 형식
#   ingest: 가드 차단(canary 무시·severity 매핑) · 리뷰 reject · 머지 blocked · 무결성 critical/missing/ghost
#           같은 경보가 여러 행이어도 1건 · 재실행 0건 · --since 창 · --dry-run 무기록 · 무출력(신규 없음)
# 실행: bash ~/projects/jarvis/infra/scripts/test-incident-ledger.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
INFRA="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d /var/tmp/incident-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
PASSED=0; FAILURES=0
ok()   { PASSED=$((PASSED+1)); }
fail() { FAILURES=$((FAILURES+1)); echo "  ✗ $*"; }
expect_eq() { [[ "$2" == "$3" ]] && ok || fail "$1: expected [$3] got [$2]"; }

export BOT_HOME="$T/runtime"
mkdir -p "$BOT_HOME"/{ledger,state}
export JARVIS_NO_EXTERNAL=1
CTL="$INFRA/scripts/incident-ctl.sh"
INGEST="$INFRA/scripts/incident-ingest.sh"
LEDGER="$BOT_HOME/ledger/incidents.jsonl"
# shellcheck source=../lib/incident-ledger.sh
source "$INFRA/lib/incident-ledger.sh"

echo "== 1. open 멱등 + id 형식"
out=$(bash "$CTL" open --source manual --key "manual:t1" --title "첫 사고" --severity high --cause "가설 A")
[[ "$out" == opened\ inc-*-* ]] && ok || fail "open 출력: $out"
id1=${out#opened }
out=$(bash "$CTL" open --source manual --key "manual:t1" --title "첫 사고(중복)")
expect_eq "같은 key 재open" "$out" "already-open $id1"
expect_eq "원장 행 수" "$(wc -l < "$LEDGER" | tr -d ' ')" "1"
expect_eq "count open" "$(bash "$CTL" count)" "1"
expect_eq "severity" "$(bash "$CTL" show "$id1" | jq -r .severity)" "high"
expect_eq "cause" "$(bash "$CTL" show "manual:t1" | jq -r .cause_hypothesis)" "가설 A"
expect_eq "by human(CLI 기본)" "$(bash "$CTL" show "$id1" | jq -r .opened_by)" "human"

echo "== 2. close 는 fix 필수"
bash "$CTL" close "$id1" >/dev/null 2>&1; expect_eq "fix 없이 close rc" "$?" "2"
expect_eq "여전히 open" "$(bash "$CTL" count)" "1"
out=$(bash "$CTL" close "$id1" --fix "abc1234" --cause "가설 B(확정)")
expect_eq "close" "$out" "closed $id1"
expect_eq "closed_at 채움" "$(bash "$CTL" show "$id1" | jq -r '.closed_at != null')" "true"
expect_eq "fix 기록" "$(bash "$CTL" show "$id1" | jq -r .structural_fix)" "abc1234"
expect_eq "cause 갱신" "$(bash "$CTL" show "$id1" | jq -r .cause_hypothesis)" "가설 B(확정)"
expect_eq "count open 0" "$(bash "$CTL" count)" "0"
expect_eq "count all 1" "$(bash "$CTL" count --all)" "1"
out=$(bash "$CTL" close "$id1" --fix "x"); expect_eq "재close" "$out" "already-closed $id1"

echo "== 3. 닫힌 key 재등장 = 재발"
out=$(bash "$CTL" open --source manual --key "manual:t1" --title "첫 사고 재발")
[[ "$out" == "recurred $id1 "* ]] && ok || fail "재발 출력: $out"
expect_eq "다시 open" "$(bash "$CTL" count)" "1"
expect_eq "recurrences" "$(bash "$CTL" show "$id1" | jq -r .recurrences)" "1"
expect_eq "fix 는 유지(재검토용)" "$(bash "$CTL" show "$id1" | jq -r .structural_fix)" "abc1234"
[[ "$(bash "$CTL" show "$id1" | jq -r '.notes[0]')" == 재발* ]] && ok || fail "재발 note"

echo "== 4. update 보호 필드"
bash "$CTL" update "$id1" --severity low --note "메모" >/dev/null
expect_eq "severity 변경" "$(bash "$CTL" show "$id1" | jq -r .severity)" "low"
expect_eq "note 누적" "$(bash "$CTL" show "$id1" | jq -r '.notes | length')" "2"
incident_update "$id1" '{"closed_at":"2020-01-01T00:00:00Z","id":"hack","key":"hack"}' >/dev/null
expect_eq "closed_at 은 update 로 못 닫음" "$(bash "$CTL" show "$id1" | jq -r '.closed_at')" "null"
expect_eq "id 불변" "$(bash "$CTL" show "$id1" | jq -r .id)" "$id1"
bash "$CTL" update "$id1" >/dev/null 2>&1; expect_eq "빈 update rc" "$?" "1"
bash "$CTL" update "없는것" --note x >/dev/null 2>&1; expect_eq "없는 대상 rc" "$?" "1"

echo "== 5. discard 는 닫힘과 구분"
bash "$CTL" open --source runtime-guard --key "runtime-guard:test" --title "시험 차단" >/dev/null
bash "$CTL" discard "runtime-guard:test" >/dev/null 2>&1; expect_eq "사유 없는 discard rc" "$?" "2"
out=$(bash "$CTL" discard "runtime-guard:test" --reason "시험 호출")
[[ "$out" == discarded\ inc-* ]] && ok || fail "discard: $out"
expect_eq "discarded" "$(bash "$CTL" show "runtime-guard:test" | jq -r .discarded)" "true"
expect_eq "open 은 1(t1만)" "$(bash "$CTL" count)" "1"
sum=$(bash "$CTL" summary)
[[ "$(head -1 <<<"$sum")" == "미닫힘 사고 1건 (high 0 · med 0 · low 1) — 닫힘 0건, 폐기(오탐·시험) 1건, 재발 1건" ]] && ok || fail "summary 첫 줄: $(head -1 <<<"$sum")"
[[ "$sum" == *"$id1 [manual/low] D+0 첫 사고"*"→ 수정 진행: abc1234"* ]] && ok || fail "summary 목록: $sum"
lst=$(bash "$CTL" list --all)
[[ "$(head -1 <<<"$lst")" == "사고 all: 2건" ]] && ok || fail "list 헤더: $(head -1 <<<"$lst")"
[[ "$lst" == *"✖ 폐기"*"시험 호출"* ]] && ok || fail "list 폐기 표기: $lst"
expect_eq "list --json 배열" "$(bash "$CTL" list --all --json | jq 'length')" "2"
expect_eq "list --source 필터" "$(bash "$CTL" list --all --source manual --json | jq 'length')" "1"
expect_eq "list --closed" "$(bash "$CTL" list --closed --json | jq 'length')" "1"

echo "== 6. 원장 깨진 행 무시"
echo 'not json' >> "$LEDGER"
echo '{"ev":"close","ts":"2026-01-01T00:00:00Z","id":"inc-없음"}' >> "$LEDGER"
expect_eq "깨진 행 뒤에도 state" "$(bash "$CTL" count --all)" "2"

echo "== 7. ingest — 센서 원장 4종"
rm -f "$LEDGER"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OLD="2026-01-01T00:00:00Z"
cat > "$BOT_HOME/state/runtime-guard.jsonl" <<EOF
{"ts":"$NOW","kind":"rm-r-child","cwd":"/tmp/guard-canary-1","segment":"rm -rf ~/.openclaw-data/runtime/zz-canary-nonexistent"}
{"ts":"$NOW","kind":"rm-root","cwd":"/tmp/bot-work/debug-x-1","segment":"rm -rf \"\$BOT_HOME\""}
{"ts":"$NOW","kind":"rm-root","cwd":"/tmp/bot-work/debug-x-2","segment":"rm -rf \"\$BOT_HOME\""}
{"ts":"$NOW","kind":"agent-git-base","role":"coder","cwd":"/x","segment":"git merge-base HEAD main"}
{"ts":"$OLD","kind":"agent-launchctl","role":"coder","cwd":"/x","segment":"launchctl bootout gui/501/com.old"}
EOF
cat > "$BOT_HOME/ledger/coder-review.jsonl" <<EOF
{"ts":"$NOW","task":"t-rej","branch":"coder/t-rej","tip":"deadbeefcafe0000","verdict":"reject","reasons":["테스트 없음","범위 초과"],"model":"m","risk":"high","class":"scripts"}
{"ts":"$NOW","task":"t-ok","branch":"coder/t-ok","tip":"0000","verdict":"merge","reasons":["ok"],"model":"m"}
EOF
cat > "$BOT_HOME/ledger/coder-merge.jsonl" <<EOF
{"ts":"$NOW","task":"t-blk","branch":"coder/t-blk","base":"main","action":"blocked","class":"scripts","approved_by":"human","files":[],"gates":{"syntax":"fail"},"reason":"게이트 실패: syntax"}
{"ts":"$NOW","task":"t-blk","branch":"coder/t-blk","base":"main","action":"blocked","class":"scripts","approved_by":"human","files":[],"gates":{"syntax":"fail"},"reason":"게이트 실패: syntax"}
{"ts":"$NOW","task":"t-dry","action":"dry_run","reason":"게이트 통과"}
{"ts":"$NOW","task":"t-mrg","action":"merged","reason":"ok"}
EOF
cat > "$BOT_HOME/ledger/tasks-integrity-audit.jsonl" <<EOF
{"ts":"$NOW","audit":{"missing_scripts":[{"id":"gone-task","script":"~/x/gone.sh"}],"policy_ghost":[{"label":"com.jarvis.ghosty","script":"x"}]},"integrity":{"level":"critical","reasons":["태스크 개수 -14 (136→122)"],"task_count":122,"prev_count":136,"removed":["a","b"]}}
{"ts":"$NOW","audit":{"missing_scripts":[],"policy_ghost":[{"label":"com.jarvis.ghosty","script":"x"}]},"integrity":{"level":"ok","reasons":[]}}
{"ts":"$OLD","audit":{"missing_scripts":[{"id":"ancient","script":"x"}]},"integrity":{"level":"critical","reasons":["옛날"]}}
EOF

out=$(bash "$INGEST" --dry-run); rc=$?
expect_eq "dry-run rc" "$rc" "0"
[[ ! -f "$LEDGER" ]] && ok || fail "dry-run 이 원장을 만들었다"
[[ "$out" == *"(dry-run) — 신규 7건"* ]] && ok || fail "dry-run 요약: $out"

out=$(bash "$INGEST"); rc=$?
expect_eq "ingest rc" "$rc" "0"
[[ "$out" == *"신규 7건 · 재발 0건 · 미닫힘 총 7건"* ]] && ok || fail "요약: $out"
expect_eq "open 7" "$(bash "$CTL" count)" "7"
st=$(bash "$CTL" list --all --json)
expect_eq "canary 무시" "$(jq '[.[] | select(.title | test("canary"))] | length' <<<"$st")" "0"
expect_eq "rm-root 1건(중복 행 합침)" "$(jq '[.[] | select(.key | startswith("runtime-guard:rm-root"))] | length' <<<"$st")" "1"
expect_eq "rm-root high" "$(jq -r '.[] | select(.key | startswith("runtime-guard:rm-root")) | .severity' <<<"$st")" "high"
expect_eq "git-base low" "$(jq -r '.[] | select(.key | startswith("runtime-guard:agent-git-base")) | .severity' <<<"$st")" "low"
expect_eq "옛 launchctl 은 창 밖" "$(jq '[.[] | select(.key | contains("launchctl"))] | length' <<<"$st")" "0"
expect_eq "리뷰 reject 1" "$(jq '[.[] | select(.source=="coder-review")] | length' <<<"$st")" "1"
expect_eq "reject cause=reasons" "$(jq -r '.[] | select(.source=="coder-review") | .cause_hypothesis' <<<"$st")" "테스트 없음 / 범위 초과"
expect_eq "머지 blocked 1(중복 합침)" "$(jq '[.[] | select(.source=="coder-merge")] | length' <<<"$st")" "1"
expect_eq "무결성 critical 1" "$(jq '[.[] | select(.key | startswith("integrity:critical"))] | length' <<<"$st")" "1"
expect_eq "누락 스크립트 1(옛것 제외)" "$(jq '[.[] | select(.key | startswith("integrity:missing-script"))] | length' <<<"$st")" "1"
expect_eq "ghost 1(두 행 합침)" "$(jq '[.[] | select(.key | startswith("integrity:ghost-plist"))] | length' <<<"$st")" "1"
expect_eq "evidence 보존" "$(jq -r '.[] | select(.key | startswith("integrity:critical")) | .evidence.integrity.prev_count' <<<"$st")" "136"
expect_eq "opened_by auto" "$(jq -r '[.[] | .opened_by] | unique | join(",")' <<<"$st")" "auto"

echo "== 8. ingest 재실행 = 무출력·무변화"
n0=$(wc -l < "$LEDGER" | tr -d ' ')
out=$(bash "$INGEST"); rc=$?
expect_eq "재실행 rc" "$rc" "0"
expect_eq "재실행 무출력" "$out" ""
expect_eq "원장 무변화" "$(wc -l < "$LEDGER" | tr -d ' ')" "$n0"
out=$(bash "$INGEST" --verbose 2>/dev/null)
[[ "$out" == "신규 사고 없음 — 미닫힘 7건" ]] && ok || fail "verbose 무신규: $out"

echo "== 9. --since 창 확장 + 닫힌 뒤 재발"
out=$(bash "$INGEST" --since 400)
[[ "$out" == *"신규 3건"* ]] && ok || fail "--since 400: $out"
expect_eq "옛 launchctl 포함" "$(bash "$CTL" list --json | jq '[.[] | select(.key | contains("launchctl"))] | length')" "1"
bash "$CTL" close "integrity:ghost-plist:com.jarvis.ghosty" --fix "9ec0ed6" >/dev/null
expect_eq "닫음" "$(bash "$CTL" count)" "9"
# 같은 옛 행을 다시 훑어도 재발이 아니다 (센서 원장 재스캔 ≠ 새 사건)
out=$(bash "$INGEST" --since 400)
expect_eq "옛 행 재스캔은 무출력" "$out" ""
expect_eq "recurrences 0" "$(bash "$CTL" show "integrity:ghost-plist:com.jarvis.ghosty" | jq -r .recurrences)" "0"
# 닫힌 뒤(closed_at 이후) 새 행이 오면 재발
LATER=$(jq -rn 'now + 120 | todate')
echo "{\"ts\":\"$LATER\",\"audit\":{\"policy_ghost\":[{\"label\":\"com.jarvis.ghosty\",\"script\":\"x\"}]},\"integrity\":{\"level\":\"ok\"}}" >> "$BOT_HOME/ledger/tasks-integrity-audit.jsonl"
out=$(bash "$INGEST" --dry-run)
[[ "$out" == *"신규 0건 · 재발 1건"* ]] && ok || fail "dry-run 재발 예고: $out"
out=$(bash "$INGEST")
[[ "$out" == *"신규 0건 · 재발 1건"* && "$out" == *"🔁 재발"*"ghosty"* ]] && ok || fail "재발 출력: $out"
expect_eq "재발 후 open" "$(bash "$CTL" count)" "10"
expect_eq "recurrences" "$(bash "$CTL" show "integrity:ghost-plist:com.jarvis.ghosty" | jq -r .recurrences)" "1"
[[ "$(bash "$CTL" show "integrity:ghost-plist:com.jarvis.ghosty" | jq -r '.notes[-1]')" == "재발 ${LATER}:"* ]] && ok || fail "재발 note 에 사건 시각"

echo "== 10. 잘못된 인자"
bash "$INGEST" --since abc >/dev/null 2>&1; expect_eq "--since 비정수 rc" "$?" "1"
bash "$INGEST" --bogus >/dev/null 2>&1; expect_eq "미지 옵션 rc" "$?" "1"
bash "$CTL" >/dev/null 2>&1; expect_eq "ctl 무인자 rc" "$?" "1"
bash "$CTL" open --source x >/dev/null 2>&1; expect_eq "open 인자 부족 rc" "$?" "1"
bash "$CTL" open --source x --key k --title t --severity urgent >/dev/null 2>&1; expect_eq "severity 검증 rc" "$?" "2"

echo "== 11. ingest — 센서 크론 자체의 실패 (logs/cron.log)"
mkdir -p "$BOT_HOME/logs"
TODAY_L=$(date '+%Y-%m-%d')
cat > "$BOT_HOME/logs/cron.log" <<EOF
[${TODAY_L} 10:07:03] [tasks-integrity-audit] 시작
[${TODAY_L} 10:07:05] [tasks-integrity-audit] FAILED (exit: 2)
[${TODAY_L} 10:37:05] [tasks-integrity-audit] FAILED (exit: 2)
[${TODAY_L} 12:16:18] [daily-summary] FAILED (exit: 1)
[${TODAY_L} 20:00:42] [coder-review] [FAILED:TIMEOUT] exit=1 retries=3
[2026-01-01 03:00:00] [incident-ingest] FAILED (exit: 1)
[${TODAY_L} 11:00:00] [mistake-extractor] SUCCESS
EOF
before=$(bash "$CTL" count)
out=$(bash "$INGEST" --dry-run)
[[ "$out" == *"(dry-run) — 신규 2건"* ]] && ok || fail "cron-failed dry-run: $out"
out=$(bash "$INGEST")
[[ "$out" == *"신규 2건 · 재발 0건"* ]] && ok || fail "cron-failed 요약: $out"
expect_eq "open +2" "$(bash "$CTL" count)" "$((before + 2))"
cf=$(bash "$CTL" list --all --source cron-failed --json)
expect_eq "센서 실패 2건(같은 날 두 번 = 1건, daily-summary 제외, 옛 행 제외)" "$(jq 'length' <<<"$cf")" "2"
expect_eq "key 형식" "$(jq -r '[.[] | .key] | sort | join(",")' <<<"$cf")" "cron-failed:coder-review:${TODAY_L},cron-failed:tasks-integrity-audit:${TODAY_L}"
expect_eq "severity high" "$(jq -r '[.[] | .severity] | unique | join(",")' <<<"$cf")" "high"
expect_eq "exit 코드 보존" "$(jq -r '.[] | select(.key | contains("integrity")) | .evidence.exit' <<<"$cf")" "2"
expect_eq "timeout 종류 보존" "$(jq -r '.[] | select(.key | contains("coder-review")) | .evidence.kind' <<<"$cf")" "timeout"
[[ "$(jq -r '.[] | select(.key | contains("integrity")) | .title' <<<"$cf")" == *"미검출"* ]] && ok || fail "제목에 결과(미검출) 명시"
[[ "$(jq -r '.[] | select(.key | contains("integrity")) | .cause_hypothesis' <<<"$cf")" == *"수동 재실행"* ]] && ok || fail "cause 에 조치"
out=$(bash "$INGEST"); expect_eq "재실행 무출력" "$out" ""
out=$(bash "$INGEST" --since 400)
[[ "$out" == *"신규 1건"* ]] && ok || fail "--since 400 에 옛 incident-ingest 실패 포함: $out"
# 대상 태스크 목록은 환경변수로 바꿀 수 있다 (daily-summary 를 센서로 지정하면 잡힌다)
out=$(JARVIS_SENSOR_TASKS="daily-summary" bash "$INGEST" --dry-run)
[[ "$out" == *"신규 1건"*"daily-summary"* ]] && ok || fail "JARVIS_SENSOR_TASKS 재정의: $out"
# cron.log 가 없어도 죽지 않는다
rm -f "$BOT_HOME/logs/cron.log"
out=$(bash "$INGEST"); rc=$?; expect_eq "cron.log 없음 rc" "$rc" "0"

echo
echo "PASSED=$PASSED FAILURES=$FAILURES"
[[ $FAILURES -eq 0 ]]
