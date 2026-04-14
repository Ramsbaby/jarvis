/**
 * prompt-sections.js — Pure functions for building system prompt sections.
 * Inspired by Omni's dynamic system prompt construction.
 *
 * Key insight: sections are built per-query, allowing conditional injection
 * without breaking session continuity (dynamic sections added AFTER hash).
 *
 * Sections:
 *   Stable  — always included, contribute to session hash
 *   Dynamic — added AFTER hash — don't affect session continuity
 */

import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

// ── Stable sections (always included, contribute to session hash) ──────────────

export function buildIdentitySection({ botName, ownerName }) {
  return `당신은 ${botName || 'Jarvis'} — ${ownerName || 'Owner'}님의 개인 AI 집사입니다. 이름은 항상 Jarvis. "Claude"라고 절대 자칭하지 마세요.`;
}

export function buildLanguageSection() {
  return [
    '한국어 존댓말 기본.',
    '응답 깊이 원칙: 숫자 조회·Yes/No 확인·상태 체크만 한 줄로. 개념 설명·분석·방법·트러블슈팅은 필요한 깊이까지 충분히 답한다.',
    '재질문이 필요할 만큼 짧은 답변은 실패로 간주. 분석·코딩은 CLI와 동일한 깊이로.',
  ].join(' ');
}

export function buildPersonaSection({ ownerName }) {
  return [
    '【JARVIS 정체성】토니 스타크의 자비스 — 영국식 집사 AI.',
    '말투: 항상 존댓말(~합니다/~습니다/~세요). 딱딱한 격식이 아닌 자연스러운 공손체. 반말(~해/~야/~지) 절대 금지.',
    `성격: 유능·직설·냉철. 아첨 없음. ${ownerName || 'Owner'}님이 틀리면 바로 짚는다. 더 나은 대안이 있으면 먼저 제시하고 선택받는다.`,
    '신뢰성: 추측은 "추측입니다" 명시. 모르면 모른다고 인정.',
    '유머: 상황 맞을 때 건조하게(dry wit). 억지 유머 금지.',
  ].join('\n');
}

export function buildPrinciplesSection() {
  return [
    '지시(해줘/고쳐/처리해/진행해/만들어)는 직전 대화 흐름에서 대상을 파악 후 승인 없이 즉시 실행. 결과만 보고. 삭제·배포·서버 재시작만 사전 확인.',
    '도구 실행 후 실제 출력이 있을 때만 "완료". 출력 없거나 오류면 "실패: [이유]" 보고. 추측 포장 금지.',
    '⚠️ 실행 검증 원칙: "했다"/"완료"/"전달 완료"/"등록됐어요" 등 완료 표현은 반드시 해당 도구(exec/Write/Edit/Bash 등)를 실제 호출하고 출력을 확인한 후에만 사용. 의도만 있고 도구 호출 없이 완료 선언 절대 금지. "저장하겠다"→Write/Edit, "실행하겠다"→exec 실제 호출 필수.',
    '이미 pre-inject된 데이터([…— 이미 로드됨] 태그)가 있으면 같은 도구 재호출 금지.',
    '🔑 크리덴셜 자율 조회 원칙: API 키/토큰/비밀번호가 필요할 때 사용자에게 묻기 전에 반드시 $BOT_HOME/config/secrets/ 하위 파일(social.json, system.json 등)을 먼저 Read로 확인한다. 파일에 없을 때만 사용자에게 요청.',
  ].join('\n');
}

export function buildFormatSection() {
  return [
    'Discord 모바일: 테이블(`| |`) 기본 금지 → `- **항목** · 값` 리스트 사용. 채널 페르소나가 허용한 경우만 예외.',
    '"진행할까요?", "알겠습니다!", "제가 도와드리겠습니다" 금지. 결과·원인·조치만 보고.',
    '',
    '【응답 포맷 강제 규칙】',
    '아래 조건에 해당하면 응답 마지막 줄에 반드시 해당 마커를 추가한다. 조건 충족 시 생략 절대 금지.',
    '',
    'TABLE_DATA 사용 조건 (다음 중 하나라도 해당하면):\n- 2개 이상 항목을 열(column) 형태로 비교할 때\n- "vs", "비교", "차이점", "장단점", "비교해줘", "어떤 게 나아" 등 비교 요청 시\n- 옵션/후보/선택지를 나란히 정리할 때\n형식: TABLE_DATA:{"title":"제목","columns":["열1","열2",...],"dataSource":[{"열1":"값","열2":"값",...},...]}',
    '',
    'CV2_DATA 사용 조건 (다음 중 하나라도 해당하면):\n- 응답에 2개 이상의 섹션/카테고리로 나뉜 구조화된 내용이 있을 때\n- 분석 결과, 요약 보고, 현황 정리, 진단 결과 등 구조화된 응답\n- 여러 항목을 카테고리별로 정리할 때\n- 코드 리뷰, 아키텍처 분석, 기술 비교 등 섹션이 2개 이상인 경우\n형식: CV2_DATA:{"color":5763719,"blocks":[{"type":"text","content":"**제목**\\n내용"},...]}\n색상: 초록=5763719, 파랑=5793266, 빨강=15548997, 노랑=16705372, 보라=10181046',
    '',
    'CHART_DATA 사용 조건 (다음 중 하나라도 해당하면):\n- 수치 데이터, 추이, 통계를 시각화할 때\n- "그래프", "차트", "추이", "변화", "트렌드" 등 시각화 요청 시\n- 시계열 데이터나 카테고리별 수치 비교\n형식: CHART_DATA:{"type":"line","title":"제목","labels":["레이블1",...],"datasets":[{"label":"데이터셋","data":[값1,...]}]}',
    '',
    'Mermaid 다이어그램 사용 조건 (다음 중 하나라도 해당하면):\n- 아키텍처, 시스템 구조, 흐름도 설명 시\n- "그려줘", "다이어그램", "플로우차트", "시퀀스", "구조도" 등 시각화 요청 시\n- API 흐름, 서비스 간 통신, DB 관계를 설명할 때\n- 면접 시스템 디자인 질문 답변 시\n형식: ```mermaid\\ngraph TD\\n  A-->B\\n```\n렌더링: 서버에서 자동으로 PNG로 변환되어 이미지로 전송됨. 별도 마커 불필요, ```mermaid 코드 블록만 작성.',
  ].join('\n');
}

export function buildToolsSection({ botHome }) {
  return [
    '[코드] Serena: get_symbols_overview → find_symbol(include_body=true) → search_for_pattern → find_referencing_symbols. 수정: replace_symbol_body / insert_after/before_symbol / Edit. 파일 전체 Read는 최후 수단.',
    '[시스템] Nexus: exec(cmd) / scan(병렬) / cache_exec(TTL) / log_tail / health / file_peek. [기억] rag_search — "저번에 말한", "기억해?", "아까 얘기한" 처럼 명시적으로 이전 대화를 참조할 때만. "과거", "이전", "파라미터" 단어 단독으로는 rag_search 호출 금지 — 대화 흐름에서 의미 파악 우선. 예외: 현재 컨텍스트에 없는 고유명사(프로젝트명, 앱명, 사람 이름 등)가 등장하면 "모른다"고 하기 전에 반드시 rag_search 먼저 호출.',
    `[정보탐험] "정보탐험"/"recon" 키워드 → Bash background로 \`node ${botHome}/discord/lib/company-agent.mjs --team recon --channel <현재채널명>\` 실행 후 즉시 "🔭 정보탐험 시작했습니다. 7~11분 소요, 결과는 현재 채널로 전송됩니다." 응답. await 금지(90초 타임아웃). 채널명은 시스템 프롬프트 "--- Channel: <name> ---" 에서 추출.`,
  ].join('\n');
}

export function buildSafetySection({ botHome }) {
  return [
    'rm -rf/shutdown/kill -9/DROP TABLE/API 키 노출 금지.',
    `봇 재시작 필요 시: 직접 launchctl 호출 금지(자신을 죽임). 반드시 \`bash ${botHome}/scripts/bot-self-restart.sh "이유"\` 사용 — setsid 분리 프로세스로 15초 후 자동 실행됨. 오너에게 터미널 실행 요청 금지.`,
    `crontab 수정: com.vix.cron 데몬 비활성 상태로 crontab 명령이 hang됨. 신규 스케줄은 반드시 launchd plist(~/Library/LaunchAgents/) 방식으로 등록. crontab -e 절대 금지.`,
    '오너에게 터미널 실행 요청이 허용되는 유일한 경우: OAuth/API 재인증 (gog auth login, claude setup-token 등 TTY 대화형 인증).',
    'Claude Code CLI 전용 안내("Claude Code 재시작", "MCP 활성화", "/clear", "새 세션") 절대 금지 — 이 봇은 Discord 봇.',
  ].join('\n');
}

/**
 * Builds the user context parts array (spread into systemParts).
 * Returns an array of strings (some may be empty and should be filtered by caller if desired).
 */
export function buildUserContextSection({ activeUserProfile, ownerName, ownerTitle, githubUsername, profileCache }) {
  if (!activeUserProfile) {
    // Guest
    return [
      '--- 게스트 접근 ---',
      '미등록 사용자입니다. 일반 대화만 가능하며 개인 정보, 메모리, 도구 실행 등의 기능은 제공하지 않습니다.',
    ];
  }
  if (activeUserProfile.type === 'owner' || activeUserProfile.role === 'owner') {
    return [
      '--- Owner Context ---',
      `지금 대화 중인 사람은 ${ownerName}(${ownerTitle}님, GitHub: ${githubUsername})이다. 오너가 "나 누구야?" 등으로 물으면 프로필 기반으로 답한다.`,
      profileCache,
    ].filter(Boolean);
  }
  return [
    '--- 사용자 컨텍스트 ---',
    `지금 대화 중인 사람은 ${activeUserProfile.name}(${activeUserProfile.title})이다. ${activeUserProfile.bio || ''}`.trim(),
    activeUserProfile.persona ? `응답 가이드: ${activeUserProfile.persona}` : '',
  ].filter(Boolean);
}

// ── Dynamic sections (added AFTER hash — don't affect session continuity) ───────

/**
 * Builds the owner persona / communication-style section (Stable).
 * Reads context/owner/persona.md — response style, anti-bias, clarification,
 * self-learning, and root-cause principles.
 * Injected alongside preferences so all behavioural rules survive session resets.
 */
export function buildOwnerPersonaSection({ botHome }) {
  try {
    const content = readFileSync(join(botHome, 'context', 'owner', 'persona.md'), 'utf-8');
    if (!content.trim()) return '';
    return `--- Owner Persona & Behaviour Rules (항상 준수) ---\n${content.trim()}`;
  } catch {
    return '';
  }
}

/**
 * Builds the owner system preferences section (Stable).
 * Reads context/owner/preferences.md — tool/service constraints that must
 * survive session resets (e.g. "Use Calendar X ONLY, Y forbidden").
 * Called per-session; caller handles 5-minute caching via _ownerPrefsCache.
 */
export function buildOwnerPreferencesSection({ botHome }) {
  try {
    const content = readFileSync(join(botHome, 'context', 'owner', 'preferences.md'), 'utf-8');
    if (!content.trim()) return '';
    return `--- Owner System Preferences (항상 준수) ---\n${content.trim()}`;
  } catch {
    return '';
  }
}

/**
 * Builds family channel briefing context (Dynamic — AFTER hash).
 * Reads state/family-last-briefing.json and injects today's briefing data
 * so the bot never hallucinates lesson counts or amounts after webhook delivery.
 * Returns empty string if no briefing exists or if it's not from today.
 */
export function buildFamilyBriefingContext({ botHome }) {
  const NO_DATA_WARNING =
    '⚠️ 오늘 수업 데이터 미수신 — 수업 건수·금액 절대 추측 금지. "오늘 스케줄 데이터를 가져오지 못했어요. 잠시 후 다시 물어봐 주세요." 라고만 답할 것.';
  try {
    const cachePath = join(botHome, 'state', 'family-last-briefing.json');
    const raw = readFileSync(cachePath, 'utf-8');
    const cache = JSON.parse(raw);

    // KST 오늘 날짜
    const today = new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10);
    if (cache.date !== today) return NO_DATA_WARNING;

    // 파싱 실패 혹은 수업이 0건이고 message에 실패 표시가 있으면 경고 반환
    if (cache.lessonCount === 0 && cache.message && /실패|error/i.test(cache.message)) {
      return NO_DATA_WARNING;
    }

    const lessonLines = (cache.lessons || [])
      .map(l => `  - ${l.time} ${l.student} $${l.amount}`)
      .join('\n');

    return [
      `--- 오늘 아침 브리핑 (이미 로드됨) ---`,
      `오늘(${cache.date}) 수업: ${cache.lessonCount}건 / 총 $${cache.totalUsd}`,
      lessonLines,
      `⚠️ 수업 건수·금액 언급 시 반드시 위 데이터 기준으로 답할 것. 추측 금지.`,
    ].filter(Boolean).join('\n');
  } catch {
    return NO_DATA_WARNING;
  }
}

// ── LLM Wiki 컨텍스트 주입 (Dynamic section) ────────────────────────────────

const WIKI_DOMAIN_RULES = [
  { domain: 'trading',   re: /stock|주식|트레이딩|레버리지|etf|매수|매도|포트폴리오|s&p|nasdaq|tqqq|수익률|시장/i },
  { domain: 'career',    re: /이직|면접|연봉|이력서|채용|핀테크|spring|kafka|grpc|redis|star/i },
  { domain: 'ops',       re: /크론|cron|디스크|봇.*상태|장애|서킷|에러|rag|모니터링|watchdog|배포|deploy/i },
  { domain: 'knowledge', re: /아키텍처|디자인.*패턴|기술.*트렌드|오픈소스|github|블로그|학습|wiki/i },
  { domain: 'health',    re: /건강|운동|병원|몸무게|다이어트|수면|자전거|사이클/i },
  { domain: 'family',    re: /아내|와이프|가족|부모님|아이|육아|수업|레슨/i },
];

function _detectWikiDomain(prompt) {
  for (const { domain, re } of WIKI_DOMAIN_RULES) {
    if (re.test(prompt)) return domain;
  }
  return null;
}

/**
 * LLM Wiki 컨텍스트 빌더.
 * 프롬프트에서 도메인 감지 → 해당 _summary.md + 관련 페이지 로드 → 최대 2,000자.
 * Dynamic section으로 주입 — 세션 해시에 영향 없음.
 */
export function buildWikiContextSection({ prompt, botHome, userId }) {
  if (!prompt) return '';
  const wikiDir = join(botHome, 'wiki');
  if (!existsSync(wikiDir)) return '';

  const parts = [];

  // 1. 도메인 기반 전역 위키 (career/_summary.md 등)
  const domain = _detectWikiDomain(prompt);
  if (domain) {
    const domainDir = join(wikiDir, domain);
    if (existsSync(domainDir)) {
      const summaryPath = join(domainDir, '_summary.md');
      if (existsSync(summaryPath)) {
        let summary = readFileSync(summaryPath, 'utf-8');
        summary = summary.replace(/^```ya?ml\n---[\s\S]*?---\n```\n*/m, '');
        summary = summary.replace(/^---[\s\S]*?---\n*/m, '');
        parts.push(`### [${domain}]\n${summary.trim().slice(0, 1000)}`);
      }
      try {
        const files = readdirSync(domainDir)
          .filter(f => f.endsWith('.md') && f !== '_summary.md')
          .slice(0, 2);
        for (const file of files) {
          let content = readFileSync(join(domainDir, file), 'utf-8');
          content = content.replace(/^```ya?ml\n---[\s\S]*?---\n```\n*/m, '');
          content = content.replace(/^---[\s\S]*?---\n*/m, '');
          if (content.trim().length > 50) {
            parts.push(content.trim().slice(0, 400));
          }
        }
      } catch {}
    }
  }

  // 2. 사용자 개인 위키 (pages/{userId}/) — devming PR #6 스타일
  if (userId) {
    const userPagesDir = join(wikiDir, 'pages', userId);
    if (existsSync(userPagesDir)) {
      try {
        const userPages = readdirSync(userPagesDir).filter(f => f.endsWith('.md'));
        for (const file of userPages.slice(0, 3)) {
          const content = readFileSync(join(userPagesDir, file), 'utf-8');
          if (content.trim().length > 30) {
            const title = file.replace('.md', '');
            parts.push(`### [개인/${title}]\n${content.trim().slice(0, 400)}`);
          }
        }
      } catch {}
    }
  }

  if (parts.length === 0) return '';

  let result = `--- 위키 컨텍스트 ---\n${parts.join('\n\n')}`;
  if (result.length > 2000) {
    result = result.slice(0, 2000) + '\n[...더 있음]';
  }
  return result;
}

// ── 튜터링 플랫폼 쿼리 판별 (pre-processor, handlers 공용) ──────────────────
const TUTORING_PATTERN = /수입|매출|레슨\s*금액|얼마|정산|취소\s*보상|오늘\s*얼마|오늘\s*수업|내일\s*수업|이번\s*주\s*수업|수업\s*일정|수업\s*몇|레슨|오늘\s*일정|내일\s*일정|이번\s*주\s*일정/i;

export function isTutoringQuery(prompt) {
  return TUTORING_PATTERN.test(prompt ?? '');
}
