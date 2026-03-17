#!/usr/bin/env node
/**
 * RAG Indexer - Incremental indexing for the knowledge base
 *
 * Runs via cron (hourly). Only re-indexes files whose mtime changed.
 * Targets: context .md, rag .md, results (7 days)
 */

import { readFile, writeFile, stat, unlink, open as fsOpen } from 'node:fs/promises';
import { writeFileSync, unlinkSync, appendFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { config } from 'dotenv';

// Load .env for cron environment (OPENAI_API_KEY)
config({ path: join(process.env.BOT_HOME || join(homedir(), '.jarvis'), 'discord', '.env') });

if (!process.env.OPENAI_API_KEY) {
  console.error('[rag-index] FATAL: OPENAI_API_KEY not set. Check ~/.jarvis/discord/.env');
  process.exit(1);
}

import { RAGEngine } from '../lib/rag-engine.mjs';

const BOT_HOME = join(process.env.BOT_HOME || join(homedir(), '.jarvis'));
const STATE_FILE = join(BOT_HOME, 'rag', 'index-state.json');
const PID_FILE = join(BOT_HOME, 'state', 'rag-index.pid');

// ─── Global RAG write mutex (cross-process, /tmp/jarvis-rag-write.lock) ───────
// Prevents concurrent LanceDB writes between rag-index cron and rag-watch daemon.
// Uses open(O_EXCL) which is atomic on POSIX — no TOCTOU race.
const RAG_WRITE_LOCK = '/tmp/jarvis-rag-write.lock';
const RAG_WRITE_LOCK_TIMEOUT_MS = 30_000; // 30s max wait
const RAG_WRITE_LOCK_POLL_MS   = 500;     // poll interval
const RAG_WRITE_LOCK_STALE_MS  = 120_000; // 2min — stale lock auto-cleanup

let _ragWriteLockFd = null; // FileHandle for the lock file (kept open while held)

async function _tryAcquireWriteLock() {
  // Check for stale lock before attempting (handles crash without cleanup)
  try {
    const st = await stat(RAG_WRITE_LOCK);
    if (Date.now() - st.mtimeMs > RAG_WRITE_LOCK_STALE_MS) {
      try { await unlink(RAG_WRITE_LOCK); } catch { /* race ok */ }
    }
  } catch { /* lock file doesn't exist yet — OK */ }

  try {
    // O_EXCL: fails with EEXIST if file already exists — atomic on POSIX
    _ragWriteLockFd = await fsOpen(RAG_WRITE_LOCK, 'wx');
    await _ragWriteLockFd.writeFile(`${process.pid}\n`);
    return true;
  } catch (e) {
    if (e.code === 'EEXIST') return false;
    throw e; // unexpected error
  }
}

async function acquireWriteLock() {
  const deadline = Date.now() + RAG_WRITE_LOCK_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (await _tryAcquireWriteLock()) return true;
    await new Promise(r => setTimeout(r, RAG_WRITE_LOCK_POLL_MS));
  }
  return false;
}

function releaseWriteLock() {
  try { if (_ragWriteLockFd) { _ragWriteLockFd.close().catch(() => {}); _ragWriteLockFd = null; } } catch {}
  try { unlinkSync(RAG_WRITE_LOCK); } catch {}
}

// Acquire global write lock before any LanceDB writes.
// Wait up to 30s for rag-watch to finish its current file, then skip if still busy.
const gotWriteLock = await acquireWriteLock();
if (!gotWriteLock) {
  console.log(`[${new Date().toISOString()}] [rag-index] RAG write lock timeout (30s) — another process is writing. Skipping this run.`);
  process.exit(0);
}

// Cleanup: release lock on all exit paths
const _cleanupLock = () => { releaseWriteLock(); };
process.on('exit', _cleanupLock);
process.on('SIGTERM', () => { _cleanupLock(); process.exit(0); });
process.on('SIGINT',  () => { _cleanupLock(); process.exit(0); });

// rag-watch 인덱싱 중 동시 쓰기 방지: lock 파일만으로 판단 (레거시 호환 유지)
// (rag-watch.mjs가 engine.indexFile() 직전에 lock 파일을 갱신함)
const RAG_WATCH_LOCK = join(BOT_HOME, 'state', 'rag-watch-indexing.lock');
import { statSync } from 'node:fs';
function isRagWatchActive() {
  // lock 파일이 2분 이내 갱신됐으면 현재 쓰기 중 → 이번 run 스킵.
  // 프로세스 존재 여부는 체크하지 않음 (rag-watch는 항상 실행 중이므로 무의미).
  try {
    const s = statSync(RAG_WATCH_LOCK);
    return Date.now() - s.mtimeMs < 120_000;
  } catch {
    return false; // lock 파일 없음 = 인덱싱 중 아님
  }
}
// NOTE: rag-watch check retained for defence-in-depth, but global write lock
// above is the primary mutex. If rag-watch held the lock, acquireWriteLock()
// would have already timed out above.

// PID 센티넬: rag-watch가 rag-index 실행 중임을 감지해 충돌 회피
writeFileSync(PID_FILE, String(process.pid));
const _cleanupPid = () => { try { unlinkSync(PID_FILE); } catch {} };
process.on('exit', _cleanupPid);
process.on('SIGTERM', () => { _cleanupPid(); process.exit(0); });
process.on('SIGINT',  () => { _cleanupPid(); process.exit(0); });

async function loadState() {
  try {
    const raw = await readFile(STATE_FILE, 'utf-8');
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

async function saveState(state) {
  const tmp = `${STATE_FILE}.tmp`;
  await writeFile(tmp, JSON.stringify(state, null, 2));
  const { rename } = await import('node:fs/promises');
  await rename(tmp, STATE_FILE);
}

function appendIncident(type, detail) {
  try {
    const incidentPath = join(BOT_HOME, 'rag', 'incidents.md');
    const ts = new Date().toISOString().replace('T', ' ').slice(0, 19);
    appendFileSync(incidentPath, `\n- [${ts}] **[rag-index]** ${type}: ${detail}\n`);
  } catch { /* non-critical */ }
}

async function getMtime(filePath) {
  try {
    const s = await stat(filePath);
    return s.mtimeMs;
  } catch {
    return null;
  }
}

async function main() {
  const startTime = Date.now();
  const engine = new RAGEngine(join(BOT_HOME, 'rag', 'lancedb'));
  await engine.init();

  // DB-state 무결성 검사: index-state.json에 항목이 있는데 DB가 비어있으면
  // 동시 쓰기 충돌로 손상된 것으로 판단 → state 초기화 후 전체 재구성
  let state = await loadState();
  const stateEntries = Object.keys(state).length;
  if (stateEntries > 0) {
    const currentStats = await engine.getStats();
    if (currentStats.totalChunks === 0) {
      console.warn(
        `[rag-index] WARN: DB empty but index-state has ${stateEntries} entries — state/DB mismatch. Resetting state for full rebuild.`
      );
      appendIncident('DB 손상 감지', `index-state ${stateEntries}개 vs DB 0 chunks 불일치 → 전체 재구성 시작`);
      state = {};
      await saveState(state);
    }
  }
  const _hadMismatch = Object.keys(state).length === 0 && stateEntries > 0;
  let indexed = 0;
  let skipped = 0;

  // Collect all target files
  const { readdir } = await import('node:fs/promises');
  const { extname } = await import('node:path');
  const targets = [];

  // 1. Context files (top-level + discord-history subdir)
  try {
    const contextDir = join(BOT_HOME, 'context');
    const entries = await readdir(contextDir, { withFileTypes: true });
    for (const e of entries) {
      if (!e.isDirectory() && extname(e.name) === '.md') {
        targets.push(join(contextDir, e.name));
      }
    }
    // discord-history: 최근 7일치만 (파일이 날마다 누적됨)
    const histDir = join(contextDir, 'discord-history');
    try {
      const histFiles = await readdir(histDir);
      for (const f of histFiles) {
        if (extname(f) !== '.md') continue;
        const fPath = join(histDir, f);
        const mtime = await getMtime(fPath);
        if (mtime) {
          const ageDays = (Date.now() - mtime) / (1000 * 60 * 60 * 24);
          if (ageDays <= 7) targets.push(fPath);
        }
      }
    } catch { /* discord-history 아직 없으면 스킵 */ }
    // context/owner/ and context/career/ (오너 프로필, 커리어 데이터)
    for (const subDir of ['owner', 'career']) {
      try {
        const subDirPath = join(contextDir, subDir);
        const subEntries = await readdir(subDirPath);
        for (const f of subEntries) {
          if (extname(f) === '.md') targets.push(join(subDirPath, f));
        }
      } catch { /* dir may not exist */ }
    }
  } catch { /* dir may not exist */ }

  // 2. RAG memory files (decisions는 주간 파일 decisions-YYYY-WXX.md 동적 glob)
  for (const f of ['memory.md', 'handoff.md', 'incidents.md']) {
    targets.push(join(BOT_HOME, 'rag', f));
  }
  // decisions 주간 파일: archive/ 제외하고 현재 rag/ 루트의 decisions-*.md만
  try {
    const ragDir = join(BOT_HOME, 'rag');
    const ragEntries = await readdir(ragDir);
    for (const f of ragEntries) {
      if (f.startsWith('decisions-') && f.endsWith('.md')) {
        targets.push(join(ragDir, f));
      }
    }
  } catch { /* rag dir not found */ }

  // 3. Config 파일 (company-dna, autonomy-levels)
  for (const f of ['company-dna.md', 'autonomy-levels.md']) {
    targets.push(join(BOT_HOME, 'config', f));
  }

  // 4. 팀 보고서 & 공유 인박스 (팀 간 통신 이력)
  for (const dir of ['reports', 'shared-inbox']) {
    try {
      const dirPath = join(BOT_HOME, 'rag', 'teams', dir);
      const entries = await readdir(dirPath);
      for (const f of entries) {
        if (extname(f) === '.md') targets.push(join(dirPath, f));
      }
    } catch { /* dir may not exist */ }
  }
  // proposals-tracker
  targets.push(join(BOT_HOME, 'rag', 'teams', 'proposals-tracker.md'));

  // 5. 프로젝트 문서: README/ROADMAP/docs/adr는 봇 대화 컨텍스트에 부적합한 개발 메모이므로 제외.
  // Jarvis가 시스템 구조를 이해하려면 config/company-dna.md(섹션 3에서 이미 포함) 활용.

  // 5b. Jarvis-Vault (Obsidian Knowledge Hub) — 재귀 탐색
  //
  // RAG_EXCLUDED_VAULT_DIRS: 봇 대화에 부적합한 개발/아키텍처 문서 디렉토리.
  // 이 경로에 속한 파일은 BM25/벡터 검색 결과에 노이즈를 발생시키므로 인덱싱 제외.
  // - 06-knowledge/adr: ADR 개발 의사결정 메모 (haiku 날짜 코드, bash 패턴 등 기술 노트)
  // - 06-knowledge/architecture: 시스템 아키텍처 다이어그램/설계 문서
  const RAG_EXCLUDED_VAULT_DIRS = [
    'adr',
    'architecture',
  ];

  // RAG_EXCLUDED_VAULT_FILES: 특정 파일명 제외 (디렉토리 무관)
  const RAG_EXCLUDED_VAULT_FILES = new Set([
    'ARCHITECTURE.md',
    'upgrade-roadmap-v2.md',
    'docdd-roadmap.md',
    'obsidian-enhancement-plan.md',
    'PKM-Obsidian-Research.md',
    'session-changelog.md',
    'ADR-INDEX.md',
  ]);

  async function collectVaultMd(dirPath, opts = {}) {
    const { maxAgeDays } = opts;
    try {
      const entries = await readdir(dirPath, { withFileTypes: true });
      for (const e of entries) {
        if (e.name.startsWith('.')) continue; // .obsidian 등 제외
        const fullPath = join(dirPath, e.name);
        if (e.isDirectory()) {
          // 개발/아키텍처 문서 디렉토리 제외
          if (RAG_EXCLUDED_VAULT_DIRS.includes(e.name)) {
            console.log(`[rag-index] Skip excluded dir: ${fullPath}`);
            continue;
          }
          await collectVaultMd(fullPath, opts); // 재귀 탐색
        } else if (extname(e.name) === '.md') {
          // 개발 메모 파일명 제외
          if (RAG_EXCLUDED_VAULT_FILES.has(e.name)) {
            console.log(`[rag-index] Skip excluded file: ${fullPath}`);
            continue;
          }
          if (maxAgeDays) {
            const mtime = await getMtime(fullPath);
            if (!mtime || (Date.now() - mtime) / (1000 * 60 * 60 * 24) > maxAgeDays) continue;
          }
          targets.push(fullPath);
        }
      }
    } catch { /* dir may not exist */ }
  }
  try {
    const vaultBase = join(homedir(), 'Jarvis-Vault');
    // 상시 인덱싱: 01-system, 03-teams, 04-owner, 05-career, 06-knowledge (재귀)
    // 주의: 06-knowledge 내 adr/, architecture/ 은 collectVaultMd에서 자동 제외됨
    for (const dir of ['01-system', '03-teams', '04-owner', '05-career', '06-knowledge']) {
      await collectVaultMd(join(vaultBase, dir));
    }
    // 02-daily/insights: 최근 7일
    await collectVaultMd(join(vaultBase, '02-daily', 'insights'), { maxAgeDays: 7 });
    // 02-daily/kpi: 최근 30일
    await collectVaultMd(join(vaultBase, '02-daily', 'kpi'), { maxAgeDays: 30 });
    // 02-daily/standup: 최근 7일
    await collectVaultMd(join(vaultBase, '02-daily', 'standup'), { maxAgeDays: 7 });
  } catch { /* vault may not exist */ }

  // 5c. 사용자 커스텀 메모리 (선택적 외부 경로)
  // BOT_EXTRA_MEMORY 환경변수에 경로를 지정하면 해당 디렉토리도 인덱싱
  const extraMemoryPath = process.env.BOT_EXTRA_MEMORY;
  if (extraMemoryPath) {
    const extraFixed = [
      'domains/owner-profile.md', 'domains/system-preferences.md',
      'domains/decisions.md', 'domains/persona.md',
      'hot/HOT_MEMORY.md', 'lessons.md',
    ];
    for (const p of extraFixed) {
      targets.push(join(extraMemoryPath, p));
    }
    for (const dir of ['teams/reports', 'teams/learnings', 'career']) {
      try {
        const dirPath = join(extraMemoryPath, dir);
        const entries = await readdir(dirPath);
        for (const f of entries) {
          if (extname(f) !== '.md') continue;
          const fPath = join(dirPath, f);
          const mtime = await getMtime(fPath);
          if (mtime) {
            const ageDays = (Date.now() - mtime) / (1000 * 60 * 60 * 24);
            if (ageDays <= 14) targets.push(fPath);
          }
        }
      } catch { /* dir may not exist */ }
    }
  }

  // 6. Results (latest per task, max 7 days)
  try {
    const resultsDir = join(BOT_HOME, 'results');
    const taskDirs = await readdir(resultsDir, { withFileTypes: true });
    for (const td of taskDirs) {
      if (!td.isDirectory()) continue;
      const taskDir = join(resultsDir, td.name);
      const files = await readdir(taskDir);
      const mdFiles = files
        .filter((f) => extname(f) === '.md')
        .sort()
        .reverse()
        .slice(0, 1); // Latest only
      for (const f of mdFiles) {
        const fPath = join(taskDir, f);
        const mtime = await getMtime(fPath);
        if (mtime) {
          const ageDays = (Date.now() - mtime) / (1000 * 60 * 60 * 24);
          if (ageDays <= 7) targets.push(fPath);
        }
      }
    }
  } catch { /* dir may not exist */ }

  // Prune state entries for files that no longer exist (메모리/디스크 누수 방지)
  let pruned = 0;
  for (const filePath of Object.keys(state)) {
    if (await getMtime(filePath) === null) {
      delete state[filePath];
      pruned++;
    }
  }
  if (pruned > 0) console.log(`[rag-index] Pruned ${pruned} stale state entries`);

  // Index changed files
  for (const filePath of targets) {
    const mtime = await getMtime(filePath);
    if (mtime === null) continue;

    // Skip if unchanged
    if (state[filePath] === mtime) {
      skipped++;
      continue;
    }

    try {
      const chunks = await engine.indexFile(filePath);
      indexed++;
      state[filePath] = mtime;
    } catch (err) {
      console.error(`Error indexing ${filePath}: ${err.message}`);
    }
  }

  const stats = await engine.getStats();
  const duration = ((Date.now() - startTime) / 1000).toFixed(1);

  // 안전장치: 파일을 처리했는데 DB에 0 chunks이면 쓰기 실패 → state 저장하지 않아 다음 실행에서 재시도
  if (indexed > 0 && stats.totalChunks === 0) {
    const msg = `indexed ${indexed} files but DB has 0 chunks — write failure. State NOT saved, will retry next run.`;
    console.error(`[${new Date().toISOString()}] [rag-index] ABORT: ${msg}`);
    appendIncident('쓰기 실패 ABORT', msg);
    process.exit(1);
  }

  await saveState(state);

  // DB 손상 후 재구성 성공 시 incidents.md 기록
  if (_hadMismatch && stats.totalChunks > 0) {
    appendIncident('DB 재구성 완료', `${stats.totalChunks} chunks / ${stats.totalSources} sources 복구됨 (${duration}s)`);
  }

  console.log(
    `[${new Date().toISOString()}] RAG index: ${indexed} new/modified, ${skipped} unchanged, ${stats.totalChunks} total chunks, ${stats.totalSources} sources (${duration}s)`,
  );
}

main().catch((err) => {
  console.error(`RAG indexer failed: ${err.message}`);
  process.exit(1);
});
