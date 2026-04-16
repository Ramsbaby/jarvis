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
    // "이제/먼저/다음으로 ~합니다/하겠습니다" 류 진행 선언
    /^.{0,5}(?:이제|먼저|다음으로|그럼|우선|그러면).{0,40}(?:합니다|하겠습니다|봅니다|살펴봅니다|확인합니다|수정합니다|진행합니다|처리합니다|추가합니다|변경합니다|작성합니다|삭제합니다|설정합니다|적용합니다).*$/gm,
    // "완료/확인/수정했습니다." 단독 완료 보고 (요약 아닌 단순 보고)
    /^.{0,10}(?:완료|확인|수정|삭제|추가|변경|적용|업데이트|저장|생성|등록)(?:했습니다|됐습니다|되었습니다|완료입니다)\.?\s*$/gm,
    // "line 42", "Lines 60-61" 등 코드 행번호 참조
    /^.{0,10}(?:line|Lines?|라인)\s*\d+(?:\s*[-–~]\s*\d+)?.*(?:제거|삭제|수정|추가|변경).*$/gm,
  ];
  let result = text;
  for (const p of patterns) {
    result = result.replace(p, '');
  }
  return result;
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

/** Downshift headings: # → ##, ## → ###. Discord only renders up to ###. */
const normalizeHeadings = withCodeFenceGuard((text) =>
  text.replace(/^(#{1,2}) /gm, (_, hashes) => '#' + hashes + ' '),
);

/** Collapse 3+ consecutive blank lines to 2. */
const collapseBlankLines = withCodeFenceGuard((text) =>
  text.replace(/(\n\s*){3,}/g, '\n\n'),
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

/** Suppress Discord link previews when 2+ bare URLs in non-code text. */
const suppressLinkPreviews = withCodeFenceGuard((text) => {
  const bareUrls = text.match(/(?<![(<])(https?:\/\/[^\s>)]+)/g) || [];
  if (bareUrls.length < 2) return text;
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

const TRANSFORMS = [
  { name: 'filterNarration', fn: filterNarration },
  { name: 'tableToList', fn: tableToList },
  { name: 'normalizeHeadings', fn: normalizeHeadings },
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
