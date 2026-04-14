/**
 * RAG (Retrieval-Augmented Generation) helper — lazy-init RAG engine and search.
 *
 * Exports:
 *   PAST_REF_PATTERN  — RegExp matching Korean past-reference phrases
 *   searchRagForContext(query, limit?) — returns formatted RAG context string or ''
 */

import { join } from 'node:path';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { log } from './claude-runner.js';


const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');

// Past-reference patterns — detect when user mentions previous conversation
export const PAST_REF_PATTERN = /저번에|아까|기억|지난번|전에 말한|예전에|그때|다시 한번|아까 말한|이전에|방금|위에서|위에꺼|앞에서/;

// ---------------------------------------------------------------------------
// RAG source exclusion — 개발/아키텍처 문서는 봇 대화 컨텍스트에 부적합
// 인덱스에 이미 들어간 오염 항목을 검색 결과 단계에서 방어적으로 필터링.
// ---------------------------------------------------------------------------

/**
 * 경로 세그먼트 기반 제외 패턴.
 * source 경로에 이 문자열 중 하나라도 포함되면 결과에서 제거.
 */
const RAG_EXCLUDED_SOURCE_SEGMENTS = [
  '/adr/',          // ADR 개발 의사결정 문서 (.jarvis/adr/, vault/.../adr/)
  '/docs/',         // 기술 설계 문서
  '/architecture/', // 아키텍처 문서
  'MEMORY.md',      // Claude Code 개발 메모 (session notes, haiku 날짜 코드 등)
  'ADR-',           // ADR-001.md ~ ADR-010.md 등 파일명 패턴
  'upgrade-roadmap',
  'session-changelog',
  'obsidian-enhancement',
  'PKM-Obsidian',
  'docdd-roadmap',
];

/**
 * RAG 검색 결과에서 개발/아키텍처 문서 소스를 제거.
 * @param {Array<{source: string, text: string, headerPath: string}>} results
 * @returns {Array}
 */
function filterDevSources(results) {
  return results.filter(r => {
    const src = r.source || '';
    return !RAG_EXCLUDED_SOURCE_SEGMENTS.some(seg => src.includes(seg));
  });
}

// ---------------------------------------------------------------------------
// Family 전용 RAG 필터 — Owner 개인 데이터 family 채널에서 제외
// ---------------------------------------------------------------------------

/** family 사용자 ID — family 본인 메모리는 허용, 타 사용자 메모리는 제거 */
const FAMILY_USER_ID = process.env.FAMILY_USER_ID || '';

/** family 채널에서 제외할 소스 경로 패턴 */
const FAMILY_EXCLUDED_SOURCE_SEGMENTS = [
  'trading', 'portfolio', 'stock',
  '/career/', '/market/',
  'invest', 'nasdaq', 'leverage',
];

/**
 * Family 채널용 RAG 결과 필터.
 * - 타 사용자 user-memory 파일 제거 (Owner owner private 메모 등)
 * - 트레이딩/커리어 관련 소스 경로 제거
 * @param {Array} results
 * @returns {Array}
 */
function filterFamilySources(results) {
  return results.filter(r => {
    const src = (r.source || '').toLowerCase();
    // user-memory 파일이면 family 본인 것만 허용
    if (src.includes('user-memory-') && !src.includes(FAMILY_USER_ID)) {
      return false;
    }
    // Owner-specific 토픽 경로 제거
    return !FAMILY_EXCLUDED_SOURCE_SEGMENTS.some(seg => src.includes(seg));
  });
}

// ---------------------------------------------------------------------------
// RAG auto-inject — lazy singleton
// ---------------------------------------------------------------------------

let _ragEngine = null;
let _ragLastFailAt = 0;
const RAG_RETRY_COOLDOWN_MS = 5 * 60 * 1000;

async function getRagEngine() {
  if (_ragEngine) return _ragEngine;
  if (Date.now() - _ragLastFailAt < RAG_RETRY_COOLDOWN_MS) return null;
  try {
    const ragPath = join(import.meta.dirname, '..', '..', '..', 'rag', 'lib', 'rag-engine.mjs');
    const { RAGEngine } = await import(pathToFileURL(ragPath).href);
    const ragHome = process.env.JARVIS_RAG_HOME || join(BOT_HOME, 'rag');
    const engine = new RAGEngine(join(ragHome, 'lancedb'));
    await engine.init();
    _ragEngine = engine;
    log('info', 'RAG engine initialized for auto-inject');
    return engine;
  } catch (err) {
    _ragLastFailAt = Date.now();
    log('warn', 'RAG engine init failed — will retry after cooldown', { error: err.message });
    return null;
  }
}

/**
 * RAG 엔진 참조 해제 — 봇 shutdown 시 호출하여 DB 핸들 GC 유도.
 */
export function closeRagEngine() {
  if (_ragEngine) {
    _ragEngine.close();
    _ragEngine = null;
  }
}

/**
 * Search RAG for context relevant to the query.
 * LLM Wiki와 병행 사용: Wiki → RAG 순서로 컨텍스트 우선순위 결정.
 * @param {string} query - The user's prompt
 * @param {number} [limit=3] - Max results
 * @returns {Promise<string>} Formatted context block or empty string
 */
export async function searchRagForContext(query, limit = 3, opts = {}) {
  const engine = await getRagEngine();
  if (!engine) return '';
  let rawResults;
  try {
    // limit * 2 로 여유 있게 검색한 뒤 개발 문서 필터링 후 limit 적용
    // opts.episodic=true 시 discord-history 소스 우선 검색 (에피소딕 메모리)
    rawResults = await engine.search(query, limit * 2, opts);
  } catch (err) {
    // stale manifest로 인한 "Not found" 에러 시 테이블 재연결 후 1회 retry
    if (err.message?.includes('Not found') || err.message?.includes('not found')) {
      try {
        await engine.refreshTable();
        rawResults = await engine.search(query, limit * 2, opts);
      } catch (retryErr) {
        log('warn', '[rag-helper] search retry failed after refreshTable', { error: retryErr.message });
        return '';
      }
    } else {
      log('warn', '[rag-helper] search error', { error: err.message });
      return '';
    }
  }

  if (!rawResults || rawResults.length === 0) return '';

  let filtered = filterDevSources(rawResults);
  if (opts.familyOnly) filtered = filterFamilySources(filtered);
  const results = filtered.slice(0, limit);
  if (results.length === 0) return '';

  const lines = results.map(r => {
    const src = r.source?.split('/').pop() ?? '';
    const snippet = r.text?.slice(0, 300) ?? '';
    return `[${src}] ${snippet}`;
  });
  return `## 관련 과거 기록 (RAG)\n${lines.join('\n\n')}\n\n`;
}

/**
 * 위키 기반 컨텍스트 검색 (LLM Wiki 레이어).
 * RAG보다 먼저 호출 — 소화된 구조화 정보 제공.
 * 비어 있으면 빈 문자열 반환 → 호출부에서 RAG로 폴백.
 */
export async function searchWikiForContext(userId, query) {
  if (!userId || !query) return '';
  try {
    const { getWikiContext } = await import('./wiki-engine.mjs');
    return getWikiContext(userId, query);
  } catch (err) {
    log('warn', '[rag-helper] wiki search failed', { error: err.message });
    return '';
  }
}
