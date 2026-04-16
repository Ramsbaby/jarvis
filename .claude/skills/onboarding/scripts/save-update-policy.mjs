#!/usr/bin/env node
/**
 * save-update-policy.mjs — 업데이트 정책 저장
 *
 * Usage:
 *   node save-update-policy.mjs --mode <auto|manual>
 *
 * Output:
 *   신규: { "status": "ok",      "mode": "auto",   "path": "..." }
 *   기존: { "status": "exists",  "mode": "manual", "path": "...", "updatedAt": "..." }
 *
 * 이미 설정된 경우 덮어쓰지 않고 현재 값을 반환.
 * 강제 업데이트가 필요하면 --force 플래그 사용.
 */
import { mkdirSync, writeFileSync, existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const args = process.argv.slice(2);
const force = args.includes('--force');

const modeIdx = args.indexOf('--mode');
const raw = modeIdx !== -1 ? args[modeIdx + 1]?.toLowerCase() : null;

const mode = raw === 'a' || raw === 'auto'   ? 'auto'
           : raw === 'm' || raw === 'manual' ? 'manual'
           : null;

if (!mode) {
  console.error(JSON.stringify({ error: 'Usage: --mode <auto|manual> [--force]' }));
  process.exit(1);
}

const configDir  = join(HOME, '.jarvis', 'config');
const policyPath = join(configDir, 'update-policy.json');

try {
  mkdirSync(configDir, { recursive: true });
} catch (e) {
  console.error(JSON.stringify({ error: 'Failed to create config directory: ' + e.message, path: configDir }));
  process.exit(1);
}

// 이미 존재하고 --force 없으면 현재 값 반환 (덮어쓰지 않음)
if (existsSync(policyPath) && !force) {
  try {
    const current = JSON.parse(readFileSync(policyPath, 'utf-8'));
    console.log(JSON.stringify({ status: 'exists', mode: current.mode, path: policyPath, updatedAt: current.updatedAt }));
    process.exit(0);
  } catch {
    // 파싱 실패 시 덮어씀
  }
}

const policy = {
  mode,
  updatedAt: new Date().toISOString(),
  description: mode === 'auto'
    ? '새 릴리즈 발견 시 새벽 3시에 자동 설치 & 봇 재시작'
    : '새 릴리즈 발견 시 #🚀jarvis-update 채널에 알림만 발송',
};

writeFileSync(policyPath, JSON.stringify(policy, null, 2), { mode: 0o600 });
console.log(JSON.stringify({ status: 'ok', mode, path: policyPath }));
