#!/usr/bin/env node
/**
 * rag-stats.mjs — RAG DB 안전 진단 CLI
 *
 * openReadOnly()만 사용하므로 DB를 절대 생성하지 않음.
 * 상태 확인은 반드시 이 스크립트를 사용할 것 (RAGEngine().init() 직접 호출 금지).
 *
 * 사용법: node ~/.jarvis/bin/rag-stats.mjs [--json]
 */

import { join } from 'node:path';
import { existsSync, statSync, readdirSync } from 'node:fs';
import { LANCEDB_PATH, RAG_HOME, RAG_WRITE_LOCK } from '../lib/paths.mjs';

const JSON_MODE = process.argv.includes('--json');

// ── 경로 ──
const DB_PATH     = LANCEDB_PATH;
const SENTINEL    = join(RAG_HOME, '.rebuild-complete');
const LOCK_FILE   = RAG_WRITE_LOCK;

function log(msg)  { if (!JSON_MODE) process.stdout.write(msg + '\n'); }
function warn(msg) { if (!JSON_MODE) process.stderr.write('[warn] ' + msg + '\n'); }

async function main() {
  const result = {
    dbExists:      false,
    totalChunks:   0,
    totalSources:  0,
    deletedChunks: 0,
    dbSizeKB:      0,
    lastModified:  null,
    rebuilding:    false,
    locked:        false,
    error:         null,
  };

  // ── 리빌드/락 파일 확인 ──
  result.locked    = existsSync(LOCK_FILE);
  result.rebuilding = !existsSync(SENTINEL);  // sentinel 없으면 리빌드 진행 중 또는 미완료

  if (result.locked) warn('write lock active: ' + LOCK_FILE);
  if (result.rebuilding) warn('rebuild sentinel missing — rebuild may be in progress');

  // ── DB 존재 여부 ──
  const lancePath = join(DB_PATH, 'documents.lance');
  if (!existsSync(lancePath)) {
    result.error = 'DB not found: ' + lancePath;
    log('RAG DB 없음: ' + lancePath);
    if (JSON_MODE) process.stdout.write(JSON.stringify(result, null, 2) + '\n');
    process.exit(0);
  }
  result.dbExists = true;

  // ── DB 폴더 크기 ──
  try {
    let totalBytes = 0;
    const walk = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) walk(full);
        else totalBytes += statSync(full).size;
      }
    };
    walk(lancePath);
    result.dbSizeKB = Math.round(totalBytes / 1024);

    // 마지막 수정 시각: documents.lance 폴더의 최신 파일 mtime
    let latest = 0;
    const walkMtime = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) walkMtime(full);
        else { const mt = statSync(full).mtimeMs; if (mt > latest) latest = mt; }
      }
    };
    walkMtime(lancePath);
    if (latest > 0) result.lastModified = new Date(latest).toISOString();
  } catch (e) {
    warn('DB size/mtime scan failed: ' + e.message);
  }

  // ── openReadOnly로 청크/소스 수 조회 ──
  try {
    const { RAGEngine } = await import('../lib/rag-engine.mjs');
    const engine = new RAGEngine(DB_PATH);
    await engine.openReadOnly();
    const stats = await engine.getStats();
    result.totalChunks   = stats.totalChunks   ?? 0;
    result.totalSources  = stats.totalSources  ?? 0;
    result.deletedChunks = stats.deletedChunks ?? 0;
  } catch (e) {
    result.error = e.message;
    warn('getStats failed: ' + e.message);
  }

  // ── 출력 ──
  if (JSON_MODE) {
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
  } else {
    log('');
    log('=== RAG DB 상태 ===');
    log(`  DB 경로   : ${DB_PATH}`);
    log(`  DB 크기   : ${result.dbSizeKB.toLocaleString()} KB`);
    log(`  마지막 수정: ${result.lastModified ?? '알 수 없음'}`);
    log(`  청크(active): ${result.totalChunks.toLocaleString()}`);
    log(`  소스 파일  : ${result.totalSources.toLocaleString()}`);
    log(`  삭제(soft) : ${result.deletedChunks.toLocaleString()}`);
    log(`  리빌드 중  : ${result.rebuilding ? '예 (sentinel 없음)' : '아니오'}`);
    log(`  Write 락   : ${result.locked ? '있음 (' + LOCK_FILE + ')' : '없음'}`);
    if (result.error) log(`  오류       : ${result.error}`);
    log('');
  }
}

main().catch(e => {
  process.stderr.write('[rag-stats] fatal: ' + e.message + '\n');
  process.exit(0); // exit 0 — 상태 확인이 응답을 차단하면 안 됨
});
