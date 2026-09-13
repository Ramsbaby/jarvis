#!/usr/bin/env node
// runtime/ledger 의 .jsonl 중 mtime 최신 N개와 각 파일 마지막 항목의 타임스탬프 출력
import fs from 'node:fs';
import path from 'node:path';

const RUNTIME = process.env.BOT_HOME || path.join(process.env.HOME, '.openclaw-data/runtime');
const DIR = process.env.JARVIS_LEDGER_DIR || path.join(RUNTIME, 'ledger');
const N = Number(process.argv[2]) || 3;
const TS_KEYS = ['ts', 'timestamp', 'time', 'date', 'created_at', 'at'];

const lastTs = (file) => {
  const lines = fs.readFileSync(file, 'utf8').trimEnd().split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const o = JSON.parse(lines[i]);
      const k = TS_KEYS.find((k) => typeof o[k] === 'string' || typeof o[k] === 'number');
      if (k) return String(o[k]);
      return '(타임스탬프 필드 없음)';
    } catch { /* 마지막 줄이 깨졌으면 위로 */ }
  }
  return '(파싱 불가)';
};

fs.readdirSync(DIR)
  .filter((f) => f.endsWith('.jsonl'))
  .map((f) => {
    const p = path.join(DIR, f);
    return { f, p, mtime: fs.statSync(p).mtime };
  })
  .sort((a, b) => b.mtime - a.mtime)
  .slice(0, N)
  .forEach(({ f, p, mtime }, i) => {
    console.log(`${i + 1}. ${f}`);
    console.log(`   파일 수정: ${mtime.toISOString()}`);
    console.log(`   마지막 항목: ${lastTs(p)}`);
  });
