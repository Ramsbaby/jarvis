#!/usr/bin/env node
/**
 * wiki-reference-report.mjs
 *
 * 목적
 *   Wiki/오답노트가 "실제로 주입되고 있는가?"를 주간 리포트로 검증한다.
 *   `wiki-inject.log`를 집계해 도메인별 주입 빈도, 오답노트 주입율,
 *   최근 7일 대비 이전 7일 증감을 계산해 Discord로 리포트한다.
 *
 * 호출
 *   매주 일요일 20:00 KST 크론 (compound-review 전 30분)
 *   수동: node wiki-reference-report.mjs [--dry-run]
 *
 * 입력
 *   - ~/jarvis/runtime/logs/wiki-inject.log
 *     각 줄: {"ts","domain","chars","parts","mistakes"(2026-04-20 이후)}
 *
 * 출력
 *   - stdout: Discord 포맷 메시지 (bot-cron.sh → route-result.sh)
 *   - ~/jarvis/runtime/wiki/meta/metrics.jsonl append
 *     {"ts","type":"reference_report","week","wikiRefs","mistakeNoteRefs","domains":{...}}
 */

import { readFileSync, appendFileSync, existsSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis', 'runtime');
const LOG_PATH = join(BOT_HOME, 'logs', 'wiki-inject.log');
const METRICS_PATH = join(BOT_HOME, 'wiki', 'meta', 'metrics.jsonl');
const DRY_RUN = process.argv.includes('--dry-run');

const NOW = new Date();
const NOW_MS = NOW.getTime();
const DAY_MS = 24 * 60 * 60 * 1000;
const WINDOW_MS = 7 * DAY_MS;

function parseLog() {
  if (!existsSync(LOG_PATH)) {
    return { entries: [], error: `로그 파일 없음: ${LOG_PATH}` };
  }
  const raw = readFileSync(LOG_PATH, 'utf-8');
  const lines = raw.split('\n').filter(Boolean);
  const entries = [];
  let parseErrors = 0;
  for (const line of lines) {
    try {
      const obj = JSON.parse(line);
      if (obj.ts && obj.domain) {
        entries.push({
          ...obj,
          tsMs: new Date(obj.ts).getTime(),
        });
      }
    } catch {
      parseErrors++;
    }
  }
  return { entries, parseErrors };
}

function aggregate(entries, startMs, endMs) {
  const window = entries.filter(e => e.tsMs >= startMs && e.tsMs < endMs);
  const domains = {};
  let mistakeRefs = 0;
  let totalChars = 0;
  let totalParts = 0;
  for (const e of window) {
    const d = e.domain || 'none';
    domains[d] = (domains[d] || 0) + 1;
    if (e.mistakes === true) mistakeRefs++;
    totalChars += Number(e.chars || 0);
    totalParts += Number(e.parts || 0);
  }
  return {
    total: window.length,
    domains,
    mistakeRefs,
    avgChars: window.length ? Math.round(totalChars / window.length) : 0,
    avgParts: window.length ? Number((totalParts / window.length).toFixed(2)) : 0,
  };
}

function diff(curr, prev) {
  if (prev === 0) return curr === 0 ? '±0' : `+${curr}`;
  const pct = Math.round(((curr - prev) / prev) * 100);
  const sign = pct >= 0 ? '+' : '';
  return `${sign}${pct}%`;
}

function formatKST(date) {
  const kst = new Date(date.getTime() + 9 * 60 * 60 * 1000);
  return kst.toISOString().slice(0, 10);
}

function formatReport({ recent, previous, allTime, parseErrors }) {
  const weekEnd = formatKST(NOW);
  const weekStart = formatKST(new Date(NOW_MS - WINDOW_MS));

  // 도메인별 최근 주 카운트 (상위 5개)
  const domainList = Object.entries(recent.domains)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5);

  const lines = [];
  lines.push(`📊 **Wiki/오답노트 참조 리포트** — ${weekStart} ~ ${weekEnd}`);
  lines.push('');
  lines.push('### 🧠 최근 7일');
  lines.push(`- **총 주입 횟수** · ${recent.total}회 (이전 대비 ${diff(recent.total, previous.total)})`);
  lines.push(`- **오답노트 주입** · ${recent.mistakeRefs}회 (${recent.total ? Math.round((recent.mistakeRefs / recent.total) * 100) : 0}%)`);
  lines.push(`- **평균 컨텍스트** · ${recent.avgChars}자 / ${recent.avgParts} 섹션`);
  lines.push('');

  if (domainList.length > 0) {
    lines.push('### 🗂️ 도메인별 주입 (상위 5)');
    for (const [d, c] of domainList) {
      const prevCount = previous.domains[d] || 0;
      lines.push(`- **${d}** · ${c}회 (이전 ${prevCount}회, ${diff(c, prevCount)})`);
    }
    lines.push('');
  }

  lines.push('### 📈 누적 통계 (전체 기간)');
  lines.push(`- **총 주입** · ${allTime.total}회`);
  lines.push(`- **오답노트 주입** · ${allTime.mistakeRefs}회`);
  lines.push(`- **활성 도메인** · ${Object.keys(allTime.domains).length}개`);

  // 경보 조건
  const warnings = [];
  if (recent.total === 0) {
    warnings.push('⚠️ 최근 7일 주입 0건 — wiki 주입 파이프라인 점검 필요');
  }
  if (recent.mistakeRefs === 0 && recent.total > 10) {
    warnings.push('⚠️ 오답노트가 주입되지 않음 — prompt-sections.js meta 로직 확인');
  }
  if (recent.total > 0 && recent.total < previous.total * 0.5) {
    warnings.push(`⚠️ 주입 횟수 급감 (${previous.total} → ${recent.total}, -${Math.round((1 - recent.total / previous.total) * 100)}%)`);
  }
  if (parseErrors > 10) {
    warnings.push(`⚠️ 로그 파싱 실패 ${parseErrors}건 — 포맷 오염 가능성`);
  }

  if (warnings.length > 0) {
    lines.push('');
    lines.push('### 🚨 경보');
    for (const w of warnings) lines.push(`- ${w}`);
  }

  return lines.join('\n');
}

function main() {
  const { entries, parseErrors = 0, error } = parseLog();
  if (error) {
    console.log(`❌ **Wiki 리포트 실패**\n${error}`);
    process.exit(0);
  }

  if (entries.length === 0) {
    console.log('⚠️ **Wiki 리포트** — 수집된 로그 없음. wiki-inject.log 비어있음.');
    process.exit(0);
  }

  const recentStart = NOW_MS - WINDOW_MS;
  const prevStart = NOW_MS - 2 * WINDOW_MS;

  const recent = aggregate(entries, recentStart, NOW_MS);
  const previous = aggregate(entries, prevStart, recentStart);
  const allTime = aggregate(entries, 0, NOW_MS);

  const report = formatReport({ recent, previous, allTime, parseErrors });

  // metrics.jsonl append
  const metric = {
    ts: NOW.toISOString(),
    type: 'reference_report',
    weekStart: formatKST(new Date(recentStart)),
    weekEnd: formatKST(NOW),
    wikiRefs: recent.total,
    mistakeNoteRefs: recent.mistakeRefs,
    avgChars: recent.avgChars,
    avgParts: recent.avgParts,
    domains: recent.domains,
    trend: {
      totalDelta: recent.total - previous.total,
      mistakeDelta: recent.mistakeRefs - previous.mistakeRefs,
    },
  };

  if (DRY_RUN) {
    console.log('=== DRY RUN — metrics.jsonl 미기록 ===');
    console.log(JSON.stringify(metric, null, 2));
    console.log('=== 리포트 미리보기 ===');
    console.log(report);
    return;
  }

  try {
    appendFileSync(METRICS_PATH, JSON.stringify(metric) + '\n');
  } catch (e) {
    console.error(`metrics.jsonl 기록 실패: ${e.message}`);
  }

  // stdout → bot-cron.sh가 route-result.sh로 전달 → Discord
  console.log(report);
}

main();
