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

// 4. .env 파일 + 필수 키 (주석 줄 제외하는 파싱)
const envPath = join(HOME, '.jarvis', '.env');
if (existsSync(envPath)) {
  const lines = readFileSync(envPath, 'utf-8').split('\n');
  const definedKeys = new Set();
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eqIdx = trimmed.indexOf('=');
    if (eqIdx === -1) continue;
    definedKeys.add(trimmed.slice(0, eqIdx).trim());
  }
  const presentKeys = REQUIRED_ENV_KEYS.filter(k => definedKeys.has(k));
  details.envFile = true;
  details.envKeysOk = presentKeys.length === REQUIRED_ENV_KEYS.length;
  details.missingEnvKeys = REQUIRED_ENV_KEYS.filter(k => !definedKeys.has(k));
} else {
  details.envFile = false;
  details.envKeysOk = false;
  details.missingEnvKeys = REQUIRED_ENV_KEYS;
}

// 5. LaunchAgent 상태 (macOS only)
if (process.platform === 'darwin') {
  try {
    // stdio: ['pipe','pipe','pipe'] 로 stderr를 캡처하여 2>/dev/null 대체
    const laCtl = execSync('launchctl list', { stdio: ['pipe', 'pipe', 'pipe'] }).toString();
    details.launchAgents = {
      discordBot:     laCtl.includes('ai.jarvis.discord-bot'),
      releaseChecker: laCtl.includes('ai.jarvis.release-checker'),
    };
  } catch {
    details.launchAgents = { discordBot: false, releaseChecker: false };
  }
} else {
  try {
    // pm2 검사: 라인 전체에서 jarvis/discord 포함 여부로 판단 (공백 포함 프로세스명 대응)
    const pm2List = execSync('pm2 list --no-color', { stdio: ['pipe', 'pipe', 'pipe'] }).toString();
    const pm2Lines = pm2List.split('\n');
    details.pm2 = pm2Lines.some(l => l.includes('jarvis') || l.includes('discord'));
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
