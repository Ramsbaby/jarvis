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

import { readFileSync, existsSync, readdirSync, appendFileSync, statSync } from 'node:fs';
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
    '`>` 블록쿼트로 강조, `###` 섹션 구분, `-#` 메타 정보, `**bold**` 핵심만. 헤더는 `###`까지만 사용 — `####`·`#####`은 Discord 미지원이므로 절대 금지. 4단계 이상 섹션 구분 필요 시 `**bold**`로 대체.',
    '"~할까요?"/"~할게요"/"진행할까요?"/"확인해 드릴까요?"/"알겠습니다" 금지. 결과·원인·조치만 출력. 다음 행동을 제안하려면 "→ 다음: ~" 형태의 단정 문장으로.',
    '긴 응답: 핵심 요점 먼저, 상세는 섹션(`###`)으로 분리. 스포일러(`||...||`) 금지 — 매번 클릭해야 해서 오히려 불편. 코드 작업은 변경 요약만.',
    '',
    '이모지 밀도: 모든 응답에 최소 2종 이모지 사용. 상태 항목마다 아이콘 필수. 건조한 텍스트 금지.',
    '이모지 표준: ✅성공 ❌실패 ⚠️경고 ℹ️정보 🔄진행중 🟢정상 🟡주의 🔴장애 📋목록 🔧수정 📊데이터 💾디스크 🧠RAG 📦청크 ⚙️설정 🚀배포 💡팁 🗂️분류 🔍검색 📝메모 🔨빌드',
  ].join('\n');
}

/** Tier 1 — 키워드 매칭 시만 로드되는 상세 포맷 규칙 */
export function buildFormatDetailSection() {
  return [
    '【상세 포맷 규칙】',
    '- 핵심 3줄 + 상세는 `###` 섹션으로 분리. 스포일러(`||...||`) 사용 금지. 5개+ 리스트는 카테고리별로 묶기.',
    '- `#`(H1)·`####`·`#####`·`######`은 Discord 미지원 — 사용 금지. 헤더는 `##`/`###`만 허용. 4단계 이상 구분 필요 시 `**bold**`로 대체.',
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
    '[코드] **Serena MUST 우선** (Read 통째 금지): 코드 파일(.ts/.tsx/.js/.mjs/.py) 접근 시 → 먼저 mcp__serena__get_symbols_overview, 그 다음 find_symbol(include_body=true). **Read로 코드 파일 통째 읽기 금지** (1500줄 파일 = 토큰 70% 손실). 추가 탐색: search_for_pattern / find_referencing_symbols. 수정도 Serena 우선: replace_symbol_body / insert_after_symbol / insert_before_symbol. **Read 허용 범위: .md / .json / 짧은 설정 파일만**.',
    '[시스템] Nexus: exec(cmd) / scan(병렬) / cache_exec(TTL) / log_tail / health / file_peek.',
    '[기억] rag_search 호출 기준 (구체적 예시):',
    '  - ✅ 호출: "저번에 말한 여행 일정", "기억해? 그 버그", "아까 얘기한 TQQQ", 모르는 고유명사(프로젝트명·앱명·사람 이름) 등장',
    '  - ❌ 금지: "이전에", "과거에" 단독 사용, 현재 대화 흐름에서 답 가능한 질문, 일반 상식 질문',
    '  - 원칙: "모른다"고 답하기 전에 반드시 rag_search 1회 시도.',
    `[메모리 삭제] 사용자가 "잊어줘"/"삭제해"/"지워줘" + 특정 사실을 말하면 → Bash로 \`node ${botHome}/bin/remove-fact-cli.mjs <userId> <핵심 키워드>\` 실행 (argv 로 전달되므로 쉘 인용 무관). stdout 의 {removed,facts,corrections} 파싱. removed>0 면 "삭제했습니다 (facts N개 / corrections M개)" 응답, 0 이면 "해당 내용을 찾지 못했어요" 응답. node -e 인라인 쓰지 말 것(injection 서피스).`,
    `[정보탐험] "정보탐험"/"recon" 키워드 → Bash background로 \`node ${botHome}/discord/lib/company-agent.mjs --team recon --channel <현재채널명>\` 실행 후 즉시 "🔭 정보탐험 시작했습니다. 7~11분 소요, 결과는 현재 채널로 전송됩니다." 응답. await 금지(90초 타임아웃). 채널명은 시스템 프롬프트 "--- Channel: <name> ---" 에서 추출.`,
  ].join('\n');
}

/**
 * Tier 1 (Contextual) — 코드 작업 시에만 로드되는 Serena 풀 가이드.
 * 2026-04-26 신설: prompt-sections.js의 [코드] 한 줄로는 baseline 본능을 못 이김
 *  → 코드 키워드 매칭 시 5단계 워크플로우 + 자비스맵 핵심 파일 비용표 풀 주입.
 */
export function buildToolsCodeDetailSection() {
  return [
    '## 코드 작업 Serena 5단계 워크플로우 (MUST 준수)',
    '',
    '코드 파일 접근 시 **반드시 이 순서**. Read 통째 호출은 토큰 70~90% 손실.',
    '',
    '| 단계 | 도구 | 설명 | 추정 토큰 |',
    '|:---:|---|---|---:|',
    '| 1 | mcp__serena__get_symbols_overview | 파일 함수/컴포넌트 목록 (가장 먼저) | ~2K |',
    '| 2 | mcp__serena__find_symbol(include_body=true) | 수정 대상 심볼만 정확히 | ~1K |',
    '| 3 | mcp__serena__find_referencing_symbols | 호출처 파악 (blast radius) | ~0.5K |',
    '| 4 | Read (offset+limit, .md/.json만) | 마크다운/설정 파일 부분 읽기 | 상황별 |',
    '| 5 | mcp__serena__find_referencing_symbols | 수정 후 영향 범위 재확인 | ~0.5K |',
    '',
    '## 수정 도구 우선순위',
    '- 1순위: mcp__serena__replace_symbol_body / insert_after_symbol / insert_before_symbol',
    '- 2순위 (Serena 미인식 시만): Edit',
    '',
    '## 자비스맵 핵심 파일 비용 (Read vs Serena)',
    '',
    '| 파일 | 줄 수 | Read 비용 | Serena 비용 |',
    '|---|---:|---:|---:|',
    '| VirtualOffice.tsx | 2,780 | ~20K | ~2K (90% ↓) |',
    '| TeamBriefingPopup.tsx | 1,413 | ~10K | ~1.5K (85% ↓) |',
    '| canvas-draw.ts | 911 | ~7K | ~1K (86% ↓) |',
    '| briefing/route.ts | 874 | ~6K | ~0.8K (87% ↓) |',
    '',
    '## Serena가 안 되는 경우 (Read/Grep 사용 OK)',
    '- CSS-in-JS style 객체 내부 값 (인라인 객체 → LSP 미인식)',
    '- 픽셀 좌표 등 숫자 리터럴 (canvas-draw.ts 좌표값)',
    '- 마크다운/JSON/짧은 설정 파일',
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
  const personaPath = join(botHome, 'context', 'owner', 'persona.md');
  try {
    const content = readFileSync(personaPath, 'utf-8');
    if (!content.trim()) {
      console.error(`[persona] WARN: ${personaPath} 비어있음 — 페르소나 가드 미주입`);
      return '';
    }
    return `--- Owner Persona & Behaviour Rules (항상 준수) ---\n${content.trim()}`;
  } catch (e) {
    // silent fail 재발 방지 (persona-integrity-audit.sh 검출 항목)
    console.error(`[persona] FATAL: ${personaPath} 로드 실패 — ${e.message}. 페르소나 가드 없이 응답 생성됨.`);
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
 * Builds the owner visualization policy section (Stable).
 * Reads context/owner/visualization.md — AI Slop prevention + design defaults
 * applied to all visual outputs (Discord cards, jarvis-board, resume, blog, HTML reports).
 * 출처: Anthropic Opus 4.7 프롬프팅 가이드 (2025-04).
 */
export function buildOwnerVisualizationSection({ botHome }) {
  try {
    const content = readFileSync(join(botHome, 'context', 'owner', 'visualization.md'), 'utf-8');
    if (!content.trim()) return '';
    return `--- Visual Output Design Policy (시각 결과물에 항상 적용) ---\n${content.trim()}`;
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
  { domain: 'career',    re: /이직|면접|연봉|이력서|채용|핀테크|spring|kafka|grpc|redis|star|삼성물산|dxp|홈닉|바인드|ai-itb|조혜정|이주용|이현아/i },
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

  // 3. meta/learned-mistakes.md — 도메인 불문 항상 주입 (Compound Engineering)
  //    오답노트는 "실수 회피"용이므로 모든 응답 전에 참조되어야 함.
  //    도메인 감지와 무관하게 전역 주입.
  //    [가드 #3 2026-04-28] top5 → top10, 캡 1800 → 2500, 키워드 매칭 우선 정렬.
  //    이유: 최신 5건만 노출하면 관련 항목이 6위 이하일 때 LLM에게 안 보임.
  //    사용자 prompt 토큰(2자+ 한글, 3자+ 영문) 추출 → 헤더 섹션별 매칭 점수 부여 → 정렬.
  //    최신성 보너스(상위 3건 +10) 유지로 시간/관련성 균형.
  let mistakesInjected = false;
  try {
    const mistakesPath = join(wikiDir, 'meta', 'learned-mistakes.md');
    if (existsSync(mistakesPath)) {
      let mistakes = readFileSync(mistakesPath, 'utf-8');
      mistakes = mistakes.replace(/^---[\s\S]*?---\n*/m, '').trim();
      if (mistakes.length > 100) {
        const sections = mistakes.split(/^(?=## \d{4}-\d{2}-\d{2})/m);
        const headerSections = sections.filter(s => /^## \d{4}-\d{2}-\d{2}/.test(s));

        // 가드 #3: 사용자 prompt 키워드 추출
        const promptTokens = (prompt || '')
          .toLowerCase()
          .match(/[가-힣]{2,}|[a-z]{3,}/g) || [];
        const uniqTokens = [...new Set(promptTokens)].slice(0, 20);

        // 섹션별 매칭 점수 (긴 토큰 가중)
        const scored = headerSections.map((sec, idx) => {
          const lower = sec.toLowerCase();
          let score = 0;
          for (const tok of uniqTokens) {
            if (lower.includes(tok)) score += tok.length;
          }
          if (idx < 3) score += 10; // 최신 보너스
          return { sec, idx, score };
        });
        scored.sort((a, b) => b.score - a.score || a.idx - b.idx);
        const topN = scored.slice(0, 10).map(x => x.sec.trim());

        const safe = topN.join('\n\n') || mistakes.slice(0, 2200);
        const capped = safe.length > 2500 ? safe.slice(0, 2500) + '\n[...더 있음]' : safe;
        parts.push(`### [meta/오답노트]\n${capped}`);
        mistakesInjected = true;
      }
    }
  } catch {}

  if (parts.length === 0) return '';

  let result = `--- 위키 컨텍스트 ---\n${parts.join('\n\n')}`;
  // [가드 #3 2026-04-28] 캡 3500 → 4500 — 오답노트 top10 (최대 2500자) + 도메인 컨텍스트 동시 수용
  if (result.length > 4500) {
    result = result.slice(0, 4500) + '\n[...더 있음]';
  }

  // 위키 주입 관찰 로그 — 실제로 주입되는지 추적
  // mistakes 필드 추가: meta/learned-mistakes.md 주입 여부 별도 기록 (reference-report용)
  try {
    const logLine = JSON.stringify({
      ts: new Date().toISOString(),
      domain: domain || 'none',
      chars: result.length,
      parts: parts.length,
      mistakes: mistakesInjected,
    }) + '\n';
    appendFileSync(join(botHome, 'logs', 'wiki-inject.log'), logLine);
  } catch {}

  return result;
}

// ── 분노 신호 강제 주입 섹션 (Harness P2) ──────────────────────────────
// anger-detector가 24h 이내 감지한 최신 분노 신호 1건을 다음 turn system prompt에
// "🚨 직전 정정" 헤더로 강제 주입. 같은 편향 즉시 재발 차단.
// learned-mistakes.md top5 캡 밖이라도, 사용자가 방금 정정한 신호는 무조건 LLM에 노출.
export function buildAngerCorrectionSection({ botHome }) {
  try {
    const signalsFile = join(botHome, 'state', 'anger-signals.jsonl');
    if (!existsSync(signalsFile)) return '';
    const raw = readFileSync(signalsFile, 'utf-8').trim();
    if (!raw) return '';
    const lines = raw.split('\n').filter(Boolean);
    if (lines.length === 0) return '';
    let last;
    try { last = JSON.parse(lines[lines.length - 1]); } catch { return ''; }
    if (!last || !last.ts) return '';
    // 24h retention
    const lastMs = new Date(last.ts.replace('+09:00', 'Z')).getTime() - 9 * 3600_000;
    const ageH = (Date.now() - lastMs) / 3600_000;
    if (ageH > 24) return '';
    return `🚨 직전 정정 신호 (${last.ts.slice(11, 16)} KST · 키워드: "${last.keyword}")
주인님이 방금 직전 응답을 정정하셨습니다. 같은 편향 절대 재발 금지.

[직전 사용자 발화]: ${(last.userText || '').slice(0, 300)}
[직전 자비스 응답 일부]: ${(last.assistantText || '').slice(0, 400)}

이번 응답은 위 정정을 반영하여 작성하십시오. 동일 패턴 반복 시 즉시 신뢰 붕괴.`;
  } catch {
    return '';
  }
}

// ── 가드 #2 (2026-04-28): 자동 하네스 트리거 섹션 ───────────────────────
// 사용자 발화에 "동작 원리/메커니즘/어떻게 답 결정" 류 키워드 매칭 시
// 관련 하네스 스크립트 자동 실행 → 결과를 system prompt에 강제 주입.
// LLM이 페르소나 자연어 룰만 보고 코드 SSoT 누락하는 거짓 답변 차단.
export async function buildHarnessAutoTriggerSection(prompt) {
  if (!prompt || typeof prompt !== 'string') return '';
  try {
    const { autoTriggerHarness } = await import('./skill-auto-trigger.mjs');
    const injected = await autoTriggerHarness(prompt);
    return injected || '';
  } catch (err) {
    return '';
  }
}

// ── 가드 #5 (2026-04-29): _facts.md 키워드 매칭 자동 발췌 ───────────────────
// 직전 SSoT Cross-Link 봉쇄 사고: career/_summary.md 존재로 _facts.md 4000줄
// (interview-deep-* 풀 디테일 3995건)이 시스템 프롬프트에 영구 미주입.
// 해결: 사용자 프롬프트 키워드와 매칭되는 bullet line top-N을 600~1000자로 발췌 주입.
//
// 동작:
//  1. 도메인 감지 (이미 _detectWikiDomain 재사용)
//  2. {domain}/_facts.md 라인 단위 분리
//  3. 사용자 prompt 토큰 추출 (한글 2자+ / 영문 3자+)
//  4. 라인별 매칭 점수 (긴 토큰 가중)
//  5. top 8 라인 + 800자 캡으로 발췌
//  6. 매칭 0건이면 빈 문자열 (noise 차단)
//
// 효과:
//  - 4000줄짜리 _facts.md 풀 인덱스에서 관련 부분만 자동 인출
//  - LLM "PENDING/추정" 단정 전 진짜 팩트 도달
//
// [보강 2026-04-29] LRU 캐시 (5분 TTL, max 16) — skill-auto-trigger 패턴 동일.
//   동일 (prompt+domain+factsMtime) 키 5분 내 재호출 시 grep 스킵 → 5~10ms 절감.
//   _facts.md 변경 시 mtime 키로 자동 무효화.
const FACTS_KW_CACHE = new Map();
const FACTS_KW_CACHE_TTL_MS = 5 * 60 * 1000;
const FACTS_KW_CACHE_MAX = 16;

function _factsKwCacheGet(key) {
  const e = FACTS_KW_CACHE.get(key);
  if (!e) return null;
  if (Date.now() > e.expiresAt) { FACTS_KW_CACHE.delete(key); return null; }
  return e.result;
}
function _factsKwCacheSet(key, result) {
  if (FACTS_KW_CACHE.size >= FACTS_KW_CACHE_MAX) {
    const oldest = FACTS_KW_CACHE.keys().next().value;
    if (oldest) FACTS_KW_CACHE.delete(oldest);
  }
  FACTS_KW_CACHE.set(key, { result, expiresAt: Date.now() + FACTS_KW_CACHE_TTL_MS });
}

// ── 가드 #9 (2026-04-29) — 실측 의무 트리거 (Evidence Mandate) ────────────────
// 사용자 prompt가 인프라/시스템 검토 카테고리면 시스템 프롬프트에 실측 의무 룰 강제 prepend.
// LLM 의식 의존 차단 — "딥다이브·검토·분석" 키워드 매칭 시 실측 증거 첨부 의무화.
//
// 트리거 키워드 (정밀 매칭):
//   - 검토·분석·딥다이브·실측·점검·검증
//   - 왜·이유·원인·문제·결함·이슈
//   - 메카니즘·동작·원리·구조·흐름·아키텍처
//   - 박힘·주입·노출·매칭·발동·적용
//
// 효과: 가드 #10 (단정 표현 검출)과 함께 동작 — prepend된 룰을 LLM이 보면
// 단정 표현 자체를 줄임 + 단정 시 실측 증거 동반 → 가드 #10 false positive ↓.
const EVIDENCE_MANDATE_KEYWORDS = [
  /딥다이브|deepdive/i,
  /검토|점검|검증|verify/i,
  /분석|analysis/i,
  /실측|측정/,
  /왜\s*(?:이렇|그렇|안|못|틀|거짓)/,
  /(?:이유|원인|문제|결함|이슈|bug|버그)\s*(?:가|를|는|이|의)?/,
  /(?:메카니즘|메커니즘|동작\s*원리|구조|흐름|아키텍처)/,
  /(?:박힘|주입|노출|매칭|발동|적용|호출|실행)\s*(?:되|중|확인|검증)/,
  /(?:맞을지|맞는지|틀린지|거짓|단정)/,
];

export function buildEvidenceMandateSection({ prompt }) {
  if (!prompt || typeof prompt !== 'string') return '';
  const matched = EVIDENCE_MANDATE_KEYWORDS.some(rx => rx.test(prompt));
  if (!matched) return '';

  return `🚨 실측 의무 트리거 (가드 #9) — 본 질문은 인프라/시스템 검토 카테고리입니다.

답변 작성 규칙 (위반 시 거짓 단정 위험 — 가드 #10이 차단합니다):

1. **단정 표현 옆에 실측 증거 직접 인용 필수**
   - 코드 라인 번호 (예: \`prompt-sections.js#L277\`)
   - 로그 출력 raw 인용 (\`\`\`...\`\`\`로 감싸기)
   - grep/awk/Bash 명령 출력
   - 파일 mtime·크기 등 stat 결과

2. **증거 없는 단정 절대 금지** — "추정"·"가능성"·"~로 보임" 표현으로 대체

3. **다음 표현은 실측 증거 없이 사용 시 가드 #10이 응답 차단**:
   - "박힘 0건 · 주입 0건 · 노출 0 · 매칭 0건"
   - "정확 동일 · 완전 동일 · 정확히 일치"
   - "이미 박혀있음 · 이미 적용됨 · 이미 작동중"
   - "확정됨 · 미주입 · 미적용 · 전혀 없"

4. **코드 grep만으로 단정 금지** — 다음 3가지를 동시 실측:
   - 코드 (grep·Read)
   - 로그 출력 (봇 stdout/stderr·cron log)
   - 실행 흔적 (프로세스 env·실제 동작 결과)

5. **위반 시 다음 turn에 강제 정정 신호 prepend** — anger-signals.jsonl 자동 기록.

오답노트 패턴 (이번 세션 6건 거짓 단정 학습):
- 코드 grep만으로 시스템 구조 단정 (실측 회피)
- dotenv 추가 로드·SSoT 분기 빌더 누락
- 봇 출력 로그 미확인 → "활성 X" 단정
- env 의존성 미검증 → "박힘 0건" 단정`;
}

// ── 가드 #5 (2026-04-29) — _facts.md 키워드 grep ────────────────────────────
export function buildFactsKeywordSection({ prompt, botHome }) {
  if (!prompt || typeof prompt !== 'string') return '';
  try {
    const domain = _detectWikiDomain(prompt);
    if (!domain) return '';

    const factsPath = join(botHome, 'wiki', domain, '_facts.md');
    if (!existsSync(factsPath)) return '';

    // LRU 캐시 hit 검사 — prompt 첫 200자 + domain + mtime
    let cacheKey = '';
    try {
      const mtime = statSync(factsPath).mtimeMs | 0;
      cacheKey = `${domain}:${mtime}:${prompt.slice(0, 200)}`;
      const cached = _factsKwCacheGet(cacheKey);
      if (cached !== null) return cached;
    } catch { /* 캐시 실패해도 계속 진행 */ }

    const facts = readFileSync(factsPath, 'utf-8');
    if (!facts || facts.length < 100) return '';

    // 사용자 prompt 토큰 추출 (한글 2자+ / 영문 3자+)
    const promptTokens = (prompt || '')
      .toLowerCase()
      .match(/[가-힣]{2,}|[a-z]{3,}/g) || [];
    const uniqTokens = [...new Set(promptTokens)].slice(0, 25);
    if (uniqTokens.length === 0) return '';

    // bullet line만 추출 (- [YYYY-MM-DD] [source:...] 패턴)
    const lines = facts.split('\n')
      .filter(line => /^- \[\d{4}-\d{2}-\d{2}\]/.test(line));
    if (lines.length === 0) return '';

    // 라인별 매칭 점수 (긴 토큰 가중치 ↑)
    const scored = lines.map((line) => {
      const lower = line.toLowerCase();
      let score = 0;
      for (const tok of uniqTokens) {
        if (lower.includes(tok)) {
          score += tok.length;  // 긴 토큰일수록 의미 있음
        }
      }
      return { line, score };
    }).filter(s => s.score > 0)
      .sort((a, b) => b.score - a.score);

    if (scored.length === 0) {
      if (cacheKey) _factsKwCacheSet(cacheKey, '');
      return '';
    }

    // top 8 + 800자 캡
    const TOP_N = 8;
    const CAP = 800;
    const picked = [];
    let total = 0;
    for (const { line } of scored.slice(0, TOP_N)) {
      const trimmed = line.trim();
      if (total + trimmed.length + 1 > CAP) break;
      picked.push(trimmed);
      total += trimmed.length + 1;
    }
    if (picked.length === 0) {
      if (cacheKey) _factsKwCacheSet(cacheKey, '');
      return '';
    }

    const out = [
      `--- [${domain}/_facts 키워드 매칭 발췌 — 매 응답 자동 인출] ---`,
      `사용자 발화 키워드(${uniqTokens.slice(0, 8).join(', ')})와 매칭되는 _facts.md 항목 ${picked.length}건. 진짜 팩트 베이스 — PENDING/추정 단정 전 반드시 참조:`,
      '',
      ...picked,
      `--- _facts 발췌 끝 ---`,
    ].join('\n');
    if (cacheKey) _factsKwCacheSet(cacheKey, out);
    return out;
  } catch {
    return '';
  }
}

// ── 튜터링 플랫폼 쿼리 판별 (pre-processor, handlers 공용) ──────────────────
const TUTORING_PATTERN = /수입|매출|레슨\s*금액|얼마|정산|취소\s*보상|오늘\s*얼마|오늘\s*수업|내일\s*수업|이번\s*주\s*수업|수업\s*일정|수업\s*몇|레슨|오늘\s*일정|내일\s*일정|이번\s*주\s*일정/i;

export function isTutoringQuery(prompt) {
  return TUTORING_PATTERN.test(prompt ?? '');
}

// ── 오너 시간 인식 컨텍스트 (Dynamic section) ────────────────────────────────
// KST 현재시각 + 마지막 활동 경과시간 + 오너 수면 패턴을 주입.
// runtime/state/last-activity.json, owner-schedule.json 파일 기반.
// 파일 없어도 봇 크래시 없도록 try-catch 전체 감싸기.
export function buildOwnerTimeContext({ botHome }) {
  if (!botHome) return '';

  const stateDir = join(botHome, 'state');
  const lines = [];

  // 1. KST 현재시각
  try {
    const now = new Date();
    const parts = new Intl.DateTimeFormat('ko-KR', {
      timeZone: 'Asia/Seoul',
      year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', weekday: 'short',
      hour12: false,
    }).formatToParts(now);
    const get = (type) => parts.find(p => p.type === type)?.value ?? '';
    const kstStr = `${get('year')}-${get('month')}-${get('day')} ${get('hour')}:${get('minute')} KST (${get('weekday')})`;
    lines.push(`현재 KST: ${kstStr}`);
  } catch { /* silent */ }

  // 2. 마지막 활동 경과시간
  try {
    const lastActivityPath = join(stateDir, 'last-activity.json');
    if (existsSync(lastActivityPath)) {
      const data = JSON.parse(readFileSync(lastActivityPath, 'utf-8'));
      if (data.timestamp) {
        const lastTs = new Date(data.timestamp).getTime();
        const elapsedMs = Date.now() - lastTs;
        const elapsedH = Math.floor(elapsedMs / 3600_000);
        const elapsedM = Math.floor((elapsedMs % 3600_000) / 60_000);
        if (elapsedH > 0) {
          lines.push(`마지막 활동: ${elapsedH}시간 ${elapsedM}분 전`);
        } else if (elapsedM > 1) {
          lines.push(`마지막 활동: ${elapsedM}분 전`);
        }
      }
    }
  } catch { /* silent */ }

  // 3. 오너 수면 패턴
  try {
    const schedulePath = join(stateDir, 'owner-schedule.json');
    if (existsSync(schedulePath)) {
      const schedule = JSON.parse(readFileSync(schedulePath, 'utf-8'));
      if (schedule.wake_time) lines.push(`오너 기상 시간: ${schedule.wake_time}`);
      if (schedule.sleep_time) lines.push(`오너 취침 시간: ${schedule.sleep_time}`);
    }
  } catch { /* silent */ }

  if (lines.length === 0) return '';
  return `--- 오너 시간 컨텍스트 ---\n${lines.join('\n')}`;
}

