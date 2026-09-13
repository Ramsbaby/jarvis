#!/usr/bin/env node
// runtime/ledger 의 .jsonl 중 최근 기록 N개(기본 3)와 각 파일 마지막 항목의 타임스탬프.
import { readdirSync, statSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const DIR = join(process.env.BOT_HOME || join(process.env.HOME, '.openclaw-data/runtime'), 'ledger');
const N = Number(process.argv[2]) || 3;
const TS_KEYS = ['ts', 'timestamp', 'created_at', 'time', 'date'];

const lastLine = (p) => {
  const s = readFileSync(p, 'utf8').trimEnd();
  return s.slice(s.lastIndexOf('\n') + 1);
};

const lastTs = (p) => {
  try {
    const line = lastLine(p);
    if (!line) return '(빈 파일)';
    const o = JSON.parse(line);
    for (const k of TS_KEYS) if (o[k]) return `${o[k]}  [${k}]`;
    return '(타임스탬프 필드 없음)';
  } catch (e) {
    return `(파싱 실패: ${e.message})`;
  }
};

const files = readdirSync(DIR)
  .filter((f) => f.endsWith('.jsonl'))
  .map((f) => ({ f, p: join(DIR, f), mtime: statSync(join(DIR, f)).mtime }))
  .sort((a, b) => b.mtime - a.mtime)
  .slice(0, N);

for (const { f, p, mtime } of files) {
  console.log(`${f}\n  파일 수정: ${mtime.toISOString()}\n  마지막 항목: ${lastTs(p)}`);
}
