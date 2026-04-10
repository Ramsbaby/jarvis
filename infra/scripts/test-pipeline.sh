#!/usr/bin/env bash
# test-pipeline.sh — 댓글 파이프라인 핵심 로직 검증
# Usage: bash ~/.jarvis/scripts/test-pipeline.sh
#
# 실제 API 호출 없이 파이프라인 로직을 검증:
# 1. jq 필터 정합성 (is_resolution, is_visitor INTEGER 처리)
# 2. SQL safe() 함수 동작
# 3. 투표→합성 순서 확인
# 4. vote-collector 투표 프롬프트 구성
# 5. synthesizer 투표 반영 프롬프트 구성

set -euo pipefail

PASS=0
FAIL=0
TOTAL=0

pass() { ((PASS++)); ((TOTAL++)); echo "  ✅ $1"; }
fail() { ((FAIL++)); ((TOTAL++)); echo "  ❌ $1"; }

echo "=== 파이프라인 테스트 시작 ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "📋 1. jq 필터: INTEGER 0/1 처리 (is_resolution, is_visitor)"
# ─────────────────────────────────────────────────────────────────────────────

# 테스트 데이터: is_resolution=0 (INTEGER), is_visitor=0 (INTEGER)
MOCK_COMMENTS='{"comments":[
  {"id":"c1","author":"kim-seonhwi","author_display":"김선휘","content":"테스트","is_resolution":0,"is_visitor":0,"parent_id":null},
  {"id":"c2","author":"infra-lead","author_display":"박태성","content":"인프라 의견","is_resolution":0,"is_visitor":0,"parent_id":null},
  {"id":"c3","author":"owner","author_display":"대표","content":"대표 의견","is_resolution":0,"is_visitor":1,"parent_id":null},
  {"id":"c4","author":"board-synthesizer","author_display":"이사회","content":"결의","is_resolution":1,"is_visitor":0,"parent_id":null}
]}'

# 1a. vote-collector 필터: is_resolution==0 AND is_visitor==0 (정수)
VOTE_FILTER_COUNT=$(echo "$MOCK_COMMENTS" | jq '[.comments[] | select((.is_resolution == 0 or .is_resolution == null or .is_resolution == false) and (.is_visitor == 0 or .is_visitor == null or .is_visitor == false))] | length')
[[ "$VOTE_FILTER_COUNT" == "2" ]] && pass "vote-collector 필터: 에이전트 댓글 2개 (resolution/visitor 제외)" || fail "vote-collector 필터: 기대 2, 실제 $VOTE_FILTER_COUNT"

# 1b. replier 필터: 자기 자신 제외
REPLIER_COUNT=$(echo "$MOCK_COMMENTS" | jq --arg me "kim-seonhwi" '[.comments[] | select(.author != $me and (.is_resolution == 0 or .is_resolution == null or .is_resolution == false) and (.is_visitor == 0 or .is_visitor == null or .is_visitor == false) and (.parent_id == null or .parent_id == ""))] | length')
[[ "$REPLIER_COUNT" == "1" ]] && pass "replier 필터: 자기 제외 1개" || fail "replier 필터: 기대 1, 실제 $REPLIER_COUNT"

# 1c. synthesizer 필터: is_resolution != 1
SYNTH_FILTER_COUNT=$(echo "$MOCK_COMMENTS" | jq '[.comments[] | select(.is_resolution != 1)] | length')
[[ "$SYNTH_FILTER_COUNT" == "3" ]] && pass "synthesizer 필터: 비-결의 댓글 3개" || fail "synthesizer 필터: 기대 3, 실제 $SYNTH_FILTER_COUNT"

# 1d. 구 방식 (==false) 테스트 — 이 방식은 실패해야 정상
OLD_FILTER=$(echo "$MOCK_COMMENTS" | jq '[.comments[] | select(.is_resolution == false)] | length')
[[ "$OLD_FILTER" == "0" ]] && pass "구 ==false 필터 검증: INTEGER 0은 ==false 매칭 안 됨 (수정 이유 확인)" || fail "구 ==false 필터: 기대 0, 실제 $OLD_FILTER"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "📋 2. SQL safe() 함수: 따옴표 에스케이핑"
# ─────────────────────────────────────────────────────────────────────────────

safe() { printf '%s' "$1" | sed "s/'/''/g"; }

# 2a. 단일 따옴표
INPUT1="It's a test"
ESCAPED1=$(safe "$INPUT1")
[[ "$ESCAPED1" == "It''s a test" ]] && pass "safe(): 단일 따옴표 에스케이핑" || fail "safe(): '$ESCAPED1' != 'It''s a test'"

# 2b. 복수 따옴표
INPUT2="He said 'hello' and 'bye'"
ESCAPED2=$(safe "$INPUT2")
[[ "$ESCAPED2" == "He said ''hello'' and ''bye''" ]] && pass "safe(): 복수 따옴표 에스케이핑" || fail "safe(): 실패"

# 2c. 따옴표 없는 문자열
INPUT3="Normal text"
ESCAPED3=$(safe "$INPUT3")
[[ "$ESCAPED3" == "Normal text" ]] && pass "safe(): 따옴표 없는 문자열 통과" || fail "safe(): 변형됨"

# 2d. 실제 SQLite INSERT 테스트 (임시 DB)
TMPDB=$(mktemp /tmp/test-pipeline-XXXXX.db)
trap "rm -f $TMPDB" EXIT
sqlite3 "$TMPDB" "CREATE TABLE test (id TEXT PRIMARY KEY, content TEXT);"
TEST_CONTENT="국내 '극소수'는 AI 전환에 '뒤처진' 기업들"
sqlite3 "$TMPDB" "INSERT INTO test VALUES ('t1', '$(safe "$TEST_CONTENT")');"
RETRIEVED=$(sqlite3 "$TMPDB" "SELECT content FROM test WHERE id='t1';")
[[ "$RETRIEVED" == "$TEST_CONTENT" ]] && pass "safe() + SQLite: 실제 INSERT/SELECT 왕복 성공" || fail "safe() + SQLite: 데이터 불일치"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "📋 3. 투표 결과 프롬프트 구성 (synthesizer용)"
# ─────────────────────────────────────────────────────────────────────────────

MOCK_VOTES='{"votes":[
  {"comment_id":"c1abcdef","best_count":4,"worst_count":0,"total_voters":4},
  {"comment_id":"c2ghijkl","best_count":0,"worst_count":3,"total_voters":3}
],"bestReason":"핵심 분석이 뛰어남","worstReason":"일반적 지적에 그침"}'

VOTE_DETAILS=$(echo "$MOCK_VOTES" | jq -r '
  [.votes[]? | select(.best_count > 0 or .worst_count > 0) |
   "- 댓글 \(.comment_id[:8])...: 베스트 \(.best_count)표, 워스트 \(.worst_count)표"]
  | join("\n")' 2>/dev/null)
BEST_REASON=$(echo "$MOCK_VOTES" | jq -r '.bestReason // ""')
WORST_REASON=$(echo "$MOCK_VOTES" | jq -r '.worstReason // ""')

[[ -n "$VOTE_DETAILS" ]] && pass "투표 요약 생성: $(echo "$VOTE_DETAILS" | wc -l | tr -d ' ')건" || fail "투표 요약 비어있음"
[[ "$BEST_REASON" == "핵심 분석이 뛰어남" ]] && pass "bestReason 추출 성공" || fail "bestReason: $BEST_REASON"
[[ "$WORST_REASON" == "일반적 지적에 그침" ]] && pass "worstReason 추출 성공" || fail "worstReason: $WORST_REASON"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "📋 4. 데몬 순서 검증: 투표→합성 파이프라인"
# ─────────────────────────────────────────────────────────────────────────────

DAEMON="$HOME/.jarvis/bin/discussion-daemon.sh"
# Step 1 (투표)이 Step 2 (합성) 앞에 있는지 확인
STEP1_LINE=$(grep -n "Step 1: 투표 먼저 수집" "$DAEMON" | head -1 | cut -d: -f1)
STEP2_LINE=$(grep -n "Step 2: 투표 결과 포함하여 합성자" "$DAEMON" | head -1 | cut -d: -f1)
if [[ -n "$STEP1_LINE" && -n "$STEP2_LINE" && "$STEP1_LINE" -lt "$STEP2_LINE" ]]; then
  pass "데몬 순서: Step 1(투표 L${STEP1_LINE}) → Step 2(합성 L${STEP2_LINE})"
else
  fail "데몬 순서 이상: Step1=${STEP1_LINE:-없음} Step2=${STEP2_LINE:-없음}"
fi

# auto-close 선행 경로에서도 투표→합성 순서 확인
EARLY_VOTE=$(grep -n "투표 수집 (auto-close 선행)" "$DAEMON" | head -1 | cut -d: -f1)
EARLY_SYNTH=$(grep -n "합성자 트리거 (auto-close 선행, 투표 반영)" "$DAEMON" | head -1 | cut -d: -f1)
if [[ -n "$EARLY_VOTE" && -n "$EARLY_SYNTH" && "$EARLY_VOTE" -lt "$EARLY_SYNTH" ]]; then
  pass "auto-close 선행 경로: 투표(L${EARLY_VOTE}) → 합성(L${EARLY_SYNTH})"
else
  fail "auto-close 선행 경로 순서 이상"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "📋 5. 스크립트 문법 검증"
# ─────────────────────────────────────────────────────────────────────────────

for script in \
  "$HOME/.jarvis/bin/discussion-daemon.sh" \
  "$HOME/.jarvis/bin/discussion-synthesizer.sh" \
  "$HOME/.jarvis/bin/persona-commenter.sh" \
  "$HOME/.jarvis/bin/persona-replier.sh" \
  "$HOME/.jarvis/scripts/board-vote-collector.sh"; do
  NAME=$(basename "$script")
  if bash -n "$script" 2>/dev/null; then
    pass "$NAME 문법 OK"
  else
    fail "$NAME 문법 에러"
  fi
done

echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "📋 6. synthesizer 투표 반영 코드 존재 확인"
# ─────────────────────────────────────────────────────────────────────────────

SYNTH="$HOME/.jarvis/bin/discussion-synthesizer.sh"
grep -q "peer-votes" "$SYNTH" && pass "synthesizer: peer-votes API 호출 존재" || fail "synthesizer: peer-votes 호출 없음"
grep -q "동료 평가 결과" "$SYNTH" && pass "synthesizer: 투표 결과 프롬프트 섹션 존재" || fail "synthesizer: 투표 프롬프트 없음"
grep -q "높은 평가를 받은 의견에 더 비중" "$SYNTH" && pass "synthesizer: 비중 지시 존재" || fail "synthesizer: 비중 지시 없음"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "📋 7. persona-commenter safe() 함수 사용 확인"
# ─────────────────────────────────────────────────────────────────────────────

COMMENTER="$HOME/.jarvis/bin/persona-commenter.sh"
grep -q 'safe()' "$COMMENTER" && pass "commenter: safe() 함수 정의됨" || fail "commenter: safe() 없음"
if grep -q "//\\\\'/" "$COMMENTER" 2>/dev/null; then
  fail "commenter: 구 에스케이핑 패턴 잔존"
else
  pass "commenter: 구 에스케이핑 0건"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "📋 8. persona-replier safe() 함수 사용 확인"
# ─────────────────────────────────────────────────────────────────────────────

REPLIER="$HOME/.jarvis/bin/persona-replier.sh"
grep -q 'safe()' "$REPLIER" && pass "replier: safe() 함수 정의됨" || fail "replier: safe() 없음"
if grep -q "//\\\\'/" "$REPLIER" 2>/dev/null; then
  fail "replier: 구 에스케이핑 패턴 잔존"
else
  pass "replier: 구 에스케이핑 0건"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "📋 9. vote-collector 임원 ID 동적 로딩 확인"
# ─────────────────────────────────────────────────────────────────────────────

VOTER="$HOME/.jarvis/scripts/board-vote-collector.sh"
grep -q 'tier.*executive' "$VOTER" && pass "vote-collector: 임원 ID를 설정에서 동적 로드" || fail "vote-collector: 임원 ID 하드코딩"
grep -q '_SAVED_KEY' "$VOTER" && pass "vote-collector: env 덮어쓰기 방지 로직 존재" || fail "vote-collector: env 덮어쓰기 방지 없음"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "📋 10. 전체 스크립트 safe() vs 구 에스케이핑 현황"
# ─────────────────────────────────────────────────────────────────────────────

SCRIPTS=(
  "$HOME/.jarvis/bin/discussion-daemon.sh"
  "$HOME/.jarvis/bin/discussion-synthesizer.sh"
  "$HOME/.jarvis/bin/persona-commenter.sh"
  "$HOME/.jarvis/bin/persona-replier.sh"
  "$HOME/.jarvis/scripts/board-vote-collector.sh"
)
ALL_CLEAN=true
for s in "${SCRIPTS[@]}"; do
  NAME=$(basename "$s")
  # sqlite3 INSERT/UPDATE/SELECT 문에서 구 에스케이핑 사용 여부만 체크
  # (jq @sh 따옴표 제거 "${var//\'/}" 패턴은 정상이므로 제외)
  if grep "sqlite3" "$s" 2>/dev/null | grep -q "//\\\\'/" 2>/dev/null; then
    fail "$NAME: sqlite3 구 에스케이핑 잔존"
    ALL_CLEAN=false
  fi
done
$ALL_CLEAN && pass "전체 스크립트: sqlite3 구 에스케이핑 0건"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
echo "📋 11. 합성자 날짜 파싱 (restarted_at 포맷 호환성)"
# ─────────────────────────────────────────────────────────────────────────────

# 테스트: "2026-03-23 14:35:21" 형식 (SQLite datetime)
FMT1="2026-03-23 14:35:21"
_C="${FMT1//T/ }"; _C="${_C%%Z}"; _C="${_C%%.*}"
E1=$(TZ=UTC date -jf "%Y-%m-%d %H:%M:%S" "$_C" +%s 2>/dev/null || echo 0)
[[ "$E1" != "0" ]] && pass "날짜 파싱: '$FMT1' → epoch $E1" || fail "날짜 파싱 실패: '$FMT1'"

# 테스트: "2026-03-23T14:35:21Z" 형식 (ISO8601)
FMT2="2026-03-23T14:35:21Z"
_C="${FMT2//T/ }"; _C="${_C%%Z}"; _C="${_C%%.*}"
E2=$(TZ=UTC date -jf "%Y-%m-%d %H:%M:%S" "$_C" +%s 2>/dev/null || echo 0)
[[ "$E2" != "0" ]] && pass "날짜 파싱: '$FMT2' → epoch $E2" || fail "날짜 파싱 실패: '$FMT2'"

# 테스트: "2026-03-23T14:35:21.000Z" 형식 (밀리초 포함)
FMT3="2026-03-23T14:35:21.000Z"
_C="${FMT3//T/ }"; _C="${_C%%Z}"; _C="${_C%%.*}"
E3=$(TZ=UTC date -jf "%Y-%m-%d %H:%M:%S" "$_C" +%s 2>/dev/null || echo 0)
[[ "$E3" != "0" ]] && pass "날짜 파싱: '$FMT3' → epoch $E3" || fail "날짜 파싱 실패: '$FMT3'"

# 세 포맷 모두 같은 epoch이어야 함
[[ "$E1" == "$E2" && "$E2" == "$E3" ]] && pass "세 포맷 epoch 일치: $E1" || fail "epoch 불일치: $E1 / $E2 / $E3"

echo ""
echo "═══════════════════════════════════════"
echo "결과: ${PASS} 통과 / ${FAIL} 실패 / ${TOTAL} 총"
if [[ "$FAIL" -eq 0 ]]; then
  echo "🎉 전체 테스트 통과!"
  exit 0
else
  echo "⚠️  ${FAIL}건 실패 — 확인 필요"
  exit 1
fi
