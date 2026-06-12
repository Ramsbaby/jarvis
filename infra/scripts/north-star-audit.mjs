#!/usr/bin/env node
// north-star-audit.mjs — 자비스 최종 목표(시간 해방·복리 학습·신뢰 자율) 정렬도 주간 채점기
//
// Why 1줄: 자비스가 최종 목표에서 이탈해도 아무도 모르는 사고를 막는다 (2026-06-12 주인님 승인).
// 원천 데이터는 전부 기존 원장 — LLM 호출 0회, 토큰 비용 0.
// DRYRUN 가드: 자기 원장(north-star-audit.jsonl)의 첫 기록이 7일 미만이면 Discord 미전송(로그만).
//
// 채점 공식 (전부 이 파일이 SSoT — 바꾸면 여기만 수정):
//   신뢰 자율  = 100 × (1 − min(1, 위반율×10))           위반율 = §0 위반건 / 검사건 (7일)
//   복리 학습  = 100 × min(1, (applied+dev_queue)/candidates) − 15×재발건  (promoter 7일 합산)
//   시간 해방  = 100 − 15×좀비크론수 − 20×수동개입수      (바닥 0)
//   종합       = 3축 평균

import { readFileSync, existsSync, appendFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';

const HOME = homedir();
const LEDGER = join(HOME, 'jarvis/runtime/ledger');
const SELF_LEDGER = join(LEDGER, 'north-star-audit.jsonl');
const WINDOW_MS = 7 * 24 * 3600 * 1000;
const now = Date.now();
const since = now - WINDOW_MS;

const inWindow = (ts) => { const t = Date.parse(ts); return !isNaN(t) && t >= since; };
const readJsonl = (p) => existsSync(p)
  ? readFileSync(p, 'utf8').split('\n').filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean)
  : [];

// ── 축 1: 신뢰 자율 (§0 위반율) ──────────────────────────────
const s0 = readJsonl(join(LEDGER, 'section0-violation.jsonl')).filter(e => inWindow(e.ts));
const checks = s0.length;
const violations = s0.reduce((a, e) => a + (e.violations || 0), 0);
const vioRate = checks ? violations / checks : 0;
const trustScore = Math.round(100 * (1 - Math.min(1, vioRate * 10)));

// ── 축 2: 복리 학습 (promoter 구현율 − 재발 페널티) ──────────
const pm = readJsonl(join(LEDGER, 'promoter-ledger.jsonl')).filter(e => e.type === 'run_metrics' && inWindow(e.ts));
const cand = pm.reduce((a, e) => a + (e.candidates || 0), 0);
const acted = pm.reduce((a, e) => a + (e.applied || 0) + (e.dev_queue || 0), 0);
let recurrences = 0;
const lmPath = join(HOME, 'jarvis/runtime/wiki/meta/learned-mistakes.md');
if (existsSync(lmPath)) {
  const cutoff = new Date(since).toISOString().slice(0, 10);
  for (const line of readFileSync(lmPath, 'utf8').split('\n')) {
    const m = line.match(/^## (\d{4}-\d{2}-\d{2}) — (.*)/);
    if (m && m[1] >= cutoff && m[2].includes('재발')) recurrences++;
  }
}
const learnScore = Math.max(0, Math.round(100 * (cand ? Math.min(1, acted / cand) : 0)) - 15 * recurrences);

// ── 축 3: 시간 해방 (좀비 크론 + 수동 개입) ──────────────────
let zombies = 0;
const cronLog = join(HOME, 'jarvis/runtime/logs/cron.log');
if (existsSync(cronLog)) {
  const cutoff = new Date(since).toISOString().slice(0, 10);
  const failCounts = {};
  for (const line of readFileSync(cronLog, 'utf8').split('\n')) {
    const m = line.match(/^\[(\d{4}-\d{2}-\d{2}) [\d:]+\] \[([^\]]+)\] \[FAILED/);
    if (m && m[1] >= cutoff) failCounts[m[2]] = (failCounts[m[2]] || 0) + 1;
  }
  zombies = Object.values(failCounts).filter(c => c >= 3).length;
}
const interventions = readJsonl(join(HOME, 'jarvis/runtime/logs/oauth-incident-ledger.jsonl')).filter(e => inWindow(e.ts)).length;
const timeScore = Math.max(0, 100 - 15 * zombies - 20 * interventions);

// ── 종합 + 추세 ──────────────────────────────────────────────
const overall = Math.round((trustScore + learnScore + timeScore) / 3);
const prev = readJsonl(SELF_LEDGER).at(-1);
const delta = prev ? overall - prev.overall : null;
const trend = delta === null ? '첫 측정' : delta >= 0 ? `▲ +${delta}` : `▼ ${delta}`;

const entry = {
  ts: new Date(now).toISOString(),
  overall, trustScore, learnScore, timeScore,
  raw: { checks, violations, candidates: cand, acted, recurrences, zombies, interventions },
};
appendFileSync(SELF_LEDGER, JSON.stringify(entry) + '\n');

// ── DRYRUN 판정: 첫 기록 후 7일 경과 + env 미강제 시에만 Discord ──
const all = readJsonl(SELF_LEDGER);
const firstTs = Date.parse(all[0]?.ts || new Date(now).toISOString());
const dryrun = process.env.NORTH_STAR_DRYRUN === '1' || (now - firstTs) < WINDOW_MS;

console.log(`🎯 북극성 정렬 감사 (최근 7일, KST ${new Date(now).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })})`);
console.log(`   ⏱️  시간 해방  ${timeScore}점 (좀비 ${zombies}건 · 수동 개입 ${interventions}건)`);
console.log(`   📚 복리 학습  ${learnScore}점 (구현행동 ${acted}/${cand} · 재발 ${recurrences}건)`);
console.log(`   🤝 신뢰 자율  ${trustScore}점 (§0 위반 ${violations}/${checks})`);
console.log(`   🧭 종합 ${overall}점 ${trend}${dryrun ? ' [DRYRUN — Discord 미전송]' : ''}`);

if (!dryrun) {
  try {
    execFileSync('node', [join(HOME, '.jarvis/scripts/discord-visual.mjs'),
      '--type', 'stats',
      '--data', JSON.stringify({
        title: `🧭 북극성 정렬 ${overall}점 (${trend})`,
        data: {
          '시간 해방': `${timeScore}점 (좀비 ${zombies} · 개입 ${interventions})`,
          '복리 학습': `${learnScore}점 (구현 ${acted}/${cand} · 재발 ${recurrences})`,
          '신뢰 자율': `${trustScore}점 (§0 ${violations}/${checks})`,
        },
        timestamp: new Date(now).toISOString().slice(0, 10),
      }),
      '--channel', 'jarvis-system',
    ], { stdio: 'inherit', timeout: 30000 });
  } catch { console.error('⚠️ Discord 전송 실패 — 채점은 원장에 기록됨 (exit 0 유지)'); }
}
