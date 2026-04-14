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
const nodePath     = execSync('which node').toString().trim();

// .env에서 DISCORD_TOKEN 등 읽기
function readEnvValue(key) {
  if (!existsSync(envPath)) return '';
  const line = readFileSync(envPath, 'utf-8').split('\n').find(l => l.startsWith(`${key}=`));
  return line ? line.slice(key.length + 1).trim() : '';
}

const discordToken   = readEnvValue('DISCORD_TOKEN');
const guildId        = readEnvValue('GUILD_ID');
const channelIds     = readEnvValue('CHANNEL_IDS');
const ownerDiscordId = readEnvValue('OWNER_DISCORD_ID');
const ownerName      = readEnvValue('OWNER_NAME');

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
    <string>${nodePath}</string>
    <string>${join(projectRoot, 'infra', 'discord', 'discord-bot.js')}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${join(projectRoot, 'infra', 'discord')}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>BOT_HOME</key>
    <string>${botHome}</string>
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
  <string>${join(botHome, 'logs', 'discord-bot.log')}</string>
  <key>StandardErrorPath</key>
  <string>${join(botHome, 'logs', 'discord-bot.log')}</string>
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
    <string>${nodePath}</string>
    <string>${join(projectRoot, 'infra', 'scripts', 'release-checker.mjs')}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${projectRoot}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>BOT_HOME</key>
    <string>${botHome}</string>
    <key>UPDATE_CHANNEL_ID</key>
    <string>${channelId}</string>
    <key>ENV_PATH</key>
    <string>${envPath}</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>3</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${join(botHome, 'logs', 'release-checker.log')}</string>
  <key>StandardErrorPath</key>
  <string>${join(botHome, 'logs', 'release-checker.log')}</string>
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

  try {
    execSync(`launchctl load "${plistPath}"`);
    results.push({ label, status: 'loaded', path: plistPath });
  } catch (e) {
    results.push({ label, status: 'load_failed', error: e.message, path: plistPath });
  }
}

console.log(JSON.stringify({ status: 'ok', agents: results }));
