#!/usr/bin/env bash
# test-rule-proposals.sh — 규칙 승격 제안서(4b) 회귀 테스트: rule-proposals.mjs · rule-proposal-ctl.mjs · mistake-promoter.mjs
#
# 검증 대상 (임시 BOT_HOME + 가짜 llm-gateway/discord-route — 외부 송출·LLM 호출 없음):
#   근거 3건 미만은 제안서에 오르지 않음 / 같은 패턴(문구·구두점·대소문자 변형, 멤버 겹침)은 1건으로 병합
#   17개 변형 클러스터 → 제안 1건 (2026-07-19 17중복 재발 방지) / promote·reject·reopen 상태 전이
#   promote --to 는 지정 파일에 블록 1회만 append / 결정 뒤 재발은 recurrence_after_decision 증가
#   promoter: tier_a 시뮬 YES → proposed_rule + 제안서 / 근거 부족 → 시뮬 생략·미등재 / 재실행 시 근거만 갱신
#             reprocess 행으로 최종 상태 철회 / PROMOTER_WRITE_RULES 미설정이면 규칙 파일 미기재
# 실행: bash ~/projects/jarvis/infra/scripts/test-rule-proposals.sh
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"
INFRA="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T=$(mktemp -d /var/tmp/rule-proposals-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
PASSED=0; FAILURES=0
ok()   { PASSED=$((PASSED+1)); }
fail() { FAILURES=$((FAILURES+1)); echo "  ✗ $*"; }
expect_eq() { [[ "$2" == "$3" ]] && ok || fail "$1: expected [$3] got [$2]"; }
expect_has() { grep -q -- "$3" <<<"$2" && ok || fail "$1: [$3] 없음 in: $(head -c 300 <<<"$2")"; }

export BOT_HOME="$T/runtime"
mkdir -p "$BOT_HOME"/{ledger,state,wiki/meta}
export JARVIS_NO_EXTERNAL=1
unset PROMOTER_WRITE_RULES
LIB="$INFRA/lib/rule-proposals.mjs"
CTL="$INFRA/scripts/rule-proposal-ctl.mjs"
PROMOTER="$INFRA/scripts/mistake-promoter.mjs"
STATE="$BOT_HOME/state/rule-proposals.json"
MD="$BOT_HOME/wiki/meta/rule-proposals.md"
MLEDGER="$BOT_HOME/state/mistake-ledger.jsonl"
PLEDGER="$BOT_HOME/ledger/promoter-ledger.jsonl"

# ── mistake-ledger 픽스처: 패턴 A 4건(변형 포함) · 패턴 B 1건 · 패턴 C 3건 ──
cat > "$MLEDGER" <<'EOF'
{"ts":"2026-09-01T10:00:00.000+09:00","source":"stop-hook","count":1,"titles":["통지일 미확인 상태에서 역산 기한 단언"],"session_file":"/x/s1.md"}
{"ts":"2026-09-02T10:00:00.000+09:00","source":"discord-turn","count":2,"titles":["통지일 미확인 → 기한 계산 오류","무관한 실수 B"],"session_file":"/x/s2.md"}
{"ts":"2026-09-03T10:00:00.000+09:00","source":"stop-hook","count":1,"titles":["통지일 미확인 상태에서 역산 기한 단언"],"session_file":"/x/s3.md"}
not json at all
{"ts":"2026-09-04T10:00:00.000+09:00","source":"stop-hook","count":2,"titles":["정확한 통지 날짜 확인 없이 마감 기한 권고","완료 선언 후 검증 생략"],"session_file":"/x/s4.md"}
{"ts":"2026-09-04T11:00:00.000+09:00","source":"stop-hook","count":1,"titles":["완료 선언 후 검증 생략!"],"session_file":"/x/s5.md"}
{"ts":"2026-09-04T12:00:00.000+09:00","source":"batch-daily","count":1,"titles":["완료 선언 후 검증 생략."],"session_file":null}
EOF

# node 로 lib 함수를 호출하는 헬퍼 — 인자: JSON 입력 → 결과 JSON 1줄
up() { node --input-type=module -e "
import { upsertProposal } from '$LIB';
const r = upsertProposal(JSON.parse(process.argv[1]));
console.log(JSON.stringify(r));" "$1"; }
fp() { node --input-type=module -e "import { fingerprint } from '$LIB'; console.log(fingerprint(process.argv[1]));" "$1"; }

echo "== 1. fingerprint — 구두점·대소문자·공백 변형은 같은 키"
expect_eq "fp 변형1" "$(fp '완료 선언 후 검증 생략!')" "$(fp '완료 선언 후  검증 생략.')"
expect_eq "fp 대소문자" "$(fp 'Env 미확인 단정')" "$(fp 'env 미확인 단정')"
[[ "$(fp '통지일 미확인')" != "$(fp '완료 선언')" ]] && ok || fail "다른 문장이 같은 fp"

echo "== 2. 근거 3건 미만은 미등재 · 4건은 등재"
r=$(up '{"cluster_id":"cl-b","seed":"무관한 실수 B","members":["무관한 실수 B"],"size":2,"rule_block":"B 금지","scenario":"s"}')
expect_eq "B insufficient" "$(jq -r .action <<<"$r")" "insufficient"
expect_eq "B evidence 1" "$(jq -r .evidence_count <<<"$r")" "1"
[[ ! -f "$STATE" ]] && ok || fail "insufficient 인데 상태 파일 생성됨"
r=$(up '{"cluster_id":"cl-a1","seed":"통지일 미확인 상태에서 역산 기한 단언","members":["통지일 미확인 상태에서 역산 기한 단언","통지일 미확인 → 기한 계산 오류","정확한 통지 날짜 확인 없이 마감 기한 권고"],"size":4,"rule_title":"통지일 미확인 기한 단언","rule_block":"통지일을 확인하기 전에는 기한 숫자를 말하지 않는다.","scenario":"통지서 없이 마감 질문","reason":"빈도 4","sim":"YES 교정 예상"}')
expect_eq "A new" "$(jq -r .action <<<"$r")" "new"
expect_eq "A evidence 4" "$(jq -r .evidence_count <<<"$r")" "4"
idA=$(jq -r .id <<<"$r")
[[ "$idA" == rp-?????????? ]] && ok || fail "id 형식: $idA"
expect_eq "state 1건" "$(jq '.proposals|length' "$STATE")" "1"
expect_eq "md 생성" "$([[ -f "$MD" ]] && echo yes)" "yes"
expect_has "md 근거 건수" "$(cat "$MD")" "근거 4건"
expect_has "md 룰 본문" "$(cat "$MD")" "통지일을 확인하기 전에는"
expect_has "md 근거 행(세션)" "$(cat "$MD")" "s1.md"
expect_has "md 손상행 무시(정상 동작)" "$(cat "$MD")" "2026-09-04 \[stop-hook\]"

echo "== 3. 같은 패턴 변형 → 병합 (시드 변형 · 멤버 겹침)"
r=$(up '{"cluster_id":"cl-a2","seed":"통지일 미확인 상태에서 역산 기한 단언.","members":["통지일 미확인 상태에서 역산 기한 단언."],"size":3,"rule_block":"다른 문구","scenario":"s"}')
expect_eq "시드 변형 merged" "$(jq -r .action <<<"$r")" "merged"
expect_eq "같은 id" "$(jq -r .id <<<"$r")" "$idA"
r=$(up '{"cluster_id":"cl-a3","seed":"기한을 확인 없이 단언","members":["기한을 확인 없이 단언","정확한 통지 날짜 확인 없이 마감 기한 권고","통지일 미확인 → 기한 계산 오류"],"size":3,"rule_block":"x","scenario":"s"}')
expect_eq "멤버 겹침 merged" "$(jq -r .action <<<"$r")" "merged"
expect_has "how overlap" "$(jq -r .how <<<"$r")" "overlap"
expect_eq "state 여전히 1건" "$(jq '.proposals|length' "$STATE")" "1"
expect_eq "cluster_ids 3개" "$(jq '.proposals[0].cluster_ids|length' "$STATE")" "3"
expect_eq "근거 중복 없음(4건 유지)" "$(jq '.proposals[0].evidence_count' "$STATE")" "4"
expect_eq "rule_block 은 첫 등재 유지" "$(jq -r '.proposals[0].rule_block' "$STATE")" "통지일을 확인하기 전에는 기한 숫자를 말하지 않는다."

echo "== 4. 17개 변형 클러스터 → 제안 1건 (2026-07-19 17중복 회귀)"
for i in $(seq 1 17); do
  up "{\"cluster_id\":\"cl-c$i\",\"seed\":\"완료 선언 후 검증 생략$(printf '%.0s!' $(seq 1 $i))\",\"members\":[\"완료 선언 후 검증 생략\"],\"size\":3,\"rule_block\":\"검증 없이 완료라 말하지 않는다\",\"scenario\":\"s\"}" >/dev/null
done
expect_eq "state 2건(A,C)" "$(jq '.proposals|length' "$STATE")" "2"
idC=$(jq -r '.proposals[] | select(.title|startswith("완료")) | .id' "$STATE")
expect_eq "C cluster_ids 17" "$(jq --arg id "$idC" '.proposals[] | select(.id==$id) | .cluster_ids|length' "$STATE")" "17"
expect_eq "C 근거 3건" "$(jq --arg id "$idC" '.proposals[] | select(.id==$id) | .evidence_count' "$STATE")" "3"
expect_eq "md 제안 섹션 2개" "$(grep -c '^### `rp-' "$MD")" "2"

echo "== 5. CLI — list/count/summary/show"
out=$(node "$CTL" list)
expect_has "list 헤더" "$out" "규칙 제안 pending: 2건"
expect_has "list A" "$out" "$idA  근거   4건"
expect_eq "count" "$(node "$CTL" count)" "2"
expect_eq "summary" "$(node "$CTL" summary)" "규칙 제안 대기 2건 — 승격 0건, 기각 0건, 결정 후 재발 0건"
expect_eq "show prefix" "$(node "$CTL" show "${idA:0:8}" | jq -r .id)" "$idA"

echo "== 6. reject 는 사유 필수 · promote --to 는 파일에 1회만 append"
node "$CTL" reject "$idC" >/dev/null 2>&1 && fail "reason 없이 reject 됨" || ok
expect_eq "reject" "$(node "$CTL" reject "$idC" --reason "이미 훅이 막음")" "rejected $idC"
expect_eq "reject 재실행" "$(node "$CTL" reject "$idC" --reason "x")" "already-rejected $idC"
RULES="$T/rules/sample.md"
out=$(node "$CTL" promote "$idA" --to "$RULES")
expect_has "promote 출력" "$out" "promoted $idA → $RULES"
expect_eq "블록 1개" "$(grep -c "RP:BEGIN id=$idA " "$RULES")" "1"
expect_has "블록 본문" "$(cat "$RULES")" "통지일을 확인하기 전에는"
expect_has "블록 출처" "$(cat "$RULES")" "근거 4건"
expect_eq "promote 재실행" "$(node "$CTL" promote "$idA" --to "$RULES")" "already-promoted $idA → $RULES"
expect_eq "블록 여전히 1개" "$(grep -c "RP:BEGIN id=$idA " "$RULES")" "1"
expect_eq "count pending 0" "$(node "$CTL" count)" "0"
expect_eq "count all 2" "$(node "$CTL" count --all)" "2"
expect_has "md 결정됨 표" "$(cat "$MD")" "| \`$idA\` | 통지일 미확인 기한 단언 | 승격 |"
expect_has "md 기각 사유" "$(cat "$MD")" "이미 훅이 막음"

echo "== 7. 결정 뒤 재발 → recurrence_after_decision"
r=$(up '{"cluster_id":"cl-a9","seed":"통지일 미확인 상태에서 역산 기한 단언","members":["통지일 미확인 상태에서 역산 기한 단언"],"size":3}')
expect_eq "recurred" "$(jq -r .action <<<"$r")" "recurred_after_decision"
expect_eq "status promoted 유지" "$(jq -r .status <<<"$r")" "promoted"
expect_eq "counter 1" "$(jq --arg id "$idA" '.proposals[] | select(.id==$id) | .recurrence_after_decision' "$STATE")" "1"
expect_eq "reopen" "$(node "$CTL" reopen "$idA" --note "룰 무효")" "reopened $idA"
expect_eq "summary 재발" "$(node "$CTL" summary)" "규칙 제안 대기 1건 — 승격 0건, 기각 1건, 결정 후 재발 1건"

echo "== 8. 불변 규칙 ① — 제안서 어디에도 근거 3건 미만 없음"
expect_eq "min evidence 위반 0" "$(jq '[.proposals[] | select(.evidence_count < 3)] | length' "$STATE")" "0"

# ─────────────────────────────────────────────────────────────────────────────
echo "== 9. promoter 통합 — 가짜 gateway/discord (LLM·송출 없음)"
rm -f "$STATE" "$MD" "$PLEDGER"
FAKE="$T/infra"; mkdir -p "$FAKE/lib" "$FAKE/scripts"
export JARVIS_INFRA_HOME="$FAKE"
export PROMOTER_RULES_FILE="$T/rules/autolearn.md"
export FAKE_JUDGE_FILE="$T/judge.json"
cat > "$FAKE/lib/llm-gateway.sh" <<'EOF'
llm_call() {
  local model="" output=""
  while [[ $# -gt 0 ]]; do case "$1" in --model) model="$2"; shift 2;; --output) output="$2"; shift 2;; --prompt|--system|--timeout) shift 2;; *) shift;; esac; done
  echo "fake-llm $model" >> "$FAKE_CALLS"
  if [[ "$model" == *haiku* ]]; then
    python3 -c 'import json,sys; print(json.dumps({"result":"YES\n룰이 기한 단언을 막는다","cost_usd":0}))' > "$output"
  else
    python3 -c 'import json,sys; print(json.dumps({"result":open(sys.argv[1]).read(),"cost_usd":0}))' "$FAKE_JUDGE_FILE" > "$output"
  fi
}
EOF
cat > "$FAKE/lib/discord-route.sh" <<'EOF'
discord_route() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FAKE_DISCORD"; }
EOF
export FAKE_CALLS="$T/calls.log" FAKE_DISCORD="$T/discord.log"
: > "$FAKE_CALLS"; : > "$FAKE_DISCORD"
# recurrence 리포트: A(근거 4) · B(근거 1)
NOW=$(node -e 'console.log(new Date(Date.now()+9*3600e3).toISOString().replace(/\.\d+Z$/,"+09:00"))')
cat > "$BOT_HOME/state/mistake-recurrence.json" <<EOF
{"generated_at":"$NOW","window_days":7,"threshold":3,"top_clusters":[
 {"seed":"통지일 미확인 상태에서 역산 기한 단언","size":4,"members":["통지일 미확인 상태에서 역산 기한 단언","통지일 미확인 → 기한 계산 오류","정확한 통지 날짜 확인 없이 마감 기한 권고"]},
 {"seed":"무관한 실수 B","size":2,"members":["무관한 실수 B","무관한 실수 B 변형"]}]}
EOF
idA_cl=$(node -e 'const {createHash}=require("crypto");console.log("cl-"+createHash("sha256").update(process.argv[1],"utf-8").digest("hex").slice(0,16))' "통지일 미확인 상태에서 역산 기한 단언")
idB_cl=$(node -e 'const {createHash}=require("crypto");console.log("cl-"+createHash("sha256").update(process.argv[1],"utf-8").digest("hex").slice(0,16))' "무관한 실수 B")
cat > "$FAKE_JUDGE_FILE" <<EOF
[{"id":"$idA_cl","tier":"tier_a","title":"통지일 미확인 기한 단언","reason":"빈도 4","rule_block":"통지일을 확인하기 전에는 기한 숫자를 말하지 않는다. (출처 $idA_cl) 자기검열: 기산일을 봤는가?","scenario":"통지서 없이 마감 질문"},
 {"id":"$idB_cl","tier":"tier_a","title":"무관 B","reason":"x","rule_block":"B 금지 (출처 $idB_cl)","scenario":"s"}]
EOF
export PROMOTER_MAX_APPLY=2
out=$(node "$PROMOTER" 2>&1); rc=$?
expect_eq "promoter rc" "$rc" "0"
expect_has "A proposed" "$out" "tier_a 처리 완료 (proposed_rule/report_only, 제안 new rp-"
expect_has "B 근거 부족" "$out" "근거 부족 — $idB_cl 실제 발생 1건 < 3"
expect_eq "LLM 콜 = 판정1 + 시뮬1 (B 시뮬 생략)" "$(wc -l < "$FAKE_CALLS" | tr -d ' ')" "2"
expect_eq "규칙 파일 미기재" "$([[ -f "$PROMOTER_RULES_FILE" ]] && echo written || echo none)" "none"
expect_eq "제안 1건" "$(jq '.proposals|length' "$STATE")" "1"
expect_eq "제안 근거 4" "$(jq '.proposals[0].evidence_count' "$STATE")" "4"
expect_has "제안 rule_block 보존" "$(jq -r '.proposals[0].rule_block' "$STATE")" "통지일을 확인하기 전에는 기한 숫자를 말하지 않는다"
expect_eq "ledger A proposed_rule" "$(jq -r --arg c "$idA_cl" 'select(.type=="cluster" and .cluster_id==$c) | .status' "$PLEDGER")" "proposed_rule"
expect_eq "ledger A rule_block 저장" "$(jq -r --arg c "$idA_cl" 'select(.type=="cluster" and .cluster_id==$c) | .rule_block | length > 10' "$PLEDGER")" "true"
expect_eq "ledger B held_insufficient_evidence" "$(jq -r --arg c "$idB_cl" 'select(.type=="cluster" and .cluster_id==$c) | .status' "$PLEDGER")" "held_insufficient_evidence"
expect_has "discord 제안 통보" "$(cat "$FAKE_DISCORD")" "retro|규칙 승격 제안"
expect_has "discord 통보에 근거" "$(cat "$FAKE_DISCORD")" "근거=4건"
expect_has "discord info 집계" "$(cat "$FAKE_DISCORD")" "제안서등재=1건"
rpA=$(jq -r '.proposals[0].id' "$STATE")

echo "== 10. promoter 재실행 — A 는 근거만 갱신(LLM 0), B 는 재판정 후 다시 근거 부족, 제안 여전히 1건"
: > "$FAKE_CALLS"; : > "$FAKE_DISCORD"
out=$(node "$PROMOTER" 2>&1); rc=$?
expect_eq "rc" "$rc" "0"
expect_has "A touch" "$out" "제안 근거 갱신 (merged): $idA_cl → $rpA 근거 4건"
expect_eq "LLM 콜 = 판정1 (B만)" "$(wc -l < "$FAKE_CALLS" | tr -d ' ')" "1"
expect_eq "제안 여전히 1건" "$(jq '.proposals|length' "$STATE")" "1"
expect_eq "ledger touch 행" "$(jq -r 'select(.type=="proposal_touch") | .action' "$PLEDGER" | tail -1)" "merged"
expect_eq "discord 제안 통보 없음(신규 아님)" "$(grep -c '규칙 승격 제안' "$FAKE_DISCORD")" "0"

echo "== 11. reprocess 행 → A 재판정 → 병합(중복 등재 없음)"
echo "{\"ts\":\"$NOW\",\"type\":\"cluster\",\"cluster_id\":\"$idA_cl\",\"status\":\"reprocess\",\"reason\":\"test\"}" >> "$PLEDGER"
: > "$FAKE_CALLS"
out=$(node "$PROMOTER" 2>&1)
expect_has "A 재판정 merged" "$out" "제안 merged $rpA"
expect_eq "제안 여전히 1건" "$(jq '.proposals|length' "$STATE")" "1"
expect_eq "LLM 콜 = 판정1 + 시뮬1" "$(wc -l < "$FAKE_CALLS" | tr -d ' ')" "2"

echo "== 12. --dry-run 은 아무것도 쓰지 않음"
cp "$STATE" "$T/state.before"; cp "$PLEDGER" "$T/pledger.before"
out=$(node "$PROMOTER" --dry-run 2>&1)
expect_has "dry 출력" "$out" "[DRY]"
cmp -s "$STATE" "$T/state.before" && ok || fail "dry-run 이 state 를 바꿈"
cmp -s "$PLEDGER" "$T/pledger.before" && ok || fail "dry-run 이 ledger 를 바꿈"

echo
echo "결과: PASS $PASSED / FAIL $FAILURES"
[[ $FAILURES -eq 0 ]]
