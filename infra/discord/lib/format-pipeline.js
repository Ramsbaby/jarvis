/**
 * Format pipeline — transforms Claude output for Discord readability.
 *
 * Each transform is a pure (text) => text function.
 * Code blocks (```) are automatically protected via withCodeFenceGuard.
 *
 * Exports: formatForDiscord(text, opts)
 */

// ---------------------------------------------------------------------------
// Code-fence guard (DRY wrapper)
// ---------------------------------------------------------------------------

/**
 * Wrap a text transform so it only applies outside code fences.
 * The inner fn receives one non-code segment at a time.
 */
function withCodeFenceGuard(fn) {
  return (text) => {
    const parts = text.split(/(```[\s\S]*?```)/g);
    return parts.map((part, i) => (i % 2 === 1 ? part : fn(part))).join('');
  };
}

// ---------------------------------------------------------------------------
// Channel overrides
// ---------------------------------------------------------------------------

const _MARKET_ID = process.env.MARKET_CHANNEL_ID || '';
const CHANNEL_OVERRIDES = Object.fromEntries(
  [_MARKET_ID && [_MARKET_ID, { skip: ['tableToList'] }]].filter(Boolean)
);  // jarvis-market: set MARKET_CHANNEL_ID env var to enable tableToList skip

// ---------------------------------------------------------------------------
// Narration filter — tool-use 중간과정 제거 (P0 가독성 개선)
// ---------------------------------------------------------------------------

/**
 * Claude가 출력하는 tool-use 내러티브("이제 ~합니다", "확인합니다" 등)를
 * Discord 전송 전에 제거. 코드 블록 내부는 보호.
 */
const filterNarration = withCodeFenceGuard((text) => {
  const patterns = [
    // [2026-05-21] 감정 트리거 지시문 에코 차단 — 안전망 (1순위)
    // Claude가 systemParts의 [지시] 마커를 preamble로 출력하거나,
    // 이전 버전의 "Round N 각도 / 이번이 N회차 / 현재 저장된 count" 텍스트를 에코할 때 제거.
    /^\[지시[^\]]*\].{0,200}$/gm,
    /^.{0,30}(?:Round\s*\d+\s*각도|이번이\s*\d+회차|현재\s*저장된\s*count).{0,150}$/gm,
    // "이제/먼저/다음으로 ~합니다/하겠습니다" 류 진행 선언 (존칭/경어 포함)
    // [2026-05-21] 그러면|그리고|또한 제거 — 한국어 분석 글의 자연스러운 연결어.
    //   "그리고 합격 가능성을 분석합니다" 같은 legitimate 분석 문장이 삭제되는 FP 방지.
    /^.{0,5}(?:이제|먼저|다음으로|그럼|우선).{0,60}(?:합니다|하겠습니다|봅니다|살펴봅니다|확인합니다|수정합니다|진행합니다|처리합니다|추가합니다|변경합니다|작성합니다|삭제합니다|설정합니다|적용합니다|조회합니다|설치합니다|실행합니다|시작합니다|해주겠습니다|해드리겠습니다|해보겠습니다|해봅니다|할게요|볼게요|볼까요).*$/gm,
    // "~를 확인/실행/호출합니다" — 목적어+도구실행 동사 패턴
    // [2026-05-21] 살펴|검토|분석 제거 — 분석성 응답에서 정당하게 사용되는 동사.
    //   "근거를 분석합니다", "상황을 검토합니다" 같은 분석 문장이 삭제되는 FP 방지.
    /^.{0,50}(?:를|을)\s*(?:확인|실행|호출|조회|가져|불러|로드)(?:합니다|하겠습니다|봅니다|봅시다|볼게요).*$/gm,
    /^.{0,50}(?:에서|에서는)\s*.{0,20}(?:확인|실행|호출|조회|가져|불러|로드)(?:합니다|하겠습니다|봅니다|봅시다|볼게요).*$/gm,
    // "~를 읽습니다/씁니다" — ㅂ니다 종결 동사
    /^.{0,60}(?:읽습니다|씁니다|찾습니다|봅니다|줍니다|잡습니다|넣습니다|뽑습니다|돌립니다)\.?\s*$/gm,
    // "완료/확인/수정했습니다." 단독 완료 보고 (요약 아닌 단순 보고)
    /^.{0,15}(?:완료|확인|수정|삭제|추가|변경|적용|업데이트|저장|생성|등록|설치|실행|복원)(?:했습니다|됐습니다|되었습니다|완료입니다|완료됐습니다|하겠습니다|할게요)\.?\s*$/gm,
    // "line 42", "Lines 60-61", "라인 42번" 등 코드 행번호 참조
    /^.{0,15}(?:line|Lines?|라인|줄)\s*\d+(?:\s*[-–~]\s*\d+)?(?:번)?.*(?:제거|삭제|수정|추가|변경|확인).*$/gm,
    // "결과는 다음과 같습니다" / "상태를 확인했습니다" — 빈 도입부
    /^(?:결과는 다음과 같습니다|상태를 확인했습니다|다음과 같이 처리했습니다|아래와 같습니다)\.?\s*$/gm,
  ];
  let result = text;
  for (const p of patterns) {
    result = result.replace(p, '');
  }
  // 3+줄 연속 빈줄 → 2줄 (narration 제거 후 빈줄 누적 정리)
  return result.replace(/\n{3,}/g, '\n\n');
});

// ---------------------------------------------------------------------------
// Tool-call artifact stripper — 모델이 text 블록에 흘린 함수 호출 XML 제거
// ---------------------------------------------------------------------------

/**
 * [2026-06-15] 모델이 응답 text 안에 흘린 도구 호출 XML 잔재를 제거하는 안전망.
 *
 * 원인: Claude Agent SDK 가 tool_use 블록을 정상 분리하지 못하거나(malformed tool call),
 * 모델이 함수 호출 신택스를 텍스트로 생성하면 invoke/parameter/function_calls 태그로 된
 * XML 블록이 그대로 Discord 로 송출된다. filterNarration 은 "이제 ~합니다" 류 내러티브만
 * 잡을 뿐 이 XML 은 못 거른다.
 *
 * filterNarration 과 달리 항상 ON 으로 둔다 — 이 XML 은 100% 도구호출 누수이지
 * 정상 답변 텍스트가 아니므로 알맹이를 도려낼 위험이 없다. 코드 펜스 내부는
 * withCodeFenceGuard 로 보호하므로, 코드 예시로 의도된 태그는 보존된다.
 */
const stripToolCallArtifacts = withCodeFenceGuard((text) => {
  if (!text || (text.indexOf('<' + 'invoke') < 0 && text.indexOf('<' + 'function_calls') < 0 && text.indexOf('<' + 'parameter') < 0)) {
    return text; // 빠른 경로 — 누수 토큰이 전혀 없으면 정규식 스킵
  }
  let r = text;
  // 1) 완전한 function_calls 래퍼 블록 (antml: prefix 유무 모두 대응)
  r = r.replace(/(?:^|\n)[ \t]*<(?:antml:)?function_calls>[\s\S]*?<\/(?:antml:)?function_calls>[ \t]*/gi, '\n');
  // 2) 완전한 invoke 블록 — 앞에 붙는 'call' 한 줄 prefix까지 함께 제거
  r = r.replace(/(?:^|\n)[ \t]*(?:call[ \t]*\n)?[ \t]*<(?:antml:)?invoke\b[\s\S]*?<\/(?:antml:)?invoke>[ \t]*/gi, '\n');
  // 3) 스트리밍 도중 닫는 태그가 아직 안 온 미완성 블록 — 여는 태그부터 버퍼 끝까지
  //    (1·2에서 완전 블록은 이미 제거됐으므로, 여기 걸리는 건 잘린 잔재뿐)
  r = r.replace(/(?:^|\n)[ \t]*(?:call[ \t]*\n)?[ \t]*<(?:antml:)?(?:function_calls|invoke|parameter)\b[\s\S]*$/i, '\n');
  // 4) 블록 매칭에서 빠진 단독 여닫는 태그 잔재
  r = r.replace(/<\/?(?:antml:)?(?:function_calls|invoke|parameter)\b[^>]*>/gi, '');
  // 5) 제거 후 빈 줄 누적 정리
  return r.replace(/\n{3,}/g, '\n\n');
});

// ---------------------------------------------------------------------------
// Transforms
// ---------------------------------------------------------------------------

/**
 * Convert markdown tables to compact bullet lists (Discord mobile compat).
 * First column becomes bold title, remaining values joined by ·
 */
const tableToList = withCodeFenceGuard((text) =>
  text.replace(
    /(?:^|\n)((?:\|.+\|[ \t]*\n)+\|.+\|[ \t]*(?:\n|$))/g,
    (match) => {
      const lines = match.trim().split('\n').filter((l) => l.trim());
      const sepIdx = lines.findIndex((l) => /^\|[\s:|-]*-+[\s:|-]*\|$/.test(l.trim()));
      if (sepIdx < 0) return match; // not a real table
      const headers = lines[0].split('|').map((c) => c.trim()).filter(Boolean);
      const dataLines = lines.slice(sepIdx + 1);
      if (dataLines.length === 0) return match;
      const result = [''];
      for (const line of dataLines) {
        const cells = line.split('|').map((c) => c.trim()).filter(Boolean);
        const title = cells[0] ?? '';
        const rest = cells.slice(1).filter(Boolean);
        if (rest.length > 0) {
          result.push(`- **${title}** · ${rest.join(' · ')}`);
        } else {
          result.push(`- **${title}**`);
        }
      }
      result.push('');
      return result.join('\n');
    },
  ),
);

/** Downshift H1 → H2 only. Discord natively renders ##/### since 2023 — do NOT downshift further.
 *  2026-05-14: 기존 H2→H3 downshift 제거. ## ### 네이티브 헤더 보존. */
const normalizeHeadings = withCodeFenceGuard((text) =>
  text.replace(/^# /gm, '## '),
);

/** Collapse 3+ consecutive blank lines to 2. */
const collapseBlankLines = withCodeFenceGuard((text) =>
  text.replace(/(\n\s*){3,}/g, '\n\n'),
);

/** Downshift H4+ headers to ### — Discord does not render #### or deeper visually. */
const normalizeDeepHeadings = withCodeFenceGuard((text) =>
  text.replace(/^#{4,} /gm, '### '),
);

/** Strip Discord spoiler wrappers ||text|| → text (click-to-reveal harms mobile readability). */
const suppressSpoilers = withCodeFenceGuard((text) =>
  text.replace(/\|\|(.+?)\|\|/gs, '$1'),
);

/** Keep at most 2 horizontal rules (---) per message. */
function trimHorizontalRules(text) {
  const parts = text.split(/(```[\s\S]*?```)/g);
  let count = 0;
  return parts
    .map((part, i) => {
      if (i % 2 === 1) return part; // code block
      return part.replace(/^---+$/gm, (match) => {
        count++;
        return count <= 2 ? match : '';
      });
    })
    .join('');
}

/** Suppress Discord link previews for bare URLs (1개라도 프리뷰 카드 방지). */
const suppressLinkPreviews = withCodeFenceGuard((text) => {
  const bareUrls = text.match(/(?<![(<])(https?:\/\/[^\s>)]+)/g) || [];
  if (bareUrls.length < 1) return text;
  return text.replace(/(?<![(<])(https?:\/\/[^\s>)]+)/g, '<$1>');
});

/** Convert YYYY-MM-DD HH:MM(:SS)? (KST|UTC)? to Discord native timestamp. */
const discordTimestamp = withCodeFenceGuard((text) =>
  text.replace(
    /(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}(?::\d{2})?)\s*(KST|UTC)?/g,
    (match, date, time, tz) => {
      const padded = time.length === 5 ? time + ':00' : time;
      const offset = tz === 'UTC' ? '+00:00' : '+09:00'; // default KST
      const ms = Date.parse(`${date}T${padded}${offset}`);
      if (!Number.isFinite(ms)) return match;
      const unix = Math.floor(ms / 1000);
      return `<t:${unix}:f> (<t:${unix}:R>)`;
    },
  ),
);

// ---------------------------------------------------------------------------
// Pipeline runner
// ---------------------------------------------------------------------------

// [2026-05-21] 3-part 안전망 DISABLED — 형식 강제가 답변 영혼 죽임의 dominant 변수로
// 독립 감사관 적발. 자비스가 prompt 층에서 비활성화 보고했으나 이 후처리가 살아있어
// 자연 응답을 다시 3-part로 강제 변환하던 결함. 코드는 보존(env 가드 통해 복구 가능).
const ENABLE_3PART_HEADER_GUARD = false;
const injectSectionHeaders = ENABLE_3PART_HEADER_GUARD
  ? withCodeFenceGuard((text) =>
      text
        .replace(/^\**\s*(💙 공감)\s*\**\s*$/gm, '## $1')
        .replace(/^\**\s*(📊 근거 재확인)\s*\**\s*$/gm, '## $1')
        .replace(/^\**\s*(🎯 다음 행동)\s*\**\s*$/gm, '## $1'),
    )
  : (text) => text;

// [2026-05-22 v5] filterNarration default OFF — 정규식이 "이제 ~합니다", "확인했습니다" 등
// 정상 한국어 분석 문장을 통째 도려냄 → 1500자 모델 출력이 600자로 짜내짐 사고.
// 출력 알맹이 보존이 narration 제거보다 우선. opt-in 방식으로만 활성화.
const _NARRATION_FILTER_ON = process.env.ENABLE_NARRATION_FILTER === '1';
const TRANSFORMS = [
  // [2026-06-15] 최우선 — 도구 호출 XML 누수 제거. 다른 transform 전에 먼저 걷어낸다.
  { name: 'stripToolCallArtifacts', fn: stripToolCallArtifacts },
  ...(_NARRATION_FILTER_ON ? [{ name: 'filterNarration', fn: filterNarration }] : []),
  { name: 'injectSectionHeaders', fn: injectSectionHeaders },
  { name: 'tableToList', fn: tableToList },
  { name: 'normalizeHeadings', fn: normalizeHeadings },
  { name: 'normalizeDeepHeadings', fn: normalizeDeepHeadings },
  { name: 'suppressSpoilers', fn: suppressSpoilers },
  { name: 'collapseBlankLines', fn: collapseBlankLines },
  { name: 'trimHorizontalRules', fn: trimHorizontalRules },
  { name: 'suppressLinkPreviews', fn: suppressLinkPreviews },
  { name: 'discordTimestamp', fn: discordTimestamp },
];

/**
 * Run all transforms on text, respecting channel-level overrides.
 * @param {string} text  Raw markdown from Claude
 * @param {{ channelId?: string }} opts
 * @returns {string} Formatted text for Discord
 */
export function formatForDiscord(text, { channelId } = {}) {
  const overrides = (channelId && CHANNEL_OVERRIDES[channelId]) || {};
  const skipSet = new Set(overrides.skip || []);

  let result = text;
  for (const { name, fn } of TRANSFORMS) {
    if (!skipSet.has(name)) {
      result = fn(result);
    }
  }
  return result;
}

/**
 * Validate text for Discord rendering issues AFTER all transforms.
 * Non-destructive — returns issues list for logging, does not modify text.
 * Called by format-discord.mjs to produce pre-send audit trail.
 *
 * @param {string} text  Formatted text (output of formatForDiscord)
 * @returns {{ type: string, line: number, snippet: string, severity: 'error'|'warn'|'info' }[]}
 */
export function validateForDiscord(text) {
  if (!text || !text.trim()) {
    return [{ type: 'EMPTY_MESSAGE', line: 0, snippet: '', severity: 'error' }];
  }

  const issues = [];
  const lines = text.split('\n');
  let inCodeFence = false;

  lines.forEach((line, i) => {
    const ln = i + 1;

    // Code fence tracking — skip checks inside ``` blocks
    if (/^```/.test(line.trim())) {
      inCodeFence = !inCodeFence;
      return;
    }
    if (inCodeFence) return;

    // H4+ headers — normalizeDeepHeadings should have caught these (safety net)
    if (/^#{4,} /.test(line)) {
      issues.push({ type: 'H4_PLUS_HEADER', line: ln, snippet: line.slice(0, 60), severity: 'warn' });
    }

    // Markdown table row survivors — tableToList should have converted them
    if (/^\|.+\|$/.test(line.trim()) && !/^\|[\s:|-]+\|$/.test(line.trim())) {
      issues.push({ type: 'TABLE_ROW_SURVIVOR', line: ln, snippet: line.slice(0, 60), severity: 'error' });
    }

    // Spoiler syntax survivors — suppressSpoilers should have stripped these
    if (/\|\|.+\|\|/.test(line)) {
      issues.push({ type: 'SPOILER_SYNTAX', line: ln, snippet: line.slice(0, 60), severity: 'warn' });
    }

    // Very long single line (> 1900 chars) — will be chunked mid-line by route script
    if (line.length > 1900) {
      issues.push({ type: 'LONG_LINE', line: ln, snippet: `length=${line.length}`, severity: 'warn' });
    }

    // Bare HTML tags — Discord renders them as plain text, not markup
    if (/<[a-zA-Z][^>]*>/.test(line)) {
      issues.push({ type: 'HTML_TAG', line: ln, snippet: line.slice(0, 60), severity: 'info' });
    }
  });

  return issues;
}
