#!/usr/bin/env node
/**
 * memorybench.mjs — RAG 검색 품질 벤치마크
 *
 * 두 가지 모드:
 *   1. QA 모드 (기본): 명시적 Q&A 테스트케이스 → 정확한 소스 매칭
 *   2. Self-retrieval 모드 (BENCH_MODE=self): 기존 청크 텍스트로 자가검증
 *
 * 지표:
 *   Recall@1  : 1위 결과가 기대 소스 포함
 *   Recall@5  : top-5 중 기대 소스 포함
 *   MRR       : Mean Reciprocal Rank
 *   Latency   : 평균 검색 시간(ms)
 *
 * 환경변수:
 *   BENCH_MODE=qa|self     모드 선택 (기본: qa)
 *   BENCH_SAMPLE=50        self 모드 샘플 수
 *   BENCH_TOPK=5           top-k
 *   BENCH_VERBOSE=1        각 쿼리 결과 상세 출력
 */
import { RAGEngine } from '../lib/rag-engine.mjs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const BOT_HOME  = process.env.BOT_HOME  || join(homedir(), 'jarvis/runtime');
const MODE      = process.env.BENCH_MODE   || 'qa';
const SAVE      = process.env.BENCH_SAVE === '1';
const SAMPLE    = parseInt(process.env.BENCH_SAMPLE  || '30', 10);
const TOP_K     = parseInt(process.env.BENCH_TOPK    || '5',  10);
const VERBOSE   = process.env.BENCH_VERBOSE === '1';

// ── QA 테스트케이스 ──
// query: 검색할 질문
// expectedSrc: source 경로에 이 문자열이 포함되면 hit (부분 매칭)
// 파일 선정 기준: RAG에 실제 인덱스된 다중 청크 파일만 포함
const QA_CASES = [
  // _capabilities.md — 시스템 운영 규칙
  { query: '소통 원칙 설명 난이도 결론 먼저',                  expectedSrc: '_capabilities' },
  { query: 'LanceDB single writer pattern mergeInsert upsert',  expectedSrc: '_capabilities' },
  { query: 'RAG 데이터베이스 보호 규칙 indexFile 금지',         expectedSrc: '_capabilities' },
  { query: '봇 재시작 bot-self-restart.sh setsid',             expectedSrc: '_capabilities' },
  { query: 'crontab hang launchd plist LaunchAgents 스케줄',    expectedSrc: '_capabilities' },

  // career-weekly.md — 이직/커리어 정보
  { query: '이직 백엔드 채용 포지션 대기업',                   expectedSrc: 'career-weekly' },
  { query: 'Java Spring Boot 백엔드 개발자 채용 기술 스택',     expectedSrc: 'career-weekly' },

  // infra-daily.md — 인프라 현황
  { query: '인프라 시스템 헬스 체크 CPU 메모리 디스크',        expectedSrc: 'infra-daily' },
  { query: 'LaunchAgent 서비스 상태 Discord 봇 실행',          expectedSrc: 'infra-daily' },

  // cron-auditor.md — 크론 감사
  { query: '크론 실행 성공률 실패 작업 KPI 감사',              expectedSrc: 'cron-auditor' },
  { query: '감사팀 크론 태스크 실행 결과 리포트',              expectedSrc: 'cron-auditor' },
];

async function main() {
  const dbPath = join(BOT_HOME, 'rag', 'lancedb');
  const engine = new RAGEngine(dbPath);
  await engine.init();

  if (MODE === 'self') {
    await runSelfRetrieval(engine);
  } else {
    await runQA(engine);
  }

  await engine.close();
}

// ── QA 모드 ──
async function runQA(engine) {
  console.log(`\n[memorybench] QA 모드 — ${QA_CASES.length}개 테스트케이스, top-${TOP_K}\n`);

  let hit1 = 0, hit5 = 0;
  const recipRanks = [];
  const latencies  = [];
  const details    = [];

  for (const tc of QA_CASES) {
    const t0      = Date.now();
    const results = await engine.search(tc.query, TOP_K).catch(() => []);
    latencies.push(Date.now() - t0);

    const rank = results.findIndex(r =>
      (r.source || '').toLowerCase().includes(tc.expectedSrc.toLowerCase())
    );

    if (rank === 0) hit1++;
    if (rank >= 0)  hit5++;
    recipRanks.push(rank >= 0 ? 1 / (rank + 1) : 0);

    details.push({ query: tc.query.slice(0, 50), expectedSrc: tc.expectedSrc, rank, results });

    if (VERBOSE) {
      const status = rank < 0 ? '✗ MISS' : `✓ rank ${rank + 1}`;
      console.log(`  [${status}] "${tc.query.slice(0, 55)}"`);
      if (rank < 0) {
        console.log(`         expected: ${tc.expectedSrc}`);
        console.log(`         got:      ${results.slice(0, 3).map(r => r.source?.split('/').pop()).join(', ')}`);
      }
    }
  }

  printSummary(QA_CASES.length, hit1, hit5, recipRanks, latencies);

  if (!VERBOSE) {
    const missed = details.filter(d => d.rank < 0);
    if (missed.length > 0) {
      console.log(`\n  MISS (${missed.length}개):`);
      for (const m of missed) {
        const top3 = m.results.slice(0, 3).map(r => r.source?.split('/').pop()).join(', ');
        console.log(`    "${m.query}"  → got: ${top3 || '없음'}`);
      }
    }
  }
  console.log('');
}

// ── Self-retrieval 모드 ──
async function runSelfRetrieval(engine) {
  console.log(`\n[memorybench] Self-retrieval 모드 — 샘플 ${SAMPLE}개, top-${TOP_K}\n`);

  // chunk_index >= 2 인 다중 청크 소스에서 샘플 (단일 청크 파일 제외)
  const ts = Date.now();
  let rows = [];
  try {
    rows = await engine.table.query()
      .where(`chunk_index >= 2 AND (deleted IS NULL OR deleted = false) AND (is_latest IS NULL OR is_latest = true)`)
      .limit(SAMPLE * 10)
      .toArray();
  } catch (e) {
    rows = await engine.table.query()
      .where('chunk_index >= 1 AND (deleted IS NULL OR deleted = false)')
      .limit(SAMPLE * 10)
      .toArray().catch(() => []);
  }

  if (rows.length < 5) {
    console.error(`[bench] 유효 행 ${rows.length}개 부족`);
    return;
  }

  // 소스당 최대 1개
  const seen = new Set();
  const sample = rows
    .filter(r => (r.text || '').length >= 100 && !seen.has(r.source) && seen.add(r.source))
    .sort(() => Math.random() - 0.5)
    .slice(0, SAMPLE);

  let hit1 = 0, hit5 = 0;
  const recipRanks = [];
  const latencies  = [];

  for (const row of sample) {
    const query = (row.text || '').slice(0, 400).trim();
    if (query.length < 40) { recipRanks.push(0); continue; }

    const t0      = Date.now();
    const results = await engine.search(query, TOP_K).catch(() => []);
    latencies.push(Date.now() - t0);

    const rank = results.findIndex(r => r.source === row.source);
    if (rank === 0) hit1++;
    if (rank >= 0)  hit5++;
    recipRanks.push(rank >= 0 ? 1 / (rank + 1) : 0);

    if (VERBOSE) {
      const status = rank < 0 ? '✗ MISS' : `✓ rank ${rank + 1}`;
      console.log(`  [${status}] ${row.source?.split('/').pop()} — "${query.slice(0, 50)}..."`);
    }
  }

  printSummary(sample.length, hit1, hit5, recipRanks, latencies);
  console.log('');
}

function printSummary(n, hit1, hit5, recipRanks, latencies) {
  const mrr        = recipRanks.reduce((a, b) => a + b, 0) / Math.max(n, 1);
  const avgLatency = latencies.length > 0
    ? Math.round(latencies.reduce((a, b) => a + b, 0) / latencies.length)
    : 0;

  const line = '─'.repeat(40);
  console.log(line);
  console.log('  RAG 벤치마크 결과');
  console.log(line);
  console.log(`  샘플 수       ${n.toString().padStart(6)}`);
  console.log(`  Recall@1      ${pct(hit1, n).padStart(6)}  (${hit1}/${n})`);
  console.log(`  Recall@5      ${pct(hit5, n).padStart(6)}  (${hit5}/${n})`);
  console.log(`  MRR           ${mrr.toFixed(3).padStart(6)}`);
  console.log(`  Avg Latency   ${(avgLatency + 'ms').padStart(6)}`);
  console.log(line);

  if (SAVE) {
    saveBenchResult({ n, hit1, hit5, mrr, avgLatency, mode: MODE });
  }
}

function saveBenchResult(result) {
  const histPath = join(BOT_HOME, 'state', 'bench-history.json');
  let history = [];
  if (existsSync(histPath)) {
    try { history = JSON.parse(readFileSync(histPath, 'utf8')); } catch {}
  }
  history.push({
    ts: new Date().toISOString(),
    mode: result.mode,
    n: result.n,
    recall1: parseFloat((result.hit1 / Math.max(result.n, 1) * 100).toFixed(1)),
    recall5: parseFloat((result.hit5 / Math.max(result.n, 1) * 100).toFixed(1)),
    mrr: parseFloat(result.mrr.toFixed(3)),
    avgLatencyMs: result.avgLatency,
  });
  // 최근 30회만 보존
  if (history.length > 30) history = history.slice(-30);
  writeFileSync(histPath, JSON.stringify(history, null, 2));
  console.log(`  [saved] → state/bench-history.json (${history.length}회 누적)`);
}

function pct(n, total) {
  return (n / Math.max(total, 1) * 100).toFixed(1) + '%';
}

main().catch(e => { console.error('[bench] 오류:', e); process.exit(1); });