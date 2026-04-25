#!/usr/bin/env node
/**
 * interview-ledger-report.mjs
 * jarvis-interview 채널 ledger 자동 분석. 봇 재시작 후 자체 검증용.
 *
 * 사용:
 *   node ~/jarvis/infra/scripts/interview-ledger-report.mjs --since=last-restart
 *   node ~/jarvis/infra/scripts/interview-ledger-report.mjs --since=15m
 *   node ~/jarvis/infra/scripts/interview-ledger-report.mjs --since=2026-04-25T07:35:00Z
 */
import { readFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const LEDGER = join(homedir(), 'jarvis/runtime/state/openai-ledger.jsonl');
const BOT_LOG = join(homedir(), 'jarvis/runtime/logs/discord-bot.out.log');

const args = process.argv.slice(2);
const sinceArg = (args.find(a => a.startsWith('--since=')) || '--since=last-restart').split('=')[1];

function resolveSince(arg) {
  if (arg === 'last-restart') {
    if (!existsSync(BOT_LOG)) throw new Error(`bot log missing: ${BOT_LOG}`);
    const log = readFileSync(BOT_LOG, 'utf-8');
    const matches = [...log.matchAll(/\[([^\]]+)\]\s+info:\s+Bot restarted/g)];
    if (!matches.length) throw new Error('"Bot restarted" line not found in bot log');
    return matches[matches.length - 1][1];
  }
  const minMatch = /^(\d+)m$/.exec(arg);
  if (minMatch) {
    const minutes = parseInt(minMatch[1], 10);
    return new Date(Date.now() - minutes * 60_000).toISOString();
  }
  return arg;
}

const sinceTs = resolveSince(sinceArg);

if (!existsSync(LEDGER)) {
  console.error(`ledger missing: ${LEDGER}`);
  process.exit(1);
}
const entries = readFileSync(LEDGER, 'utf-8')
  .split('\n').filter(Boolean)
  .map(l => { try { return JSON.parse(l); } catch { return null; } })
  .filter(Boolean)
  .filter(e => e.channel === 'jarvis-interview' && e.ts >= sinceTs);

console.log(`📊 jarvis-interview ledger report — since ${sinceTs}`);
console.log(`Total entries: ${entries.length}`);
if (entries.length === 0) { console.log('(no entries)'); process.exit(0); }
console.log('');

// By phase
const byPhase = {};
for (const e of entries) {
  const p = e.phase || 'unknown';
  byPhase[p] ||= { count: 0, pass: 0, fail: 0, reject: 0, preFlight: 0, followUp: 0, totalChars: 0 };
  const s = byPhase[p];
  s.count++;
  if (e.verdict === 'PASS') s.pass++;
  if (e.verdict === 'FAIL') s.fail++;
  if (e.verdict === 'REJECT') s.reject++;
  if (e.preFlightRejected) s.preFlight++;
  if (e.isFollowUp) s.followUp++;
  s.totalChars += e.bodyChars || 0;
}
console.log('📌 By phase:');
for (const [phase, s] of Object.entries(byPhase)) {
  const avg = s.count ? Math.round(s.totalChars / s.count) : 0;
  console.log(`  ${phase.padEnd(10)} count=${s.count} | PASS=${s.pass} FAIL=${s.fail} REJECT=${s.reject} | avgChars=${avg} | followUp=${s.followUp} preFlight=${s.preFlight}`);
}

// SHORT length 회귀 의심
const shortLong = entries.filter(e => e.phase === 'short' && e.verdict === 'FAIL' && e.bodyChars > 200);
if (shortLong.length) {
  console.log('\n⚠️ SHORT FAIL with bodyChars > 200 (길이 회귀 의심):');
  for (const e of shortLong) console.log(`  ${e.ts} | ${e.bodyChars}자 sents=${e.sentences} | q="${(e.question || '').slice(0, 60)}"`);
}

// DETAIL 창작 의심
const detailCreative = entries.filter(e => e.phase === 'detail' && e.verdict === 'FAIL' && (e.frankenstein || (e.forbidden || []).length));
if (detailCreative.length) {
  console.log('\n⚠️ DETAIL FAIL with frankenstein/forbidden (창작 의심):');
  for (const e of detailCreative) {
    console.log(`  ${e.ts} | bodyChars=${e.bodyChars} | forbidden=[${(e.forbidden || []).join(',')}] | frankenstein=${e.frankenstein} | q="${(e.question || '').slice(0, 60)}"`);
  }
}

// pre-flight 거절
const preflights = entries.filter(e => e.preFlightRejected);
if (preflights.length) {
  console.log('\n🚫 Pre-flight REJECT (LLM 호출 차단됨):');
  for (const e of preflights) console.log(`  ${e.ts} | external=${e.externalHit} | q="${(e.question || '').slice(0, 60)}"`);
}

// Follow-up summary
const followUps = entries.filter(e => e.isFollowUp);
if (followUps.length) {
  console.log(`\n🔁 Follow-up entries: ${followUps.length}`);
  for (const e of followUps) console.log(`  ${e.ts} | phase=${e.phase} verdict=${e.verdict} | q="${(e.question || '').slice(0, 60)}"`);
}

// 토큰 사용
const totalIn = entries.reduce((a, e) => a + (e.inputTokens || 0), 0);
const totalOut = entries.reduce((a, e) => a + (e.outputTokens || 0), 0);
const totalCost = entries.reduce((a, e) => a + (e.costUsd || 0), 0);
console.log(`\n💰 Tokens: in=${totalIn.toLocaleString()} out=${totalOut.toLocaleString()} | cost=$${totalCost.toFixed(4)}`);
console.log('');
console.log('✅ Report done.');
