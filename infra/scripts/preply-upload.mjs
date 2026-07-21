#!/usr/bin/env node
// preply-upload.mjs — 보람님 교재(HTML/PDF)를 jarvis-preply-tutor 채널에 첨부 전송하는 재사용 업로더.
// 배경: 봇이 교재를 올릴 때마다 즉석 스크립트를 짜다 #jarvis-boram 등 엉뚱한 채널로 보내는 실수가 있었음(2026-06-26).
//       채널 ID를 레지스트리에서 단일 소스로 읽어 항상 올바른 채널로 보낸다.
// 사용: node preply-upload.mjs "<메시지>" <파일1> [파일2 ...]
//       node preply-upload.mjs --channel <id> "<메시지>" <파일...>   (채널 직접 지정)
//
// 토큰: ~/jarvis/runtime/.env 의 DISCORD_TOKEN
// 의존: discord.js (infra/discord/node_modules 에 존재)

import { readFileSync, existsSync, statSync, appendFileSync, mkdirSync } from 'node:fs';
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

// --- 업로드 시도/결과 원장 (2026-07-13: '파일전송' 반복 불만이 verify/렌더 검사 사각지대라 조용히 실패하던 문제.
//     업로드 성공·실패를 기록해 가시화 → preply-complaint-scan이 교차 참조 가능.) ---
const UPLOAD_LEDGER = `${HOME}/jarvis/runtime/state/preply-upload-ledger.jsonl`;
function logUpload(rec) {
  try {
    mkdirSync(dirname(UPLOAD_LEDGER), { recursive: true });
    appendFileSync(UPLOAD_LEDGER, JSON.stringify(rec) + '\n');
  } catch { /* 로깅 실패가 업로드를 막지 않도록 삼킴 */ }
}

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
// 업로드 전 무결성 검증: 생성이 중간에 끊기면 0바이트/손상 파일이 조용히 올라가 보람님이 "다시 올려줘" 반복.
for (const f of files) {
  if (!existsSync(f)) die(`파일 없음(생성 미완 의심): ${f}`);
  const sz = statSync(f).size;
  if (sz === 0) die(`파일이 비어있음(생성 중단 의심): ${f}`);
  if (/\.pdf$/i.test(f) && sz < 1024) die(`PDF가 비정상적으로 작음(${sz}B, 손상 의심): ${f}`);
}

const token = loadToken();
const client = new Client({ intents: [GatewayIntentBits.Guilds] });

const filesMeta = files.map((f) => ({ path: f, bytes: statSync(f).size }));

// 재시도 여유를 둔 전체 타임아웃 (기존 30s → 90s: 3회 재시도+백오프 수용)
const timeout = setTimeout(() => {
  logUpload({ ts: new Date().toISOString(), channel: channelId, files: filesMeta, result: 'timeout' });
  die('타임아웃(90초) — 채널 ID/권한/네트워크 확인');
}, 90000);

client.once('clientReady', async () => {
  let channel;
  try {
    channel = await client.channels.fetch(channelId);
    if (!channel || !channel.isTextBased()) die(`텍스트 채널이 아님: ${channelId}`);
  } catch (e) {
    logUpload({ ts: new Date().toISOString(), channel: channelId, files: filesMeta, result: 'channel-fetch-fail', error: e.message });
    clearTimeout(timeout);
    die(`채널 조회 실패: ${e.message}`);
  }

  const maxAttempts = 3;
  let lastErr = null;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      const attachments = files.map((f) => new AttachmentBuilder(f));
      const sent = await channel.send({ content: message, files: attachments });
      // 전송 후 검증: 첨부가 전부 도착했는지 확인 (부분 업로드/누락 감지 — verify가 못 잡던 사각지대)
      const landed = sent?.attachments?.size ?? 0;
      if (landed !== files.length) {
        throw new Error(`첨부 개수 불일치: 보낸 ${files.length}개 / 도착 ${landed}개`);
      }
      logUpload({ ts: new Date().toISOString(), channel: channel.name || channelId, files: filesMeta, attempts: attempt, result: 'ok' });
      console.log(`✅ 업로드 완료 → #${channel.name || channelId} (파일 ${files.length}개, 시도 ${attempt}회)`);
      clearTimeout(timeout);
      await client.destroy();
      process.exit(0);
    } catch (e) {
      lastErr = e;
      console.error(`⚠️ 업로드 시도 ${attempt}/${maxAttempts} 실패: ${e.message}`);
      if (attempt < maxAttempts) await new Promise((r) => setTimeout(r, attempt * 2000)); // 2s → 4s 백오프
    }
  }
  // 모든 재시도 소진 — 실패를 원장에 남기고 명확히 종료 (조용한 실패 금지 → "왜 안 올려" 방지)
  logUpload({ ts: new Date().toISOString(), channel: channel.name || channelId, files: filesMeta, attempts: maxAttempts, result: 'fail', error: lastErr?.message });
  clearTimeout(timeout);
  die(`전송 실패(${maxAttempts}회 재시도 후): ${lastErr?.message}`);
});

client.on('error', (e) => die(`디스코드 클라이언트 오류: ${e.message}`));
client.login(token).catch((e) => die(`로그인 실패: ${e.message}`));
