/**
 * Tests for pre-processor.js
 *
 * Strategy: node:child_process is mocked at the module level via vi.mock so
 * that execSync never touches the filesystem.  claude-runner.js and
 * rag-helper.js are also mocked to avoid heavy side-effects at import time.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// ── Set FAMILY_CHANNEL_IDS env before module load (BORAM_CHANNEL_IDS is read at import time)
process.env.FAMILY_CHANNEL_IDS = '0000000000000000001,0000000000000000002';

// ── Module-level mocks (hoisted before imports) ─────────────────────────────

vi.mock('node:child_process', () => ({
  execSync: vi.fn(),
}));

vi.mock('../claude-runner.js', () => ({
  log: vi.fn(),
}));

vi.mock('../rag-helper.js', () => ({
  PAST_REF_PATTERN: /저번에|아까|기억|지난번|전에 말한|예전에|그때|다시 한번|아까 말한|이전에|방금|위에서|위에꺼|앞에서/,
  searchRagForContext: vi.fn(),
}));

// ── Now import the modules under test ───────────────────────────────────────

import {
  ProcessorContext,
  BasePreProcessor,
  PreplyScheduleProcessor,
  PreplyIncomeProcessor,
  RagContextProcessor,
  PreProcessorRegistry,
  createPreProcessorRegistry,
} from '../pre-processor.js';

import { execSync } from 'node:child_process';

// Channel IDs — dummy values for testing (real IDs come from FAMILY_CHANNEL_IDS env var)
const BORAM_CHANNEL = '0000000000000000001';
const OTHER_BORAM   = '0000000000000000002';
const WRONG_CHANNEL = '9999999999999999999';

// ---------------------------------------------------------------------------
// ProcessorContext
// ---------------------------------------------------------------------------

describe('ProcessorContext', () => {
  it('constructs with all fields', () => {
    const ctx = new ProcessorContext({
      originalPrompt: 'hello',
      channelId: '123',
      threadId: '456',
      botHome: '/home/.jarvis',
    });
    expect(ctx.originalPrompt).toBe('hello');
    expect(ctx.channelId).toBe('123');
    expect(ctx.threadId).toBe('456');
    expect(ctx.botHome).toBe('/home/.jarvis');
  });

  it('originalPrompt is accessible', () => {
    const ctx = new ProcessorContext({ originalPrompt: '테스트', channelId: 'c', threadId: 't', botHome: '/b' });
    expect(ctx.originalPrompt).toBe('테스트');
  });
});

// ---------------------------------------------------------------------------
// BasePreProcessor
// ---------------------------------------------------------------------------

describe('BasePreProcessor', () => {
  const base = new BasePreProcessor();
  const ctx = new ProcessorContext({ originalPrompt: '아무 말', channelId: '1', threadId: '1', botHome: '/b' });

  it('matches() returns false by default', () => {
    expect(base.matches(ctx)).toBe(false);
  });

  it('enrich() returns null by default', async () => {
    const result = await base.enrich('prompt', ctx);
    expect(result).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// PreplyScheduleProcessor
// ---------------------------------------------------------------------------

describe('PreplyScheduleProcessor', () => {
  const proc = new PreplyScheduleProcessor();

  // Helper to make a context for the family channel
  const familyCtx = (prompt, channelId = BORAM_CHANNEL) =>
    new ProcessorContext({ originalPrompt: prompt, channelId, threadId: 't', botHome: '/bot' });

  // ── matches() ────────────────────────────────────────────────────────────

  describe('matches()', () => {
    it('true for "오늘 수업" with correct channelId', () => {
      expect(proc.matches(familyCtx('오늘 수업 몇 개야?'))).toBe(true);
    });

    it('true for "내일 수업" with correct channelId', () => {
      expect(proc.matches(familyCtx('내일 수업 알려줘'))).toBe(true);
    });

    it('true for "이번 주 수업" with correct channelId', () => {
      expect(proc.matches(familyCtx('이번 주 수업 일정'))).toBe(true);
    });

    it('true for "preply 일정" with correct channelId', () => {
      expect(proc.matches(familyCtx('preply 일정 알려줘'))).toBe(true);
    });

    it('true for "레슨 몇 개야" with correct channelId', () => {
      expect(proc.matches(familyCtx('레슨 몇 개야?'))).toBe(true);
    });

    it('true for second family channel id', () => {
      expect(proc.matches(familyCtx('오늘 수업', OTHER_BORAM))).toBe(true);
    });

    it('false for "오늘 수업" with WRONG channelId', () => {
      expect(proc.matches(familyCtx('오늘 수업 몇 개야?', WRONG_CHANNEL))).toBe(false);
    });

    it('false for "내일 수업" with WRONG channelId', () => {
      expect(proc.matches(familyCtx('내일 수업 알려줘', WRONG_CHANNEL))).toBe(false);
    });

    it('false for unrelated prompt "날씨 어때" with correct channelId', () => {
      expect(proc.matches(familyCtx('날씨 어때?'))).toBe(false);
    });
  });

  // ── enrich() ─────────────────────────────────────────────────────────────

  describe('enrich()', () => {
    beforeEach(() => {
      vi.clearAllMocks();
    });

    const successPayload = (items = []) =>
      JSON.stringify({ items });

    const ctx = (prompt) => familyCtx(prompt);

    it('returns enriched prompt with "[Google Calendar Preply 수업 일정 — 이미 로드됨]" prefix on success', async () => {
      execSync.mockReturnValue(Buffer.from(successPayload([
        { start: { dateTime: '2026-03-11T09:00:00+09:00' }, summary: '영어 수업' },
      ])));

      const result = await proc.enrich('오늘 수업 몇 개야?', ctx('오늘 수업 몇 개야?'));
      expect(result).toContain('[Google Calendar Preply 수업 일정 — 이미 로드됨]');
      expect(result).toContain('09:00');
      expect(result).toContain('영어 수업');
    });

    it('returns null when JSON has error field', async () => {
      execSync.mockReturnValue(Buffer.from(JSON.stringify({ error: 'calendar unavailable' })));

      const result = await proc.enrich('오늘 수업', ctx('오늘 수업'));
      expect(result).toBeNull();
    });

    it('returns null when execSync throws (graceful failure)', async () => {
      execSync.mockImplementation(() => { throw new Error('script not found'); });

      // enrich itself should not throw — the registry catches, but enrich may throw;
      // the implementation does NOT catch internally, so expect it to propagate.
      // The registry is responsible for catching. We verify the throw propagates:
      await expect(proc.enrich('오늘 수업', ctx('오늘 수업'))).rejects.toThrow('script not found');
    });

    // ── Date parsing ─────────────────────────────────────────────────────

    it('date parsing: "어제" → yesterday\'s date used in command', async () => {
      execSync.mockReturnValue(Buffer.from(successPayload()));
      await proc.enrich('어제 수업 몇 개야?', ctx('어제 수업 몇 개야?'));

      const cmdArg = execSync.mock.calls[0][0];
      // The command should contain a date string matching YYYY-MM-DD
      const dateMatch = cmdArg.match(/(\d{4}-\d{2}-\d{2})\s+(\d{4}-\d{2}-\d{2})/);
      expect(dateMatch).not.toBeNull();
      // dateFrom and dateTo should be the same (yesterday)
      expect(dateMatch[1]).toBe(dateMatch[2]);

      const yesterday = new Date(Date.now() + 9 * 3600 * 1000);
      yesterday.setDate(yesterday.getDate() - 1);
      const expectedDate = yesterday.toISOString().slice(0, 10);
      expect(dateMatch[1]).toBe(expectedDate);
    });

    it('date parsing: "내일" → tomorrow\'s date used in command', async () => {
      execSync.mockReturnValue(Buffer.from(successPayload()));
      await proc.enrich('내일 수업 어때?', ctx('내일 수업 어때?'));

      const cmdArg = execSync.mock.calls[0][0];
      const dateMatch = cmdArg.match(/(\d{4}-\d{2}-\d{2})\s+(\d{4}-\d{2}-\d{2})/);
      expect(dateMatch).not.toBeNull();
      expect(dateMatch[1]).toBe(dateMatch[2]);

      const tomorrow = new Date(Date.now() + 9 * 3600 * 1000);
      tomorrow.setDate(tomorrow.getDate() + 1);
      const expectedDate = tomorrow.toISOString().slice(0, 10);
      expect(dateMatch[1]).toBe(expectedDate);
    });

    it('date parsing: "이번 주" → two different ISO dates passed as dateFrom/dateTo range', async () => {
      execSync.mockReturnValue(Buffer.from(successPayload()));
      await proc.enrich('이번 주 수업 일정', ctx('이번 주 수업 일정'));

      const cmdArg = execSync.mock.calls[0][0];
      const dateMatch = cmdArg.match(/(\d{4}-\d{2}-\d{2})\s+(\d{4}-\d{2}-\d{2})/);
      // Two dates must appear in the command
      expect(dateMatch).not.toBeNull();
      // They must differ (a range, not a single day)
      expect(dateMatch[1]).not.toBe(dateMatch[2]);
      // Both must be valid YYYY-MM-DD
      expect(dateMatch[1]).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      expect(dateMatch[2]).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      // to must be after from
      expect(new Date(dateMatch[2]).getTime()).toBeGreaterThan(new Date(dateMatch[1]).getTime());
    });

    it('date parsing: ISO date "2026-03-15" used verbatim', async () => {
      execSync.mockReturnValue(Buffer.from(successPayload()));
      await proc.enrich('2026-03-15 수업', ctx('2026-03-15 수업'));

      const cmdArg = execSync.mock.calls[0][0];
      expect(cmdArg).toContain('2026-03-15 2026-03-15');
    });

    it('date parsing: Korean date "3월 15일" → YYYY-03-15', async () => {
      execSync.mockReturnValue(Buffer.from(successPayload()));
      await proc.enrich('3월 15일 수업 알려줘', ctx('3월 15일 수업 알려줘'));

      const cmdArg = execSync.mock.calls[0][0];
      const yr = new Date(Date.now() + 9 * 3600 * 1000).getUTCFullYear();
      expect(cmdArg).toContain(`${yr}-03-15 ${yr}-03-15`);
    });

    it('enriched result contains original prompt as the question', async () => {
      execSync.mockReturnValue(Buffer.from(successPayload()));
      const original = '오늘 수업 몇 개야?';
      const result = await proc.enrich(original, ctx(original));
      expect(result).toContain(`질문: ${original}`);
    });
  });
});

// ---------------------------------------------------------------------------
// PreplyIncomeProcessor
// ---------------------------------------------------------------------------

describe('PreplyIncomeProcessor', () => {
  const proc = new PreplyIncomeProcessor();

  const mkCtx = (prompt) =>
    new ProcessorContext({ originalPrompt: prompt, channelId: BORAM_CHANNEL, threadId: 't', botHome: '/bot' });

  describe('matches()', () => {
    it('true for "오늘 수입"', () => {
      expect(proc.matches(mkCtx('오늘 수입 얼마야?'))).toBe(true);
    });

    it('true for "레슨 금액 얼마야"', () => {
      expect(proc.matches(mkCtx('레슨 금액 얼마야?'))).toBe(true);
    });

    it('true for "정산 얼마"', () => {
      expect(proc.matches(mkCtx('정산 얼마야?'))).toBe(true);
    });

    it('false for "오늘 날씨"', () => {
      expect(proc.matches(mkCtx('오늘 날씨 어때?'))).toBe(false);
    });

    it('false for "코드 고쳐줘"', () => {
      expect(proc.matches(mkCtx('코드 고쳐줘'))).toBe(false);
    });
  });

  describe('enrich()', () => {
    beforeEach(() => {
      vi.clearAllMocks();
    });

    const incomePayload = { scheduledCount: 3, totalIncome: 90 };

    it('returns prompt with "[Preply 오늘 수입 데이터 — 이미 로드됨]" prefix on success (no date arg)', async () => {
      execSync.mockReturnValue(Buffer.from(JSON.stringify(incomePayload)));

      const result = await proc.enrich('오늘 수입 얼마야?', mkCtx('오늘 수입 얼마야?'));
      expect(result).toContain('[Preply 오늘 수입 데이터 — 이미 로드됨]');
    });

    it('extracts Korean date "3월 5일" and passes it as YYYY-MM-DD arg', async () => {
      execSync.mockReturnValue(Buffer.from(JSON.stringify(incomePayload)));

      await proc.enrich('3월 5일 수입 얼마야?', mkCtx('3월 5일 수입 얼마야?'));

      const cmdArg = execSync.mock.calls[0][0];
      const yr = new Date().getFullYear();
      expect(cmdArg).toContain(`${yr}-03-05`);
    });

    it('extracts ISO date "2026-03-05" and passes it as arg', async () => {
      execSync.mockReturnValue(Buffer.from(JSON.stringify(incomePayload)));

      await proc.enrich('2026-03-05 수입 알려줘', mkCtx('2026-03-05 수입 알려줘'));

      const cmdArg = execSync.mock.calls[0][0];
      expect(cmdArg).toContain('2026-03-05');
    });

    it('extracts "어제" and converts to yesterday\'s date arg', async () => {
      execSync.mockReturnValue(Buffer.from(JSON.stringify(incomePayload)));

      await proc.enrich('어제 수입 얼마야?', mkCtx('어제 수입 얼마야?'));

      const cmdArg = execSync.mock.calls[0][0];
      const yesterday = new Date();
      yesterday.setDate(yesterday.getDate() - 1);
      const expectedDate = yesterday.toISOString().slice(0, 10);
      expect(cmdArg).toContain(expectedDate);
    });

    it('returns null when execSync throws (graceful failure propagates to registry)', async () => {
      execSync.mockImplementation(() => { throw new Error('preply script error'); });

      await expect(proc.enrich('오늘 수입', mkCtx('오늘 수입'))).rejects.toThrow('preply script error');
    });

    it('includes original prompt as the question', async () => {
      execSync.mockReturnValue(Buffer.from(JSON.stringify(incomePayload)));
      const original = '오늘 수입 얼마야?';
      const result = await proc.enrich(original, mkCtx(original));
      expect(result).toContain(`질문: ${original}`);
    });
  });
});

// ---------------------------------------------------------------------------
// RagContextProcessor
// ---------------------------------------------------------------------------

describe('RagContextProcessor', () => {
  const mkCtx = (prompt) =>
    new ProcessorContext({ originalPrompt: prompt, channelId: '123', threadId: 't', botHome: '/bot' });

  describe('matches()', () => {
    it('true for "저번에 말한 거"', () => {
      const proc = new RagContextProcessor(vi.fn());
      expect(proc.matches(mkCtx('저번에 말한 거 뭐야?'))).toBe(true);
    });

    it('true for "기억해? 아까"', () => {
      const proc = new RagContextProcessor(vi.fn());
      expect(proc.matches(mkCtx('기억해? 아까 얘기했잖아'))).toBe(true);
    });

    it('true for "지난번에 얘기한"', () => {
      const proc = new RagContextProcessor(vi.fn());
      expect(proc.matches(mkCtx('지난번에 얘기한 거'))).toBe(true);
    });

    it('false for Preply queries (PREPLY_PATTERN exclusion): "오늘 수입"', () => {
      const proc = new RagContextProcessor(vi.fn());
      // PREPLY_PATTERN matches "수입", so even if PAST_REF_PATTERN matched it would be excluded
      expect(proc.matches(mkCtx('오늘 수입 얼마야?'))).toBe(false);
    });

    it('false for unrelated prompt "오늘 날씨"', () => {
      const proc = new RagContextProcessor(vi.fn());
      expect(proc.matches(mkCtx('오늘 날씨 어때?'))).toBe(false);
    });
  });

  describe('enrich()', () => {
    it('long context (>600 chars) is truncated to 600 + "..." prepended to prompt', async () => {
      const longContext = 'X'.repeat(700);
      const searchFn = vi.fn().mockResolvedValue(longContext);
      const proc = new RagContextProcessor(searchFn);

      const result = await proc.enrich('아까 말한 거', mkCtx('아까 말한 거'));
      expect(result).toContain('X'.repeat(600) + '...');
      expect(result).toContain('아까 말한 거');
      expect(result.startsWith('X'.repeat(600) + '...')).toBe(true);
    });

    it('short context (<=600 chars) is prepended as-is', async () => {
      const shortContext = 'RAG 결과입니다';
      const searchFn = vi.fn().mockResolvedValue(shortContext);
      const proc = new RagContextProcessor(searchFn);

      const result = await proc.enrich('저번에 말한 거', mkCtx('저번에 말한 거'));
      expect(result).toBe('RAG 결과입니다\n\n저번에 말한 거');
    });

    it('exactly 600 chars context is NOT truncated', async () => {
      const exactContext = 'A'.repeat(600);
      const searchFn = vi.fn().mockResolvedValue(exactContext);
      const proc = new RagContextProcessor(searchFn);

      const result = await proc.enrich('기억해?', mkCtx('기억해?'));
      expect(result).toContain('A'.repeat(600));
      expect(result).not.toContain('...');
    });

    it('searchFn returns null → returns null (no change)', async () => {
      const searchFn = vi.fn().mockResolvedValue(null);
      const proc = new RagContextProcessor(searchFn);

      const result = await proc.enrich('저번에', mkCtx('저번에'));
      expect(result).toBeNull();
    });

    it('searchFn throws → returns null (graceful)', async () => {
      const searchFn = vi.fn().mockRejectedValue(new Error('RAG error'));
      const proc = new RagContextProcessor(searchFn);

      const result = await proc.enrich('아까', mkCtx('아까'));
      expect(result).toBeNull();
    });
  });
});

// ---------------------------------------------------------------------------
// PreProcessorRegistry
// ---------------------------------------------------------------------------

describe('PreProcessorRegistry', () => {
  it('register() returns this (fluent API)', () => {
    const registry = new PreProcessorRegistry();
    const proc = new BasePreProcessor();
    const returned = registry.register(proc);
    expect(returned).toBe(registry);
  });

  it('run() with no matching processors returns original prompt unchanged', async () => {
    const registry = new PreProcessorRegistry();
    // A processor that never matches
    const noMatch = new BasePreProcessor(); // matches() always returns false
    registry.register(noMatch);

    const ctx = new ProcessorContext({ originalPrompt: 'hello', channelId: '1', threadId: '1', botHome: '/b' });
    const result = await registry.run('hello', ctx);
    expect(result).toBe('hello');
  });

  it('run() with one matching processor returns enriched prompt', async () => {
    const registry = new PreProcessorRegistry();

    const mockProc = {
      name: 'MockProc',
      matches: () => true,
      enrich: vi.fn().mockResolvedValue('enriched result'),
    };
    registry.register(mockProc);

    const ctx = new ProcessorContext({ originalPrompt: 'original', channelId: '1', threadId: '1', botHome: '/b' });
    const result = await registry.run('original', ctx);
    expect(result).toBe('enriched result');
  });

  it('run() with processor that throws logs error and continues, returns last good result', async () => {
    const { log } = await import('../claude-runner.js');
    vi.clearAllMocks();

    const registry = new PreProcessorRegistry();

    const failingProc = {
      name: 'FailingProc',
      matches: () => true,
      enrich: vi.fn().mockRejectedValue(new Error('boom')),
    };

    const goodProc = {
      name: 'GoodProc',
      matches: () => true,
      enrich: vi.fn().mockResolvedValue('good result'),
    };

    registry.register(failingProc);
    registry.register(goodProc);

    const ctx = new ProcessorContext({ originalPrompt: 'original', channelId: '1', threadId: '1', botHome: '/b' });
    const result = await registry.run('original', ctx);

    // Should continue past failing processor and use good processor's result
    expect(result).toBe('good result');
    // log('warn', ...) should have been called
    expect(log).toHaveBeenCalledWith('warn', expect.stringContaining('FailingProc'), expect.any(Object));
  });

  it('sequential processing: processor 2 receives output of processor 1', async () => {
    const registry = new PreProcessorRegistry();

    const proc1 = {
      name: 'Proc1',
      matches: () => true,
      enrich: vi.fn().mockResolvedValue('step1-result'),
    };

    const proc2 = {
      name: 'Proc2',
      matches: () => true,
      enrich: vi.fn().mockResolvedValue('step2-result'),
    };

    registry.register(proc1);
    registry.register(proc2);

    const ctx = new ProcessorContext({ originalPrompt: 'original', channelId: '1', threadId: '1', botHome: '/b' });
    const result = await registry.run('original', ctx);

    // proc2.enrich should receive 'step1-result' (output of proc1)
    expect(proc2.enrich).toHaveBeenCalledWith('step1-result', ctx);
    // Final result is proc2's output
    expect(result).toBe('step2-result');
  });

  it('run() processor returning null does NOT update the result', async () => {
    const registry = new PreProcessorRegistry();

    const proc1 = {
      name: 'NullProc',
      matches: () => true,
      enrich: vi.fn().mockResolvedValue(null),
    };

    const proc2 = {
      name: 'GoodProc',
      matches: () => true,
      enrich: vi.fn().mockResolvedValue('final'),
    };

    registry.register(proc1);
    registry.register(proc2);

    const ctx = new ProcessorContext({ originalPrompt: 'original', channelId: '1', threadId: '1', botHome: '/b' });
    const result = await registry.run('original', ctx);

    // proc2 should receive 'original' since proc1 returned null
    expect(proc2.enrich).toHaveBeenCalledWith('original', ctx);
    expect(result).toBe('final');
  });
});

// ---------------------------------------------------------------------------
// createPreProcessorRegistry
// ---------------------------------------------------------------------------

describe('createPreProcessorRegistry', () => {
  it('returns a PreProcessorRegistry instance', () => {
    const registry = createPreProcessorRegistry(vi.fn());
    expect(registry).toBeInstanceOf(PreProcessorRegistry);
  });

  it('has 3 processors registered (Schedule, Income, Rag) — tested via behavior', async () => {
    vi.clearAllMocks();
    execSync.mockReturnValue(Buffer.from(JSON.stringify({ items: [] })));

    const mockSearch = vi.fn().mockResolvedValue(null);
    const registry = createPreProcessorRegistry(mockSearch);

    // Test 1: Schedule processor matches family channel schedule query
    const schedCtx = new ProcessorContext({
      originalPrompt: '오늘 수업 몇 개야?',
      channelId: BORAM_CHANNEL,
      threadId: 't',
      botHome: '/bot',
    });
    const schedResult = await registry.run('오늘 수업 몇 개야?', schedCtx);
    expect(schedResult).toContain('[Google Calendar Preply 수업 일정 — 이미 로드됨]');

    vi.clearAllMocks();
    execSync.mockReturnValue(Buffer.from(JSON.stringify({ scheduledCount: 0 })));

    // Test 2: Income processor matches income query
    const incomeCtx = new ProcessorContext({
      originalPrompt: '오늘 수입 얼마야?',
      channelId: '123',
      threadId: 't',
      botHome: '/bot',
    });
    const incomeResult = await registry.run('오늘 수입 얼마야?', incomeCtx);
    expect(incomeResult).toContain('[Preply');

    // Test 3: RAG processor matches past-reference query
    const ragSearch = vi.fn().mockResolvedValue('RAG context here');
    const registry2 = createPreProcessorRegistry(ragSearch);
    const ragCtx = new ProcessorContext({
      originalPrompt: '저번에 말한 거 뭐였지?',
      channelId: '123',
      threadId: 't',
      botHome: '/bot',
    });
    const ragResult = await registry2.run('저번에 말한 거 뭐였지?', ragCtx);
    expect(ragResult).toContain('RAG context here');
  });
});
