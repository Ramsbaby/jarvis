#!/usr/bin/env bash
# test-tasks-json-integrity.sh — tasks-json-integrity.sh 시나리오 테스트 (SELF-HEAL-PLAN 2d)
# 임시 BOT_HOME·백업 디렉터리에서만 돈다. 실제 tasks.json 은 읽기만 한다.
# 실행: bash ~/projects/jarvis/infra/scripts/test-tasks-json-integrity.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
INFRA="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SUT="$INFRA/scripts/tasks-json-integrity.sh"
T=$(mktemp -d /var/tmp/tji-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
export BOT_HOME="$T/rt" JARVIS_TASKS_BACKUP_DIR="$T/bk" JARVIS_NO_EXTERNAL=1
mkdir -p "$BOT_HOME"/{config,ledger,logs,state}
TASKS="$BOT_HOME/config/tasks.json"
PASSED=0; FAILURES=0
ok()   { PASSED=$((PASSED+1)); }
fail() { FAILURES=$((FAILURES+1)); echo "  ✗ $*"; }
expect_json() { # <설명> <jq 필터(true 여야 통과)>
    local out; out=$(bash "$SUT")
    if jq -e "$2" <<<"$out" >/dev/null 2>&1; then ok; else fail "$1 — got: $(jq -c '{level,task_count,count_delta,added:(.added|length),removed:(.removed|length),changed:(.changed|length),reasons}' <<<"$out")"; fi
}

# 합성 tasks.json — 실제 파일에 의존하지 않는다
mk() { # <n> → tasks t01..tNN
    jq -n --argjson n "$1" '{tasks: [range(1;$n+1) | {id: ("t" + (tostring|if length<2 then "0"+. else . end)), schedule: "0 0 * * *", script: "x.sh", enabled: true}]}'
}
mk 20 > "$TASKS"

echo "── 1) 첫 실행: 기준선 없음 → ok + 백업 1개"
expect_json "첫 실행" '.level=="ok" and .prev_sha256==null and .backup_written!=null and .backup_total==1 and .task_count==20'

echo "── 2) 변화 없음 → ok, 백업 추가 안 함"
expect_json "변화 없음" '.level=="ok" and .backup_written==null and .backup_total==1 and .count_delta==0'

echo "── 3) 옛 파일로 덮어쓰기 (12개 사라지고 3개 새로 생김) → critical + 복원 힌트"
BASE=$(ls "$JARVIS_TASKS_BACKUP_DIR"/tasks-*.json | head -1)
jq '.tasks |= (.[0:8] + [{id:"new1",script:"y.sh"},{id:"new2",script:"y.sh"},{id:"new3",script:"y.sh"}])' "$TASKS" > "$T/old.json" && cp "$T/old.json" "$TASKS"
expect_json "옛 파일 덮어쓰기" '.level=="critical" and .count_delta==-9 and (.removed|length)==12 and (.added|length)==3 and (.text|contains("복원: `cp"))'
[[ -f "$BASE" ]] && ok || fail "기준선 백업이 보존돼야 한다"
[[ $(ls "$JARVIS_TASKS_BACKUP_DIR"/tasks-*.json | wc -l) -eq 2 ]] && ok || fail "변조 상태도 백업돼야 한다 (2개)"

echo "── 4) 기준선으로 복원 → critical (되돌아온 것도 큰 변화) 후 다음 실행은 ok"
cp "$BASE" "$TASKS"
expect_json "복원 직후" '.level=="critical" and .count_delta==9'
expect_json "복원 후 안정" '.level=="ok"'

echo "── 5) 태스크 하나의 enabled 만 바꿈 → notice, 변경 id·필드 표시"
jq '(.tasks[] | select(.id=="t05") | .enabled) = false' "$TASKS" > "$T/one.json" && cp "$T/one.json" "$TASKS"
expect_json "필드 변경" '.level=="notice" and (.changed|length)==1 and .changed[0].id=="t05" and .changed[0].keys==["enabled"] and .enabled_count==19'

echo "── 6) 태스크 4개 삭제 → notice (임계 5 미만)"
jq '.tasks |= .[0:16]' "$TASKS" > "$T/four.json" && cp "$T/four.json" "$TASKS"
expect_json "4개 삭제" '.level=="notice" and .count_delta==-4 and (.removed|length)==4'

echo "── 7) 5개 삭제 → critical"
jq '.tasks |= .[0:11]' "$TASKS" > "$T/five.json" && cp "$T/five.json" "$TASKS"
expect_json "5개 삭제" '.level=="critical" and (.removed|length)==5'

echo "── 8) JSON 파손 → critical, 파일 미변경"
echo '{"tasks":[' > "$TASKS"
expect_json "파손" '.level=="critical" and (.reasons[0]|contains("파싱 실패"))'

echo "── 9) 파일 없음 → critical"
rm -f "$TASKS"
expect_json "없음" '.level=="critical" and (.reasons[0]|contains("없음"))'

echo "── 10) 회전: 15일 지난 백업은 지우되 최신 1개는 남긴다"
NEWEST=$(ls -t "$JARVIS_TASKS_BACKUP_DIR"/tasks-*.json | head -1)
cp "$NEWEST" "$TASKS"   # 최신 백업과 같은 내용 → 새 백업 없이 회전만 일어난다
for f in "$JARVIS_TASKS_BACKUP_DIR"/tasks-*.json; do touch -t "$(date -v-20d +%Y%m%d%H%M)" "$f"; done
touch -t "$(date -v-20d +%Y%m%d%H%M).30" "$NEWEST"   # 동일 분 안에서 최신이 되도록 30초를 더한다
N_BEFORE=$(ls "$JARVIS_TASKS_BACKUP_DIR"/tasks-*.json | wc -l | tr -d ' ')
OUT=$(bash "$SUT")
N_AFTER=$(ls "$JARVIS_TASKS_BACKUP_DIR"/tasks-*.json | wc -l | tr -d ' ')
# 현재 sha 가 최신 백업(5개 삭제 상태)과 같으므로 새 백업 없음 → 옛것 중 최신 1개만 남는다
[[ "$N_AFTER" -eq 1 ]] && ok || fail "회전 후 1개여야 함 (before=$N_BEFORE after=$N_AFTER pruned=$(jq .pruned <<<"$OUT"))"
[[ $(jq .pruned <<<"$OUT") -eq $((N_BEFORE-1)) ]] && ok || fail "pruned 수치 불일치"

echo "── 11) 원장 연동: ledger 의 integrity.sha256 이 전일 값으로 쓰인다"
LEDGER="$BOT_HOME/ledger/tasks-integrity-audit.jsonl"
printf '{"ts":"x","ts_unix":%d,"audit":{},"integrity":{"sha256":"deadbeef","task_count":50}}\n' "$(( $(date +%s) - 3600 ))" > "$LEDGER"
expect_json "원장 기준" '.prev_sha256=="deadbeef" and .prev_count==50 and .level=="critical" and .count_delta==(11-50)'

echo "── 12) 원인 단서: 창 안의 코더 활동·쓰기차단이 세어진다"
NOW_TS=$(date '+%Y-%m-%d %H:%M:%S'); NOW_ISO=$(date -u +%FT%TZ)
printf '[%s] [jarvis-coder] 큐 비어있음\n[%s] [jarvis-coder] 태스크 시작: abc\n[%s] [jarvis-coder] running abc\n' "$NOW_TS" "$NOW_TS" "$NOW_TS" > "$BOT_HOME/logs/jarvis-coder.log"
printf '{"ts":"%s","kind":"agent-write-protected","role":"coder"}\n' "$NOW_ISO" > "$BOT_HOME/state/runtime-guard.jsonl"
expect_json "단서" '.evidence.coder_activity_lines==2 and .evidence.guard_blocks==1 and .evidence.mtime_in_window==true'

echo "── 13) --text 는 사람용 요약만"
bash "$SUT" --text | head -1 | grep -q "tasks.json 무결성" && ok || fail "--text 첫 줄"

echo "PASSED=$PASSED FAILURES=$FAILURES"
[[ $FAILURES -eq 0 ]]
