#!/usr/bin/env node
/**
 * RAG Query CLI - Semantic search for ask-claude.sh and /search command
 *
 * Usage: node rag-query.mjs "query text"
 * Output: Markdown-formatted context to stdout
 * On error: prints empty string and exits 0 (never breaks caller)
 */

import { RAGEngine } from './rag-engine.mjs';
import { join } from 'node:path';
import { homedir } from 'node:os';

async function main() {
  const query = process.argv[2];
  if (!query || !query.trim()) {
    process.exit(0);
  }

  const dbPath = join(process.env.BOT_HOME || join(homedir(), '.jarvis'), 'rag', 'lancedb');
  const engine = new RAGEngine(dbPath);
  await engine.init();

  const results = await engine.search(query, 5);
  if (results.length === 0) {
    process.exit(0);
  }

  const output = ['## RAG Context (semantic search)', ''];

  for (const r of results) {
    const source = r.source.replace(/^\/Users\/[^/]+\//, '~/');
    const header = r.headerPath ? ` — ${r.headerPath}` : '';
    output.push(`### From: ${source}${header}`);
    output.push(r.text);
    output.push('');
  }

  process.stdout.write(output.join('\n'));
}

main().catch((err) => {
  // Stderr diagnostic (won't break callers that pipe stdout only)
  process.stderr.write(`[rag-query] ERROR: ${err?.message || err}\n`);
  process.exit(0);
});
