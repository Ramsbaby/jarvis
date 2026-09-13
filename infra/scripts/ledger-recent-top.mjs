#!/usr/bin/env node
// runtime/ledger 의 .jsonl 중 마지막 항목이 가장 최근인 파일 N개를 출력한다.
// 정렬 기준은 파일 mtime 이 아니라 "마지막 줄의 타임스탬프"다 — 원장마다 UTC(Z)와 KST(+0900)가
// 섞여 있으므로 epoch 로 정규화해서 비교한다. mtime 은 어긋남을 보이도록 같이 찍는다.
// usage: node infra/scripts/ledger-recent-top.mjs [--top 3] [--dir <path>]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};

// BOT_HOME 은 저장소 루트가 아니라 repo/runtime 을 가리킨다.
const BOT_HOME = process.env.BOT_HOME || fileURLToPath(new URL('../../runtime', import.meta.url));
const LEDGER_DIR = opt('dir', path.join(BOT_HOME, 'ledger'));
const TOP_N = Number(opt('top', 3));
// 원장마다 시각 필드명이 다르다 — ts 가 대부분이지만 deferred-tasks 는 created_at.
const TS_KEYS = ['ts', 'created_at', 'timestamp', 'time', 'date'];

if (!Number.isFinite(TOP_N) || TOP_N <= 0) {
  console.error(`--top 값이 잘못됐습니다: ${opt('top', 3)}`);
  process.exit(2);
}

// 마지막 줄만 필요하다 — 원장은 수 MB까지 자라므로 끝에서 64KB만 읽는다.
function lastLine(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const size = fs.fstatSync(fd).size;
    if (!size) return '';
    const len = Math.min(65536, size);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    const lines = buf.toString('utf8').split('\n').filter((l) => l.trim());
    return lines[lines.length - 1] || '';
  } finally {
    fs.closeSync(fd);
  }
}

function extractTs(line) {
  let obj;
  try { obj = JSON.parse(line); } catch { return null; }
  if (!obj || typeof obj !== 'object') return null;
  for (const k of TS_KEYS) {
    if (typeof obj[k] === 'string') {
      const ms = Date.parse(obj[k]);
      if (!Number.isNaN(ms)) return { raw: obj[k], ms };
    }
  }
  if (typeof obj.ts_unix === 'number') {
    return { raw: String(obj.ts_unix), ms: obj.ts_unix * 1000 };
  }
  return null;
}

const kst = (ms) => new Date(ms).toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' });

const files = fs.readdirSync(LEDGER_DIR).filter((f) => f.endsWith('.jsonl'));
const dated = [];
const undated = [];

for (const f of files) {
  const full = path.join(LEDGER_DIR, f);
  const mtimeMs = fs.statSync(full).mtimeMs;
  const ts = extractTs(lastLine(full));
  if (ts) dated.push({ f, ts, mtimeMs });
  else undated.push(f);
}

dated.sort((a, b) => b.ts.ms - a.ts.ms);

console.log(`${LEDGER_DIR} — .jsonl ${files.length}개 중 마지막 기록 최신 ${TOP_N}건 (KST)\n`);
for (const [i, e] of dated.slice(0, TOP_N).entries()) {
  console.log(`${i + 1}. ${e.f}`);
  console.log(`   마지막 항목  ${kst(e.ts.ms)}  (원문: ${e.ts.raw})`);
  console.log(`   파일 mtime   ${kst(e.mtimeMs)}`);
}
if (undated.length) {
  console.log(`\n타임스탬프를 못 읽은 파일 ${undated.length}건 (순위에서 제외): ${undated.join(', ')}`);
}
