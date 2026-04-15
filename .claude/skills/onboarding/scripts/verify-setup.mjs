#!/usr/bin/env node
/**
 * verify-setup.mjs — 온보딩 최종 검증
 *
 * Usage: node verify-setup.mjs
 * Output: JSON { passed, total, details }
 */
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
import { execSync } from 'node:child_process';

const HOME = homedir();
const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '../../../../');
const botHome = process.env.BOT_HOME || join(HOME, '.local', 'share', 'jarvis');

const REQUIRED_ENV_KEYS = ['DISCORD_TOKEN', 'ANTHROPIC_API_KEY', 'GUILD_ID', 'OWNER_DISCORD_ID', 'OWNER_NAME'];
const DATA_SUBDIRS      = ['logs', 'state', 'context', 'inbox', 'results', 'rag', 'data', 'config'];

const details = {};

// 1. node_modules 존재
details.discordDeps = existsSync(join(projectRoot, 'infra', 'discord', 'node_modules'));

// 2. 봇 문법 검증
try {
  execSync(`node --check "${join(projectRoot, 'infra', 'discord', 'discord-bot.js')}"`, { stdio: 'pipe' });
  details.botSyntax = true;
} catch {
  details.botSyntax = false;
}

// 3. 데이터 디렉토리 8개
details.dataDirs = DATA_SUBDIRS.every(d => existsSync(join(botHome, d)));
details.missingDirs = DATA_SUBDIRS.filter(d => !existsSync(join(botHome, d)));

// 4. .env 파일 + 필수 키
const envPath = join(HOME, '.jarvis', '.env');
if (existsSync(envPath)) {
  const content = readFileSync(envPath, 'utf-8');
  const presentKeys = REQUIRED_ENV_KEYS.filter(k => content.includes(`${k}=`));
  details.envFile = true;
  details.envKeysOk = presentKeys.length === REQUIRED_ENV_KEYS.length;
  details.missingEnvKeys = REQUIRED_ENV_KEYS.filter(k => !content.includes(`${k}=`));
} else {
  details.envFile = false;
  details.envKeysOk = false;
  details.missingEnvKeys = REQUIRED_ENV_KEYS;
}

// 5. LaunchAgent 상태 (macOS only)
if (process.platform === 'darwin') {
  try {
    const laCtl = execSync('launchctl list 2>/dev/null').toString();
    details.launchAgents = {
      discordBot:      laCtl.includes('ai.jarvis.discord-bot'),
      releaseChecker:  laCtl.includes('ai.jarvis.release-checker'),
    };
  } catch {
    details.launchAgents = { discordBot: false, releaseChecker: false };
  }
} else {
  try {
    const pm2List = execSync('pm2 list --no-color 2>/dev/null').toString();
    details.pm2 = pm2List.includes('jarvis') || pm2List.includes('discord');
  } catch {
    details.pm2 = false;
  }
}

// 최종 집계
const checks = [
  details.discordDeps,
  details.botSyntax,
  details.dataDirs,
  details.envFile && details.envKeysOk,
];
const passed = checks.filter(Boolean).length;
const total  = checks.length;

console.log(JSON.stringify({ passed, total, details }, null, 2));
process.exit(passed === total ? 0 : 1);
