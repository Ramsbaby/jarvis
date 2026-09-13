#!/usr/bin/env bash
# test-career-grounding-guard.sh — Stop 훅 사후 정합성 검증기 회귀 테스트
#
# 왜 있나 (2026-08-03 사고):
#   자비스가 이미 폐기된 총보상 수치를 하루 종일 벤치마크로 썼다.
#   7/11·7/29에 이은 세 번째 노후 데이터 사고. 틀린 숫자는 실제 돈으로 청구된다.
#
# 픽스처는 왜 파일로 빠져 있나 (2026-09-10):
#   케이스 ①②의 문장에는 본인 총보상·오퍼 실금액이 들어간다. 그게 이 스크립트
#   본문에 박혀 있었고 공개 저장소 push 직전에 발견했다. 이제 비공개 파일에서 읽는다.
#   파일이 없으면 ①②를 건너뛰고 ③만 돌린다 — 포크한 사람도 무언가는 돌려볼 수 있게.
#
# 무엇을 지키나:
#   ① SSoT(user-profile.md STATE 블록)와 모순되는 수치를 주장하면 차단한다 (exit 2)
#   ② SSoT와 맞는 수치는 통과시킨다 (오탐 차단이 미탐보다 비싸다)
#   ③ 커리어 수치가 없는 턴은 모델을 부르지 않는다 (값싼 사전 필터 — 대부분의 턴)
#
# 주의: ①②는 소형 모델을 호출하므로 케이스당 30~40초가 걸린다. 전체 ~70초.
#
# 실행: bash ~/projects/jarvis/infra/scripts/test-career-grounding-guard.sh

set -uo pipefail

HOOK="${HOME}/.claude/hooks/stop-career-grounding-guard.sh"
WORK="${TMPDIR:-/tmp}/career-grounding-test.$$"
FIXTURES="${CAREER_GROUNDING_FIXTURES:-${HOME}/projects/jarvis/infra/config/career-grounding-fixtures.json}"
PASS=0
FAIL=0
SKIP=0

# 픽스처에서 한 필드를 꺼낸다. 없으면 빈 문자열.
fx() {
  [[ -f "$FIXTURES" ]] || return 0
  python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding='utf-8'))
    print(d[sys.argv[2]][sys.argv[3]])
except Exception:
    pass
" "$FIXTURES" "$1" "$2" 2>/dev/null
}

if [[ ! -x "$HOOK" ]]; then
  echo "❌ 훅을 찾을 수 없음: $HOOK"
  exit 1
fi

mkdir -p "$WORK" || exit 1
trap 'rm -rf "$WORK"' EXIT

t() {
  local desc="$1" text="$2" want="$3"
  local f="${WORK}/t${RANDOM}.jsonl"
  local start end code got mark

  python3 -c "
import json, sys
with open(sys.argv[2], 'w', encoding='utf-8') as f:
    f.write(json.dumps({'type': 'user', 'message': {'content': '질문'}}, ensure_ascii=False) + '\n')
    f.write(json.dumps({'type': 'assistant',
                        'message': {'content': [{'type': 'text', 'text': sys.argv[1]}]}},
                       ensure_ascii=False) + '\n')
" "$text" "$f" 2>/dev/null || { echo "❌ 트랜스크립트 생성 실패"; return 1; }

  start=$(python3 -c 'import time; print(time.time())')
  python3 -c "
import json, sys
print(json.dumps({'transcript_path': sys.argv[1], 'session_id': 'regress'}))
" "$f" 2>/dev/null | bash "$HOOK" >/dev/null 2>&1
  code=$?
  end=$(python3 -c 'import time; print(time.time())')

  got="PASS"
  [[ "$code" -eq 2 ]] && got="BLOCK"
  if [[ "$got" == "$want" ]]; then
    mark="✅"; PASS=$((PASS + 1))
  else
    mark="💥"; FAIL=$((FAIL + 1))
  fi
  python3 -c "
print(f'{\"$mark\"} {\"$got\":<6}(기대 {\"$want\":<5}) {float('$end') - float('$start'):>5.1f}s  {\"$desc\"}')
" 2>/dev/null
}

echo "━━━ 커리어 수치 사후 정합성 검증기 회귀 테스트 ━━━"
echo
if [[ ! -f "$FIXTURES" ]]; then
  echo "⏭  픽스처 없음 — 케이스 ①② 건너뜀: $FIXTURES"
  echo "   (예시: infra/config/career-grounding-fixtures.example.json 을 복사해 본인 SSoT 기준으로 고쳐 쓴다)"
  SKIP=2
else
  echo "── 차단해야 하는 것: SSoT와 모순되는 수치 ──"
  t "$(fx contradicts_ssot desc)" "$(fx contradicts_ssot text)" BLOCK

  echo
  echo "── 통과해야 하는 것: SSoT와 맞는 수치 ──"
  t "$(fx matches_ssot desc)" "$(fx matches_ssot text)" PASS
fi

echo
echo "── 모델을 부르지 않아야 하는 것: 커리어 수치 없는 턴 ──"
t "일반 기술 응답 (1초 미만이어야 정상)" \
  "이 스크립트는 set -euo pipefail이 빠져 있어서 3번째 줄에서 조용히 실패합니다." \
  PASS

echo
if [[ "$SKIP" -gt 0 ]]; then
  echo "━━━ 결과: ${PASS} 통과 / ${FAIL} 실패 / ${SKIP} 건너뜀 ━━━"
else
  echo "━━━ 결과: ${PASS} 통과 / ${FAIL} 실패 ━━━"
fi
[[ "$FAIL" -eq 0 ]] || exit 1
