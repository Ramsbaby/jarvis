#!/usr/bin/env node
/**
 * copy-config-templates.mjs — infra/config/*.example.json → BOT_HOME/config/
 *
 * Usage: node copy-config-templates.mjs
 * - 이미 존재하는 파일은 덮어쓰지 않음 (safe)
 */
import { copyFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { join, basename } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const HOME = homedir();
const __dirname = dirname(fileURLToPath(import.meta.url));

const projectRoot = join(__dirname, '../../../../');
const srcDir     = join(projectRoot, 'infra', 'config');
const dstDir     = join(process.env.BOT_HOME || join(HOME, '.local', 'share', 'jarvis'), 'config');

mkdirSync(dstDir, { recursive: true });

const results = { copied: [], skipped: [], failed: [], notFound: [] };

if (!existsSync(srcDir)) {
  console.log(JSON.stringify({ status: 'warn', message: `infra/config/ not found at ${srcDir}`, ...results }));
  process.exit(0);
}

const files = readdirSync(srcDir).filter(f => f.endsWith('.example.json'));

if (files.length === 0) {
  console.log(JSON.stringify({ status: 'ok', message: 'No *.example.json templates found', ...results }));
  process.exit(0);
}

for (const file of files) {
  const srcPath = join(srcDir, file);
  const dstName = file.replace('.example', '');
  const dstPath = join(dstDir, dstName);

  if (existsSync(dstPath)) {
    results.skipped.push(dstName);
    continue;
  }

  // copyFileSync를 try/catch로 감싸 실패 파일 리포트
  try {
    copyFileSync(srcPath, dstPath);
    results.copied.push(dstName);
  } catch (e) {
    results.failed.push({ file: dstName, error: e.message });
  }
}

const status = results.failed.length > 0 ? 'partial' : 'ok';
console.log(JSON.stringify({ status, dstDir, ...results }));
