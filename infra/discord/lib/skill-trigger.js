// skill-trigger.js — Discord 자연어 스킬 트리거 매칭 엔진
//
// CLI sensor-skill-trigger.sh (~/.claude/hooks/) 의 JS 포팅.
// Jarvis 단일 뇌 철학: CLI 표면과 동일한 트리거 매트릭스를 Discord 표면에도 적용.
//
// 설계:
//   - 1차: 정규식 매칭 (명시적·결정적·빠름) — 본 모듈 담당
//   - 2차: LLM 의도 판별 (Phase 1.8 오탐 가드에서 선택 투입)
//   - 이미 "/skill" 명시 입력이면 confidence=1.0 즉시 반환
//
// SSoT: CLI sensor와 키워드 동기화. 갱신 시 양쪽 모두 반영 필요.

const TRIGGER_MATRIX = [
  {
    skill: 'doctor',
    patterns: [
      /뭐\s*문제\s*없/,
      /시스템\s*(건강|점검)/,
      /서비스\s*점검/,
      /jarvis\s*(점검|건강)/i,
      /점검\s*(해?\s*줘|좀)/,
      /\/doctor\b/i,
    ],
  },
  {
    skill: 'status',
    patterns: [
      /서비스\s*상태/,
      /다\s*돌아가/,
      /전체\s*현황/,
      /대시보드/,
      /서비스\s*확인/,
      /\/status\b/i,
    ],
  },
  {
    skill: 'brief',
    patterns: [
      /브리핑\s*해?\s*줘/,
      /오늘\s*뭐\s*있/,
      /일일\s*요약/,
      /오늘\s*현황/,
      /\/brief\b/i,
    ],
  },
  {
    skill: 'tqqq',
    patterns: [
      /tqqq\s*상태/i,
      /주식\s*모니터/,
      /tqqq\s*어때/i,
      /시장\s*모니터링/,
      /\/tqqq\b/i,
    ],
  },
  {
    skill: 'retro',
    patterns: [
      /회고\s*(해|록|하자|하지|$|\s)/,
      /작업\s*정리\s*해?\s*줘/,
      /retrospective/i,
      /\/retro\b/i,
    ],
  },
  {
    skill: 'oops',
    patterns: [
      /오답노트에\s*추가/,
      /이건\s*오답노트로/,
      /실수\s*기록/,
      /오답\s*기재/,
      /\/oops\b/i,
    ],
  },
  {
    skill: 'autoplan',
    patterns: [
      /자동\s*계획/,
      /플랜\s*세워/,
      /계획\s*수립/,
      /autoplan/i,
      /\/autoplan\b/i,
    ],
  },
  {
    skill: 'crisis',
    patterns: [
      /긴급\s*상황/,
      /장애\s*대응/,
      /봇이\s*죽/,
      /서비스\s*멈/,
      /\/crisis\b/i,
    ],
  },
  {
    skill: 'deploy',
    patterns: [
      /배포\s*해?\s*줘/,
      /업데이트\s*진행/,
      /최신화\s*해?\s*줘/,
      /\/deploy\b/i,
    ],
  },
];

// 일상 대화에서 오탐 유발할 수 있는 부정 패턴 (검사 통과 시 트리거 억제).
// 감사관(2026-04-24 3차) 지적 반영: 한국어 구어체 광범위 커버 + 메타/제안/의문형.
const NEGATIVE_PATTERNS = [
  // 가족·사람 대상 건강/점검 언급
  /(아이들?|애들?|딸|아들|우리\s*애|우리\s*가족)\s*(건강|점검|상태)/,
  /(엄마|아빠|어머니|아버지|할머니|할아버지|남편|아내|애인)\s*(건강|점검|상태)/,
  // 반려동물 광범위
  /(강아지|고양이|개|댕댕이|냥이|반려)\s*(건강|점검|상태|병원)/,
  // 사물·식물·기기·장소 일상 언급
  /(화분|식물|꽃|나무|화초)\s*(건강|상태)/,
  /(카페|식당|가게|공장|사무실|여행)\s*(상태|점검|확인)/,
  // 메타 대화 (예시·가정·참조)
  /\s(농담|예시|예를\s*들어|테스트용|참고로)\s/,
  /예를\s*들어|만약에|가령/,
  // 인용문·설명 요청
  /^["'`“”].*["'`“”]$/, // 전체 따옴표 (스마트 따옴표 포함)
  /".*".*뜻/, // "XX" 뜻이 뭐야
  /라는\s*(말|뜻|의미)/, // "XX라는 말이야?"
  /는\s*말이야|말이지|말한\s*거야/, // 인용 화법
  // 제안·가정형 (명령이 아님)
  /해볼까\s*[?？]?|해야\s*할까|해야지|\s해야\s*하/,
  /해줘야|해줘야겠|해줘야지|해야\s*(해|하지)/, // "배포 해줘야 하는 거" 같은 미래 가정
  // 사용법·추천 질문
  /어떻게\s*(만들|해|하지|쓰지|구현|시작)/,
  /\s(좋아|좋니|괜찮아|괜찮니)\s*[?？]/,
  /어디(가|서)\s*(좋|추천)/,
  /회사\s*(어디|추천)/,
  // 시간 한정 팀 활동 (팀 회고 이번 주 같은)
  /(이번|다음|지난|저번|오늘|내일|어제)\s*(주|달|월|금요일|월요일).*(회의|회고|브리핑|리뷰|미팅)/,
  /(팀|조)\s*(회고|회의|미팅)\s*(이번|다음|지난|언제|어디)/,
];

/**
 * 자연어 텍스트에서 스킬 트리거 감지.
 * @param {string} text 사용자 입력 메시지
 * @returns {{skill: string, confidence: number, via: string} | null}
 */
export function detectSkillTrigger(text) {
  // kill switch — 전체 트리거 비활성화 환경변수
  if (process.env.DISCORD_SKILL_TRIGGER_ENABLED === '0') return null;

  if (!text || typeof text !== 'string') return null;

  const trimmed = text.trim();
  if (!trimmed) return null;

  // 부정 패턴 선 검사 — 오탐 방지
  for (const np of NEGATIVE_PATTERNS) {
    if (np.test(trimmed)) return null;
  }

  const lower = trimmed.slice(0, 2000).toLowerCase();

  for (const { skill, patterns } of TRIGGER_MATRIX) {
    // 1) 명시적 /skill 입력 — 최고 신뢰도
    const explicitSlash = new RegExp(`^/${skill}(\\s|$)`, 'i');
    if (explicitSlash.test(trimmed)) {
      return { skill, confidence: 1.0, via: 'explicit-slash' };
    }

    // 2) 자연어 키워드 매칭
    for (const p of patterns) {
      if (p.test(lower)) {
        return { skill, confidence: 0.8, via: 'keyword' };
      }
    }
  }

  return null;
}

export const SKILLS = TRIGGER_MATRIX.map((m) => m.skill);
export { TRIGGER_MATRIX };
