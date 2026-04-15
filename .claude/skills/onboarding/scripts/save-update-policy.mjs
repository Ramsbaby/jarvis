#!/usr/bin/env node
/**
 * save-update-policy.mjs — 업데이트 정책 저장
 *
 * Usage:
 *   node save-update-policy.mjs --mode <auto|manual>
 *
 * Output:
 *   { "status": "ok", "mode": "auto", "path": "~/.jarvis/config/update-policy.json" }
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const args = process.argv.slice(2);
const modeIdx = args.indexOf('--mode');
const raw = modeIdx !== -1 ? args[modeIdx + 1]?.toLowerCase() : null;

const mode = raw === 'a' || raw === 'auto' ? 'auto'
           : raw === 'm' || raw === 'manual' ? 'manual'
           : null;

if (!mode) {
  console.error(JSON.stringify({ error: 'Usage: --mode <auto|manual>' }));
  process.exit(1);
}

const configDir = join(HOME, '.jarvis', 'config');

try {
  mkdirSync(configDir, { recursive: true });
} catch (e) {
  console.error(JSON.stringify({ error: 'Failed to create config directory: ' + e.message, path: configDir }));
  process.exit(1);
}

const policyPath = join(configDir, 'update-policy.json');
const policy = {
  mode,
  updatedAt: new Date().toISOString(),
  description: mode === 'auto'
    ? '새 릴리즈 발견 시 새벽 3시에 자동 설치 & 봇 재시작'
    : '새 릴리즈 발견 시 #🚀jarvis-update 채널에 알림만 발송',
};

// 파일 모드 0o600 설정 (write-env.mjs와 일관성)
writeFileSync(policyPath, JSON.stringify(policy, null, 2), { mode: 0o600 });
console.log(JSON.stringify({ status: 'ok', mode, path: policyPath }));
