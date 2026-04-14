#!/usr/bin/env node
/**
 * install-release-checker.mjs — 릴리즈 체커 LaunchAgent 등록
 *
 * Usage:
 *   node install-release-checker.mjs --channel-id CHANNEL_ID
 *
 * 생성: ~/Library/LaunchAgents/ai.jarvis.release-checker.plist
 */
import { writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const HOME = homedir();
const __dirname = dirname(fileURLToPath(import.meta.url));

const args = process.argv.slice(2);
const cidIdx = args.indexOf('--channel-id');
const channelId = cidIdx !== -1 ? args[cidIdx + 1] : null;

if (!channelId) {
  console.error(JSON.stringify({ error: 'Usage: --channel-id CHANNEL_ID' }));
  process.exit(1);
}

// release-checker.mjs 위치: infra/scripts/release-checker.mjs
const projectRoot = join(__dirname, '../../../../');
const checkerScript = join(projectRoot, 'infra', 'scripts', 'release-checker.mjs');
const botHome = process.env.BOT_HOME || join(HOME, '.local', 'share', 'jarvis');
const envPath = join(HOME, '.jarvis', '.env');
const logPath = join(botHome, 'logs', 'release-checker.log');
const nodePath = execSync('which node').toString().trim();

const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.jarvis.release-checker</string>
  <key>ProgramArguments</key>
  <array>
    <string>${nodePath}</string>
    <string>${checkerScript}</string>
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
  <string>${logPath}</string>
  <key>StandardErrorPath</key>
  <string>${logPath}</string>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
`;

const plistPath = join(HOME, 'Library', 'LaunchAgents', 'ai.jarvis.release-checker.plist');

// 기존 언로드
try {
  if (existsSync(plistPath)) {
    execSync(`launchctl unload "${plistPath}" 2>/dev/null || true`);
  }
} catch {}

writeFileSync(plistPath, plist);

// 로드
execSync(`launchctl load "${plistPath}"`);

// dry-run (즉시 1회 실행, 출력만 확인)
let dryRunResult = 'skipped';
try {
  dryRunResult = execSync(
    `${nodePath} "${checkerScript}" --dry-run 2>&1 | tail -5`,
    { env: { ...process.env, BOT_HOME: botHome, UPDATE_CHANNEL_ID: channelId, ENV_PATH: envPath } }
  ).toString().trim();
} catch (e) {
  dryRunResult = e.message;
}

console.log(JSON.stringify({
  status: 'ok',
  plistPath,
  schedule: '매일 03:00 (KST)',
  dryRun: dryRunResult,
}));
