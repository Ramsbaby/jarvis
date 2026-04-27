#!/usr/bin/env node
/**
 * weekly-surface-learning-gap.mjs — 표면별 학습 격차 모니터 (Harness P4)
 *
 * mistake-ledger.jsonl을 source별로 집계해 비대칭 학습 자동 감지.
 * 매주 월 09:00 KST cron 실행. 격차 임계 초과 시 Discord 알림.
 *
 * 격차 신호:
 * - discord-turn 비율 < 평균의 30% → "디스코드 학습 부족"
 * - stop-hook 비율 < 10% → "Claude Code CLI 활용 저조"
 * - batch-daily 0건 (지난 7일) → "03:15 KST cron 정지"
 *
 * 사용:
 *   node infra/scripts/weekly-surface-learning-gap.mjs           # 보고만
 *   node infra/scripts/weekly-surface-learning-gap.mjs --notify  # Discord 알림 동반
 */

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { spawnSync } from 'node:child_process';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const LEDGER = join(BOT_HOME, 'state', 'mistake-ledger.jsonl');
const NOTIFY = process.argv.includes('--notify');

const WINDOW_DAYS = 7;
const NOW = Date.now();
const SINCE = NOW - WINDOW_DAYS * 24 * 3600_000;

if (!existsSync(LEDGER)) {
  console.error(`❌ ledger 부재: ${LEDGER}`);
  process.exit(1);
}

const lines = readFileSync(LEDGER, 'utf-8').trim().split('\n').filter(Boolean);
const bySource = {};
const byDay = {};
let totalCount = 0;

for (const line of lines) {
  let o;
  try { o = JSON.parse(line); } catch { continue; }
  const ts = o.ts ? new Date(o.ts.replace('+09:00', 'Z')).getTime() - 9 * 3600_000 : 0;
  if (ts < SINCE) continue;
  const src = o.source || 'unknown';
  bySource[src] = (bySource[src] || 0) + (o.count || 0);
  const day = (o.ts || '').slice(0, 10);
  if (day) byDay[day] = (byDay[day] || 0) + (o.count || 0);
  totalCount += (o.count || 0);
}

const sources = Object.entries(bySource).sort((a, b) => b[1] - a[1]);
const daysActive = Object.keys(byDay).length;
const avgPerSource = sources.length > 0 ? totalCount / sources.length : 0;

// 격차 신호 분석
// P2 anger-detector는 direct-fact 모드로 발화하므로 'direct-fact'도 디스코드 표면 학습으로 합산
// (DISCORD_TURN_SOURCE=1 env 전달되지만 direct-fact 분기가 우선되어 source='direct-fact'로 기록됨)
const alerts = [];
const discordCount = (bySource['discord-turn'] || 0) + (bySource['direct-fact'] || 0);
const stopHookCount = bySource['stop-hook'] || 0;
const batchCount = bySource['batch-daily'] || 0;

if (discordCount === 0 && totalCount > 0) {
  alerts.push(`🔴 Discord 학습 0건 (discord-turn + direct-fact) — Harness P0/P2 trigger 미작동 가능. claude-runner.js triggerDiscordMistakeExtract / anger-detector 검증 필요.`);
} else if (totalCount > 10 && discordCount < totalCount * 0.1) {
  alerts.push(`🟡 Discord 비율 ${((discordCount / totalCount) * 100).toFixed(1)}% — 평균 대비 부족. 디스코드 turn 종료 hook 점검.`);
}

if (stopHookCount === 0 && totalCount > 0) {
  alerts.push(`🟡 Claude Code CLI 학습 0건 — Stop 훅 비활성 또는 CLI 미사용 주간.`);
}

if (batchCount === 0 && daysActive >= 5) {
  alerts.push(`🔴 batch-daily 0건 (${WINDOW_DAYS}일) — 03:15 KST mistake-extractor cron 정지 의심. ai.jarvis.mistake-extractor 점검.`);
}

if (totalCount === 0) {
  alerts.push(`🔴 학습 ledger 비어있음 (${WINDOW_DAYS}일) — 전체 파이프라인 중단 의심.`);
}

// 보고서
const report = `# 📊 표면별 학습 격차 모니터 (지난 ${WINDOW_DAYS}일)
집계 기간: ${new Date(SINCE).toISOString().slice(0, 10)} ~ ${new Date(NOW).toISOString().slice(0, 10)}
총 등재 건수: ${totalCount}
활성 일수: ${daysActive} / ${WINDOW_DAYS}

## 표면별 분포
${sources.map(([s, c]) => {
  const pct = totalCount > 0 ? ((c / totalCount) * 100).toFixed(1) : '0.0';
  const bar = '█'.repeat(Math.round(c / Math.max(1, sources[0][1]) * 20));
  return `  ${s.padEnd(15)} ${String(c).padStart(4)}건 (${pct.padStart(5)}%) ${bar}`;
}).join('\n')}

## 격차 신호
${alerts.length > 0 ? alerts.map(a => `- ${a}`).join('\n') : '- ✅ 격차 신호 없음'}

## 일별 추이
${Object.entries(byDay).sort().map(([d, c]) => `  ${d}: ${c}건`).join('\n')}
`;

console.log(report);

if (NOTIFY && alerts.length > 0) {
  // Discord 알림 (jarvis-system 채널)
  const notifyScript = join(homedir(), '.jarvis/scripts/discord-visual.mjs');
  if (existsSync(notifyScript)) {
    try {
      const data = JSON.stringify({
        title: '📊 표면 학습 격차 감지',
        data: Object.fromEntries([
          ['총 등재', `${totalCount}건 / ${WINDOW_DAYS}일`],
          ['Discord (turn+anger)', `${discordCount}건`],
          ['CLI Stop훅', `${stopHookCount}건`],
          ['Batch (03:15)', `${batchCount}건`],
          ['알림 수', `${alerts.length}건`],
        ]),
        timestamp: new Date().toISOString().slice(0, 16).replace('T', ' '),
      });
      spawnSync('node', [notifyScript, '--type', 'stats', '--data', data, '--channel', 'jarvis-system'], {
        timeout: 10_000,
        stdio: 'inherit',
      });
    } catch (e) {
      console.error(`알림 전송 실패: ${e.message}`);
    }
  }
}

process.exit(alerts.length > 0 ? 1 : 0);
