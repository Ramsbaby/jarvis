#!/usr/bin/env node
/**
 * entity-graph.mjs — Phase 2: Entity Graph Builder
 *
 * LanceDB에서 enrichDocument가 추출한 entities/topics를 읽어
 * 엔티티 간 co-occurrence 관계 그래프를 빌드하고 저장.
 *
 * 출력: ~/.jarvis/rag/entity-graph.json
 * 구조:
 *   nodes: { [entity]: { count, importance, topics, sources[] } }
 *   edges: { [e1|e2]: { weight, sources[] } }
 *
 * 실행: node ~/.jarvis/bin/entity-graph.mjs
 * 크론: 매일 새벽 03:45 (rag-index 30분 후)
 */

import { join } from 'node:path';
import { homedir } from 'node:os';
import { writeFileSync, readFileSync } from 'node:fs';
import * as lancedb from '@lancedb/lancedb';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const DB_PATH   = join(BOT_HOME, 'rag', 'lancedb');
const OUT_PATH  = join(BOT_HOME, 'rag', 'entity-graph.json');

// 너무 일반적인 단어는 엔티티로 쓰지 않음
const STOP_ENTITIES = new Set([
  '개발', '시스템', '코드', '기능', '서비스', '데이터', '처리', '관리',
  'API', 'DB', '서버', '클라이언트', '배포', '테스트', '문서',
]);

async function main() {
  console.error('[entity-graph] 시작...');

  const db = await lancedb.connect(DB_PATH);
  let table;
  try {
    table = await db.openTable('documents');
  } catch {
    console.error('[entity-graph] documents 테이블 없음 — 종료');
    process.exit(0);
  }

  // 전체 레코드에서 entities, topics, source, importance 읽기
  const rows = await table.query()
    .select(['source', 'entities', 'topics', 'importance'])
    .toArray();

  console.error(`[entity-graph] ${rows.length}개 청크 처리 중...`);

  const nodes = {};   // entity → { count, importanceSum, topics: Set, sources: Set }
  const edges = {};   // "e1|e2" → { weight, sources: Set }

  for (const row of rows) {
    let entities = [];
    let topics = [];
    try { entities = JSON.parse(row.entities || '[]'); } catch { /* skip */ }
    try { topics = JSON.parse(row.topics || '[]'); } catch { /* skip */ }

    const imp = row.importance ?? 0.5;
    const src = row.source ?? '';

    // 필터: STOP_ENTITIES 제거, 빈 문자열 제거, 너무 짧은 것 제거
    const validEntities = entities
      .map(e => String(e).trim())
      .filter(e => e.length >= 2 && !STOP_ENTITIES.has(e));

    // 노드 누적
    for (const e of validEntities) {
      if (!nodes[e]) {
        nodes[e] = { count: 0, importanceSum: 0, topics: new Set(), sources: new Set() };
      }
      nodes[e].count++;
      nodes[e].importanceSum += imp;
      for (const t of topics) nodes[e].topics.add(t);
      nodes[e].sources.add(src);
    }

    // 엣지 누적 (같은 청크에 함께 나온 엔티티끼리 co-occurrence)
    for (let i = 0; i < validEntities.length; i++) {
      for (let j = i + 1; j < validEntities.length; j++) {
        const [a, b] = [validEntities[i], validEntities[j]].sort();
        const key = `${a}|${b}`;
        if (!edges[key]) edges[key] = { weight: 0, sources: new Set() };
        edges[key].weight++;
        edges[key].sources.add(src);
      }
    }
  }

  // Set → Array 직렬화 + importance 평균화
  const serializedNodes = {};
  for (const [e, v] of Object.entries(nodes)) {
    serializedNodes[e] = {
      count: v.count,
      importance: v.count > 0 ? +(v.importanceSum / v.count).toFixed(3) : 0.5,
      topics: [...v.topics].slice(0, 10),
      sources: [...v.sources].slice(0, 20),
    };
  }

  const serializedEdges = {};
  for (const [key, v] of Object.entries(edges)) {
    if (v.weight >= 2) {  // 1회 co-occurrence는 노이즈 — 2회 이상만 저장
      serializedEdges[key] = {
        weight: v.weight,
        sources: [...v.sources].slice(0, 10),
      };
    }
  }

  const graph = {
    generated: new Date().toISOString(),
    nodeCount: Object.keys(serializedNodes).length,
    edgeCount: Object.keys(serializedEdges).length,
    nodes: serializedNodes,
    edges: serializedEdges,
  };

  writeFileSync(OUT_PATH, JSON.stringify(graph, null, 2));
  console.error(
    `[entity-graph] 완료 — nodes: ${graph.nodeCount}, edges: ${graph.edgeCount} → ${OUT_PATH}`
  );
}

main().catch((err) => {
  console.error('[entity-graph] ERROR:', err.message);
  process.exit(1);
});
