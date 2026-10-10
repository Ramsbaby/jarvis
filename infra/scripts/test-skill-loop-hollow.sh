#!/usr/bin/env bash
# test-skill-loop-hollow.sh — 스킬 루프가 "ok 인데 실질 0"으로 끝나지 않는지 재현 시험 (2026-10-10)
#
# 왜: 10-04~10-10 7밤 "적용 0건"이 전부 ok 였다. 출력으로 가르니 두 가지였다.
#   (1) 4밤은 채점 5건이 전부 일일 예산 상한에 막혀 점수 -1 이었는데 "선별 0건 · ✅ 배치 완료" 로 끝났다(이유는 가드 로그에만).
#   (2) 결재 카드 버튼을 받던 디스코드 봇이 없어져 결재가 한 건도 기록될 수 없었다 — decision 0건이 영구 상태.
# 임시 HOME 에 가둔다: 진짜 원장·pending·~/.claude/skills 를 건드리지 않고, 디스코드로 아무것도 쏘지 않는다
#   (discord-visual.mjs 는 호출을 기록만 하는 가짜, 카드 송출은 SKILL_LOOP_NOTIFY_DRY=1).
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PASSED=0; FAILURES=0
ok()  { echo "  ok   $1"; PASSED=$((PASSED + 1)); }
bad() { echo "  FAIL $1"; FAILURES=$((FAILURES + 1)); }
expect()     { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1 — got: ${2:0:300}"; }
expect_not() { [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1 — 들어 있으면 안 되는 말: $3"; }
expect_eq()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 — got: $2 (want $3)"; }

TMP="$(mktemp -d /tmp/skill-loop-hollow-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
RT="$HOME/.openclaw-data/runtime"
DRAFTS="$RT/state/skill-drafts"
SCR="$HOME/projects/jarvis/infra/scripts"
unset BOT_HOME JARVIS_HOME
export JARVIS_NO_EXTERNAL=1

mkdir -p "$DRAFTS/pending" "$DRAFTS/decisions" "$DRAFTS/archive" "$DRAFTS/approved" "$RT/ledger" "$RT/logs" "$RT/context" \
         "$SCR" "$HOME/projects/jarvis/infra/bin" "$HOME/.claude/projects/p1" "$HOME/.claude/skills" \
         "$HOME/.claude/commands/skill-creator/scripts"
for f in skill-loop-select.mjs skill-loop-promote.mjs skill-loop-decide.mjs skill-loop-notify.mjs skill-loop-extract.mjs skill-loop-nightly.sh; do
  ln -s "$HERE/$f" "$SCR/$f"
done
# 디스코드로 나가는 길은 가짜 — 부르면 기록만 한다
printf 'import {appendFileSync} from "node:fs"; appendFileSync(process.env.HOME+"/discord-visual-calls.log", process.argv.slice(2).join(" ")+"\\n");\n' > "$SCR/discord-visual.mjs"
printf '{"currentLatest":{"haiku":"fake-model"}}\n' > "$RT/context/model-policy.json"
printf '{"dryrun": true}\n' > "$DRAFTS/config.json"          # nightly 가 카드 송출(skill-loop-notify)을 건너뛴다
printf 'import sys\nsys.exit(0)\n' > "$HOME/.claude/commands/skill-creator/scripts/quick_validate.py"

mk_draft() {   # <slug> <expires>
  mkdir -p "$DRAFTS/pending/$1"
  printf -- '---\nname: %s\ndescription: 시험용 초안 %s\nmetadata:\n  score: 8\n  evidence-count: 8\n  mode: new\n  expires: %s\n---\n\n## 검증 증거\n$ echo ok\n' "$1" "$1" "$2" > "$DRAFTS/pending/$1/SKILL.md"
}
# select 가 후보로 집을 만한 세션 기록(30KB↑·도구호출 15↑·성공 신호 3↑, 2시간 전 수정)
mk_transcript() {
  local f="$HOME/.claude/projects/p1/sess.jsonl" i
  : > "$f"
  for i in $(seq 1 40); do
    printf '{"type":"tool_use","n":%d,"note":"✅ ok passed 통과 %s"}\n' "$i" "$(printf 'x%.0s' $(seq 1 800))" >> "$f"
  done
  printf '{"type":"user","message":{"role":"user","content":"시험용 첫 요청 — 스킬로 만들 가치가 있는 절차인지 본다"}}\n' >> "$f"
  touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M)" "$f"
}
fake_ask() {   # <exit|score>  — exit N: 예산 가드처럼 아무 출력 없이 N 으로 끝남 / score S: 정상 채점 결과를 남김
  if [[ "$1" == exit* ]]; then
    printf '#!/usr/bin/env bash\nexit %s\n' "${1#exit }" > "$HOME/projects/jarvis/infra/bin/ask-claude.sh"
  else
    mkdir -p "$RT/results/skill-loop-score"
    printf '#!/usr/bin/env bash\nmkdir -p "%s/results/skill-loop-score"\nprintf "## Result\\n{\\"score\\": %s, \\"topic\\": \\"시험\\", \\"slug\\": \\"t\\"}\\n" > "%s/results/skill-loop-score/$(date +%%s%%N).md"\n' "$RT" "${1#score }" "$RT" > "$HOME/projects/jarvis/infra/bin/ask-claude.sh"
  fi
}
guard_log() {
  printf '{"ts":"2026-10-10T18:50:04.734Z","level":"ERROR","task":"skill-loop-score","msg":"[TOKEN_BUDGET_GUARD] DAILY_CAP_EXCEEDED: daily=35.6056 USD >= cap=10 USD"}\n' > "$RT/logs/token-budget-guard.log"
}

echo "▶ select — 채점이 전부 실패하면 '선별 0건' 이 아니라 '채점 못 함'"
mk_transcript; guard_log; fake_ask "exit 2"
out="$(node "$SCR/skill-loop-select.mjs" --cap 3 2>&1)"; rc=$?
expect_eq "채점 전부 실패 → 종료코드 3"                 "$rc" "3"
expect    "'전부 실패' 와 후보 아닌 평가 불능을 밝힌다"   "$out" "채점 1/1건 전부 실패"
expect    "이유에 예산 가드 사유가 들어간다(명령줄이 아니라)" "$out" "DAILY_CAP_EXCEEDED: daily=35.6056 USD >= cap=10 USD"
expect_not "예전 '명령줄 120자' 이유는 더 안 나온다"      "$out" "Command failed"
expect    "원장에 scoring-failed 가 남는다"             "$(cat "$RT/ledger/skill-loop.jsonl")" '"event":"scoring-failed"'

fake_ask "score 3"
out="$(node "$SCR/skill-loop-select.mjs" --cap 3 2>&1)"; rc=$?
expect_eq "정상 채점(임계치 미달) → 종료코드 0"          "$rc" "0"
expect    "정상이면 '선별 0건'이 맞다"                    "$out" "→ 0건 (상한 3)"
expect_not "정상이면 전부 실패 문구가 없다"               "$out" "전부 실패"

echo "▶ nightly — 채점 못 한 밤은 잡이 실패로 끝난다(끝까지 돌린 뒤)"
mk_draft slug-a 2099-01-01
fake_ask "exit 2"
out="$(bash "$SCR/skill-loop-nightly.sh" 2>&1)"; rc=$?
expect_eq "채점 전부 실패 → 잡 종료코드 1"               "$rc" "1"
expect    "나머지 단계는 끝까지 돈다(배치 완료 줄)"       "$out" "✅ 배치 완료"
expect    "결재 대기 줄과 되는 결재 방법이 나온다"         "$out" "결재 대기 1건"
expect    "결재 방법에 decide 명령이 들어간다"            "$out" "skill-loop-decide.mjs"
expect    "마지막에 실패를 선언한다"                      "$out" "❌ 채점 전부 실패"
[[ ! -e "$HOME/discord-visual-calls.log" ]] && ok "채점 실패는 크래시가 아니라 디스코드 실패 카드를 안 쏜다" || bad "예상 밖 디스코드 호출: $(cat "$HOME/discord-visual-calls.log")"

fake_ask "score 3"
out="$(bash "$SCR/skill-loop-nightly.sh" 2>&1)"; rc=$?
expect_eq "정상 밤 → 잡 종료코드 0"                      "$rc" "0"
expect_not "정상 밤엔 실패 선언이 없다"                   "$out" "❌ 채점 전부 실패"

echo "▶ decide — 봇 없이 결재가 기록되고 적용된다"
mk_draft slug-b 2099-01-02; mk_draft slug-c 2099-01-03
printf '[]\n' > "$DRAFTS/pending/anger-111.json"
out="$(node "$SCR/skill-loop-decide.mjs" list 2>&1)"
expect     "list 는 초안만 센다(anger-*.json 제외)"       "$out" "결재 대기 3건"
node "$SCR/skill-loop-decide.mjs" approve slug-b --by tester >/dev/null 2>&1
expect_eq  "approve 가 봇과 같은 형식으로 기록"           "$(python3 -c "import json;d=json.load(open('$DRAFTS/decisions/slug-b.json'));print(d['slug'],d['decision'],d['by'],bool(d['ts']))")" "slug-b approve tester True"
out="$(node "$SCR/skill-loop-decide.mjs" approve slug-b --apply 2>&1)"
expect     "--apply 면 등재까지 간다"                     "$out" "✅ slug-b: 등재"
[[ -d "$HOME/.claude/skills/slug-b" && -d "$DRAFTS/approved/slug-b" && ! -d "$DRAFTS/pending/slug-b" ]] && ok "등재: skills 설치·approved 이동·pending 제거" || bad "등재 결과 폴더 상태가 다르다"
node "$SCR/skill-loop-decide.mjs" reject slug-c --apply >/dev/null 2>&1
ls "$DRAFTS/archive" | grep -q '^slug-c-rejected-' && ok "reject --apply → archive 로 보관" || bad "reject 가 archive 로 안 갔다"
out="$(node "$SCR/skill-loop-decide.mjs" approve no-such-draft 2>&1)"; rc=$?
expect_eq  "pending 에 없는 이름은 거절(종료코드 1)"        "$rc" "1"
out="$(node "$SCR/skill-loop-decide.mjs" approve '../etc' 2>&1)"; rc=$?
expect_eq  "경로 문자가 든 이름은 거절(종료코드 2)"         "$rc" "2"

echo "▶ notify — 죽은 버튼을 달지 않고 되는 결재 방법을 적는다(송출 없이 DRY)"
mk_draft slug-n 2099-02-01
printf 'DISCORD_TOKEN=fake\n' > "$RT/.env"; mkdir -p "$RT/config"; printf '{"l3_channel_id":"1"}\n' > "$RT/config/monitoring.json"
rm -f "$DRAFTS/notified.json"
out="$(SKILL_LOOP_NOTIFY_DRY=1 node "$SCR/skill-loop-notify.mjs" 2>&1)"
expect     "카드 문구가 만들어진다"                       "$out" "스킬 초안 결재 요청"
expect     "결재는 대화로 한다고 적는다"                   "$out" "스킬 초안 slug-n 승인"
expect_not "죽은 버튼(slapprove)이 없다"                  "$out" "slapprove"
expect_not "components(버튼 묶음)가 없다"                 "$out" "components"

echo ""
echo "PASSED=${PASSED} FAILURES=${FAILURES}"
exit $((FAILURES > 0 ? 1 : 0))
