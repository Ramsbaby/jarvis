#!/usr/bin/env node
/**
 * enrich-migrate.mjs — 기존 LanceDB 레코드 메타데이터 마이그레이션
 *
 * enrichDocument가 OpenAI→로컬 룰 기반으로 전환된 후,
 * 기존 7500+ 청크의 importance/entities/topics를 재계산·갱신.
 * table.update() 사용 → vector(임베딩) 완전히 건드리지 않음.
 *
 * 실행: node ~/jarvis/runtime/bin/enrich-migrate.mjs
 */

import { join } from 'node:path';
import { homedir } from 'node:os';
import { RAGEngine } from '../lib/rag-engine.mjs';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const DB_PATH  = join(BOT_HOME, 'rag', 'lancedb');
const BATCH    = 300; // 한 번에 읽을 레코드 수

async function main() {
  const rag = new RAGEngine(DB_PATH);
  await rag.init();
  const table = rag.table;

  const total = await table.countRows();
  console.log(`[enrich-migrate] 총 ${total}개 레코드 처리 시작`);

  let offset = 0;
  let updated = 0;
  let errors  = 0;

  while (offset < total) {
    const rows = await table.query()
      .select(['id', 'text'])
      .limit(BATCH)
      .offset(offset)
      .toArray();

    if (rows.length === 0) break;

    // id별로 enrichment 계산 후 개별 update
    for (const r of rows) {
      const id   = r.id;
      const text = r.text || '';
      const { importance, entities, topics } = rag.enrichDocument(text);

      try {
        await table.update({
          where: `id = '${id.replace(/'/g, "\\'")}'`,
          values: {
            importance: importance,
            entities:   JSON.stringify(entities),
            topics:     JSON.stringify(topics),
          },
        });
        updated++;
      } catch (e) {
        errors++;
        if (errors <= 3) console.warn(`\n[enrich-migrate] update 실패 (id=${id}):`, e.message);
      }
    }

    process.stdout.write(`\r[enrich-migrate] ${updated}/${total} 갱신 (오류: ${errors})`);
    offset += BATCH;
  }

  console.log(`\n[enrich-migrate] 완료. ${updated}개 갱신, ${errors}개 실패.`);

  // entity-graph 재빌드
  console.log('[enrich-migrate] entity-graph 재빌드...');
  try {
    const { execSync } = await import('node:child_process');
    execSync(`node ${join(BOT_HOME, 'bin', 'entity-graph.mjs')}`, { stdio: 'inherit' });
    console.log('[enrich-migrate] entity-graph 완료.');
  } catch (e) {
    console.warn('[enrich-migrate] entity-graph 빌드 실패:', e.message);
  }
}

main().catch(e => { console.error('[enrich-migrate] 치명 오류:', e.message); process.exit(1); });