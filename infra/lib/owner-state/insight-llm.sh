#!/usr/bin/env bash
# insight-llm.sh — 2층 LLM 통찰: 스냅샷 → 모순·맹점·임박리스크 통찰 후보
#
# 규칙 매칭이 아니라 맥락 종합. 근거는 스냅샷 실측값만. 통찰 없으면 빈 배열(침묵 기본).
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"   # 한글 바이트 처리 (cron 로케일 누락 방지)

BOT_HOME="${BOT_HOME:-${HOME}/jarvis/runtime}"
SNAPSHOT="${BOT_HOME}/state/owner-state/snapshot-latest.json"
LLM_OUT="${BOT_HOME}/state/owner-state/llm-out.json"
FEEDBACK="${BOT_HOME}/state/owner-state/feedback.jsonl"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$SNAPSHOT" ] || { echo "[insight-llm] snapshot 없음 — collect-snapshot 먼저 실행"; exit 1; }

# 4층 학습: 과거 노이즈로 평가된 패턴을 회피 지침으로 주입
AVOID=""
if [ -f "$FEEDBACK" ]; then
  AVOID=$(grep '"verdict":"noise"' "$FEEDBACK" 2>/dev/null | tail -10 | sed 's/.*"insight":"//;s/".*//' | sed 's/^/  - /')
fi

source "${BOT_HOME}/lib/llm-gateway.sh"

SYSTEM='너는 오너(주인님)의 AI 집사 자비스다. 아래 "주인님 상태 스냅샷"(일정·커리어·건강·가족·오늘 주인님 발화)을 읽고, 주인님이 놓치고 있는 것을 찾아라.

★ 핵심 분석법: recent_decisions(주인님이 오늘 직접 한 말·결정)를 calendar·facts와 반드시 교차하라. 주인님의 "말"과 "일정/행동"이 어긋나는 곳이 최고의 통찰이다. 예: 발화에 "면접 거절"이 있는데 캘린더에 그 면접이 남아있으면 → 노쇼 위험.

★ 통찰 도메인(누적·진화): open_insights는 이미 주인님께 보낸 "미해결 통찰"이다. 절대 규칙:
  - open_insights와 같은 통찰을 또 내지 마라(중복 금지). 주인님은 이미 봤다.
  - 대신 open_insights의 owner_answer(주인님 답)가 있으면, 그 답 위에서 다음 단계를 제시하라(진화). 예: 답이 "①AI 금지 때문"이면 → "AI 없이 코테 통과 가능한지 점검"이 다음 통찰.
  - 정말 새로운 통찰만 추가하라. 새 게 없으면 빈 배열이 맞다.

목표: 규칙 알림(D-day 카운트 등 달력만 봐도 아는 것)이 아니라, 여러 데이터를 엮어야 보이는 통찰이다. 특히 세 종류:
- 모순: 서로 어긋나는 행동/결정 (예: 면접 볼 시간 없다며 단타한다 / 거절한 면접이 캘린더에 남아있다)
- 맹점: 주인님이 못 보는 빈 곳 (예: 본인 건강 데이터 부재 / 임박한 시험에 집중이 분산됨)
- 리스크: 임박 일정 + 준비 부족 신호

엄격한 규칙(위반 시 무효):
1. 근거는 반드시 스냅샷의 실제 값만 인용한다. 날짜·요일·금액·수치를 절대 창작하지 마라. 요일은 스냅샷에 이미 계산돼 있으니 그대로 쓴다.
2. stale_sources에 있는 소스(오래된 데이터)는 단정 근거로 쓰지 마라. 참고만.
3. "주인님의 행동을 바꾸는" 통찰만 낸다. 단순 정보 나열(달력 읽기)은 제외한다.
4. 애매하거나 약한 통찰뿐이면 빈 배열 []을 반환한다. 억지로 만들지 마라. 침묵이 기본값이다.
5. 단, 객관적 사실 위반은 침묵 금지 — 반드시 포함하라: (a) 거절/완료한 일정이 캘린더에 잔존 (b) D-3 이내 임박 일정에 준비 신호 부재 (c) 같은 시간대 일정 충돌. 이런 명백한 것은 비결정적으로 누락하지 말고 항상 잡아라.
6. 투자·주식·포트폴리오·매수/매도·자산 비중에 대한 조언은 절대 금지다. 그 데이터는 실시간 추적이 안 돼 snapshot에서 제외했다(advisory_excluded 참고). 투자는 주인님이 직접 본다. 투자 관련 통찰은 무효 처리된다.
7. 각 통찰의 evidence에는 근거로 쓴 데이터가 무엇인지 명시한다. 근거가 stale_sources에 있으면 그 통찰은 내지 마라.
8. 최대 3개. 가장 중요한 것만.

출력: JSON 배열만 출력한다. 설명·인사 없이 JSON만. 각 원소:
{"type":"모순|맹점|리스크","domain":"이 통찰의 주제를 정확히 분류 — career(면접·이직·시험·코테)|health(주인님 본인 건강·체력·수면)|family(가족)|finance(투자)|life(그 외) 중 하나. 본인 건강 얘기면 career 키워드가 섞여도 반드시 health","insight":"통찰을 2~3문장으로 깊이 있게 — 표면 현상만 말하지 말고 왜 중요한지·무엇과 연결되는지·방치하면 어떤 결과로 이어지는지까지 분석","evidence":"스냅샷에서 인용한 실측 근거","action":"즉시 실행 가능한 구체적 행동","question":"답에 따라 방향이 갈리는 핵심 질문을 주인님께 던져라. 애매할수록 질문으로 더 파고들어라 (없으면 빈 문자열)"}

깊이 원칙(필수): 한 줄짜리 얕은 지적은 금지다. 데이터를 엮어 주인님도 미처 못 본 함의를 드러내라. 예: "면접 거절"에서 멈추지 말고 — 거절 이유(일정 충돌? 의향 변화?)에 따라 다음 커리어 전략이 어떻게 갈리는지까지 파고들고, 그 갈림길을 질문으로 던져라. 표면 한 줄이면 차라리 빼라.'

if [ -n "$AVOID" ]; then
  SYSTEM="${SYSTEM}

[과거 노이즈로 평가된 통찰 — 유사한 것은 내지 마라]
${AVOID}"
fi

PROMPT="주인님 상태 스냅샷(JSON):
$(cat "$SNAPSHOT")

위 스냅샷을 분석해 통찰 JSON 배열을 출력하라. 진짜 통찰이 없으면 [] 만 출력하라."

JARVIS_MAX_OUTPUT_TOKENS=2500 llm_call \
  --prompt "$PROMPT" \
  --system "$SYSTEM" \
  --timeout 180 \
  --output "$LLM_OUT" \
  --model "sonnet" || { echo "[insight-llm] llm_call 실패"; exit 1; }

BOT_HOME="$BOT_HOME" node "${DIR}/extract-insights.mjs"
