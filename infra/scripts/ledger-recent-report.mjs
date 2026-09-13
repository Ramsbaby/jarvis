#!/usr/bin/env node
// runtime/ledger 의 .jsonl 중 mtime 최신 N개와 각 파일 마지막 항목의 타임스탬프를 출력한다.
import { readdirSync, statSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

// BOT_HOME 은 runtime 디렉터리를 가리킨다 (예: ~/.openclaw-data/runtime)
const DIR = process.env.JARVIS_LEDGER_DIR
  || join(process.env.BOT_HOME || join(process.env.HOME, '.openclaw-data/runtime'), 'ledger');
const N = Number(process.argv[2]) || 3;

const lastTs = (path) => {
  // ponytail: 파일 전체를 읽는다. 수십 MB 원장이 생기면 tail 청크 읽기로 교체.
  const lines = readFileSync(path, 'utf8').trimEnd().split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const o = JSON.parse(lines[i]);
      const k = Object.keys(o).find((k) => /^(ts|timestamp|time|date|created_at|updated_at)$/i.test(k));
      if (k) return String(o[k]);
    } catch { /* 깨진 줄은 건너뛴다 */ }
  }
  return '(타임스탬프 없음)';
};

readdirSync(DIR)
  .filter((f) => f.endsWith('.jsonl'))
  .map((f) => ({ f, mtime: statSync(join(DIR, f)).mtime }))
  .sort((a, b) => b.mtime - a.mtime)
  .slice(0, N)
  .forEach(({ f, mtime }, i) => {
    console.log(`${i + 1}. ${f}`);
    console.log(`   mtime      : ${mtime.toISOString()}`);
    console.log(`   마지막 항목: ${lastTs(join(DIR, f))}`);
  });
