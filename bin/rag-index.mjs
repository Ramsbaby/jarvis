#!/usr/bin/env node
/**
 * RAG Indexer - Incremental indexing for the knowledge base
 *
 * Runs via cron (hourly). Only re-indexes files whose mtime changed.
 * Targets: context .md, rag .md, results (7 days)
 */

import { readFile, writeFile, stat } from 'node:fs/promises';
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

async function loadState() {
  try {
    const raw = await readFile(STATE_FILE, 'utf-8');
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

async function saveState(state) {
  await writeFile(STATE_FILE, JSON.stringify(state, null, 2));
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
  const engine = new RAGEngine();
  await engine.init();

  const state = await loadState();
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
  } catch { /* dir may not exist */ }

  // 2. RAG memory files
  for (const f of ['memory.md', 'decisions.md', 'handoff.md']) {
    targets.push(join(BOT_HOME, 'rag', f));
  }

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

  // 5. 사용자 커스텀 메모리 (선택적 외부 경로)
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

  await saveState(state);
  const stats = await engine.getStats();
  const duration = ((Date.now() - startTime) / 1000).toFixed(1);

  console.log(
    `[${new Date().toISOString()}] RAG index: ${indexed} new/modified, ${skipped} unchanged, ${stats.totalChunks} total chunks, ${stats.totalSources} sources (${duration}s)`,
  );
}

main().catch((err) => {
  console.error(`RAG indexer failed: ${err.message}`);
  process.exit(1);
});
