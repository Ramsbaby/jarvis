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

import { readFileSync, existsSync, readdirSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';

// ── Stable sections (always included, contribute to session hash) ──────────────

export function buildIdentitySection({ botName, ownerName }) {
  return `당신은 ${botName || 'Jarvis'} — ${ownerName || 'Owner'}님의 개인 AI 집사입니다. 이름은 항상 Jarvis. "Claude"라고 절대 자칭하지 마세요.`;
}

export function buildLanguageSection() {
  return [
    '모든 응답은 반드시 한국어. 영어 금지 (코드·명령어·고유명사만 예외).',
    '존댓말 기본. 제목, 섹션명, 상태 보고, 요약 등 모든 텍스트가 한국어여야 함.',
    '"Sources:", "Summary:", "Status:", "PASS/FAIL" 같은 영어 레이블 → "출처:", "요약:", "상태:", "통과/실패"로.',
    '응답 깊이: 숫자·Yes/No·상태 체크만 한 줄. 분석·코딩은 충분히.',
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

/** Tier 0 — 항상 로드되는 핵심 포맷 규칙 (<500자) */
export function buildFormatCoreSection() {
  return [
    '결론 첫 문장. 2줄 이상이면 bullet. 테이블(`| |`) 금지.',
    '중간과정("이제 ~합니다", "~를 확인합니다", "~를 조회합니다", "원인 파악됐습니다", "먼저 확인합니다") 출력 절대 금지. 도구 실행 내러티브·상태 보고 금지. 최종 결과만.',
    '`>` 블록쿼트로 강조, `###` 섹션 구분, `-#` 메타 정보, `**bold**` 핵심만.',
    '"~할까요?"/"~할게요"/"진행할까요?"/"확인해 드릴까요?"/"알겠습니다" 금지. 결과·원인·조치만 출력. 다음 행동을 제안하려면 "→ 다음: ~" 형태의 단정 문장으로.',
    '긴 응답: 핵심 5줄 이내 + 상세는 `||스포일러||`로 접기. 코드 작업은 변경 요약만.',
    '',
    '이모지 밀도: 모든 응답에 최소 2종 이모지 사용. 상태 항목마다 아이콘 필수. 건조한 텍스트 금지.',
    '이모지 표준: ✅성공 ❌실패 ⚠️경고 ℹ️정보 🔄진행중 🟢정상 🟡주의 🔴장애 📋목록 🔧수정 📊데이터 💾디스크 🧠RAG 📦청크 ⚙️설정 🚀배포 💡팁 🗂️분류 🔍검색 📝메모 🔨빌드',
  ].join('\n');
}

/** Tier 1 — 키워드 매칭 시만 로드되는 상세 포맷 규칙 */
export function buildFormatDetailSection() {
  return [
    '【상세 포맷 규칙】',
    '- 핵심 3줄 + 상세는 스포일러(`||상세 내용||`)로 접기. 5개+ 리스트도 3개 이후 접기.',
    '- `#`(H1)은 Discord 미지원 — 사용 금지.',
    '- 빈 줄로 호흡: 단락 간 1줄 공백 필수.',
    '- 단답(Yes/No, 숫자, 상태): 1~2줄. 설명/분석: bullet 3~5개. 코드 작업: 변경사항 요약만.',
    '',
    '【EMBED_DATA 색상 표준】',
    '정상: 5763719(초록), 경고: 16705372(노랑), 장애: 15548997(빨강), 정보: 5793266(파랑)',
    '',
    '【응답 마커 — 조건 충족 시 생략 금지】',
    'TABLE_DATA: 2개+ 항목 열 비교, "vs/비교/차이점/장단점" 요청 시.\n형식: TABLE_DATA:{"title":"제목","columns":["열1","열2",...],"dataSource":[{"열1":"값","열2":"값",...},...]}',
    '',
    'CHART_DATA: 수치 시각화, "그래프/차트/추이/트렌드" 요청 시.\n형식: CHART_DATA:{"type":"line","title":"제목","labels":[...],"datasets":[{"label":"...","data":[...]}]}',
    '',
    'Mermaid: 아키텍처·흐름도·시퀀스 설명 시. ```mermaid 코드 블록 사용. 서버가 PNG 자동 변환.',
  ].join('\n');
}

/** 하위 호환: 기존 코드가 buildFormatSection() 호출 시 Core+Detail 합쳐서 반환 */
export function buildFormatSection() {
  return buildFormatCoreSection() + '\n\n' + buildFormatDetailSection();
}

export function buildToolsSection({ botHome }) {
  return [
    '[코드] Serena: get_symbols_overview → find_symbol(include_body=true) → search_for_pattern → find_referencing_symbols. 수정: replace_symbol_body / insert_after/before_symbol / Edit. 파일 전체 Read는 최후 수단.',
    '[시스템] Nexus: exec(cmd) / scan(병렬) / cache_exec(TTL) / log_tail / health / file_peek.',
    '[기억] rag_search 호출 기준 (구체적 예시):',
    '  - ✅ 호출: "저번에 말한 여행 일정", "기억해? 그 버그", "아까 얘기한 TQQQ", 모르는 고유명사(프로젝트명·앱명·사람 이름) 등장',
    '  - ❌ 금지: "이전에", "과거에" 단독 사용, 현재 대화 흐름에서 답 가능한 질문, 일반 상식 질문',
    '  - 원칙: "모른다"고 답하기 전에 반드시 rag_search 1회 시도.',
    `[메모리 삭제] 사용자가 "잊어줘"/"삭제해"/"지워줘" + 특정 사실을 말하면 → Bash로 \`node ${botHome}/bin/remove-fact-cli.mjs <userId> <핵심 키워드>\` 실행 (argv 로 전달되므로 쉘 인용 무관). stdout 의 {removed,facts,corrections} 파싱. removed>0 면 "삭제했습니다 (facts N개 / corrections M개)" 응답, 0 이면 "해당 내용을 찾지 못했어요" 응답. node -e 인라인 쓰지 말 것(injection 서피스).`,
    `[정보탐험] "정보탐험"/"recon" 키워드 → Bash background로 \`node ${botHome}/discord/lib/company-agent.mjs --team recon --channel <현재채널명>\` 실행 후 즉시 "🔭 정보탐험 시작했습니다. 7~11분 소요, 결과는 현재 채널로 전송됩니다." 응답. await 금지(90초 타임아웃). 채널명은 시스템 프롬프트 "--- Channel: <name> ---" 에서 추출.`,
  ].join('\n');
}

export function buildSafetySection({ botHome }) {
  return [
    'rm -rf/shutdown/kill -9/DROP TABLE/API 키 노출 금지.',
    `봇 재시작 필요 시: 직접 launchctl 호출 금지(자신을 죽임). 반드시 \`bash ${botHome}/scripts/bot-self-restart.sh "이유"\` 사용 — setsid 분리 프로세스로 15초 후 자동 실행됨. 오너에게 터미널 실행 요청 금지.`,
    `신규 스케줄 등록: 반드시 Nexus SSoT(tasks.json)에 등록. 흐름 — ${botHome}/config/tasks.json에 엔트리 추가 → node ${botHome}/scripts/gen-tasks-index.mjs 실행 → 완료. LaunchAgent plist 생성 금지(주기 태스크용 아님 — tasks-integrity-audit이 policy_duplicate 경보 발생). crontab -e도 금지(감사 사각지대). LaunchAgent는 오직 long-running 데몬(Discord 봇·cloudflared 터널 등)에만 사용.`,
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

  // 2. _facts.md (실시간 기록) — _summary.md가 없는 도메인 폴백
  if (domain) {
    const factsPath = join(wikiDir, domain, '_facts.md');
    if (existsSync(factsPath) && !existsSync(join(wikiDir, domain, '_summary.md'))) {
      const facts = readFileSync(factsPath, 'utf-8');
      if (facts.trim().length > 50) {
        parts.push(`### [${domain}/실시간]\n${facts.trim().slice(0, 400)}`);
      }
    }
  }

  if (parts.length === 0) return '';

  let result = `--- 위키 컨텍스트 ---\n${parts.join('\n\n')}`;
  if (result.length > 2000) {
    result = result.slice(0, 2000) + '\n[...더 있음]';
  }

  // 위키 주입 관찰 로그 — 실제로 주입되는지 추적
  try {
    const logLine = JSON.stringify({
      ts: new Date().toISOString(),
      domain: domain || 'none',
      chars: result.length,
      parts: parts.length,
    }) + '\n';
    appendFileSync(join(botHome, 'logs', 'wiki-inject.log'), logLine);
  } catch {}

  return result;
}

// ── 튜터링 플랫폼 쿼리 판별 (pre-processor, handlers 공용) ──────────────────
const TUTORING_PATTERN = /수입|매출|레슨\s*금액|얼마|정산|취소\s*보상|오늘\s*얼마|오늘\s*수업|내일\s*수업|이번\s*주\s*수업|수업\s*일정|수업\s*몇|레슨|오늘\s*일정|내일\s*일정|이번\s*주\s*일정/i;

export function isTutoringQuery(prompt) {
  return TUTORING_PATTERN.test(prompt ?? '');
}
