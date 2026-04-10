#!/usr/bin/env node
/**
 * rag-repair.mjs — LanceDB 인플레이스 중복 청크 제거
 *
 * 테이블 드롭 없이 소스별 중복(오래된) 청크를 soft-delete로 정리.
 * soft-delete 버그나 인덱서 오류로 중복이 쌓였을 때 사용.
 *
 * Usage:
 *   node ~/.jarvis/bin/rag-repair.mjs [--dry-run] [--source <path>]
 *
 *   --dry-run    실제 삭제 없이 중복 현황만 출력
 *   --source     특정 소스 파일만 처리
 *
 * 동작:
 *   1. 소스별 청크 수 집계
 *   2. 소스 파일의 현재 청크 수(index-state.json)와 비교
 *   3. 초과 청크(오래된 버전)를 modified_at 기준으로 soft-delete
 *   4. compact() 호출로 물리 공간 회수
 */

import { join } from 'node:path';
import { readFileSync, existsSync } from 'node:fs';
import { INDEX_STATE_PATH, LANCEDB_PATH } from '../lib/paths.mjs';

const STATE_FILE = INDEX_STATE_PATH;

const args = process.argv.slice(2);
const DRY_RUN = args.includes('--dry-run');
const TARGET_SOURCE = args.includes('--source') ? args[args.indexOf('--source') + 1] : null;

const log = (...a) => console.log(`[rag-repair] ${a.join(' ')}`);
const warn = (...a) => console.warn(`[rag-repair] WARN: ${a.join(' ')}`);

if (DRY_RUN) log('DRY-RUN 모드 — 실제 삭제 없음');

async function main() {
  // LanceDB 연결
  const ldb = await import('@lancedb/lancedb');
  const db = await ldb.connect(LANCEDB_PATH);
  const table = await db.openTable('documents').catch(() => null);
  if (!table) { log('ERROR: documents 테이블 없음 — rag-index 먼저 실행'); process.exit(1); }

  // 전체 통계
  const totalRows = await table.countRows();
  const deletedRows = await table.countRows('deleted = true').catch(() => 0);
  const activeRows = totalRows - deletedRows;
  log(`현재 상태: 전체 ${totalRows}, 활성 ${activeRows}, 삭제됨 ${deletedRows}`);

  // 소스별 청크 집계 (활성 행만)
  log('소스별 청크 집계 중...');
  const allActive = await table.query()
    .where('deleted IS NULL OR deleted = false')
    .select(['id', 'source', 'chunk_index', 'modified_at'])
    .toArray();

  // source → [{ id, chunk_index, modified_at }] 맵
  const bySource = new Map();
  for (const row of allActive) {
    const src = row.source;
    if (TARGET_SOURCE && src !== TARGET_SOURCE) continue;
    if (!bySource.has(src)) bySource.set(src, []);
    bySource.get(src).push({ id: row.id, chunk_index: Number(row.chunk_index), modified_at: Number(row.modified_at) });
  }

  // index-state.json 로드 (예상 청크 수 기준)
  let state = {};
  try { state = JSON.parse(readFileSync(STATE_FILE, 'utf-8')); } catch { /* empty */ }

  let totalDuplicates = 0;
  let totalSoftDeleted = 0;
  const problemSources = [];

  for (const [src, chunks] of bySource) {
    // 예상 청크 수 = index-state에 기록된 최신 청크 수
    const stateEntry = state[src];
    const expectedCount = stateEntry?.chunkCount ?? null;

    // 실제 청크 수
    const actualCount = chunks.length;

    // 중복 감지: 동일 chunk_index가 여러 개면 중복 버전 존재
    const byIndex = new Map();
    for (const c of chunks) {
      if (!byIndex.has(c.chunk_index)) byIndex.set(c.chunk_index, []);
      byIndex.get(c.chunk_index).push(c);
    }

    const duplicateIndexes = [...byIndex.entries()].filter(([, arr]) => arr.length > 1);
    if (duplicateIndexes.length === 0) continue;

    const dupCount = duplicateIndexes.reduce((s, [, arr]) => s + arr.length - 1, 0);
    totalDuplicates += dupCount;
    problemSources.push({ src, actualCount, expectedCount, dupCount });

    if (DRY_RUN) {
      log(`중복 발견: ${src.split('/').pop()} — ${actualCount}청크 중 ${dupCount}개 중복`);
      continue;
    }

    // 중복 중 오래된 것(modified_at 낮은 것) soft-delete
    const toDelete = [];
    for (const [, arr] of duplicateIndexes) {
      // modified_at 내림차순 → 최신 1개 제외, 나머지 삭제
      arr.sort((a, b) => b.modified_at - a.modified_at);
      toDelete.push(...arr.slice(1).map(c => c.id));
    }

    if (toDelete.length === 0) continue;

    // id 목록으로 soft-delete
    const idList = toDelete.map(id => `'${id.replace(/'/g, "\\'")}'`).join(', ');
    try {
      await table.update({
        where: `id IN (${idList})`,
        values: { deleted: true, deleted_at: Date.now() },
      });
      log(`정리: ${src.split('/').pop()} — ${toDelete.length}개 중복 청크 soft-delete`);
      totalSoftDeleted += toDelete.length;
    } catch (err) {
      warn(`${src.split('/').pop()} 정리 실패: ${err.message?.slice(0, 80)}`);
    }
  }

  // 요약
  log('─'.repeat(50));
  if (DRY_RUN) {
    log(`DRY-RUN 결과: ${problemSources.length}개 소스에서 ${totalDuplicates}개 중복 청크 발견`);
    if (problemSources.length > 0) {
      log('상위 10개:');
      problemSources.sort((a, b) => b.dupCount - a.dupCount).slice(0, 10)
        .forEach(s => log(`  ${s.src.split('/').pop()}: ${s.dupCount}개 중복`));
    }
  } else {
    log(`완료: ${totalSoftDeleted}개 중복 청크 soft-delete`);
    if (totalSoftDeleted > 0) {
      log('compact 실행 중 (물리 공간 회수)...');
      const { RAGEngine } = await import('../lib/rag-engine.mjs');
      const engine = new RAGEngine();
      await engine.init();
      await engine.compact();
      await engine.close();
      log('compact 완료');
    }
  }

  const finalTotal = await table.countRows();
  const finalDeleted = await table.countRows('deleted = true').catch(() => 0);
  log(`최종 상태: 전체 ${finalTotal}, 활성 ${finalTotal - finalDeleted}, 삭제됨 ${finalDeleted}`);
}

main().catch(e => { console.error('[rag-repair] FATAL:', e.message); process.exit(1); });
