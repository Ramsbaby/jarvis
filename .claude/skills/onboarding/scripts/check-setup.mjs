#!/usr/bin/env node
/**
 * check-setup.mjs — Jarvis 환경 파일 현황 확인
 *
 * Usage: node check-setup.mjs
 * Output: JSON { envPath, missing[], present[], updatePolicy }
 */
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const REQUIRED_KEYS = [
  'DISCORD_TOKEN',
  'ANTHROPIC_API_KEY',
  'GUILD_ID',
  'OWNER_DISCORD_ID',
  'OWNER_NAME',
  'BOT_HOME',
];

function parseEnv(filePath) {
  if (!existsSync(filePath)) return {};
  const lines = readFileSync(filePath, 'utf-8').split('\n');
  const result = {};
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const idx = trimmed.indexOf('=');
    if (idx === -1) continue;
    const key = trimmed.slice(0, idx).trim();
    const val = trimmed.slice(idx + 1).trim();
    if (key) result[key] = val;
  }
  return result;
}

const envPath = join(HOME, '.jarvis', '.env');
const env = parseEnv(envPath);

const missing = REQUIRED_KEYS.filter(k => !env[k]);
const present = REQUIRED_KEYS.filter(k => !!env[k]);

const policyPath = join(HOME, '.jarvis', 'config', 'update-policy.json');
let updatePolicy = null;
if (existsSync(policyPath)) {
  try { updatePolicy = JSON.parse(readFileSync(policyPath, 'utf-8')); } catch {}
}

console.log(JSON.stringify({ envPath, missing, present, updatePolicy }, null, 2));
