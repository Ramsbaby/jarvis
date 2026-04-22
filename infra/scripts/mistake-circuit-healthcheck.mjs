#!/usr/bin/env node
/**
 * mistake-circuit-healthcheck.mjs — 오답노트 추출기 회로 차단 감지 + Discord 알람
 *
 * 배경 (2026-04-22 오답노트 등재):
 *   mistake-extractor.mjs 의 circuit OPEN 상태가 24h 동안 무감지로 방치되어
 *   오답노트 자동 추출이 18시간 마비된 사고 → 동일 패턴 재발 방지용 헬스체크.
 *
 * 동작:
 *   1. ~/jarvis/runtime/state/mistake-extractor-circuit.json 읽기
 *   2. state="open" 이면 다음을 확인
 *      - 마지막 알람 송출 시각 (ledger ~/.jarvis/ # ALLOW-DOTJARVISstate/mistake-circuit-alerts.jsonl)
 *      - rate limit: 동일 OPEN 상태 동안 6시간에 1회만 알람
 *   3. 알람 대상이면 Discord jarvis-system 채널에 송출
 *   4. ledger 에 알람 기록 (append-only)
 *
 * 크론: 매시간 정각 (0 * * * *) — Nexus tasks.json 으로 등록 권장
 *
 * 실패는 exit 0 으로 흡수 — 헬스체크가 다른 파이프라인을 막지 않도록.
 *
 * CLI:
 *   node mistake-circuit-healthcheck.mjs           # 정상
 *   node mistake-circuit-healthcheck.mjs --force   # rate limit 무시 (수동 점검용)
 *   node mistake-circuit-healthcheck.mjs --dry     # 송출 없이 상태만 출력
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync, appendFileSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';

const HOME = homedir();
const CIRCUIT_FILE = join(HOME, 'jarvis/runtime/state/mistake-extractor-circuit.json');
const ALERT_LEDGER = join(HOME, '.jarvis/state/mistake-circuit-alerts.jsonl');
const VISUAL_BIN = join(HOME, '.jarvis/scripts/discord-visual.mjs');
const LOG_FILE = join(HOME, 'jarvis/runtime/logs/mistake-circuit-healthcheck.log');

const RATE_LIMIT_MS = 6 * 3600 * 1000; // 6시간
const FORCE = process.argv.includes('--force');
const DRY = process.argv.includes('--dry');

function kstNow() {
  return new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' });
}

function log(msg) {
  const line = `[${kstNow()}] healthcheck: ${msg}\n`;
  try {
    mkdirSync(dirname(LOG_FILE), { recursive: true });
    appendFileSync(LOG_FILE, line);
  } catch { /* best-effort */ }
  process.stderr.write(line);
}

function loadCircuit() {
  try {
    return JSON.parse(readFileSync(CIRCUIT_FILE, 'utf-8'));
  } catch (e) {
    log(`circuit-state 읽기 실패 (정상으로 간주): ${e.message}`);
    return null;
  }
}

function lastAlertTs() {
  if (!existsSync(ALERT_LEDGER)) return 0;
  try {
    const lines = readFileSync(ALERT_LEDGER, 'utf-8').trim().split('\n').filter(Boolean);
    if (lines.length === 0) return 0;
    const last = JSON.parse(lines[lines.length - 1]);
    return last.ts ? new Date(last.ts).getTime() : 0;
  } catch (e) {
    log(`ledger 읽기 실패 (0 으로 간주): ${e.message}`);
    return 0;
  }
}

function appendLedger(record) {
  try {
    mkdirSync(dirname(ALERT_LEDGER), { recursive: true });
    appendFileSync(ALERT_LEDGER, JSON.stringify(record) + '\n');
  } catch (e) {
    log(`ledger append 실패: ${e.message}`);
  }
}

function sendDiscord(circuit) {
  if (!existsSync(VISUAL_BIN)) {
    log(`SKIP Discord: visual 스크립트 없음 (${VISUAL_BIN})`);
    return false;
  }
  const remainMin = Math.max(0, Math.round((circuit.nextRetryTs - Date.now()) / 60000));
  const lastFailKst = circuit.lastFailTs
    ? new Date(circuit.lastFailTs).toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' })
    : '미상';

  const data = {
    title: '⚠️ 오답노트 추출기 회로 차단',
    data: {
      '상태': `OPEN (연속 실패 ${circuit.consecutiveFails}회)`,
      '재시도까지': `${remainMin}분`,
      '마지막 실패': lastFailKst + ' KST',
      '조치 필요': '~/.jarvis/ # ALLOW-DOTJARVISlogs/mistake-extractor.log 확인 → 원인 진단 후 circuit-state.json 수동 리셋 검토',
    },
    timestamp: kstNow() + ' KST',
  };

  if (DRY) {
    log(`DRY-RUN — Discord 송출 생략: ${JSON.stringify(data)}`);
    return true;
  }

  const result = spawnSync('node', [
    VISUAL_BIN,
    '--type', 'stats',
    '--data', JSON.stringify(data),
    '--channel', 'jarvis-system',
  ], { encoding: 'utf-8', timeout: 30_000 });

  if (result.status !== 0) {
    log(`Discord 송출 실패 (exit=${result.status}): ${result.stderr?.slice(0, 200)}`);
    return false;
  }
  return true;
}

function main() {
  log('=== healthcheck 시작 ===');

  const circuit = loadCircuit();
  if (!circuit) {
    log('circuit-state 없음 — 정상 종료');
    return 0;
  }

  if (circuit.state !== 'open') {
    log(`circuit closed (consecutiveFails=${circuit.consecutiveFails}) — 알람 불필요`);
    return 0;
  }

  // OPEN 상태 — rate limit 확인
  const lastAlert = lastAlertTs();
  const elapsedMs = Date.now() - lastAlert;
  if (!FORCE && elapsedMs < RATE_LIMIT_MS) {
    const remainMin = Math.round((RATE_LIMIT_MS - elapsedMs) / 60000);
    log(`circuit OPEN 이지만 rate limit (마지막 알람 후 ${Math.round(elapsedMs / 60000)}분 경과, ${remainMin}분 후 재알람)`);
    return 0;
  }

  // 알람 송출
  log(`circuit OPEN 감지 (consecutiveFails=${circuit.consecutiveFails}, nextRetryTs=${new Date(circuit.nextRetryTs).toISOString()}) — Discord 송출`);
  const sent = sendDiscord(circuit);

  // ledger 기록 (송출 성공 여부 모두 기록 — 분석용)
  appendLedger({
    ts: new Date().toISOString(),
    event: 'circuit_open_detected',
    consecutiveFails: circuit.consecutiveFails,
    nextRetryTs: new Date(circuit.nextRetryTs).toISOString(),
    lastFailTs: circuit.lastFailTs ? new Date(circuit.lastFailTs).toISOString() : null,
    discord_sent: sent,
    forced: FORCE,
    dry: DRY,
  });

  log(`완료: discord_sent=${sent}`);
  return 0;
}

process.exit(main());
