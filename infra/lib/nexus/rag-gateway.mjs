/**
 * nexus/rag-gateway.mjs — RAG 벡터검색 게이트웨이
 * 도구: rag_search
 */

import { join } from 'node:path';
import { readFileSync, writeFileSync } from 'node:fs';
import { BOT_HOME, mkResult, mkError, logTelemetry } from './shared.mjs';

// ---------------------------------------------------------------------------
// Access count tracking — ~/jarvis/runtime/rag/access-log.json
// { "source:chunkIndex": { count: N, lastAccessed: ISO } }
// ---------------------------------------------------------------------------
const ACCESS_LOG_PATH = join(BOT_HOME, 'rag', 'access-log.json');

function recordAccess(results) {
  try {
    let log = {};
    try { log = JSON.parse(readFileSync(ACCESS_LOG_PATH, 'utf-8')); } catch { /* 초기화 */ }
    const now = new Date().toISOString();
    for (const r of results) {
      const key = `${r.source}:${r.chunkIndex ?? 0}`;
      log[key] = { count: (log[key]?.count ?? 0) + 1, lastAccessed: now };
    }
    writeFileSync(ACCESS_LOG_PATH, JSON.stringify(log, null, 2));
  } catch(e) { console.error('[rag] recordAccess failed:', e.message, '| path:', ACCESS_LOG_PATH); }
}

// ---------------------------------------------------------------------------
// RAGEngine singleton
// ---------------------------------------------------------------------------
let _ragEngine = null;

async function getRAGEngine() {
  if (_ragEngine) return _ragEngine;
  const { RAGEngine } = await import('../../../rag/lib/rag-engine.mjs');
  const ragHome = process.env.JARVIS_RAG_HOME || join(BOT_HOME, 'rag');
  const rag = new RAGEngine(join(ragHome, 'lancedb'));
  try {
    await rag.init();
  } catch (err) {
    _ragEngine = null;
    throw err;
  }
  _ragEngine = rag;
  return rag;
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------
export const TOOLS = [
  {
    name: 'rag_search',
    description:
      'Jarvis 장기 메모리 검색. 오너의 이전 대화, 기록된 사실, 개인 설정, 프로젝트 컨텍스트를 의미론적으로 검색. ' +
      '기억 관련 질문("저번에", "내가 말했던", "기억해?"), 개인 맥락이 필요한 질문, ' +
      '과거 대화 참조 시 반드시 먼저 호출하라. ' +
      'BM25 전문검색(1순위) + 벡터 유사도(보조) 하이브리드 검색. Jina 리랭킹 자동 적용.',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: '검색할 자연어 쿼리' },
        limit: { type: 'number', description: '반환할 결과 수 (기본 5, 최대 10)', default: 5 },
      },
      required: ['query'],
    },
    annotations: { title: 'RAG Search', readOnlyHint: true, destructiveHint: false, openWorldHint: false },
  },
];

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------
export async function handle(name, args, start) {
  if (name !== 'rag_search') return null;

  const { query, limit = 5 } = args;
  if (!query || !query.trim()) {
    logTelemetry('rag_search', Date.now() - start, { error: 'empty_query' });
    return mkError('query가 비어있습니다.', { query });
  }

  try {
    const rag = await getRAGEngine();
    const results = await rag.search(query.trim(), Math.min(Number(limit) || 5, 10));
    if (results.length === 0) {
      logTelemetry('rag_search', Date.now() - start, { results: 0, query });
      return mkResult(`"${query}" 관련 기억 없음.`, { results: 0, query });
    }
    // 히트된 청크 접근 횟수 기록 (비동기 파이어앤포겟)
    recordAccess(results);

    const formatted = results.map((r, i) => {
      const source = r.source.split('/').slice(-2).join('/');
      const header = r.headerPath ? ` [${r.headerPath}]` : '';
      const imp = r.importance != null ? ` ·imp=${r.importance.toFixed(2)}` : '';
      return `[${i + 1}] ${source}${header}${imp}\n${r.text.slice(0, 600)}`;
    }).join('\n\n---\n\n');
    logTelemetry('rag_search', Date.now() - start, { results: results.length, query });
    return mkResult(`검색: "${query}" → ${results.length}개\n\n${formatted}`, { results: results.length, query });
  } catch (err) {
    const msg = err.message || '';
    let errText;
    if (/401|403|auth/i.test(msg)) {
      errText = 'API 인증 오류 — OPENAI_API_KEY 확인 필요';
    } else if (/ENOENT|connect/i.test(msg)) {
      errText = 'DB 연결 실패 — LanceDB 경로 확인';
    } else {
      errText = `RAG 검색 오류: ${msg}`;
    }
    logTelemetry('rag_search', Date.now() - start, { error: msg, query });
    return mkError(errText, { query });
  }
}