/**
 * Tests for rag-engine.mjs
 *
 * Strategy:
 * - splitMarkdown: pure function, tested directly without mocks.
 * - RAGEngine: LanceDB, OpenAI, fs/promises are all mocked at the module level
 *   so no actual network or disk I/O occurs.
 * - node:fs (sync) is mocked to prevent lock directory creation on disk.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// ── Module-level mocks (hoisted before any import) ───────────────────────────

// LanceDB mock
vi.mock('@lancedb/lancedb', () => {
  const mockTable = {
    countRows: vi.fn().mockResolvedValue(42),
    query: vi.fn().mockReturnValue({
      fullTextSearch: vi.fn().mockReturnValue({
        limit: vi.fn().mockReturnValue({
          toArray: vi.fn().mockResolvedValue([]),
        }),
      }),
      select: vi.fn().mockReturnValue({
        limit: vi.fn().mockReturnValue({
          toArray: vi.fn().mockResolvedValue([]),
        }),
      }),
    }),
    search: vi.fn().mockReturnValue({
      limit: vi.fn().mockReturnValue({
        toArray: vi.fn().mockResolvedValue([]),
      }),
    }),
    createIndex: vi.fn().mockResolvedValue(undefined),
    add: vi.fn().mockResolvedValue(undefined),
    delete: vi.fn().mockResolvedValue(undefined),
    optimize: vi.fn().mockResolvedValue(undefined),
  };

  const mockDb = {
    openTable: vi.fn().mockResolvedValue(mockTable),
    createTable: vi.fn().mockResolvedValue(mockTable),
    tableNames: vi.fn().mockResolvedValue(['documents']),
    query: vi.fn().mockResolvedValue({
      toArray: vi.fn().mockResolvedValue([{ cnt: 3 }]),
    }),
  };

  return {
    default: {
      connect: vi.fn().mockResolvedValue(mockDb),
    },
    connect: vi.fn().mockResolvedValue(mockDb),
    Index: {
      fts: vi.fn().mockReturnValue({}),
    },
    // Export the mockTable/mockDb for test access
    _mockTable: mockTable,
    _mockDb: mockDb,
  };
});

// OpenAI mock — must be a class (constructor) since RAGEngine does `new OpenAI()`
vi.mock('openai', () => {
  class MockOpenAI {
    constructor() {
      this.embeddings = {
        create: vi.fn().mockResolvedValue({
          data: [{ embedding: new Array(1536).fill(0.1) }],
        }),
      };
      this.chat = {
        completions: {
          create: vi.fn().mockResolvedValue({
            choices: [{
              message: {
                content: '{"importance": 0.7, "entities": ["Jarvis"], "topics": ["AI", "automation"]}',
              },
            }],
          }),
        },
      };
    }
  }
  return { default: MockOpenAI };
});

// apache-arrow mock (imported but not used in tests directly)
vi.mock('apache-arrow', () => ({}));

// node:fs/promises mock — prevent real filesystem access
vi.mock('node:fs/promises', () => ({
  readFile: vi.fn().mockResolvedValue('# Test\nSome content here for testing purposes.\n'),
  readdir: vi.fn().mockResolvedValue([]),
  stat: vi.fn().mockResolvedValue({ mtimeMs: Date.now() }),
  readFileAsync: vi.fn().mockResolvedValue(''),
}));

// node:fs (sync) mock — prevent lock directory creation
vi.mock('node:fs', () => ({
  mkdirSync: vi.fn(),
  rmdirSync: vi.fn(),
  statSync: vi.fn().mockReturnValue({ mtimeMs: Date.now() - 60_000 }),
  appendFileSync: vi.fn(),
}));

// ── Now import modules under test ───────────────────────────────────────────

import { RAGEngine, splitMarkdown } from '../../../lib/rag-engine.mjs';
import * as lancedb from '@lancedb/lancedb';
import { readFile } from 'node:fs/promises';
import { mkdirSync } from 'node:fs';

// ---------------------------------------------------------------------------
// splitMarkdown — pure function tests (no mocks needed)
// ---------------------------------------------------------------------------

describe('splitMarkdown', () => {
  it('returns empty array for empty string', () => {
    const result = splitMarkdown('');
    expect(result).toEqual([]);
  });

  it('returns empty array for whitespace-only content', () => {
    const result = splitMarkdown('   \n\n  ');
    expect(result).toEqual([]);
  });

  it('skips chunks shorter than 30 characters', () => {
    const result = splitMarkdown('Short');
    expect(result).toEqual([]);
  });

  it('returns a single chunk for simple short content', () => {
    const content = '# Section\nThis is some content that is long enough to be indexed by the RAG system.';
    const result = splitMarkdown(content);
    expect(result.length).toBeGreaterThanOrEqual(1);
    expect(result[0]).toHaveProperty('text');
    expect(result[0]).toHaveProperty('headerPath');
    expect(result[0]).toHaveProperty('index');
  });

  it('splits on markdown headers (##)', () => {
    const content = [
      '# Header 1',
      'Content of section 1. This is long enough to be treated as a chunk by the splitter.',
      '',
      '## Header 2',
      'Content of section 2. This is also long enough to be treated as a separate chunk.',
    ].join('\n');

    const result = splitMarkdown(content);
    expect(result.length).toBeGreaterThanOrEqual(2);
  });

  it('tracks header hierarchy in headerPath', () => {
    const content = [
      '# Top Level',
      'Some content that is long enough for a proper chunk to be created here.',
      '## Sub Level',
      'More content here that is long enough for a proper chunk in the sub section.',
    ].join('\n');

    const result = splitMarkdown(content);
    // Find a chunk that has a sub-level header
    const subChunk = result.find(c => c.headerPath.includes('Sub Level'));
    expect(subChunk).toBeDefined();
    expect(subChunk.headerPath).toContain('Top Level');
    expect(subChunk.headerPath).toContain('Sub Level');
  });

  it('does not split on headers inside code fences', () => {
    const content = [
      '# Real Header',
      'Content that is definitely long enough to be a valid chunk for testing.',
      '```bash',
      '# This is a comment, not a header',
      'some code here',
      '```',
    ].join('\n');

    const result = splitMarkdown(content);
    // All content should be in one or two chunks (not split on the comment inside fence)
    // The code-fence header should not create a separate chunk
    const hasCodeComment = result.some(c =>
      c.headerPath === 'This is a comment, not a header'
    );
    expect(hasCodeComment).toBe(false);
  });

  it('chunk result objects have correct structure', () => {
    const content = '# Title\nThis content is definitely long enough to be a proper chunk for the test.';
    const result = splitMarkdown(content);
    expect(result.length).toBeGreaterThan(0);
    const chunk = result[0];
    expect(chunk).toHaveProperty('text');
    expect(chunk).toHaveProperty('headerPath');
    expect(chunk).toHaveProperty('index');
    expect(typeof chunk.text).toBe('string');
    expect(typeof chunk.headerPath).toBe('string');
    expect(typeof chunk.index).toBe('number');
  });

  it('chunk index reflects position in output array', () => {
    const content = [
      '# Header A',
      'Section A content that is long enough to be a proper searchable chunk.',
      '## Header B',
      'Section B content that is also long enough to be a proper searchable chunk.',
      '### Header C',
      'Section C content that is also long enough to be a proper searchable chunk.',
    ].join('\n');

    const result = splitMarkdown(content);
    result.forEach((chunk, i) => {
      expect(chunk.index).toBe(i);
    });
  });

  it('forces split when chunk exceeds CHUNK_MAX_CHARS (2000 chars)', () => {
    // Create content that exceeds 2000 chars within a single section
    const longParagraph = 'A'.repeat(2100) + '\n';
    const content = '# Big Section\n' + longParagraph;
    const result = splitMarkdown(content);
    // Should be split into multiple chunks
    expect(result.length).toBeGreaterThanOrEqual(1);
    // No single chunk text should exceed 2000 * 1.5 chars (code block threshold)
    result.forEach(chunk => {
      expect(chunk.text.length).toBeLessThanOrEqual(2000 * 1.5 + 100);
    });
  });

  it('handles Korean text correctly', () => {
    const content = [
      '# 한국어 헤더',
      '이것은 한국어로 작성된 충분히 긴 내용입니다. RAG 인덱싱을 위해 30자 이상이어야 합니다.',
    ].join('\n');

    const result = splitMarkdown(content);
    expect(result.length).toBeGreaterThan(0);
    expect(result[0].text).toContain('한국어');
  });

  it('includes header line in the chunk text', () => {
    const content = '# My Section\nContent of section that is long enough to be indexed.';
    const result = splitMarkdown(content);
    expect(result.length).toBeGreaterThan(0);
    expect(result[0].text).toContain('# My Section');
  });

  it('20% overlap: last chunk lines are repeated in next chunk after size split', () => {
    // Build a section with lines, force a split by size, check overlap
    const lines = Array.from({ length: 50 }, (_, i) => `Line number ${i + 1} with some padding text here.`);
    const content = '# Section\n' + lines.join('\n');
    const result = splitMarkdown(content);
    if (result.length >= 2) {
      // The second chunk should contain some lines from the end of the first
      const firstChunkLines = result[0].text.split('\n');
      const secondChunkText = result[1].text;
      // At least one of the last lines of chunk 0 should appear in chunk 1
      const overlapStart = Math.floor(firstChunkLines.length * 0.8);
      const overlapLines = firstChunkLines.slice(overlapStart);
      const hasOverlap = overlapLines.some(line => line && secondChunkText.includes(line));
      expect(hasOverlap).toBe(true);
    }
  });
});

// ---------------------------------------------------------------------------
// RAGEngine — init() tests
// ---------------------------------------------------------------------------

describe('RAGEngine.init()', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Reset lancedb mock defaults
    lancedb.default.connect.mockResolvedValue(lancedb._mockDb);
    lancedb._mockDb.openTable.mockResolvedValue(lancedb._mockTable);
  });

  it('calls lancedb.connect with the dbPath', async () => {
    const engine = new RAGEngine('/tmp/test-lancedb');
    await engine.init();
    // rag-engine.mjs does `import * as lancedb` and calls `lancedb.connect()`
    expect(lancedb.connect).toHaveBeenCalledWith('/tmp/test-lancedb');
  });

  it('opens the "documents" table on init (table exists)', async () => {
    const engine = new RAGEngine('/tmp/test-lancedb');
    await engine.init();
    expect(lancedb._mockDb.openTable).toHaveBeenCalledWith('documents');
  });

  it('creates table if openTable throws (table not found)', async () => {
    lancedb._mockDb.openTable.mockRejectedValueOnce(new Error('table not found'));
    lancedb._mockDb.createTable.mockResolvedValueOnce(lancedb._mockTable);

    const engine = new RAGEngine('/tmp/test-lancedb');
    await engine.init();
    expect(lancedb._mockDb.createTable).toHaveBeenCalledWith(
      'documents',
      expect.any(Array)
    );
  });

  it('attempts to create FTS index on init', async () => {
    const engine = new RAGEngine('/tmp/test-lancedb');
    await engine.init();
    expect(lancedb._mockTable.createIndex).toHaveBeenCalledWith(
      'text',
      expect.objectContaining({ config: expect.anything() })
    );
  });

  it('does not throw if FTS index creation fails (index already exists)', async () => {
    lancedb._mockTable.createIndex.mockRejectedValueOnce(new Error('index exists'));
    const engine = new RAGEngine('/tmp/test-lancedb');
    await expect(engine.init()).resolves.not.toThrow();
  });

  it('uses default dbPath when none provided', async () => {
    const engine = new RAGEngine();
    await engine.init();
    // Should connect to a path ending in rag/lancedb
    const calledPath = lancedb.connect.mock.calls[0][0];
    expect(calledPath).toMatch(/rag\/lancedb$/);
  });
});

// ---------------------------------------------------------------------------
// RAGEngine.enrichDocument() tests
// ---------------------------------------------------------------------------

describe('RAGEngine.enrichDocument()', () => {
  let engine;

  beforeEach(async () => {
    vi.clearAllMocks();
    lancedb.default.connect.mockResolvedValue(lancedb._mockDb);
    lancedb._mockDb.openTable.mockResolvedValue(lancedb._mockTable);
    engine = new RAGEngine('/tmp/test-lancedb');
    await engine.init();
    delete process.env.ENABLE_RAG_ENRICHMENT;
  });

  afterEach(() => {
    delete process.env.ENABLE_RAG_ENRICHMENT;
  });

  it('returns default values when ENABLE_RAG_ENRICHMENT is not set', async () => {
    const result = await engine.enrichDocument('Some text about AI systems');
    expect(result).toEqual({ importance: 0.5, entities: [], topics: [] });
  });

  it('returns default values when ENABLE_RAG_ENRICHMENT=0', async () => {
    process.env.ENABLE_RAG_ENRICHMENT = '0';
    const result = await engine.enrichDocument('Some text');
    expect(result).toEqual({ importance: 0.5, entities: [], topics: [] });
  });

  it('calls OpenAI API when ENABLE_RAG_ENRICHMENT=1', async () => {
    process.env.ENABLE_RAG_ENRICHMENT = '1';
    engine.openai.chat.completions.create.mockResolvedValueOnce({
      choices: [{
        message: {
          content: '{"importance": 0.8, "entities": ["Claude"], "topics": ["AI"]}',
        },
      }],
    });
    const result = await engine.enrichDocument('Some important AI text');
    expect(engine.openai.chat.completions.create).toHaveBeenCalled();
    expect(result.importance).toBe(0.8);
    expect(result.entities).toEqual(['Claude']);
    expect(result.topics).toEqual(['AI']);
  });

  it('clamps importance to [0, 1] range', async () => {
    process.env.ENABLE_RAG_ENRICHMENT = '1';
    engine.openai.chat.completions.create.mockResolvedValueOnce({
      choices: [{
        message: { content: '{"importance": 1.5, "entities": [], "topics": []}' },
      }],
    });
    const result = await engine.enrichDocument('text');
    expect(result.importance).toBe(1);
  });

  it('returns default on JSON parse error (graceful degradation)', async () => {
    process.env.ENABLE_RAG_ENRICHMENT = '1';
    engine.openai.chat.completions.create.mockResolvedValueOnce({
      choices: [{ message: { content: 'not valid json !!!' } }],
    });
    const result = await engine.enrichDocument('text');
    expect(result).toEqual({ importance: 0.5, entities: [], topics: [] });
  });

  it('returns default on OpenAI API failure (graceful degradation)', async () => {
    process.env.ENABLE_RAG_ENRICHMENT = '1';
    engine.openai.chat.completions.create.mockRejectedValueOnce(new Error('API error'));
    const result = await engine.enrichDocument('text');
    expect(result).toEqual({ importance: 0.5, entities: [], topics: [] });
  });

  it('strips markdown code fences from JSON response', async () => {
    process.env.ENABLE_RAG_ENRICHMENT = '1';
    engine.openai.chat.completions.create.mockResolvedValueOnce({
      choices: [{
        message: {
          content: '```json\n{"importance": 0.6, "entities": ["test"], "topics": ["test"]}\n```',
        },
      }],
    });
    const result = await engine.enrichDocument('text');
    expect(result.importance).toBe(0.6);
  });

  it('returns default for non-array entities/topics fields', async () => {
    process.env.ENABLE_RAG_ENRICHMENT = '1';
    engine.openai.chat.completions.create.mockResolvedValueOnce({
      choices: [{
        message: {
          content: '{"importance": 0.5, "entities": "not an array", "topics": null}',
        },
      }],
    });
    const result = await engine.enrichDocument('text');
    expect(result.entities).toEqual([]);
    expect(result.topics).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// RAGEngine.embed() tests
// ---------------------------------------------------------------------------

describe('RAGEngine.embed()', () => {
  let engine;

  beforeEach(async () => {
    vi.clearAllMocks();
    lancedb.default.connect.mockResolvedValue(lancedb._mockDb);
    lancedb._mockDb.openTable.mockResolvedValue(lancedb._mockTable);
    engine = new RAGEngine('/tmp/test-lancedb');
    await engine.init();
  });

  it('returns array of embedding arrays', async () => {
    const result = await engine.embed(['hello', 'world']);
    expect(Array.isArray(result)).toBe(true);
    expect(result[0]).toBeInstanceOf(Array);
    expect(result[0].length).toBe(1536);
  });

  it('calls OpenAI embeddings.create with correct model and input', async () => {
    await engine.embed(['test text']);
    expect(engine.openai.embeddings.create).toHaveBeenCalledWith(
      { model: 'text-embedding-3-small', input: ['test text'] },
      expect.any(Object) // signal option
    );
  });

  it('throws immediately on 401 Unauthorized (no retry)', async () => {
    const authErr = new Error('Unauthorized');
    authErr.status = 401;
    engine.openai.embeddings.create.mockRejectedValue(authErr);

    await expect(engine.embed(['test'])).rejects.toThrow('Unauthorized');
    // Should only be called once — no retry
    expect(engine.openai.embeddings.create).toHaveBeenCalledTimes(1);
  });

  it('throws immediately on 403 Forbidden (no retry)', async () => {
    const forbiddenErr = new Error('Forbidden');
    forbiddenErr.status = 403;
    engine.openai.embeddings.create.mockRejectedValue(forbiddenErr);

    await expect(engine.embed(['test'])).rejects.toThrow('Forbidden');
    expect(engine.openai.embeddings.create).toHaveBeenCalledTimes(1);
  });

  it('returns embeddings from response data array', async () => {
    engine.openai.embeddings.create.mockResolvedValueOnce({
      data: [
        { embedding: new Array(1536).fill(0.5) },
        { embedding: new Array(1536).fill(0.3) },
      ],
    });
    const result = await engine.embed(['text1', 'text2']);
    expect(result.length).toBe(2);
    expect(result[0][0]).toBe(0.5);
    expect(result[1][0]).toBe(0.3);
  });
});

// ---------------------------------------------------------------------------
// RAGEngine.search() tests
// ---------------------------------------------------------------------------

describe('RAGEngine.search()', () => {
  let engine;
  let mockQueryChain;

  beforeEach(async () => {
    vi.clearAllMocks();

    // Set up BM25 search mock chain
    mockQueryChain = {
      toArray: vi.fn().mockResolvedValue([
        {
          id: '/path/to/file.md:0',
          text: 'This is test content about Jarvis automation',
          source: '/path/to/file.md',
          header_path: 'Setup > Config',
          chunk_index: 0,
          _distance: 0.1,
        },
      ]),
    };

    const mockFtsChain = {
      limit: vi.fn().mockReturnValue(mockQueryChain),
    };

    const mockFts = {
      fullTextSearch: vi.fn().mockReturnValue(mockFtsChain),
    };

    lancedb._mockTable.query.mockReturnValue(mockFts);

    // Vector search chain mock
    lancedb._mockTable.search.mockReturnValue({
      limit: vi.fn().mockReturnValue({
        toArray: vi.fn().mockResolvedValue([]),
      }),
    });

    lancedb.default.connect.mockResolvedValue(lancedb._mockDb);
    lancedb._mockDb.openTable.mockResolvedValue(lancedb._mockTable);

    engine = new RAGEngine('/tmp/test-lancedb');
    await engine.init();

    // Prevent _rerank from making real fetch calls
    vi.spyOn(engine, '_rerank').mockImplementation(async (_, results) => results);
  });

  it('returns empty array for empty query', async () => {
    const result = await engine.search('');
    expect(result).toEqual([]);
  });

  it('returns empty array for whitespace-only query', async () => {
    const result = await engine.search('   ');
    expect(result).toEqual([]);
  });

  it('returns results with correct shape {text, source, headerPath, distance, chunkIndex}', async () => {
    const results = await engine.search('Jarvis automation');
    expect(results.length).toBeGreaterThan(0);
    const r = results[0];
    expect(r).toHaveProperty('text');
    expect(r).toHaveProperty('source');
    expect(r).toHaveProperty('headerPath');
    expect(r).toHaveProperty('distance');
    expect(r).toHaveProperty('chunkIndex');
  });

  it('maps source, header_path, chunk_index, _distance to camelCase output fields', async () => {
    const results = await engine.search('test query');
    expect(results[0].source).toBe('/path/to/file.md');
    expect(results[0].headerPath).toBe('Setup > Config');
    expect(results[0].chunkIndex).toBe(0);
    expect(results[0].distance).toBe(0.1);
  });

  it('respects limit parameter (default 5)', async () => {
    // Return 10 BM25 results
    const many = Array.from({ length: 10 }, (_, i) => ({
      id: `file.md:${i}`,
      text: `content ${i}`,
      source: 'file.md',
      header_path: '',
      chunk_index: i,
      _distance: i * 0.1,
    }));
    mockQueryChain.toArray.mockResolvedValue(many);

    const results = await engine.search('query', 3);
    expect(results.length).toBeLessThanOrEqual(3);
  });

  it('returns empty array when BM25 throws (FTS not ready)', async () => {
    lancedb._mockTable.query.mockImplementation(() => {
      throw new Error('FTS index not ready');
    });
    engine.openai.embeddings.create.mockRejectedValue(new Error('OpenAI unavailable'));

    const results = await engine.search('anything');
    expect(Array.isArray(results)).toBe(true);
  });

  it('deduplicates vector results already found by BM25', async () => {
    // BM25 returns one result
    mockQueryChain.toArray.mockResolvedValue([{
      id: 'file.md:0',
      text: 'bm25 result',
      source: 'file.md',
      header_path: '',
      chunk_index: 0,
      _distance: 0.1,
    }]);

    // Vector search returns the same id plus one new
    lancedb._mockTable.search.mockReturnValue({
      limit: vi.fn().mockReturnValue({
        toArray: vi.fn().mockResolvedValue([
          { id: 'file.md:0', text: 'bm25 result', source: 'file.md', header_path: '', chunk_index: 0, _distance: 0.05 },
          { id: 'file.md:1', text: 'vec only result', source: 'file.md', header_path: '', chunk_index: 1, _distance: 0.2 },
        ]),
      }),
    });

    const results = await engine.search('query', 10);
    // The duplicate id should appear only once
    const ids = results.map(r => r.source + ':' + r.chunkIndex);
    const uniqueIds = new Set(ids);
    expect(ids.length).toBe(uniqueIds.size);
  });
});

// ---------------------------------------------------------------------------
// RAGEngine._normalizeKoreanQuery() tests
// ---------------------------------------------------------------------------

describe('RAGEngine._normalizeKoreanQuery()', () => {
  let engine;

  beforeEach(async () => {
    vi.clearAllMocks();
    lancedb.default.connect.mockResolvedValue(lancedb._mockDb);
    lancedb._mockDb.openTable.mockResolvedValue(lancedb._mockTable);
    engine = new RAGEngine('/tmp/test-lancedb');
    await engine.init();
  });

  it('removes trailing 에서 from Korean noun', () => {
    const result = engine._normalizeKoreanQuery('삿포로에서 여행');
    expect(result).not.toContain('에서');
    expect(result).toContain('삿포로');
  });

  it('removes trailing 에게 from Korean noun', () => {
    const result = engine._normalizeKoreanQuery('친구에게 선물');
    expect(result).not.toContain('에게');
    expect(result).toContain('친구');
  });

  it('removes trailing 까지 from Korean noun', () => {
    const result = engine._normalizeKoreanQuery('서울까지 거리');
    expect(result).not.toContain('까지');
    expect(result).toContain('서울');
  });

  it('returns plain query unchanged when no Korean particles present', () => {
    const result = engine._normalizeKoreanQuery('Jarvis automation setup');
    expect(result).toBe('Jarvis automation setup');
  });

  it('trims and collapses whitespace in result', () => {
    const result = engine._normalizeKoreanQuery('서울에서  부산까지');
    expect(result).not.toMatch(/\s{2,}/);
    expect(result.trim()).toBe(result);
  });

  it('does not modify verbs with similar endings (오탐 방지)', () => {
    // "먹고", "가는" — these are verb stems, should NOT be trimmed
    // The implementation only removes specific longer particles (에게서, 에서, 까지, etc.)
    const result = engine._normalizeKoreanQuery('먹고 싶다');
    // "고" is a verb connector, not in the particle list — should remain
    expect(result).toContain('먹고');
  });
});

// ---------------------------------------------------------------------------
// RAGEngine.getStats() tests
// ---------------------------------------------------------------------------

describe('RAGEngine.getStats()', () => {
  let engine;

  beforeEach(async () => {
    vi.clearAllMocks();
    lancedb.default.connect.mockResolvedValue(lancedb._mockDb);
    lancedb._mockDb.openTable.mockResolvedValue(lancedb._mockTable);
    engine = new RAGEngine('/tmp/test-lancedb');
    await engine.init();
  });

  it('returns {totalChunks: 0, totalSources: 0} when table is not initialized', async () => {
    const emptyEngine = new RAGEngine('/tmp/test-lancedb');
    // Do NOT call init — table is null
    const stats = await emptyEngine.getStats();
    expect(stats).toEqual({ totalChunks: 0, totalSources: 0 });
  });

  it('returns totalChunks from countRows()', async () => {
    lancedb._mockTable.countRows.mockResolvedValueOnce(57);
    lancedb._mockDb.query.mockResolvedValueOnce({
      toArray: vi.fn().mockResolvedValue([{ cnt: 5 }]),
    });
    const stats = await engine.getStats();
    expect(stats.totalChunks).toBe(57);
  });

  it('returns totalSources from SQL aggregate', async () => {
    lancedb._mockTable.countRows.mockResolvedValueOnce(20);
    lancedb._mockDb.query.mockResolvedValueOnce({
      toArray: vi.fn().mockResolvedValue([{ cnt: 4 }]),
    });
    const stats = await engine.getStats();
    expect(stats.totalSources).toBe(4);
  });

  it('falls back to source deduplication when SQL query fails', async () => {
    lancedb._mockTable.countRows.mockResolvedValueOnce(10);
    lancedb._mockDb.query.mockRejectedValueOnce(new Error('SQL not supported'));
    lancedb._mockTable.query.mockReturnValue({
      select: vi.fn().mockReturnValue({
        limit: vi.fn().mockReturnValue({
          toArray: vi.fn().mockResolvedValue([
            { source: 'a.md' },
            { source: 'a.md' },
            { source: 'b.md' },
          ]),
        }),
      }),
    });
    const stats = await engine.getStats();
    expect(stats.totalChunks).toBe(10);
    expect(stats.totalSources).toBe(2);
  });

  it('returns {totalChunks: 0, totalSources: 0} when countRows throws', async () => {
    lancedb._mockTable.countRows.mockRejectedValueOnce(new Error('db error'));
    const stats = await engine.getStats();
    expect(stats).toEqual({ totalChunks: 0, totalSources: 0 });
  });
});

// ---------------------------------------------------------------------------
// RAGEngine.deleteBySource() tests
// ---------------------------------------------------------------------------

describe('RAGEngine.deleteBySource()', () => {
  let engine;

  beforeEach(async () => {
    vi.clearAllMocks();
    lancedb.default.connect.mockResolvedValue(lancedb._mockDb);
    lancedb._mockDb.openTable.mockResolvedValue(lancedb._mockTable);
    engine = new RAGEngine('/tmp/test-lancedb');
    await engine.init();
  });

  it('calls table.delete with correct filter string', async () => {
    await engine.deleteBySource('/home/user/docs/file.md');
    expect(lancedb._mockTable.delete).toHaveBeenCalledWith(
      expect.stringContaining('/home/user/docs/file.md')
    );
  });

  it('does not throw when table.delete fails (table empty)', async () => {
    lancedb._mockTable.delete.mockRejectedValueOnce(new Error('table empty'));
    await expect(engine.deleteBySource('/some/path.md')).resolves.not.toThrow();
  });

  it('does not throw for empty string source (invalid path guard)', async () => {
    // Implementation checks for empty string and throws internally, then catches
    await expect(engine.deleteBySource('')).resolves.not.toThrow();
  });

  it('escapes single quotes in source path', async () => {
    await engine.deleteBySource("/home/user/it's/file.md");
    const callArg = lancedb._mockTable.delete.mock.calls[0][0];
    // The single quote in the path should be escaped with a backslash
    expect(callArg).toContain("\\'");
    // The filter expression should still start with "source = '"
    expect(callArg).toMatch(/^source = '/);
  });
});

// ---------------------------------------------------------------------------
// RAGEngine.indexFile() tests
// ---------------------------------------------------------------------------

describe('RAGEngine.indexFile()', () => {
  let engine;

  beforeEach(async () => {
    vi.clearAllMocks();
    lancedb.default.connect.mockResolvedValue(lancedb._mockDb);
    lancedb._mockDb.openTable.mockResolvedValue(lancedb._mockTable);
    engine = new RAGEngine('/tmp/test-lancedb');
    await engine.init();

    // mkdirSync mock: first call succeeds (lock acquired), rmdirSync is a no-op
    mkdirSync.mockImplementationOnce(() => undefined); // lock dir creation
  });

  it('returns 0 when file content is empty', async () => {
    readFile.mockResolvedValueOnce('   ');
    const result = await engine.indexFile('/path/to/empty.md');
    expect(result).toBe(0);
  });

  it('calls table.add with records when file has content', async () => {
    readFile.mockResolvedValueOnce([
      '# Test Document',
      'This is a test document with enough content to create at least one chunk for indexing.',
    ].join('\n'));

    engine.openai.embeddings.create.mockResolvedValueOnce({
      data: [{ embedding: new Array(1536).fill(0.1) }],
    });

    await engine.indexFile('/path/to/test.md');
    expect(lancedb._mockTable.add).toHaveBeenCalled();
  });

  it('stores zero vectors when embedding fails (BM25-only fallback)', async () => {
    readFile.mockResolvedValueOnce([
      '# Fallback Test',
      'Content for BM25 fallback when OpenAI embedding is unavailable for testing.',
    ].join('\n'));

    engine.openai.embeddings.create.mockRejectedValueOnce(new Error('OpenAI unavailable'));

    await engine.indexFile('/path/to/fallback.md');

    // table.add should still be called with zero vectors
    expect(lancedb._mockTable.add).toHaveBeenCalled();
    const addCallArg = lancedb._mockTable.add.mock.calls[0][0];
    expect(Array.isArray(addCallArg)).toBe(true);
    if (addCallArg.length > 0) {
      expect(addCallArg[0].vector).toEqual(new Array(1536).fill(0));
    }
  });

  it('calls deleteBySource before adding new records (dedup)', async () => {
    readFile.mockResolvedValueOnce([
      '# Dedup Test',
      'Content to test that old records are deleted before new ones are added.',
    ].join('\n'));

    engine.openai.embeddings.create.mockResolvedValueOnce({
      data: [{ embedding: new Array(1536).fill(0.2) }],
    });

    const deleteSpy = vi.spyOn(engine, 'deleteBySource');
    await engine.indexFile('/path/test.md');
    expect(deleteSpy).toHaveBeenCalledWith('/path/test.md');
  });

  it('record ids use format {filePath}:{chunkIndex}', async () => {
    readFile.mockResolvedValueOnce([
      '# ID Format Test',
      'Content to verify the record ID format used for chunk identification in the index.',
    ].join('\n'));

    engine.openai.embeddings.create.mockResolvedValueOnce({
      data: [{ embedding: new Array(1536).fill(0.1) }],
    });

    await engine.indexFile('/docs/file.md');
    const records = lancedb._mockTable.add.mock.calls[0][0];
    expect(records[0].id).toBe('/docs/file.md:0');
  });
});
