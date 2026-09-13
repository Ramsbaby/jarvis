#!/usr/bin/env bash
#
# interview-mechanism-cross-check.sh
# ====================================
# 자비스가 "#jarvis-interview 채널 동작 원리"를 답변하기 전,
# 자연어 SSoT(personas.json)와 코드 SSoT(interview-fast-path.js / runner.mjs)
# 간 drift를 자동 검사하는 하네스.
#
# 사고 사례: 2026-04-28 13:11 — 자비스가 페르소나 본문 "370~420자"만 보고
# dual-answer 구조(SHORT 350 + DETAIL 1300) 전체 누락 거짓 답변
#
# 사용법:
#   bash interview-mechanism-cross-check.sh
#
# 종료 코드:
#   0: drift 없음 (페르소나 + 코드 모두 동일 룰 인지 가능)
#   1: drift 발견 — 코드에만 있고 페르소나 미언급된 룰 N건
#
set -euo pipefail

PERSONAS=~/projects/jarvis/infra/discord/personas.json
FAST_PATH=~/projects/jarvis/infra/discord/lib/interview-fast-path.js
RUNNER_BAK=~/projects/jarvis/infra/scripts/interview-ralph-runner.mjs.bak-20260428-3rd
CHANNEL_ID="1497124568031301752"

echo "═══════════════════════════════════════════════════════"
echo "  Interview 채널 동작 원리 SSoT Cross-Check"
echo "  $(date '+%Y-%m-%d %H:%M KST')"
echo "═══════════════════════════════════════════════════════"
echo ""

# ─────────────────────────────────────────
# 1. 자연어 SSoT (페르소나) 룰 추출
# ─────────────────────────────────────────
echo "📜 자연어 SSoT — personas.json[\"$CHANNEL_ID\"]"
echo "  답변 길이 룰:"
PERSONA_RULES=$(jq -r ".[\"$CHANNEL_ID\"]" "$PERSONAS" 2>/dev/null \
  | grep -nE "길이|자|토큰|초|분|SHORT|DETAIL|dual|mode|format" || true)
echo "$PERSONA_RULES" | sed 's/^/    /'
echo ""

# ─────────────────────────────────────────
# 2. 코드 SSoT (fast-path) 룰 추출
# ─────────────────────────────────────────
echo "🧬 코드 SSoT — interview-fast-path.js"
echo "  MAX_TOKENS 상수:"
grep -nE "MAX_TOKENS_SHORT|MAX_TOKENS_DETAIL" "$FAST_PATH" | head -5 | sed 's/^/    /'
echo ""
echo "  mode × format 분기:"
grep -nE "mode === 'short'|mode === 'detail'" "$FAST_PATH" | head -10 | sed 's/^/    /'
echo ""
echo "  자기소개 3세트 (v4.46):"
grep -nE "30초/1분/2분|3세트 동시" "$FAST_PATH" | head -3 | sed 's/^/    /'
echo ""

# ─────────────────────────────────────────
# 3. drift 검사 — 코드에 있고 페르소나에 없는 키워드
# ─────────────────────────────────────────
echo "⚖️  Drift 검사"
DRIFT=0
for KEY in "MAX_TOKENS_SHORT" "MAX_TOKENS_DETAIL" "dual-answer" "30초/1분/2분"; do
  CODE_HAS=$(grep -c "$KEY" "$FAST_PATH" 2>/dev/null | head -1 | tr -d '[:space:]')
  PERSONA_HAS=$(jq -r ".[\"$CHANNEL_ID\"]" "$PERSONAS" 2>/dev/null \
    | grep -c "$KEY" 2>/dev/null | head -1 | tr -d '[:space:]')
  CODE_HAS=${CODE_HAS:-0}
  PERSONA_HAS=${PERSONA_HAS:-0}
  if [ "$CODE_HAS" -gt 0 ] 2>/dev/null && [ "$PERSONA_HAS" -eq 0 ] 2>/dev/null; then
    echo "  ⚠️  '$KEY' — 코드에만 존재 (코드 $CODE_HAS회, 페르소나 0회)"
    DRIFT=$((DRIFT + 1))
  fi
done

if [ $DRIFT -eq 0 ]; then
  echo "  ✅ Drift 없음"
else
  echo ""
  echo "  🔴 총 $DRIFT 건 drift 발견 — 페르소나 본문만 인용해 답변 시 거짓 단정 위험"
fi
echo ""

# ─────────────────────────────────────────
# 4. Runner 송출 시점 (백업 기준)
# ─────────────────────────────────────────
if [ -f "$RUNNER_BAK" ]; then
  echo "📡 Runner postWebhook 송출 시점 (백업본 기준)"
  grep -nE "await postWebhook" "$RUNNER_BAK" | head -10 | sed 's/^/    /'
fi
echo ""

# ─────────────────────────────────────────
# 5. 자비스 답변 가드 — 체크리스트
# ─────────────────────────────────────────
echo "✅ 자비스 답변 전 필수 체크리스트"
echo "   □ personas.json[\"$CHANNEL_ID\"] 자연어 룰 인용했는가?"
echo "   □ interview-fast-path.js의 MAX_TOKENS·mode·format 분기 grep했는가?"
echo "   □ runner.mjs의 postWebhook 송출 시점 확인했는가?"
echo "   □ 자기소개 3세트(v4.46) 분기 인지했는가?"
echo "   □ '370~420자' 단일 룰 단정 금지 — dual-answer 구조 전체 보고했는가?"
echo ""

exit $DRIFT
