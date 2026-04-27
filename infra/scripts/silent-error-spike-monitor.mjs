#!/usr/bin/env node
/**
 * silent-error-spike-monitor.mjs — recordSilentError 누적 스파이크 감지 (Harness R3 가드)
 *
 * 사고 사례 (2026-04-27): claude-runner.js:1334 P1 hook의 'sessionKey is not defined'
 * ReferenceError가 try/catch에 silent 삼켜져 5회 누적되는 동안 미감지.
 * snapshot 파일 부재로 P1 실측 도구 미작동 → 수동 진단 후에야 발견.
 *
 * 본 모니터는 error-ledger.jsonl을 1시간 단위로 스캔, src별 누적 임계 초과 시 알림.
 * 같은 src에서 6시간 내 5회 이상 발생하면 silent 결함 가능성 → Discord 즉시 알림.
 *
 * 사용:
 *   node infra/scripts/silent-error-spike-monitor.mjs           # 보고만
 *   node infra/scripts/silent-error-spike-monitor.mjs --notify  # 임계 초과 시 Discord 알림
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const LEDGER = join(BOT_HOME, 'state', 'error-ledger.jsonl');
const COOLDOWN_FILE = join(BOT_HOME, 'state', 'silent-error-spike-cooldown.json');
const COOLDOWN_HOURS = 6; // 같은 src는 6h 내 재알림 차단 (alert spam 방지)
const NOTIFY = process.argv.includes('--notify');

const WINDOW_HOURS = 6;
const SPIKE_THRESHOLD = 5; // 같은 src 6시간 내 5회 이상 = 스파이크
const NOW = Date.now();
const SINCE = NOW - WINDOW_HOURS * 3600_000;

if (!existsSync(LEDGER)) {
  console.log(`(error-ledger 부재 — 정상 또는 신규 시스템)`);
  process.exit(0);
}

const lines = readFileSync(LEDGER, 'utf-8').trim().split('\n').filter(Boolean);
const bySrc = {};
let totalInWindow = 0;

for (const line of lines) {
  let o;
  try { o = JSON.parse(line); } catch { continue; }
  const ts = o.ts ? new Date(o.ts).getTime() : 0;
  if (ts < SINCE) continue;
  const src = o.src || 'unknown';
  if (!bySrc[src]) bySrc[src] = { count: 0, msgs: new Set(), lastTs: o.ts };
  bySrc[src].count += 1;
  bySrc[src].msgs.add(String(o.msg || '').slice(0, 80));
  bySrc[src].lastTs = o.ts;
  totalInWindow += 1;
}

const spikes = Object.entries(bySrc)
  .filter(([, v]) => v.count >= SPIKE_THRESHOLD)
  .sort((a, b) => b[1].count - a[1].count);

console.log(`# 🔍 Silent Error Spike Monitor (지난 ${WINDOW_HOURS}시간)
총 silent error: ${totalInWindow}건 / src ${Object.keys(bySrc).length}개
임계: ${SPIKE_THRESHOLD}회/${WINDOW_HOURS}h (Spike 판정)
`);

if (spikes.length === 0) {
  console.log('✅ 스파이크 없음.');
  process.exit(0);
}

console.log(`🚨 스파이크 감지 ${spikes.length}건:\n`);
for (const [src, v] of spikes) {
  console.log(`  ${src}: ${v.count}회`);
  console.log(`    last_ts: ${v.lastTs}`);
  for (const msg of [...v.msgs].slice(0, 3)) {
    console.log(`    msg: ${msg}`);
  }
}

if (NOTIFY) {
  // P0-1: cooldown — 같은 src는 6h 내 재알림 차단 (alert spam 방지)
  let cooldown = {};
  try { if (existsSync(COOLDOWN_FILE)) cooldown = JSON.parse(readFileSync(COOLDOWN_FILE, 'utf-8')); } catch {}

  const now = Date.now();
  const COOLDOWN_MS = COOLDOWN_HOURS * 3600_000;
  const toAlert = spikes.filter(([src]) => {
    const last = cooldown[src] || 0;
    return now - last >= COOLDOWN_MS;
  });

  if (toAlert.length === 0) {
    console.log(`\n(쿨다운 중 — 알림 ${spikes.length}건 모두 ${COOLDOWN_HOURS}h 내 발송됨, skip)`);
  } else {
    const notifyScript = join(homedir(), '.jarvis/scripts/discord-visual.mjs');
    if (existsSync(notifyScript)) {
      const data = JSON.stringify({
        title: '🚨 Silent Error 스파이크',
        data: Object.fromEntries(toAlert.slice(0, 5).map(([src, v]) => [src.slice(0, 30), `${v.count}회 / ${WINDOW_HOURS}h`])),
        timestamp: new Date().toISOString().slice(0, 16).replace('T', ' '),
      });
      const r = spawnSync('node', [notifyScript, '--type', 'stats', '--data', data, '--channel', 'jarvis-system'], {
        timeout: 10_000, stdio: 'pipe', encoding: 'utf-8',
      });
      if (r.status === 0) {
        for (const [src] of toAlert) cooldown[src] = now;
        try {
          mkdirSync(dirname(COOLDOWN_FILE), { recursive: true });
          writeFileSync(COOLDOWN_FILE, JSON.stringify(cooldown, null, 2));
        } catch (e) {
          console.error(`cooldown 저장 실패: ${e.message}`);
        }
      } else {
        console.error(`알림 송출 실패 (status=${r.status}): ${(r.stderr || '').slice(0, 200)}`);
      }
    }
  }
}

process.exit(1);
