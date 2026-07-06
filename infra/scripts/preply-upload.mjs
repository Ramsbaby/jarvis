#!/usr/bin/env node
// preply-upload.mjs — 보람님 교재(HTML/PDF)를 jarvis-preply-tutor 채널에 첨부 전송하는 재사용 업로더.
// 배경: 봇이 교재를 올릴 때마다 즉석 스크립트를 짜다 #jarvis-boram 등 엉뚱한 채널로 보내는 실수가 있었음(2026-06-26).
//       채널 ID를 레지스트리에서 단일 소스로 읽어 항상 올바른 채널로 보낸다.
// 사용: node preply-upload.mjs "<메시지>" <파일1> [파일2 ...]
//       node preply-upload.mjs --channel <id> "<메시지>" <파일...>   (채널 직접 지정)
//
// 토큰: ~/jarvis/runtime/.env 의 DISCORD_TOKEN
// 의존: discord.js (infra/discord/node_modules 에 존재)

import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';

const __dirname = dirname(fileURLToPath(import.meta.url));
// discord.js는 infra/discord/node_modules에 설치돼 있음 (html2pdf.mjs와 동일 패턴)
const require = createRequire(resolve(__dirname, '..', 'discord', 'package.json'));
const { Client, GatewayIntentBits, AttachmentBuilder } = require('discord.js');

const HOME = homedir();
const REGISTRY = `${HOME}/jarvis/runtime/config/preply-students.json`;
const ENV_FILE = `${HOME}/jarvis/runtime/.env`;

function die(msg) { console.error(`❌ ${msg}`); process.exit(1); }

// --- DISCORD_TOKEN 로드 (값은 절대 출력하지 않는다) ---
function loadToken() {
  if (process.env.DISCORD_TOKEN) return process.env.DISCORD_TOKEN;
  if (!existsSync(ENV_FILE)) die(`토큰 파일 없음: ${ENV_FILE}`);
  for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = line.match(/^\s*DISCORD_TOKEN\s*=\s*(.+?)\s*$/);
    if (m) return m[1].replace(/^["']|["']$/g, '');
  }
  die('DISCORD_TOKEN 을 찾을 수 없음');
}

// --- 기본 채널 ID는 레지스트리에서 ---
function defaultChannelId() {
  try {
    const reg = JSON.parse(readFileSync(REGISTRY, 'utf8'));
    return reg?._meta?.upload_channel_id || null;
  } catch { return null; }
}

// --- 인자 파싱 ---
const argv = process.argv.slice(2);
let channelId = defaultChannelId();
const rest = [];
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--channel') { channelId = argv[++i]; continue; }
  rest.push(argv[i]);
}
if (!channelId) die('채널 ID를 결정할 수 없음 (레지스트리 _meta.upload_channel_id 또는 --channel 필요)');
if (rest.length < 2) die('사용법: preply-upload.mjs "<메시지>" <파일1> [파일2 ...]');

const message = rest[0];
const files = rest.slice(1).map((f) => resolve(f.replace(/^~/, HOME)));
for (const f of files) if (!existsSync(f)) die(`파일 없음: ${f}`);

const token = loadToken();
const client = new Client({ intents: [GatewayIntentBits.Guilds] });

const timeout = setTimeout(() => die('타임아웃(30초) — 채널 ID/권한 확인'), 30000);

client.once('clientReady', async () => {
  try {
    const channel = await client.channels.fetch(channelId);
    if (!channel || !channel.isTextBased()) die(`텍스트 채널이 아님: ${channelId}`);
    const attachments = files.map((f) => new AttachmentBuilder(f));
    await channel.send({ content: message, files: attachments });
    console.log(`✅ 업로드 완료 → #${channel.name || channelId} (파일 ${files.length}개)`);
    clearTimeout(timeout);
    await client.destroy();
    process.exit(0);
  } catch (e) {
    die(`전송 실패: ${e.message}`);
  }
});

client.on('error', (e) => die(`디스코드 클라이언트 오류: ${e.message}`));
client.login(token).catch((e) => die(`로그인 실패: ${e.message}`));
