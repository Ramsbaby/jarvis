#!/usr/bin/env node
// instrument-liveness-audit.mjs — 계측기가 조용히 죽는 것을 잡는다
//
// ★ 왜 만들었나 (2026-08-23)
//   계측기 4개가 18~43일째 죽어 있었고 아무도 몰랐다. 가장 나빴던 것은
//   verification-gate 다 — 소비자 훅은 배선이 살아 있고 파일 권한·문법도 정상이라
//   겉보기엔 멀쩡했는데, 생산자 훅(pre-verification-declaration.sh)이 8/4 배선 사고로
//   빠져서 소비자가 매번 state 파일을 못 찾고 조용히 exit 0 했다.
//   **훅이 살아 있는지 보는 감사(hooks-wiring-audit.sh)로는 못 잡는다** —
//   배선은 멀쩡했기 때문이다. 잡히는 유일한 신호는 "원장이 안 늘어난다"였다.
//
// 그래서 이 감사는 배선이 아니라 **산출물**을 본다.
//
// 종료코드: 0 = 전부 정상 / 1 = 침묵 계측기 있음 (크론이 알림으로 승격)

import { readFileSync, existsSync, statSync, appendFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

const HOME = process.env.HOME;
const CONF = join(HOME, '.openclaw-data/runtime/config/instruments.json');
const LEDGER_DIR = join(HOME, '.openclaw-data/runtime/ledger');
const quiet = process.argv.includes('--quiet');
const asJson = process.argv.includes('--json');

if (!existsSync(CONF)) {
  console.error(`명세 없음: ${CONF}`);
  process.exit(2);
}
const conf = JSON.parse(readFileSync(CONF, 'utf8'));
const expand = (p) => p.replace(/^~/, HOME);
const now = Date.now();
const rows = [];

for (const it of conf.instruments) {
  // ★ 2026-08-25 확장: 원장(JSONL)뿐 아니라 임의 산출물(문서·캐시)도 본다.
  //   SYSTEM-OVERVIEW.md 가 126일간 매일 "성공" 로그를 남기면서 아무도 안 읽는
  //   경로에 쓰고 있었는데, 감시 대상이 runtime/ledger/* 로만 한정돼 못 잡았다.
  const isArtifact = Boolean(it.artifact);
  const label = it.ledger || it.artifact;
  const p = isArtifact ? expand(it.artifact) : join(LEDGER_DIR, it.ledger);
  if (!existsSync(p)) {
    rows.push({ ...it, label, state: 'missing', silent_days: null, last: null });
    continue;
  }
  const st = statSync(p);
  const silentDays = Math.floor((now - st.mtimeMs) / 86400000);
  // mtime 은 파일이 만져지기만 해도 갱신된다. 마지막 레코드의 ts 를 정본으로 삼되,
  // ts 를 못 읽으면 mtime 으로 물러선다.
  let lastTs = null;
  try {
    if (isArtifact) throw new Error('artifact');  // 문서는 mtime 이 정본이다
    const lines = readFileSync(p, 'utf8').trimEnd().split('\n');
    for (let i = lines.length - 1; i >= 0 && i > lines.length - 20; i--) {
      const t = JSON.parse(lines[i]).ts;
      if (t) { lastTs = t; break; }
    }
  } catch { /* 파싱 실패 시 mtime 으로 */ }
  const days = lastTs
    ? Math.floor((now - Date.parse(lastTs)) / 86400000)
    : silentDays;
  rows.push({
    ...it,
    label,
    state: days > it.max_silent_days ? 'silent' : 'ok',
    silent_days: days,
    last: lastTs || new Date(st.mtimeMs).toISOString(),
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 산출물 내용 해시 — "돌고 있다"와 "일하고 있다"를 가른다.
//
// ★ 왜 (2026-08-25): exit 0 은 "죽지 않았다"는 뜻이지 "일했다"는 뜻이 아니다.
//   gen-system-overview 는 126일간 매일 exit 0 이었고 파일 mtime 도 매일 갱신됐지만,
//   소비자가 읽는 경로는 4월에 멈춰 있었다. mtime 은 파일을 다시 쓰기만 해도 오른다.
//   그래서 mtime 이 아니라 **내용**을 본다.
//
//   단, 생성 시각·커밋 해시처럼 매번 달라지는 줄은 빼고 해시한다(volatile).
//   안 빼면 내용이 얼어붙어도 해시가 매일 달라져 아무것도 못 잡는다.
const HASH_STATE = join(HOME, '.openclaw-data/runtime/state/artifact-content-hashes.json');
let hashPrev = {};
try { hashPrev = JSON.parse(readFileSync(HASH_STATE, 'utf8')); } catch { /* 최초 실행 */ }
const hashCur = {};

const contentHash = (file, volatile) => {
  let text;
  try { text = readFileSync(file, 'utf8'); } catch { return null; }
  if (Array.isArray(volatile) && volatile.length) {
    const res = volatile.map((v) => new RegExp(v));
    text = text.split('\n').filter((ln) => !res.some((re) => re.test(ln))).join('\n');
  }
  return createHash('sha256').update(text).digest('hex').slice(0, 16);
};

for (const r of rows) {
  if (!r.artifact || r.max_unchanged_days === undefined) continue;
  if (r.state === 'missing') continue;
  const file = expand(r.artifact);
  const h = contentHash(file, r.volatile);
  if (!h) continue;
  const key = r.artifact;
  const before = hashPrev[key];
  const since = before && before.hash === h ? before.since : new Date().toISOString();
  hashCur[key] = { hash: h, since };
  const frozenDays = Math.floor((now - Date.parse(since)) / 86400000);
  r.frozen_days = frozenDays;
  if (frozenDays > r.max_unchanged_days && r.state === 'ok') {
    r.state = 'frozen';   // mtime 은 갱신되는데 내용이 안 바뀐다 = 생성기가 헛돈다
  }
}
try {
  mkdirSync(join(HOME, '.openclaw-data/runtime/state'), { recursive: true });
  writeFileSync(HASH_STATE, JSON.stringify(hashCur, null, 2));
} catch { /* 기록 실패가 감사를 막지 않는다 */ }

const bad = rows.filter((r) => r.state !== 'ok');

// ─────────────────────────────────────────────────────────────────────────────
// 자(계측기)가 바뀌었는지 — 바뀌면 그 전후 추이는 비교할 수 없다.
//
// ★ 2026-08-23 실측 사례: requirement-check 의 실패율이 7월 78.1% → 8월 15.6% 로
//   보였는데, 생산자 스크립트가 08-15 에 바뀌어 있었다. 개선인지 자가 바뀐 것인지
//   구분할 방법이 없어 그 추이는 **무효 처리**할 수밖에 없었다.
//   앞으로는 바뀐 시점을 원장에 박아, 추이를 볼 때 구간을 끊을 수 있게 한다.
const VER_STATE  = join(HOME, '.openclaw-data/runtime/state/instrument-versions.json');
const VER_LEDGER = join(HOME, '.openclaw-data/runtime/ledger/instrument-versions.jsonl');
const sha = (f) => {
  try { return createHash('sha256').update(readFileSync(f)).digest('hex').slice(0, 16); }
  catch { return null; }
};

let prev = {};
try { prev = JSON.parse(readFileSync(VER_STATE, 'utf8')); } catch { /* 최초 실행 */ }
const cur = {};
const changed = [];
for (const it of conf.instruments) {
  for (const role of ['producer', 'consumer']) {
    const raw = it[role];
    if (!raw || raw.startsWith('(')) continue;   // 시험용 자리표시자 제외
    const f = expand(raw);
    const h = sha(f);
    if (!h) continue;
    const id = `${it.ledger || it.artifact}::${role}`;
    cur[id] = h;
    if (prev[id] && prev[id] !== h) changed.push({ id, from: prev[id], to: h, file: raw });
  }
}
const firstRun = Object.keys(prev).length === 0;
try {
  mkdirSync(join(HOME, '.openclaw-data/runtime/state'), { recursive: true });
  writeFileSync(VER_STATE, JSON.stringify(cur, null, 2));
} catch { /* 기록 실패는 감사 자체를 막지 않는다 */ }

if (changed.length) {
  const ts = new Date().toISOString();
  for (const c of changed) {
    try { appendFileSync(VER_LEDGER, JSON.stringify({ ts, ...c }) + '\n'); } catch {}
  }
}

if (asJson) {
  console.log(JSON.stringify({ checked: rows.length, silent: bad.length, rows }, null, 2));
} else if (!quiet || bad.length) {
  console.log(`계측기 생존 감사 — ${rows.length}개 점검 · 침묵 ${bad.length}개`
    + (firstRun ? ' · 자 지문 최초 등록' : changed.length ? ` · ⚠ 자 변경 ${changed.length}건` : ''));
  for (const c of changed) {
    console.log(`  ⚠ 자가 바뀌었다: ${c.file}`);
    console.log(`     ${c.from} → ${c.to} — 이 시점 전후 추이는 따로 끊어서 본다`);
    console.log(`     기록: runtime/ledger/instrument-versions.jsonl`);
  }
  for (const r of rows) {
    const mark = r.state === 'ok' ? '✅' : r.state === 'missing' ? '❓' : r.state === 'frozen' ? '🧊' : '🔴';
    const d = r.silent_days === null ? '산출물 없음' : `${r.silent_days}일째 조용 (한계 ${r.max_silent_days}일)`;
    console.log(`  ${mark} ${String(r.label || r.ledger).padEnd(34)} ${d}`);
    if (r.state === 'frozen') {
      console.log(`       내용이 ${r.frozen_days}일째 그대로다 (한계 ${r.max_unchanged_days}일) — mtime 은 갱신되므로 로그상 '성공'으로 보인다`);
      console.log(`       산출물 ${r.artifact}`);
      console.log(`       생산자 ${r.producer}`);
      console.log(`       볼 것: 생산자가 쓰는 경로와 소비자가 읽는 경로가 같은가`);
    }
    if (r.state === 'silent') {
      console.log(`       마지막 기록 ${String(r.last).slice(0, 19)}`);
      console.log(`       생산자 ${r.producer}`);
      if (r.consumer) console.log(`       소비자 ${r.consumer}  ← 2단이면 생산자부터 본다`);
      console.log(`       확인: bash ~/projects/jarvis/infra/scripts/hooks-wiring-audit.sh`);
    }
  }
}

process.exit(bad.length ? 1 : 0);
