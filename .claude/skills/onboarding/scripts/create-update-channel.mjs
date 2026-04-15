#!/usr/bin/env node
/**
 * create-update-channel.mjs — 🚀jarvis-update 채널 생성 및 등록
 *
 * Usage:
 *   export $(grep -v '^#' ~/.jarvis/.env | grep -v '^$' | xargs)
 *   node create-update-channel.mjs
 *
 * Output:
 *   { "channelId": "...", "channelName": "🚀jarvis-update" }
 */
import { Client, GatewayIntentBits, ChannelType, PermissionFlagsBits } from 'discord.js';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const HOME = homedir();
const __dirname = dirname(fileURLToPath(import.meta.url));

const token = process.env.DISCORD_TOKEN;
const guildId = process.env.GUILD_ID;

if (!token || !guildId) {
  console.error(JSON.stringify({ error: 'DISCORD_TOKEN and GUILD_ID required' }));
  process.exit(1);
}

const CHANNEL_NAME = '🚀jarvis-update';
const SYSTEM_PERSONA = `--- Channel: ${CHANNEL_NAME} ---
이 채널은 Jarvis 업데이트 전용 알림 채널입니다.
새 릴리즈 발견, 자동 업데이트 완료, 수동 업데이트 요청 알림을 전송합니다.
Keep responses factual and actionable. Include version info and changelog links.`;

function parseEnv(filePath) {
  if (!existsSync(filePath)) return {};
  const lines = readFileSync(filePath, 'utf-8').split('\n');
  const result = {};
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const idx = trimmed.indexOf('=');
    if (idx === -1) continue;
    result[trimmed.slice(0, idx).trim()] = trimmed.slice(idx + 1).trim();
  }
  return result;
}

function updateEnvChannelIds(envPath, newChannelId) {
  if (!existsSync(envPath)) return;
  let content = readFileSync(envPath, 'utf-8');
  const match = content.match(/^CHANNEL_IDS=(.*)$/m);
  if (match) {
    const existing = match[1].trim();
    const updated = existing ? `${existing},${newChannelId}` : newChannelId;
    content = content.replace(/^CHANNEL_IDS=.*$/m, `CHANNEL_IDS=${updated}`);
  } else {
    content += `\nCHANNEL_IDS=${newChannelId}\n`;
  }
  writeFileSync(envPath, content);
}

function updatePersonas(personasPath, channelId) {
  let personas = {};
  if (existsSync(personasPath)) {
    try { personas = JSON.parse(readFileSync(personasPath, 'utf-8')); } catch {}
  }
  personas[channelId] = SYSTEM_PERSONA;
  writeFileSync(personasPath, JSON.stringify(personas, null, 2));
}

function updatePlistChannelIds(plistPath, newChannelId) {
  if (!existsSync(plistPath)) return;
  let content = readFileSync(plistPath, 'utf-8');
  const match = content.match(/<key>CHANNEL_IDS<\/key>\s*<string>([^<]*)<\/string>/);
  if (match) {
    const existing = match[1].trim();
    const updated = existing ? `${existing},${newChannelId}` : newChannelId;
    content = content.replace(
      /<key>CHANNEL_IDS<\/key>\s*<string>[^<]*<\/string>/,
      `<key>CHANNEL_IDS</key>\n    <string>${updated}</string>`
    );
    writeFileSync(plistPath, content);
  }
}

const client = new Client({ intents: [GatewayIntentBits.Guilds] });

// 타임아웃: 60초 후에도 ready 이벤트 없으면 에러 종료
const timeout = setTimeout(() => {
  console.error(JSON.stringify({ error: 'Timeout: ready event not received within 60 seconds' }));
  client.destroy();
  process.exit(1);
}, 60000);

// 에러 핸들러: 토큰/네트워크 오류 시 hang 방지
client.on('error', (err) => {
  clearTimeout(timeout);
  console.error(JSON.stringify({ error: err.message }));
  client.destroy();
  process.exit(1);
});

client.once('ready', async () => {
  clearTimeout(timeout);
  try {
    const guild = client.guilds.cache.get(guildId) || await client.guilds.fetch(guildId);

    // 중복 확인
    const existing = guild.channels.cache.find(c => c.name === CHANNEL_NAME);
    if (existing) {
      console.log(JSON.stringify({
        channelId: existing.id,
        channelName: existing.name,
        status: 'already_exists',
      }));
      client.destroy();
      process.exit(0);
      return;
    }

    const channel = await guild.channels.create({
      name: CHANNEL_NAME,
      type: ChannelType.GuildText,
      permissionOverwrites: [{
        id: client.user.id,
        allow: [
          PermissionFlagsBits.ViewChannel,
          PermissionFlagsBits.SendMessages,
          PermissionFlagsBits.ReadMessageHistory,
          PermissionFlagsBits.EmbedLinks,
        ],
      }],
    });

    const channelId = channel.id;

    // .env 두 곳 업데이트
    updateEnvChannelIds(join(HOME, '.jarvis', '.env'), channelId);
    updateEnvChannelIds(join(HOME, '.local', 'share', 'jarvis', '.env'), channelId);

    // personas.json 업데이트 (프로젝트 루트 기준)
    const projectRoot = join(__dirname, '../../../../');
    const personasPath = join(projectRoot, 'infra', 'discord', 'personas.json');
    updatePersonas(personasPath, channelId);

    // plist CHANNEL_IDS 업데이트
    const plistPath = join(HOME, 'Library', 'LaunchAgents', 'ai.jarvis.discord-bot.plist');
    updatePlistChannelIds(plistPath, channelId);

    console.log(JSON.stringify({ channelId, channelName: channel.name, status: 'created' }));
  } catch (err) {
    console.error(JSON.stringify({ error: err.message }));
    process.exit(1);
  } finally {
    client.destroy();
  }
});

client.login(token);
