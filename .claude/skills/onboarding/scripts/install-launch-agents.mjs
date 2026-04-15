#!/usr/bin/env node
/**
 * install-launch-agents.mjs — macOS LaunchAgent 통합 설치
 *
 * Usage:
 *   node install-launch-agents.mjs --channel-id CHANNEL_ID
 *
 * 설치 대상:
 *   ai.jarvis.discord-bot      — 봇 자동 시작
 *   ai.jarvis.release-checker  — 매일 03:00 릴리즈 체크
 *   ai.jarvis.watchdog         — watchdog (plist 템플릿 있는 경우만)
 */
import { writeFileSync, existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const HOME = homedir();
const __dirname = dirname(fileURLToPath(import.meta.url));

if (process.platform !== 'darwin') {
  console.log(JSON.stringify({ status: 'skip', message: 'macOS only — use PM2 on Linux' }));
  process.exit(0);
}

const args = process.argv.slice(2);
const cidIdx = args.indexOf('--channel-id');
const channelId = cidIdx !== -1 ? args[cidIdx + 1] : null;

if (!channelId) {
  console.error(JSON.stringify({ error: 'Usage: --channel-id CHANNEL_ID' }));
  process.exit(1);
}

const projectRoot  = join(__dirname, '../../../../');
const botHome      = process.env.BOT_HOME || join(HOME, '.local', 'share', 'jarvis');
const agentsDir    = join(HOME, 'Library', 'LaunchAgents');
const envPath      = join(HOME, '.jarvis', '.env');

// which node를 try/catch로 감싸기
let nodePath;
try {
  nodePath = execSync('which node').toString().trim();
} catch (e) {
  console.error(JSON.stringify({ error: 'node not found in PATH: ' + e.message }));
  process.exit(1);
}

// XML 특수문자 이스케이프 함수
function escapeXml(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

// .env에서 값 읽기 (따옴표/공백 처리 강화)
function readEnvValue(key) {
  if (!existsSync(envPath)) return '';
  const lines = readFileSync(envPath, 'utf-8').split('\n');
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eqIdx = trimmed.indexOf('=');
    if (eqIdx === -1) continue;
    const k = trimmed.slice(0, eqIdx).trim();
    if (k !== key) continue;
    let v = trimmed.slice(eqIdx + 1).trim();
    // 따옴표 제거
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    return v;
  }
  return '';
}

const discordToken   = escapeXml(readEnvValue('DISCORD_TOKEN'));
const guildId        = escapeXml(readEnvValue('GUILD_ID'));
const channelIds     = escapeXml(readEnvValue('CHANNEL_IDS'));
const ownerDiscordId = escapeXml(readEnvValue('OWNER_DISCORD_ID'));
const ownerName      = escapeXml(readEnvValue('OWNER_NAME'));
const safeNodePath   = escapeXml(nodePath);
const safeBotHome    = escapeXml(botHome);
const safeEnvPath    = escapeXml(envPath);
const safeChannelId  = escapeXml(channelId);

const plists = {
  'ai.jarvis.discord-bot': `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.jarvis.discord-bot</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-s</string>
    <string>${safeNodePath}</string>
    <string>${escapeXml(join(projectRoot, 'infra', 'discord', 'discord-bot.js'))}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${escapeXml(join(projectRoot, 'infra', 'discord'))}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>BOT_HOME</key>
    <string>${safeBotHome}</string>
    <key>DISCORD_TOKEN</key>
    <string>${discordToken}</string>
    <key>CHANNEL_IDS</key>
    <string>${channelIds}</string>
    <key>GUILD_ID</key>
    <string>${guildId}</string>
    <key>OWNER_DISCORD_ID</key>
    <string>${ownerDiscordId}</string>
    <key>OWNER_NAME</key>
    <string>${ownerName}</string>
  </dict>
  <key>KeepAlive</key>
  <true/>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${escapeXml(join(botHome, 'logs', 'discord-bot.log'))}</string>
  <key>StandardErrorPath</key>
  <string>${escapeXml(join(botHome, 'logs', 'discord-bot.log'))}</string>
</dict>
</plist>`,

  'ai.jarvis.release-checker': `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.jarvis.release-checker</string>
  <key>ProgramArguments</key>
  <array>
    <string>${safeNodePath}</string>
    <string>${escapeXml(join(projectRoot, 'infra', 'scripts', 'release-checker.mjs'))}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${escapeXml(projectRoot)}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>BOT_HOME</key>
    <string>${safeBotHome}</string>
    <key>UPDATE_CHANNEL_ID</key>
    <string>${safeChannelId}</string>
    <key>ENV_PATH</key>
    <string>${safeEnvPath}</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>3</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${escapeXml(join(botHome, 'logs', 'release-checker.log'))}</string>
  <key>StandardErrorPath</key>
  <string>${escapeXml(join(botHome, 'logs', 'release-checker.log'))}</string>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>`,
};

const results = [];

for (const [label, content] of Object.entries(plists)) {
  const plistPath = join(agentsDir, `${label}.plist`);

  // 기존 언로드
  try {
    if (existsSync(plistPath)) execSync(`launchctl unload "${plistPath}" 2>/dev/null || true`);
  } catch {}

  writeFileSync(plistPath, content);

  // launchctl load 실패 시 에러를 명확히 리포트하되 다음 plist 계속 시도
  try {
    execSync(`launchctl load "${plistPath}"`);
    results.push({ label, status: 'loaded', path: plistPath });
  } catch (e) {
    results.push({ label, status: 'load_failed', error: e.message, path: plistPath });
  }
}

console.log(JSON.stringify({ status: 'ok', agents: results }));
