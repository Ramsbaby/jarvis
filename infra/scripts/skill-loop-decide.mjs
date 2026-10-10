#!/usr/bin/env node
// skill-loop-decide.mjs — 스킬 초안 결재를 봇 없이 기록한다 (2026-10-10)
//
// 왜: 결재는 디스코드 카드 버튼(slapprove/slreject/slhold → infra/discord/lib/approval.js)이 decision 파일을 썼다.
//     그 봇이 2026-09-10 에 없어져 버튼은 누르면 "상호작용 실패"가 되고, 그 뒤 카드 4건(10-03 ×3·10-05 ×1)은 누를 곳이 없었다.
//     결재 기록이 0건이니 skill-loop-promote 는 매일 밤 "0건 적용 (decision 0건 소비)" 로 ok 였고, pending 은 14일 뒤 만료로 사라졌다.
//     결재 기록 형식은 봇이 쓰던 것과 같다({slug, decision, by, ts}) — 등재·보관은 그대로 promote 가 한다.
//
// Usage:
//   node skill-loop-decide.mjs list                              결재 대기 초안과 만료일
//   node skill-loop-decide.mjs approve|reject|hold <이름> [--by 누구] [--apply]
//        --apply: 기록 직후 promote 를 바로 돌려 등재·보관까지 마친다(없으면 다음 야간 배치가 적용)
import { readFileSync, readdirSync, existsSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(os.homedir(), '.openclaw-data', 'runtime');
const DRAFTS = join(BOT_HOME, 'state', 'skill-drafts');
const PENDING = join(DRAFTS, 'pending');
const DECISIONS = join(DRAFTS, 'decisions');
const HERE = dirname(fileURLToPath(import.meta.url));

const field = (raw, k) => raw.match(new RegExp(`^\\s*${k}: (.+)$`, 'm'))?.[1]?.trim() || '';

function pendingDrafts() {
  if (!existsSync(PENDING)) return [];
  return readdirSync(PENDING)
    .filter(d => !d.startsWith('.') && existsSync(join(PENDING, d, 'SKILL.md')))   // anger-*.json 같은 파일은 초안이 아니다
    .map(slug => {
      const raw = readFileSync(join(PENDING, slug, 'SKILL.md'), 'utf8');
      return { slug, score: field(raw, 'score'), expires: field(raw, 'expires'), description: field(raw, 'description').slice(0, 90) };
    });
}

const [cmd, slug, ...rest] = process.argv.slice(2);

if (cmd === 'list') {
  const ds = pendingDrafts();
  if (!ds.length) { console.log('결재 대기 초안 없음'); process.exit(0); }
  console.log(`결재 대기 ${ds.length}건`);
  for (const d of ds) console.log(`- ${d.slug}  점수 ${d.score}  만료 ${d.expires}\n    ${d.description}`);
  process.exit(0);
}

if (!['approve', 'reject', 'hold'].includes(cmd) || !slug) {
  console.error('사용: skill-loop-decide.mjs list | approve|reject|hold <이름> [--by 누구] [--apply]');
  process.exit(2);
}
if (!/^[a-z0-9-]{1,64}$/.test(slug)) { console.error(`❌ 이름 형식이 맞지 않는다: ${slug}`); process.exit(2); }
if (!pendingDrafts().some(d => d.slug === slug)) {
  console.error(`❌ pending 에 없는 초안이다(이미 처리·만료?): ${slug} — list 로 확인`);
  process.exit(1);
}
const byIdx = rest.indexOf('--by');
const by = byIdx >= 0 && rest[byIdx + 1] ? rest[byIdx + 1] : 'owner-chat';

mkdirSync(DECISIONS, { recursive: true });
writeFileSync(join(DECISIONS, `${slug}.json`), JSON.stringify({ slug, decision: cmd, by, ts: new Date().toISOString() }, null, 2));
const label = { approve: '✅ 승인 기록 — 등재', reject: '🗑️ 폐기 기록 — 보관함으로', hold: '⏸️ 보류 기록 — pending 유지' }[cmd];
console.log(`${label}: ${slug} (by ${by})`);

if (rest.includes('--apply')) {
  // promote 는 decisions/ 의 모든 기록을 소비한다 — 방금 쓴 것까지 한 번에.
  const out = execFileSync('node', [join(HERE, 'skill-loop-promote.mjs')], { encoding: 'utf8', env: process.env });
  process.stdout.write(out);
} else {
  console.log('다음 야간 배치(03:50)에 적용된다. 바로 적용하려면 --apply.');
}
