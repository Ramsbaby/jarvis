#!/usr/bin/env node
/**
 * eval-keyword-search.mjs — RAG 검색 적중률·지연 측정 (읽기 전용)
 *
 * 왜 있나 (2026-10-03):
 *   키워드 쪽이 공백으로만 낱말을 잘라 "서버에서"·"로그인을" 같은 조사 붙은 꼴이 줄기와 안 맞았다.
 *   고친 뒤 정말 나아졌는지 숫자로 보려고, 실제 색인을 읽기 전용으로 열어 질의 묶음을 돌린다.
 *
 * 사용:
 *   node rag/test/eval-keyword-search.mjs [평가셋.json] [--json out.json] [--gate base.json]
 *   평가셋 기본값: $RAG_EVAL_SET 또는 <저장소>/private/rag-eval/korean-keyword-eval.json (gitignored — 주인 데이터)
 *   RAG_KO_KEYWORDS=0|1 로 한국어 키워드 보강을 끄고 켠다(엔진 기본값은 켜짐).
 *   --gate base.json: 기준 결과보다 한국어 hit@5 가 낮거나, 영어/코드 질의가 하나라도 새로 빠지면 exit 1.
 *   평가셋 파일이 없으면 건너뛰고 exit 0 (공개 저장소 사용자는 평가셋이 없다).
 *
 * 평가셋 형식: { items: [{ id, lang: 'ko'|'en', q, expected: [소스 경로(~ 축약)...] }] }
 *   적중 = 상위 k 결과의 소스 중 하나라도 expected 에 있음.
 */

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HOME = homedir();
const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..');

// rag-corpus-query.mjs 와 같은 이유로 RAG 홈을 못박는다(빈 잔재 DB 를 조용히 검색하지 않게).
process.env.BOT_HOME ||= join(HOME, '.openclaw-data/runtime');
process.env.JARVIS_RAG_HOME ||= join(process.env.BOT_HOME, 'rag');

const args = process.argv.slice(2);
const flag = (name) => {
  const i = args.indexOf(name);
  if (i < 0) return null;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
};
const jsonOut = flag('--json');
const gateFile = flag('--gate');
const setPath = args[0]
  || process.env.RAG_EVAL_SET
  || join(repoRoot, 'private', 'rag-eval', 'korean-keyword-eval.json');

if (!existsSync(setPath)) {
  console.log(`[eval] 평가셋 없음(${setPath}) — 건너뜀`);
  process.exit(0);
}

const evalSet = JSON.parse(readFileSync(setPath, 'utf-8'));
const items = evalSet.items ?? evalSet;
const shorten = (p) => (p && p.startsWith(HOME) ? `~${p.slice(HOME.length)}` : p);

const { RAGEngine } = await import(join(here, '..', 'lib', 'rag-engine.mjs'));
const { LANCEDB_PATH } = await import(join(here, '..', 'lib', 'paths.mjs'));
const engine = new RAGEngine(LANCEDB_PATH);
await engine.openReadOnly();

const LIMIT = 8; // rag_search 기본 maxResults 와 같게 — 후보 풀 크기(limit*3)도 운영과 같아진다.
// 첫 질의는 임베딩 모델 적재 시간이 섞인다 — 재지 않는 예열 1회.
await engine.search('예열 warmup', LIMIT, { topK: LIMIT });

const rows = [];
for (const it of items) {
  const expected = new Set(it.expected);
  const t0 = performance.now();
  const hits = await engine.search(it.q, LIMIT, { topK: LIMIT });
  const ms = performance.now() - t0;
  const sources = hits.map((h) => shorten(h.source));
  const rank = sources.findIndex((s) => expected.has(s)) + 1; // 0 = 못 찾음
  rows.push({ id: it.id, lang: it.lang ?? (/^en/.test(it.id) ? 'en' : 'ko'), q: it.q, rank, ms: Math.round(ms), top: sources.slice(0, 5) });
}

const pct = (xs, p) => {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))] ?? 0;
};
function summarize(lang) {
  const rs = rows.filter((r) => r.lang === lang);
  const n = rs.length || 1;
  return {
    n: rs.length,
    hit1: rs.filter((r) => r.rank === 1).length,
    hit5: rs.filter((r) => r.rank >= 1 && r.rank <= 5).length,
    hit8: rs.filter((r) => r.rank >= 1).length,
    mrr5: +(rs.reduce((s, r) => s + (r.rank >= 1 && r.rank <= 5 ? 1 / r.rank : 0), 0) / n).toFixed(3),
    p50ms: pct(rs.map((r) => r.ms), 50),
    p95ms: pct(rs.map((r) => r.ms), 95),
  };
}
const summary = {
  koKeywords: process.env.RAG_KO_KEYWORDS ?? '(default)',
  ko: summarize('ko'),
  en: summarize('en'),
};

for (const r of rows) {
  console.log(`${r.id.padEnd(5)} rank=${String(r.rank || '-').padEnd(2)} ${String(r.ms).padStart(5)}ms  ${r.q}`);
}
console.log(JSON.stringify(summary));
if (jsonOut) writeFileSync(jsonOut, JSON.stringify({ summary, rows }, null, 1));

if (gateFile) {
  const base = JSON.parse(readFileSync(gateFile, 'utf-8'));
  const problems = [];
  if (summary.ko.hit5 < base.summary.ko.hit5) problems.push(`한국어 hit@5 ${summary.ko.hit5} < 기준 ${base.summary.ko.hit5}`);
  const baseEnHit = new Set(base.rows.filter((r) => r.lang === 'en' && r.rank >= 1 && r.rank <= 5).map((r) => r.id));
  for (const r of rows.filter((x) => x.lang === 'en')) {
    if (baseEnHit.has(r.id) && !(r.rank >= 1 && r.rank <= 5)) problems.push(`영어/코드 회귀: ${r.id} (${r.q})`);
  }
  if (problems.length) {
    console.error(`[eval] 관문 실패:\n  ${problems.join('\n  ')}`);
    process.exit(1);
  }
  console.log('[eval] 관문 통과');
}
process.exit(0);
