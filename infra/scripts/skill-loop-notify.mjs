#!/usr/bin/env node
// skill-loop-notify.mjs — pending 초안의 Discord 결재 카드 송출 (+월요일 묶음 재안내)
// 카드 버튼 처리: infra/discord/lib/approval.js (slapprove/slreject/slhold → decision 파일 기록)
// Usage: node skill-loop-notify.mjs [--digest-only]
// 설계: ~/jarvis/runtime/state/autoplan/2026-06-10-skill-evolution-loop.md (Step 6)

import { readFileSync, readdirSync, existsSync, writeFileSync, mkdirSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
import os from 'node:os';

const HOME = os.homedir();
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis', 'runtime');
const DRAFTS = join(BOT_HOME, 'state', 'skill-drafts');
const DECISIONS = join(DRAFTS, 'decisions');
const NOTIFIED = join(DRAFTS, 'notified.json');

const env = readFileSync(join(BOT_HOME, '.env'), 'utf8');
const TOKEN = env.match(/^DISCORD_TOKEN=(.+)$/m)?.[1]?.trim();
const CHANNEL = JSON.parse(readFileSync(join(BOT_HOME, 'config', 'monitoring.json'), 'utf8')).l3_channel_id;
if (!TOKEN || !CHANNEL) { console.error('토큰 또는 l3_channel_id 누락'); process.exit(1); }

const DIGEST_ONLY = process.argv.includes('--digest-only');

async function send(payload) {
  const res = await fetch(`https://discord.com/api/v10/channels/${CHANNEL}/messages`, {
    method: 'POST',
    headers: { 'Authorization': `Bot ${TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`Discord API ${res.status}: ${(await res.text()).slice(0, 200)}`);
  return res.json();
}

function parseDraft(slug) {
  const raw = readFileSync(join(DRAFTS, 'pending', slug, 'SKILL.md'), 'utf8');
  const get = (k) => raw.match(new RegExp(`^\\s*${k}: (.+)$`, 'm'))?.[1] || '';
  const evidence = raw.split('## 검증 증거')[1]?.match(/\$ .+/)?.[0]?.slice(0, 120) || '(증거 발췌 실패)';
  return { slug, description: get('description').slice(0, 180), score: get('score'), evidenceCount: get('evidence-count'), expires: get('expires'), mode: get('mode'), duplicateOf: get('duplicate-of'), evidence };
}

const notified = existsSync(NOTIFIED) ? JSON.parse(readFileSync(NOTIFIED, 'utf8')) : [];
const pendingDir = join(DRAFTS, 'pending');
const pending = existsSync(pendingDir) ? readdirSync(pendingDir).filter(d => !d.startsWith('.')) : [];

// 개별 카드 (미통보 + 미결재 분만)
let sent = 0;
if (!DIGEST_ONLY) {
  for (const slug of pending) {
    if (notified.includes(slug) || existsSync(join(DECISIONS, `${slug}.json`))) continue;
    const d = parseDraft(slug);
    const dupLine = d.duplicateOf ? `\n♻️ 기존 \`${d.duplicateOf}\` 스킬 **개선 제안** 모드` : '';
    await send({
      content: [
        `🧬 **스킬 초안 결재 요청** — \`${d.slug}\``,
        `- ${d.description}`,
        `- 점수 **${d.score}**/10 · 실측 증거 **${d.evidenceCount}**건 · 만료 ${d.expires}${dupLine}`,
        `- 증거 발췌: \`${d.evidence.replace(/`/g, "'")}\``,
      ].join('\n'),
      components: [{
        type: 1,
        components: [
          { type: 2, style: 3, label: '승인', custom_id: `slapprove:${d.slug}` },
          { type: 2, style: 2, label: '보류', custom_id: `slhold:${d.slug}` },
          { type: 2, style: 4, label: '폐기', custom_id: `slreject:${d.slug}` },
        ],
      }],
    });
    notified.push(slug);
    sent++;
    // 송출 직후 즉시 기록 (중간 실패 시 재실행해도 중복 카드 방지 — /verify 지적) + 원장 흔적
    writeFileSync(NOTIFIED, JSON.stringify(notified, null, 2));
    appendFileSync(join(BOT_HOME, 'ledger', 'skill-loop.jsonl'),
      JSON.stringify({ ts: new Date().toISOString(), event: 'card-sent', slug, score: d.score }) + '\n');
  }
}

// 월요일 묶음 재안내 (KST)
const kstDay = new Date(Date.now() + 9 * 3600_000).getUTCDay();
if ((kstDay === 1 || DIGEST_ONLY) && pending.length > 0) {
  const lines = pending.map(s => { const d = parseDraft(s); return `- \`${s}\` (점수 ${d.score}, 만료 ${d.expires})`; });
  await send({ content: `📋 **스킬 초안 주간 묶음 안내** — 미결재 ${pending.length}건\n${lines.join('\n')}\n결재는 각 카드 버튼으로 부탁드립니다.` });
}
console.log(`카드 ${sent}건 송출, pending ${pending.length}건`);
