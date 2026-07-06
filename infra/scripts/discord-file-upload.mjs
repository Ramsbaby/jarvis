#!/usr/bin/env node
// discord-file-upload.mjs — 임의의 파일을 채널 이름 또는 ID로 첨부 전송하는 범용 업로더.
// preply-upload.mjs(보람님 교재 전용, preply 레지스트리 의존)와 달리 어떤 채널·파일에도 쓴다.
// 봇/discord_send는 채널 이름으로 보내는데 파일 첨부는 못 하므로, 이름 해석 + 첨부를 한 번에 처리.
//
// 사용: node discord-file-upload.mjs <채널이름|채널ID> "<메시지>" <파일1> [파일2 ...]
//   예: node discord-file-upload.mjs jarvis "면접 자료입니다" ~/Downloads/x.pdf
//
// 토큰: ~/jarvis/runtime/.env 의 DISCORD_TOKEN (값은 절대 출력하지 않음)
// 의존: discord.js (infra/discord/node_modules)

import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname, basename } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'url';
import { createRequire } from 'module';

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(resolve(__dirname, '..', 'discord', 'package.json'));
const { Client, GatewayIntentBits, AttachmentBuilder } = require('discord.js');

const HOME = homedir();
const ENV_FILE = `${HOME}/jarvis/runtime/.env`;

function die(msg) { console.error(`❌ ${msg}`); process.exit(1); }

function loadToken() {
  if (process.env.DISCORD_TOKEN) return process.env.DISCORD_TOKEN;
  if (!existsSync(ENV_FILE)) die(`토큰 파일 없음: ${ENV_FILE}`);
  for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = line.match(/^\s*DISCORD_TOKEN\s*=\s*(.+?)\s*$/);
    if (m) return m[1].replace(/^["']|["']$/g, '');
  }
  die('DISCORD_TOKEN 을 찾을 수 없음');
}

const argv = process.argv.slice(2);
if (argv.length < 3) die('사용법: discord-file-upload.mjs <채널이름|ID> "<메시지>" <파일1> [파일2 ...]');
const target = argv[0];
const message = argv[1];
const files = argv.slice(2).map((f) => resolve(f.replace(/^~/, HOME)));
for (const f of files) if (!existsSync(f)) die(`파일 없음: ${f}`);

// 디스코드는 비ASCII(한글 등) 첨부 파일명을 랜덤 해시로 저장한다 → 다운로드 시 이름 깨짐 + 중복 가드 무력화.
// 그래서 표시용 파일명은 항상 ASCII로 정규화한다(비면 attachment 폴백). 원본 로컬 파일명은 그대로 둔다.
function asciiName(name) {
  const ext = (name.match(/\.[a-zA-Z0-9]+$/) || [''])[0];
  let stem = name.slice(0, name.length - ext.length)
    .normalize('NFKD').replace(/[^\x20-\x7E]/g, '')
    .replace(/[^\w.-]+/g, '-').replace(/^[-_]+|[-_]+$/g, '');
  if (!/[a-zA-Z0-9]/.test(stem)) stem = ''; // 한글만 있던 이름 등 → 폴백
  return (stem || 'attachment') + (ext || '');
}

const token = loadToken();
const client = new Client({ intents: [GatewayIntentBits.Guilds] });
const timeout = setTimeout(() => die('타임아웃(30초) — 채널/권한 확인'), 30000);

function resolveChannel() {
  // ID(숫자)면 직접 fetch, 아니면 캐시된 채널 중 이름 매칭
  if (/^[0-9]{17,20}$/.test(target)) return client.channels.fetch(target);
  const found = client.channels.cache.find(
    (c) => c.isTextBased?.() && (c.name === target || c.name === target.replace(/^#/, '')),
  );
  return Promise.resolve(found || null);
}

client.once('clientReady', async () => {
  try {
    const channel = await resolveChannel();
    if (!channel || !channel.isTextBased()) die(`텍스트 채널을 찾지 못함: ${target}`);
    const names = files.map((f) => asciiName(basename(f)));
    files.forEach((f, i) => {
      if (names[i] !== basename(f)) console.log(`ℹ️  첨부명 ASCII 정규화: ${basename(f)} → ${names[i]}`);
    });
    // 중복 전송 방지: 최근 10개 메시지에 같은 파일명 첨부가 이미 있으면 건너뜀(멱등).
    const recent = await channel.messages.fetch({ limit: 10 }).catch(() => null);
    if (recent) {
      const already = new Set();
      for (const m of recent.values()) for (const a of m.attachments.values()) already.add(a.name);
      const dup = names.filter((n) => already.has(n));
      if (dup.length === names.length) {
        console.log(`⏭️  이미 전송됨(중복 방지) → #${channel.name || target}: ${dup.join(', ')}`);
        clearTimeout(timeout);
        await client.destroy();
        process.exit(0);
      }
    }
    // 표시명은 위에서 ASCII 정규화한 names 사용 (비ASCII면 디스코드가 랜덤 해시로 저장 → 이름 깨짐 + 가드 무력화).
    const attachments = files.map((f, i) => new AttachmentBuilder(f, { name: names[i] }));
    await channel.send({ content: message, files: attachments });
    console.log(`✅ 업로드 완료 → #${channel.name || target} (파일 ${files.length}개: ${names.join(', ')})`);
    clearTimeout(timeout);
    await client.destroy();
    process.exit(0);
  } catch (e) {
    die(`전송 실패: ${e.message}`);
  }
});

client.on('error', (e) => die(`디스코드 클라이언트 오류: ${e.message}`));
client.login(token).catch((e) => die(`로그인 실패: ${e.message}`));
