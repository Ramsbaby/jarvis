#!/usr/bin/env node
/**
 * rag-compact.mjs — LanceDB compaction + FTS rebuild
 *
 * Reclaims physical space from deleted rows and rebuilds the FTS index.
 * Intended for daily cron execution (03:00 every day).
 *
 * Usage: node ~/.jarvis/bin/rag-compact.mjs
 */

import { join } from 'node:path';
import { unlink, open as fsOpen, readFile } from 'node:fs/promises';
import { unlinkSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { RAG_WRITE_LOCK, LANCEDB_PATH, INFRA_HOME, ensureDirs } from '../lib/paths.mjs';

ensureDirs();

// rag-index.mjs가 실행 중(init() 포함)이면 compact 즉시 종료.
// write lock 체크보다 앞서 수행 — lock 획득 전 init() 단계도 차단함.
try {
  execSync('pgrep -f "rag-index.mjs"', { stdio: 'ignore' });
  console.log(`[${new Date().toISOString()}] [rag-compact] rag-index 실행 중 — compact 건너뜀`);
  process.exit(0);
} catch {
  // pgrep exit code 1 = 프로세스 없음 = compact 진행
}

// ─── Global RAG write mutex (shared with rag-index.mjs) ───────────────────────
// Prevents concurrent LanceDB writes during compaction.
const WRITE_LOCK_TIMEOUT  = 60_000; // 60s — compact은 오래 걸릴 수 있음
const WRITE_LOCK_POLL_MS  = 500;

let _lockFd = null;

async function _tryAcquire() {
  // PID-based stale lock check (time-based보다 안전 — 장시간 실행 시 lock 탈취 방지)
  try {
    const lockPid = parseInt((await readFile(RAG_WRITE_LOCK, 'utf-8')).trim(), 10);
    if (lockPid) {
      try {
        process.kill(lockPid, 0); // 살아있음 → stale 아님
      } catch {
        try { await unlink(RAG_WRITE_LOCK); } catch { /* race ok */ }
      }
    } else {
      try { await unlink(RAG_WRITE_LOCK); } catch { /* race ok */ }
    }
  } catch { /* lock file doesn't exist — OK */ }
  try {
    _lockFd = await fsOpen(RAG_WRITE_LOCK, 'wx');
    await _lockFd.writeFile(`${process.pid}\n`);
    return true;
  } catch (e) {
    if (e.code === 'EEXIST') return false;
    throw e;
  }
}

async function acquireWriteLock() {
  const deadline = Date.now() + WRITE_LOCK_TIMEOUT;
  while (Date.now() < deadline) {
    if (await _tryAcquire()) return true;
    await new Promise(r => setTimeout(r, WRITE_LOCK_POLL_MS));
  }
  return false;
}

function releaseWriteLock() {
  try { if (_lockFd) { _lockFd.close().catch(() => {}); _lockFd = null; } } catch {}
  try { unlinkSync(RAG_WRITE_LOCK); } catch {}
}

process.on('exit', releaseWriteLock);
process.on('SIGTERM', () => { releaseWriteLock(); process.exit(0); });
process.on('SIGINT',  () => { releaseWriteLock(); process.exit(0); });

// ─── Main ──────────────────────────────────────────────────────────────────────

const gotLock = await acquireWriteLock();
if (!gotLock) {
  console.log(`[${new Date().toISOString()}] [rag-compact] Write lock timeout (60s) — another process is writing. Skipping.`);
  process.exit(0);
}

const { RAGEngine } = await import('../lib/rag-engine.mjs');

const startTime = Date.now();
const engine = new RAGEngine(LANCEDB_PATH);
await engine.init();

const statsBefore = await engine.getStats();
console.log(`[rag-compact] Before: ${statsBefore.totalChunks} chunks, ${statsBefore.totalSources} sources`);

await engine.compact();

const statsAfter = await engine.getStats();
const duration = ((Date.now() - startTime) / 1000).toFixed(1);
console.log(`[rag-compact] After: ${statsAfter.totalChunks} chunks, ${statsAfter.totalSources} sources (${duration}s)`);
console.log('[rag-compact] Compaction complete');

process.exit(0);
