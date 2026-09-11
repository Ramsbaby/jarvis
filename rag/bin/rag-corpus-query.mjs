#!/usr/bin/env node
/**
 * rag-corpus-query.mjs — 오픈클로 메모리 코퍼스 보충용 JSON 어댑터
 *
 * 왜 있나 (2026-09-10 오픈클로 이식):
 *   자비스 RAG(LanceDB 133,737청크)를 오픈클로 메모리에 "흡수"하면 852청크짜리
 *   작업 기억이 오염된다. 대신 오픈클로의 registerMemoryCorpusSupplement 로 **연결**한다.
 *   그 어댑터가 요구하는 건 search/get 두 가지이고, 이 스크립트가 그 둘을 JSON 으로 낸다.
 *
 *   rag-query.mjs 를 쓰지 않는 이유: 그쪽은 마크다운만 내고 `### From:` 헤더를 파싱해야 해서
 *   포맷이 바뀌면 조용히 깨진다. 엔진을 직접 불러 구조화된 값을 낸다.
 *
 * 사용법:
 *   node rag-corpus-query.mjs search "질의" [maxResults]
 *   node rag-corpus-query.mjs get "<파일경로>" [fromLine] [lineCount]
 *
 * 출력: stdout 에 JSON 한 덩어리. 실패해도 JSON 으로 낸다(호출자가 파싱 실패로 죽지 않게).
 */

import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';

const HOME = homedir();
const CORPUS = 'jarvis-rag';

// ── RAG 홈 고정 ────────────────────────────────────────────────────────────────
// paths.mjs:15-17 은 BOT_HOME 이 없으면 ~/.local/share/jarvis/rag 로 폴백한다.
// 그쪽에는 450행짜리 잔재 DB(8.7M)가 있고, 진짜 색인은 BOT_HOME/rag(134,055행·3.7G)다.
// 게이트웨이는 launchd 의 좁은 env 로 돌아 BOT_HOME 이 없을 수 있다 —
// 그러면 조용히 빈 DB를 검색해 "결과는 나오는데 전부 무관"한 상태가 된다(2026-09-10 실측).
// 그래서 상속 env 에 기대지 않고 여기서 못박는다.
process.env.BOT_HOME ||= join(HOME, '.openclaw-data/jarvis/runtime');
process.env.JARVIS_RAG_HOME ||= join(process.env.BOT_HOME, 'rag');

// 빈 DB를 조용히 검색하면 오답을 정답처럼 돌려준다. 최소 행수를 밑돌면 실패로 낸다.
const MIN_EXPECTED_ROWS = 1000;

function out(value) {
  process.stdout.write(JSON.stringify(value));
  process.exit(0);
}
function fail(message) {
  out({ ok: false, error: String(message).slice(0, 400), results: [], result: null });
}

// 색인된 경로는 ~ 축약형과 절대경로가 섞여 있다(index-state.json 실측).
// 둘 다 받아 실제 파일로 되돌린다.
function expand(p) {
  if (!p) return '';
  return p.startsWith('~/') ? resolve(HOME, p.slice(2)) : resolve(p);
}
function shorten(p) {
  return p && p.startsWith(HOME) ? `~${p.slice(HOME.length)}` : p;
}

const [, , mode, arg1, arg2, arg3] = process.argv;

async function openEngine() {
  const { RAGEngine } = await import('../lib/rag-engine.mjs');
  const { LANCEDB_PATH } = await import('../lib/paths.mjs');
  const engine = new RAGEngine(LANCEDB_PATH);
  await engine.init();
  const rows = await engine.table.countRows();
  if (rows < MIN_EXPECTED_ROWS) {
    throw new Error(
      `색인이 비었다 — ${LANCEDB_PATH} 에 ${rows}행뿐이다(기대 ${MIN_EXPECTED_ROWS}+). ` +
        `잘못된 RAG 홈을 보고 있을 가능성이 높다. BOT_HOME/JARVIS_RAG_HOME 확인.`,
    );
  }
  return engine;
}

// 원문 파일이 없을 때 색인 청크로 본문을 되살린다.
// 왜 (2026-09-10 실측): system-cleanup 이 inbox/claude-cli-* 를 30일 뒤 지우지만 RAG 청크는 남긴다 —
// 그게 아카이브의 목적이다. 그런데 get 이 파일만 읽으면 검색은 되는데 열람은 실패하는 구멍이 생긴다.
// 활성 청크 136,711 중 31,157건(23%)이 이 상태였다.
async function reconstructFromChunks(abs) {
  const engine = await openEngine();
  const esc = abs.replace(/'/g, "''");
  const rows = await engine.table
    .query()
    .where(`source = '${esc}' AND deleted = false`)
    .select(['text', 'chunk_index', 'header_path'])
    .limit(5000)
    .toArray();
  if (!rows.length) return null;
  rows.sort((a, b) => Number(a.chunk_index) - Number(b.chunk_index));
  return rows.map((r) => String(r.text ?? '')).join('\n\n');
}

if (mode === 'get') {
  // 원문 파일이 있으면 그대로 읽는다 — 빠르고, 청크 경계가 아니라 사람이 읽는 단위로 돌려준다.
  // 없으면(30일 retention 으로 지워진 inbox 등) 색인 청크에서 되살린다.
  const abs = expand(arg1);
  if (!abs) fail(`파일 없음: ${arg1}`);
  const fromLine = Math.max(1, Number.parseInt(arg2 ?? '1', 10) || 1);
  const lineCount = Math.max(1, Number.parseInt(arg3 ?? '200', 10) || 200);
  let lines;
  let kind = 'file';
  if (existsSync(abs)) {
    try {
      lines = readFileSync(abs, 'utf-8').split('\n');
    } catch (err) {
      fail(`읽기 실패: ${err?.message ?? err}`);
    }
  } else {
    let text = null;
    try {
      text = await reconstructFromChunks(abs);
    } catch (err) {
      fail(`파일 없음: ${arg1} (청크 복원 실패: ${err?.message ?? err})`);
    }
    if (text == null) fail(`파일 없음: ${arg1} (색인에도 없음)`);
    lines = text.split('\n');
    kind = 'archived-chunks';
  }
  const slice = lines.slice(fromLine - 1, fromLine - 1 + lineCount);
  out({
    ok: true,
    result: {
      corpus: CORPUS,
      path: shorten(abs),
      title: abs.split('/').pop(),
      kind,
      content: slice.join('\n'),
      fromLine,
      lineCount: slice.length,
      totalLines: lines.length,
      sourceType: 'jarvis-rag',
      sourcePath: shorten(abs),
      note: kind === 'archived-chunks' ? '원문 파일은 retention 으로 삭제됨 — 색인 청크에서 복원한 본문' : undefined,
    },
  });
}

if (mode !== 'search') fail(`알 수 없는 모드: ${mode ?? '(없음)'} — search | get`);

const query = arg1 ?? '';
if (!query.trim()) fail('빈 질의');
const maxResults = Math.min(50, Math.max(1, Number.parseInt(arg2 ?? '8', 10) || 8));

let engine;
try {
  engine = await openEngine();
} catch (err) {
  fail(`엔진 초기화 실패: ${err?.message ?? err}`);
}

let hits;
try {
  hits = await engine.search(query, maxResults, { topK: maxResults });
} catch (err) {
  fail(`검색 실패: ${err?.message ?? err}`);
}

// LanceDB 는 거리(작을수록 가깝다)를 준다. 오픈클로 코퍼스 계약은 점수(클수록 좋다)를 요구한다.
// 정규화 벡터의 L2 거리는 0~2 범위이고(√2 ≈ 1.414 가 직교), 실측 관련 결과가 0.65~0.93 이었다.
// `1 - d` 로 뒤집으면 0.65 조차 0.35 로 눌리고 1.0 을 넘는 거리는 전부 0 으로 뭉개진다 —
// 처음에 그렇게 짰다가 모든 점수가 0 으로 나왔다. 범위를 2 로 나눠 편다.
function toScore(distance) {
  if (typeof distance !== 'number' || Number.isNaN(distance)) return 0.5;
  return Math.max(0, Math.min(1, 1 - distance / 2));
}

const results = (hits ?? []).map((h) => {
  const path = shorten(h.source ?? '');
  const header = (h.headerPath ?? '').trim();
  return {
    corpus: CORPUS,
    path,
    title: header || (path.split('/').pop() ?? path),
    kind: 'chunk',
    score: toScore(h.distance),
    snippet: String(h.text ?? '').slice(0, 1200),
    citation: header ? `${path} — ${header}` : path,
    source: 'jarvis-rag',
    provenanceLabel: '자비스 RAG (아카이브)',
    sourceType: 'jarvis-rag',
    sourcePath: path,
  };
});

out({ ok: true, results });
