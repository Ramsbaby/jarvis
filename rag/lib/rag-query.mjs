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
import { readFileSync } from 'node:fs';
import { ACCESS_LOG_PATH, LANCEDB_PATH, ensureDirs } from './paths.mjs';

function loadAccessLog() {
  try { return JSON.parse(readFileSync(ACCESS_LOG_PATH, 'utf-8')); } catch { return {}; }
}

async function main() {
  // CLI 플래그 파싱: --episodic 플래그 지원
  const args = process.argv.slice(2);
  const episodic = args.includes('--episodic');
  const query = args.find((a) => !a.startsWith('--'));

  if (!query || !query.trim()) {
    process.exit(0);
  }

  const dbPath = LANCEDB_PATH;
  const engine = new RAGEngine(dbPath);
  await engine.init();

  // ── Insight search: semantically relevant insights injected before RAG chunks ──
  let insightOutput = [];
  try {
    await engine.initInsightsTable();
    const insights = await engine.searchInsights(query, 3);
    if (insights.length > 0) {
      insightOutput.push('## User Context (inferred insights)', '');
      for (const ins of insights) {
        insightOutput.push(`- ${ins.insight_text} (confidence: ${ins.confidence.toFixed(2)})`);
        if (ins.evidence_summary) {
          insightOutput.push(`  Evidence: ${ins.evidence_summary}`);
        }
      }
      insightOutput.push('');
    }
  } catch { /* insight search failure is non-fatal */ }

  // episodic 모드: discord-history 소스 한정 검색 결과를 먼저 가져온 뒤
  // 일반 검색 결과 앞에 prepend (에피소딕 메모리 우선 노출)
  let episodicResults = [];
  if (episodic) {
    try {
      episodicResults = await engine.search(query, 5, { sourceFilter: 'episodic' });
    } catch {
      // 에피소딕 검색 실패 시 조용히 무시 → 일반 검색으로 fallback
      episodicResults = [];
    }
  }

  const generalResults = await engine.search(query, 5);

  // episodic 결과를 앞에, 일반 결과를 뒤에 합치되 중복 소스+청크 제거
  const episodicKeys = new Set(episodicResults.map((r) => `${r.source}:${r.chunkIndex}`));
  const dedupedGeneral = generalResults.filter(
    (r) => !episodicKeys.has(`${r.source}:${r.chunkIndex}`)
  );

  // importance + access_count 가중치 재정렬 (episodic은 에피소딕 우선 유지)
  // score = importance * 0.35 + relevance * 0.50 + accessBoost * 0.15
  const accessLog = loadAccessLog();
  const maxDist = Math.max(...dedupedGeneral.map((r) => r.distance ?? 1), 1);
  const maxAccess = Math.max(...dedupedGeneral.map((r) => {
    const key = `${r.source}:${r.chunkIndex ?? 0}`;
    return accessLog[key]?.count ?? 0;
  }), 1);
  const rerankedGeneral = dedupedGeneral
    .map((r) => {
      const key = `${r.source}:${r.chunkIndex ?? 0}`;
      const accessCount = accessLog[key]?.count ?? 0;
      const accessBoost = Math.pow(accessCount / maxAccess, 0.3); // 로그 스케일 완화
      return {
        ...r,
        _finalScore:
          (r.importance ?? 0.5) * 0.35 +
          (1 - (r.distance ?? 0) / maxDist) * 0.50 +
          accessBoost * 0.15,
      };
    })
    .sort((a, b) => b._finalScore - a._finalScore);

  const results = [...episodicResults, ...rerankedGeneral];

  if (results.length === 0 && insightOutput.length === 0) {
    process.exit(0);
  }

  // Insights first, then RAG chunks
  const output = [...insightOutput, '## RAG Context (semantic search)', ''];

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
