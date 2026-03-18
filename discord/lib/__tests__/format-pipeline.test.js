/**
 * Comprehensive tests for format-pipeline.js
 *
 * Since the module only exports formatForDiscord(), we test each internal
 * transform by crafting inputs that isolate one transform's behavior at a time.
 *
 * Channel override tests verify that specific transforms can be skipped.
 */

import { describe, it, expect } from 'vitest';
import { formatForDiscord } from '../format-pipeline.js';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Build a standard markdown table string. */
function makeTable(headers, separator, rows) {
  const lines = [
    '| ' + headers.join(' | ') + ' |',
    separator,
    ...rows.map((r) => '| ' + r.join(' | ') + ' |'),
  ];
  return lines.join('\n');
}

// A simple 3-column table used in many tests.
const SIMPLE_TABLE = makeTable(
  ['Name', 'Role', 'Status'],
  '| --- | --- | --- |',
  [
    ['Alice', 'Dev', 'Active'],
    ['Bob', 'PM', 'Away'],
  ],
);

// ---------------------------------------------------------------------------
// tableToList
// ---------------------------------------------------------------------------

describe('tableToList', () => {
  it('converts a normal table with header, separator, and data rows to a bullet list', () => {
    const result = formatForDiscord(SIMPLE_TABLE);
    expect(result).toContain('- **Alice** \u00b7 Dev \u00b7 Active');
    expect(result).toContain('- **Bob** \u00b7 PM \u00b7 Away');
    // Should not contain pipe characters from the original table
    expect(result).not.toMatch(/\|.*Alice/);
  });

  it('handles a table at end of string without trailing newline', () => {
    const tableNoTrailing = '| A | B |\n| --- | --- |\n| x | y |';
    const result = formatForDiscord(tableNoTrailing);
    expect(result).toContain('- **x** \u00b7 y');
    expect(result).not.toContain('| x |');
  });

  it('does NOT treat rows with empty cells as separator lines', () => {
    // A row like "|  |  |" should NOT match the separator regex.
    // The separator regex requires at least one dash: -+
    const table = '| H1 | H2 |\n|  |  |\n| data1 | data2 |';
    const result = formatForDiscord(table);
    // Without a valid separator, this should NOT be converted to bullets.
    // The pipe characters should remain.
    expect(result).toContain('|');
  });

  it('does NOT convert a table inside a code fence', () => {
    const fenced = '```\n' + SIMPLE_TABLE + '\n```';
    const result = formatForDiscord(fenced);
    // Table inside code fence should be preserved as-is
    expect(result).toContain('| Alice | Dev | Active |');
    expect(result).not.toContain('- **Alice**');
  });

  it('leaves a table with only header + separator (no data rows) unchanged', () => {
    const headerOnly = '| Name | Role |\n| --- | --- |';
    const result = formatForDiscord(headerOnly);
    // No data rows means the transform returns match unchanged
    expect(result).toContain('| Name | Role |');
  });

  it('leaves single-row pipe text unchanged (not a real table)', () => {
    const singleRow = '| just some pipe text |';
    const result = formatForDiscord(singleRow);
    expect(result).toContain('| just some pipe text |');
  });

  it('converts multiple tables in one string', () => {
    const twoTables = SIMPLE_TABLE + '\n\nSome text\n\n' + makeTable(
      ['Item', 'Price'],
      '| --- | --- |',
      [['Apple', '$1'], ['Banana', '$2']],
    );
    const result = formatForDiscord(twoTables);
    expect(result).toContain('- **Alice**');
    expect(result).toContain('- **Apple** \u00b7 $1');
    expect(result).toContain('- **Banana** \u00b7 $2');
  });

  it('handles a table row with only 1 data column (no rest values)', () => {
    const singleCol = makeTable(
      ['Name'],
      '| --- |',
      [['Alice'], ['Bob']],
    );
    const result = formatForDiscord(singleCol);
    // With only one column, rest is empty, so output should be just bold title
    expect(result).toContain('- **Alice**');
    expect(result).toContain('- **Bob**');
    expect(result).not.toContain('\u00b7'); // no middle dot when only one column
  });

  it('handles Unicode/Korean characters in table cells', () => {
    const koreanTable = makeTable(
      ['\uc774\ub984', '\uc5ed\ud560', '\uc0c1\ud0dc'],
      '| --- | --- | --- |',
      [['\uae40\uc815\uc6b0', '\uac1c\ubc1c\uc790', '\ud65c\uc131']],
    );
    const result = formatForDiscord(koreanTable);
    expect(result).toContain('- **\uae40\uc815\uc6b0** \u00b7 \uac1c\ubc1c\uc790 \u00b7 \ud65c\uc131');
  });

  it('handles a table with alignment markers in separator (e.g., :---:)', () => {
    const aligned = makeTable(
      ['Left', 'Center', 'Right'],
      '| :--- | :---: | ---: |',
      [['a', 'b', 'c']],
    );
    const result = formatForDiscord(aligned);
    expect(result).toContain('- **a** \u00b7 b \u00b7 c');
  });
});

// ---------------------------------------------------------------------------
// normalizeHeadings
// ---------------------------------------------------------------------------

describe('normalizeHeadings', () => {
  it('downshifts # H1 to ## H1', () => {
    const result = formatForDiscord('# Title');
    expect(result).toBe('## Title');
  });

  it('downshifts ## H2 to ### H2', () => {
    const result = formatForDiscord('## Subtitle');
    expect(result).toBe('### Subtitle');
  });

  it('leaves ### H3 unchanged (only shifts 1-2 hash headings)', () => {
    const result = formatForDiscord('### Section');
    expect(result).toBe('### Section');
  });

  it('leaves #### H4 unchanged', () => {
    const result = formatForDiscord('#### Deep');
    expect(result).toBe('#### Deep');
  });

  it('does NOT modify headings inside a code fence', () => {
    const fenced = '```\n# Code comment\n```';
    const result = formatForDiscord(fenced);
    expect(result).toContain('# Code comment');
    expect(result).not.toContain('## Code comment');
  });

  it('handles multiple headings in one string', () => {
    const input = '# First\nSome text\n## Second\nMore text';
    const result = formatForDiscord(input);
    expect(result).toContain('## First');
    expect(result).toContain('### Second');
  });

  it('does not touch # inside a word or non-heading context', () => {
    const result = formatForDiscord('C# is great');
    // "C# is great" does not start with "# " so it should remain unchanged
    expect(result).toBe('C# is great');
  });
});

// ---------------------------------------------------------------------------
// collapseBlankLines
// ---------------------------------------------------------------------------

describe('collapseBlankLines', () => {
  it('collapses 3+ consecutive blank lines to 2', () => {
    const input = 'A\n\n\n\nB';
    const result = formatForDiscord(input);
    expect(result).toBe('A\n\nB');
  });

  it('leaves 2 blank lines as-is', () => {
    const input = 'A\n\nB';
    const result = formatForDiscord(input);
    expect(result).toBe('A\n\nB');
  });

  it('does not modify blank lines inside code fences', () => {
    const input = '```\nA\n\n\n\nB\n```';
    const result = formatForDiscord(input);
    expect(result).toContain('A\n\n\n\nB');
  });
});

// ---------------------------------------------------------------------------
// trimHorizontalRules
// ---------------------------------------------------------------------------

describe('trimHorizontalRules', () => {
  it('keeps the first 2 horizontal rules', () => {
    const input = '---\ntext\n---\nmore';
    const result = formatForDiscord(input);
    expect(result.match(/^---+$/gm)?.length).toBe(2);
  });

  it('removes the 3rd and beyond horizontal rules', () => {
    const input = '---\nA\n---\nB\n---\nC\n---\nD';
    const result = formatForDiscord(input);
    const matches = result.match(/^---+$/gm) || [];
    expect(matches.length).toBe(2);
  });

  it('does not modify --- inside code fences', () => {
    const input = '---\n---\n```\n---\n---\n---\n```\n---';
    const result = formatForDiscord(input);
    // 2 outside rules remain, the 3rd outside one (after code fence) is removed
    // But the ones inside the code fence are untouched
    expect(result).toContain('```\n---\n---\n---\n```');
  });
});

// ---------------------------------------------------------------------------
// suppressLinkPreviews
// ---------------------------------------------------------------------------

describe('suppressLinkPreviews', () => {
  it('wraps bare URLs in <> when there are 2+ bare URLs', () => {
    const input = 'Check https://example.com and https://test.com';
    const result = formatForDiscord(input);
    expect(result).toContain('<https://example.com>');
    expect(result).toContain('<https://test.com>');
  });

  it('does NOT wrap URLs when there is only 1 bare URL', () => {
    const input = 'Visit https://example.com for more.';
    const result = formatForDiscord(input);
    expect(result).toContain('https://example.com');
    expect(result).not.toContain('<https://example.com>');
  });

  it('does NOT double-wrap URLs already in <>', () => {
    const input = '<https://example.com> and https://another.com and https://third.com';
    const result = formatForDiscord(input);
    // The already-wrapped URL should not become <<https://example.com>>
    expect(result).not.toContain('<<');
    // The bare URLs should be wrapped
    expect(result).toContain('<https://another.com>');
    expect(result).toContain('<https://third.com>');
  });

  it('does NOT wrap URLs in markdown links [text](url)', () => {
    const input = 'Click [here](https://example.com) and see https://a.com and https://b.com';
    const result = formatForDiscord(input);
    // The markdown link URL follows ( so the lookbehind should skip it
    expect(result).not.toContain('[here](<https://example.com>)');
    // The bare ones should be wrapped
    expect(result).toContain('<https://a.com>');
    expect(result).toContain('<https://b.com>');
  });

  it('does NOT wrap URLs inside code fences', () => {
    const fenced = '```\nhttps://code.example.com\nhttps://code2.example.com\n```\n\nhttps://a.com and https://b.com';
    const result = formatForDiscord(fenced);
    // URLs inside code fence should remain bare
    expect(result).toContain('https://code.example.com');
    expect(result).not.toContain('<https://code.example.com>');
  });
});

// ---------------------------------------------------------------------------
// discordTimestamp
// ---------------------------------------------------------------------------

describe('discordTimestamp', () => {
  it('converts YYYY-MM-DD HH:MM KST to Discord timestamp', () => {
    const input = '2026-03-08 14:00 KST';
    const result = formatForDiscord(input);
    expect(result).toMatch(/<t:\d+:f> \(<t:\d+:R>\)/);
  });

  it('converts YYYY-MM-DD HH:MM:SS UTC to Discord timestamp', () => {
    const input = '2026-03-08 14:00:30 UTC';
    const result = formatForDiscord(input);
    expect(result).toMatch(/<t:\d+:f>/);
    // The UTC epoch for 2026-03-08 14:00:30 UTC
    const expected = Math.floor(Date.parse('2026-03-08T14:00:30+00:00') / 1000);
    expect(result).toContain(`<t:${expected}:f>`);
  });

  it('defaults to KST when no timezone specified', () => {
    const input = '2026-03-08 09:00';
    const result = formatForDiscord(input);
    // Should parse as KST (+09:00), which means 00:00 UTC
    const expected = Math.floor(Date.parse('2026-03-08T09:00:00+09:00') / 1000);
    expect(result).toContain(`<t:${expected}:f>`);
  });

  it('does NOT convert timestamps inside code fences', () => {
    const input = '```\n2026-03-08 14:00 KST\n```';
    const result = formatForDiscord(input);
    expect(result).toContain('2026-03-08 14:00 KST');
    expect(result).not.toContain('<t:');
  });

  it('handles invalid date gracefully (returns original match)', () => {
    const input = '9999-99-99 99:99 KST';
    const result = formatForDiscord(input);
    // Date.parse returns NaN for invalid dates; the function should return match unchanged
    expect(result).toContain('9999-99-99 99:99 KST');
  });
});

// ---------------------------------------------------------------------------
// formatForDiscord (integration / pipeline)
// ---------------------------------------------------------------------------

describe('formatForDiscord (integration)', () => {
  it('applies all transforms in a single pass: table + heading + URLs', () => {
    const input = [
      '# Report',
      '',
      '| Metric | Value |',
      '| --- | --- |',
      '| CPU | 45% |',
      '| RAM | 60% |',
      '',
      'See https://example.com and https://test.com for details.',
    ].join('\n');

    const result = formatForDiscord(input);

    // Heading downshifted
    expect(result).toContain('## Report');
    // Table converted to list
    expect(result).toContain('- **CPU** \u00b7 45%');
    expect(result).toContain('- **RAM** \u00b7 60%');
    // URLs wrapped (2+ bare URLs)
    expect(result).toContain('<https://example.com>');
    expect(result).toContain('<https://test.com>');
  });

  it('respects CHANNEL_OVERRIDES: jarvis-market channel skips tableToList', () => {
    const marketChannelId = process.env.MARKET_CHANNEL_ID || '0000000000000000001';
    const input = SIMPLE_TABLE;

    const result = formatForDiscord(input, { channelId: marketChannelId });

    // tableToList should be skipped, so pipe characters remain
    expect(result).toContain('| Alice | Dev | Active |');
    expect(result).not.toContain('- **Alice**');
  });

  it('applies tableToList for an unknown channel (no override)', () => {
    const result = formatForDiscord(SIMPLE_TABLE, { channelId: '999999' });
    expect(result).toContain('- **Alice**');
  });

  it('handles empty string input', () => {
    const result = formatForDiscord('');
    expect(result).toBe('');
  });

  it('handles undefined / no options argument', () => {
    const result = formatForDiscord('Hello world');
    expect(result).toBe('Hello world');
  });

  it('handles very long input (10000+ chars) without crashing', () => {
    const longText = 'A'.repeat(10000) + '\n\nhttps://a.com\nhttps://b.com';
    const result = formatForDiscord(longText);
    expect(result.length).toBeGreaterThan(10000);
    expect(result).toContain('<https://a.com>');
  });

  it('preserves code fences entirely through the full pipeline', () => {
    const input = [
      '# Title',
      '```js',
      '# not a heading',
      '| not | a | table |',
      '| --- | --- | --- |',
      '| x | y | z |',
      'https://url1.com https://url2.com',
      '2026-03-08 14:00 KST',
      '```',
      '## Real heading',
    ].join('\n');

    const result = formatForDiscord(input);

    // Code block content should be completely untouched
    expect(result).toContain('# not a heading');
    expect(result).toContain('| not | a | table |');
    expect(result).toContain('| x | y | z |');

    // Outside code fence, transforms should apply
    expect(result).toContain('## Title');
    expect(result).toContain('### Real heading');
  });

  it('handles input with only whitespace', () => {
    const result = formatForDiscord('   \n\n   ');
    expect(typeof result).toBe('string');
  });

  it('handles input with no transformable content', () => {
    const plain = 'Just a simple message with nothing special.';
    const result = formatForDiscord(plain);
    expect(result).toBe(plain);
  });
});

// ---------------------------------------------------------------------------
// withCodeFenceGuard (indirect testing through edge cases)
// ---------------------------------------------------------------------------

describe('withCodeFenceGuard (edge cases)', () => {
  it('handles multiple code fences in one string', () => {
    const input = '# H1\n```\n# inside1\n```\n# H2\n```\n# inside2\n```\n# H3';
    const result = formatForDiscord(input);
    // Headings outside fences should be shifted
    expect(result).toContain('## H1');
    expect(result).toContain('## H2');
    expect(result).toContain('## H3');
    // Headings inside fences should stay
    expect(result).toContain('# inside1');
    expect(result).toContain('# inside2');
  });

  it('handles unclosed code fence (entire tail treated as code block)', () => {
    // The regex ```[\s\S]*?``` won't match an unclosed fence,
    // so everything after the opening ``` should be treated as normal text
    const input = '# Before\n```\n# After';
    const result = formatForDiscord(input);
    // Since the fence is unclosed, the regex won't capture it as a code block.
    // Both headings should be shifted.
    expect(result).toContain('## Before');
    expect(result).toContain('## After');
  });

  it('handles empty code fence', () => {
    const input = '# H1\n``````\n# H2';
    const result = formatForDiscord(input);
    expect(result).toContain('## H1');
    expect(result).toContain('## H2');
  });
});
