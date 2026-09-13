#!/usr/bin/env node
/**
 * gostop-bugs-channel-setup.mjs — 고스톱 버그 신고 채널·웹훅 준비 (2026-09-06, QA 자동화 1단계)
 *
 * 하는 일 (멱등 — 여러 번 돌려도 같은 결과):
 *   1. 길드에 비공개 텍스트 채널 `gostop-bugs` 가 없으면 만든다
 *      (@everyone 열람 거부 · 주인님 · 봇만 허용).
 *   2. 그 채널에 웹훅 「고스톱 버그 신고」가 없으면 만든다.
 *   3. 웹훅 주소를 테스터 env 파일(기본 ~/.config/gostop/tester.env, 0600)에
 *      `BUG_WEBHOOK_URL=…` 로 적는다. 앱 빌드 스크립트가 이 파일을 읽어
 *      `--dart-define` 으로 굳혀 넣는다.
 *
 * 출력에는 채널 id·웹훅 id·파일 경로만 나온다. 토큰·웹훅 주소는 절대 찍지 않는다.
 *
 * 입력: ~/projects/jarvis/.env 의 DISCORD_TOKEN · GUILD_ID,
 *       $BOT_HOME/config/user_profiles.json 의 owner.discordId
 * 옵션: --env-out <path>  테스터 env 파일 위치 (기본 $GOSTOP_TESTER_ENV 또는 ~/.config/gostop/tester.env)
 *       --dry-run          만들지 않고 현재 상태만 본다
 */
import fs from 'node:fs';
import path from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const BOT_HOME = process.env.BOT_HOME || path.join(HOME, '.openclaw-data/runtime');
const CHANNEL_NAME = 'gostop-bugs';
const WEBHOOK_NAME = '고스톱 버그 신고';
const API = 'https://discord.com/api/v10';

// 권한 비트 (Discord 문서)
const VIEW_CHANNEL = 1n << 10n;
const SEND_MESSAGES = 1n << 11n;
const ATTACH_FILES = 1n << 15n;
const READ_MESSAGE_HISTORY = 1n << 16n;
const MANAGE_WEBHOOKS = 1n << 29n;

function loadEnvFile(p) {
  if (!fs.existsSync(p)) return;
  for (const raw of fs.readFileSync(p, 'utf-8').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const i = line.indexOf('=');
    if (i < 0) continue;
    const k = line.slice(0, i).trim();
    let v = line.slice(i + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    if (process.env[k] === undefined) process.env[k] = v;
  }
}

function arg(name) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

loadEnvFile(path.join(HOME, 'projects/jarvis/.env'));
const TOKEN = process.env.DISCORD_TOKEN;
const GUILD_ID = process.env.GUILD_ID;
if (!TOKEN || !GUILD_ID) {
  console.error('❌ DISCORD_TOKEN 또는 GUILD_ID 가 없습니다 (~/projects/jarvis/.env)');
  process.exit(2);
}
const dryRun = process.argv.includes('--dry-run');
const envOut = arg('--env-out') || process.env.GOSTOP_TESTER_ENV || path.join(HOME, '.config/gostop/tester.env');

let ownerId = null;
try {
  ownerId = JSON.parse(fs.readFileSync(path.join(BOT_HOME, 'config/user_profiles.json'), 'utf-8'))?.owner?.discordId ?? null;
} catch { /* 없으면 @everyone 거부만 건다 */ }

async function api(method, route, body) {
  const res = await fetch(`${API}${route}`, {
    method,
    headers: {
      Authorization: `Bot ${TOKEN}`,
      'Content-Type': 'application/json',
      'X-Audit-Log-Reason': 'gostop QA: bug report channel',
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* non-json */ }
  if (!res.ok) {
    const msg = json?.message || text.slice(0, 200);
    throw new Error(`${method} ${route} → HTTP ${res.status} ${msg}`);
  }
  return json;
}

const me = await api('GET', '/users/@me');
console.log(`봇: ${me.username} (id ${me.id})`);

// 1. 채널
const channels = await api('GET', `/guilds/${GUILD_ID}/channels`);
let channel = channels.find((c) => c.type === 0 && c.name === CHANNEL_NAME);
if (channel) {
  console.log(`채널: #${CHANNEL_NAME} 이미 있음 (id ${channel.id})`);
} else if (dryRun) {
  console.log(`채널: #${CHANNEL_NAME} 없음 — dry-run 이라 만들지 않음`);
  process.exit(0);
} else {
  const allowMember = (VIEW_CHANNEL | SEND_MESSAGES | ATTACH_FILES | READ_MESSAGE_HISTORY).toString();
  const overwrites = [
    { id: GUILD_ID, type: 0, deny: VIEW_CHANNEL.toString(), allow: '0' }, // @everyone
    { id: me.id, type: 1, allow: (BigInt(allowMember) | MANAGE_WEBHOOKS).toString(), deny: '0' },
  ];
  if (ownerId) overwrites.push({ id: ownerId, type: 1, allow: allowMember, deny: '0' });
  channel = await api('POST', `/guilds/${GUILD_ID}/channels`, {
    name: CHANNEL_NAME,
    type: 0,
    topic: '고스톱 앱 버그 신고 — 앱의 「버그 신고」 버튼과 자동 감시자가 재현 파일(JSON)·화면 캡처를 올린다. 사람은 여기서 판단만.',
    permission_overwrites: overwrites,
  });
  console.log(`채널: #${CHANNEL_NAME} 만듦 (id ${channel.id}, 비공개: @everyone 거부${ownerId ? ' · 주인님 허용' : ''} · 봇 허용)`);
}

// 2. 웹훅
const hooks = await api('GET', `/channels/${channel.id}/webhooks`);
let hook = hooks.find((h) => h.name === WEBHOOK_NAME && h.token);
if (hook) {
  console.log(`웹훅: 「${WEBHOOK_NAME}」 이미 있음 (id ${hook.id})`);
} else if (dryRun) {
  console.log(`웹훅: 「${WEBHOOK_NAME}」 없음 — dry-run 이라 만들지 않음`);
  process.exit(0);
} else {
  hook = await api('POST', `/channels/${channel.id}/webhooks`, { name: WEBHOOK_NAME });
  console.log(`웹훅: 「${WEBHOOK_NAME}」 만듦 (id ${hook.id})`);
}
if (!hook.token) {
  console.error('❌ 웹훅 토큰을 받지 못했습니다 — 봇에 MANAGE_WEBHOOKS 권한이 있는지 확인');
  process.exit(3);
}
const url = `https://discord.com/api/webhooks/${hook.id}/${hook.token}`;

// 3. 테스터 env 파일 (값은 출력하지 않는다)
fs.mkdirSync(path.dirname(envOut), { recursive: true, mode: 0o700 });
const existing = fs.existsSync(envOut) ? fs.readFileSync(envOut, 'utf-8') : '';
const keep = existing.split('\n').filter((l) => l && !/^(BUG_WEBHOOK_URL|GOSTOP_BUGS_CHANNEL_ID|GOSTOP_BUGS_WEBHOOK_ID)=/.test(l));
const out = [
  '# 고스톱 테스터 빌드 시크릿 — scripts/build-release-apk.sh 가 읽어 --dart-define 으로 넣는다.',
  '# 만든 도구: ~/projects/jarvis/infra/scripts/gostop-bugs-channel-setup.mjs (다시 돌리면 갱신)',
  ...keep.filter((l) => !l.startsWith('#')),
  `GOSTOP_BUGS_CHANNEL_ID=${channel.id}`,
  `GOSTOP_BUGS_WEBHOOK_ID=${hook.id}`,
  `BUG_WEBHOOK_URL=${url}`,
  '',
].join('\n');
fs.writeFileSync(envOut, out, { mode: 0o600 });
fs.chmodSync(envOut, 0o600);
console.log(`저장: ${envOut.replace(HOME, '~')} (0600) — BUG_WEBHOOK_URL · GOSTOP_BUGS_CHANNEL_ID · GOSTOP_BUGS_WEBHOOK_ID`);
