/**
 * RAG Engine - LanceDB + OpenAI Embeddings
 *
 * Hybrid search: vector similarity (primary) + full-text BM25 (fallback/supplement).
 * Storage: ~/claude-discord-bridge/rag/lancedb/ (local embedded, no server needed)
 */

import * as lancedb from '@lancedb/lancedb';
import * as arrow from 'apache-arrow';
import OpenAI from 'openai';
import { readFile, readdir, stat } from 'node:fs/promises';
import { join, extname } from 'node:path';
import { homedir } from 'node:os';

const EMBEDDING_MODEL = 'text-embedding-3-small';
const EMBEDDING_DIM = 1536;
const CHUNK_MAX_CHARS = 2000; // ~512 tokens
const CHUNK_OVERLAP_LINES = 0.2; // 20% overlap
const TABLE_NAME = 'documents';

export class RAGEngine {
  constructor(dbPath) {
    this.dbPath = dbPath || join(process.env.BOT_HOME || join(homedir(), 'claude-discord-bridge'), 'rag', 'lancedb');
    this.db = null;
    this.table = null;
    this.openai = new OpenAI();
  }

  async init() {
    this.db = await lancedb.connect(this.dbPath);

    try {
      this.table = await this.db.openTable(TABLE_NAME);
    } catch {
      // Create table with initial schema
      this.table = await this.db.createTable(TABLE_NAME, [
        {
          id: '__init__',
          text: '',
          vector: new Array(EMBEDDING_DIM).fill(0),
          source: '',
          chunk_index: 0,
          header_path: '',
          modified_at: 0,
        },
      ]);
      // Remove the init row
      await this.table.delete("id = '__init__'");
    }

    // Create FTS index for hybrid search (idempotent — errors if exists)
    try {
      await this.table.createIndex('text', { config: lancedb.Index.fts() });
    } catch {
      // Index already exists
    }
  }

  // --- Embedding ---

  async embed(texts) {
    const response = await this.openai.embeddings.create({
      model: EMBEDDING_MODEL,
      input: texts,
    });
    return response.data.map((d) => Array.from(d.embedding));
  }

  // --- Indexing ---

  async indexFile(filePath) {
    const content = await readFile(filePath, 'utf-8');
    if (!content.trim()) return 0;

    const chunks = splitMarkdown(content);
    if (chunks.length === 0) return 0;

    // Delete old chunks from this source
    await this.deleteBySource(filePath);

    // Embed all chunks
    const texts = chunks.map((c) => c.text);
    const embeddings = await this.embed(texts);

    const records = chunks.map((chunk, i) => ({
      id: `${filePath}:${i}`,
      text: chunk.text,
      vector: embeddings[i],
      source: filePath,
      chunk_index: i,
      header_path: chunk.headerPath,
      modified_at: Date.now(),
    }));

    await this.table.add(records);
    return records.length;
  }

  async indexDirectory(dirPath, opts = {}) {
    const { extensions = ['.md'], maxAgeDays = null } = opts;
    let totalChunks = 0;
    let entries;

    try {
      entries = await readdir(dirPath, { withFileTypes: true });
    } catch {
      return 0;
    }

    for (const entry of entries) {
      const fullPath = join(dirPath, entry.name);

      if (entry.isDirectory()) {
        totalChunks += await this.indexDirectory(fullPath, opts);
        continue;
      }

      if (!extensions.includes(extname(entry.name))) continue;

      // Check file age if maxAgeDays specified
      if (maxAgeDays !== null) {
        const fstat = await stat(fullPath);
        const ageDays = (Date.now() - fstat.mtimeMs) / (1000 * 60 * 60 * 24);
        if (ageDays > maxAgeDays) continue;
      }

      totalChunks += await this.indexFile(fullPath);
    }

    return totalChunks;
  }

  // --- Search ---

  async search(query, limit = 5) {
    if (!query.trim()) return [];

    // Vector search (requires OpenAI embedding — may fail if API unavailable)
    let results = [];
    try {
      const [queryVec] = await this.embed([query]);
      results = await this.table
        .search(queryVec)
        .limit(limit * 2)
        .toArray();
    } catch (embErr) {
      // Embedding failed (API key issue, rate limit, etc.) — fall through to FTS
      console.error('[rag-engine] Embedding failed:', embErr.message);
      results = [];
    }

    // FTS (BM25) fallback — always runs if vector results are sparse or embedding failed
    // Note: LanceDB 0.26+ requires query().fullTextSearch() for FTS (not search(q,{queryType:'fts'}))
    if (results.length < limit) {
      try {
        const ftsResults = await this.table
          .query()
          .fullTextSearch(query, { columns: ['text'] })
          .limit(limit)
          .toArray();

        const seen = new Set(results.map((r) => r.id));
        for (const r of ftsResults) {
          if (!seen.has(r.id)) {
            results.push(r);
            seen.add(r.id);
          }
        }
      } catch {
        // FTS may not be available yet
      }
    }

    // Sort by distance (lower = better) and limit
    results.sort((a, b) => (a._distance ?? 999) - (b._distance ?? 999));
    return results.slice(0, limit).map((r) => ({
      text: r.text,
      source: r.source,
      headerPath: r.header_path,
      distance: r._distance,
      chunkIndex: r.chunk_index,
    }));
  }

  // --- Maintenance ---

  async deleteBySource(source) {
    try {
      await this.table.delete(`source = '${source.replace(/'/g, "''")}'`);
    } catch {
      // Table might be empty
    }
  }

  async getStats() {
    try {
      const rows = await this.table.query().toArray();
      const sources = new Set(rows.map((r) => r.source));
      return { totalChunks: rows.length, totalSources: sources.size };
    } catch {
      return { totalChunks: 0, totalSources: 0 };
    }
  }
}

// --- Markdown Chunker ---

export function splitMarkdown(content) {
  const chunks = [];
  const lines = content.split('\n');
  let currentChunk = [];
  let currentHeaders = [];

  function flushChunk() {
    if (currentChunk.length === 0) return;
    const text = currentChunk.join('\n').trim();
    if (text.length < 30) return; // Skip tiny chunks
    chunks.push({
      text,
      headerPath: currentHeaders.filter(Boolean).join(' > '),
      index: chunks.length,
    });
    // Keep overlap (last 20% of lines)
    const overlapStart = Math.floor(currentChunk.length * (1 - CHUNK_OVERLAP_LINES));
    currentChunk = currentChunk.slice(overlapStart);
  }

  let inCodeBlock = false;

  for (const line of lines) {
    // Track code fences
    if (line.startsWith('```')) {
      inCodeBlock = !inCodeBlock;
      currentChunk.push(line);
      continue;
    }

    // Don't split inside code blocks
    if (inCodeBlock) {
      currentChunk.push(line);
      // Force split if chunk is too large even inside code block
      if (currentChunk.join('\n').length > CHUNK_MAX_CHARS * 1.5) {
        flushChunk();
      }
      continue;
    }

    const headerMatch = line.match(/^(#{1,6})\s+(.+)/);

    if (headerMatch) {
      // Flush current chunk before starting new section
      flushChunk();
      currentChunk = [];

      const level = headerMatch[1].length;
      // Update header hierarchy
      currentHeaders = currentHeaders.slice(0, level - 1);
      currentHeaders[level - 1] = headerMatch[2].trim();
    }

    currentChunk.push(line);

    // Split if chunk exceeds max size
    if (currentChunk.join('\n').length > CHUNK_MAX_CHARS) {
      flushChunk();
    }
  }

  // Flush remaining
  flushChunk();

  return chunks;
}
