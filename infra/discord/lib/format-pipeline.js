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
