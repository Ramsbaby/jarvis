#!/usr/bin/env node
/**
 * wiki-contradiction-scan.mjs — wiki 모순·중복·오래된 사실 자동 감지 (Phase 3 메타인지)
 *
 * 역할: wiki/meta/_facts.md 내 모순·중복·충돌을 규칙 기반으로 자동 감지한다.
 *
 * 처리 대상:
 *   - BOT_HOME/wiki/meta/_facts.md (primary)
 *   - BOT_HOME/wiki/ 하위 모든 .md 파일 (추후 확장용 — 현재는 _facts.md만 깊이 분석)
 *
 * 감지 알고리즘:
 *   1. 중복 감지: 같은 날짜/출처/키워드 패턴이 반복 (Jaccard 유사도 > 0.7)
 *   2. 모순 감지: 부정 패턴 ("~하지 않음" vs "~함", "금지" vs "허용") — 동일 주제 키워드 쌍
 *   3. 오래된 사실: 90일 이상 된 [YYYY-MM-DD] 접두사 항목 플래그
 *
 * 출력:
 *   - stdout: JSON { duplicates, contradictions, stale, totalFacts }
 *   - Discord #jarvis-system으로 건수 요약 알림
 *   - ledger/wiki-scan.jsonl에 결과 append (같은 날 재실행 시 중복 기록 안 됨)
 *
 * 설계 원칙:
 *   - LLM 미사용 — 규칙 기반 + 정규식만 사용
 *   - 실행시간 < 5초
 *   - 멱등성: 같은 날 재실행해도 ledger 중복 기록 없음
 *
 * 실행 시점: 매주 월요일 03:00 KST
 * 모델: 없음 (LLM 미사용)
 *
 * --dry-run 플래그: Discord 알림 및 ledger 기록 건너뜀
 */

import { readFileSync, appendFileSync, existsSync, mkdirSync, readdirSync, statSync } from 'node:fs';
import { join, extname } from 'node:path';
import { homedir } from 'node:os';
import { execFileSync } from 'node:child_process';

const HOME = homedir();
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis', 'runtime');
const INFRA = join(HOME, 'jarvis', 'infra');

const WIKI_ROOT = join(BOT_HOME, 'wiki');
const FACTS_FILE = join(WIKI_ROOT, 'meta', '_facts.md');
const LEDGER_FILE = join(BOT_HOME, 'ledger', 'wiki-scan.jsonl');
const DISCORD_ROUTE_SH = join(INFRA, 'lib', 'discord-route.sh');

const DRY_RUN = process.argv.includes('--dry-run');
const STALE_DAYS = 90;
const JACCARD_THRESHOLD = 0.7;

// ── 유틸 ─────────────────────────────────────────────────────────────────────

function nowKST() {
  return new Date(Date.now() + 9 * 3600_000).toISOString().replace('Z', '+09:00');
}

function todayKST() {
  return nowKST().slice(0, 10);
}

function log(msg) {
  const ts = nowKST().slice(0, 19).replace('T', ' ');
  console.error(`[${ts}] [wiki-contradiction-scan] ${msg}`);
}

// ── 파일 수집 ─────────────────────────────────────────────────────────────────

function collectMdFiles(dir, result = []) {
  if (!existsSync(dir)) return result;
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    try {
      const stat = statSync(full);
      if (stat.isDirectory()) {
        collectMdFiles(full, result);
      } else if (stat.isFile() && extname(name) === '.md') {
        result.push(full);
      }
    } catch {
      // 접근 불가 파일 무시
    }
  }
  return result;
}

// ── 사실 행 파싱 ──────────────────────────────────────────────────────────────

const FACT_LINE_RE = /^-\s+\[(\d{4}-\d{2}-\d{2})\](.*)/;

function parseFacts(text, filePath) {
  const lines = text.split('\n');
  const facts = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    const m = line.match(FACT_LINE_RE);
    if (m) {
      facts.push({
        date: m[1],
        body: m[2].trim(),
        raw: line,
        lineNum: i + 1,
        file: filePath,
      });
    }
  }
  return facts;
}

// ── 텍스트 토큰화 (Jaccard용) ─────────────────────────────────────────────────

function tokenize(text) {
  // 한국어 + 영문 단어 단위 토큰화 (2자 이상)
  return new Set(
    text
      .toLowerCase()
      .replace(/[^\w가-힣]/g, ' ')
      .split(/\s+/)
      .filter(t => t.length >= 2)
  );
}

function jaccard(setA, setB) {
  if (setA.size === 0 && setB.size === 0) return 1;
  const intersection = new Set([...setA].filter(x => setB.has(x)));
  const union = new Set([...setA, ...setB]);
  return intersection.size / union.size;
}

// ── 중복 감지 ─────────────────────────────────────────────────────────────────

function detectDuplicates(facts) {
  const duplicates = [];
  for (let i = 0; i < facts.length; i++) {
    for (let j = i + 1; j < facts.length; j++) {
      const a = facts[i];
      const b = facts[j];
      const tokA = tokenize(a.body);
      const tokB = tokenize(b.body);
      const sim = jaccard(tokA, tokB);
      if (sim > JACCARD_THRESHOLD) {
        duplicates.push({
          factA: { date: a.date, lineNum: a.lineNum, file: a.file, snippet: a.body.slice(0, 80) },
          factB: { date: b.date, lineNum: b.lineNum, file: b.file, snippet: b.body.slice(0, 80) },
          similarity: Math.round(sim * 100) / 100,
        });
      }
    }
  }
  return duplicates;
}

// ── 모순 감지 ─────────────────────────────────────────────────────────────────

// 부정 패턴 쌍 (긍정 → 부정 매핑)
const CONTRADICTION_PAIRS = [
  // 한국어
  { pos: /허용/, neg: /금지|불허|차단/ },
  { pos: /활성화|켜짐|on/, neg: /비활성화|꺼짐|off/ },
  { pos: /가능/, neg: /불가능|안됨|불가/ },
  { pos: /(?<!하지\s)않음/, neg: /함$|한다$/ },  // "~하지 않음" vs "~함"
  { pos: /사용/, neg: /미사용|사용\s*안/ },
  { pos: /필수/, neg: /선택|옵션/ },
  { pos: /실행/, neg: /중단|중지|종료/ },
  { pos: /자동/, neg: /수동/ },
  { pos: /포함/, neg: /제외|미포함/ },
  // 영문
  { pos: /enabled?/, neg: /disabled?/ },
  { pos: /allow/, neg: /deny|block|forbid/ },
  { pos: /true/, neg: /false/ },
  { pos: /required/, neg: /optional/ },
];

function extractKeywords(text) {
  // [source:xxx], 조사/어미 제거 후 핵심 명사 추출
  return text
    .replace(/\[source:[^\]]+\]/g, '')
    .replace(/\[[^\]]+\]/g, '')
    .toLowerCase()
    .replace(/[^\w가-힣\s]/g, ' ')
    .split(/\s+/)
    .filter(t => t.length >= 2);
}

function sharedKeywords(a, b) {
  const ka = new Set(extractKeywords(a));
  const kb = new Set(extractKeywords(b));
  return [...ka].filter(k => kb.has(k));
}

function detectContradictions(facts) {
  const contradictions = [];

  for (let i = 0; i < facts.length; i++) {
    for (let j = i + 1; j < facts.length; j++) {
      const a = facts[i];
      const b = facts[j];

      // 공유 키워드 없으면 모순 관계 아님
      const shared = sharedKeywords(a.body, b.body);
      if (shared.length < 2) continue;

      // 각 패턴 쌍에 대해 A가 긍정, B가 부정 (또는 반대) 체크
      for (const pair of CONTRADICTION_PAIRS) {
        const aPos = pair.pos.test(a.body);
        const aNeg = pair.neg.test(a.body);
        const bPos = pair.pos.test(b.body);
        const bNeg = pair.neg.test(b.body);

        if ((aPos && bNeg) || (aNeg && bPos)) {
          contradictions.push({
            factA: { date: a.date, lineNum: a.lineNum, file: a.file, snippet: a.body.slice(0, 80) },
            factB: { date: b.date, lineNum: b.lineNum, file: b.file, snippet: b.body.slice(0, 80) },
            sharedKeywords: shared.slice(0, 5),
            pattern: `${pair.pos.source} vs ${pair.neg.source}`,
          });
          break; // 같은 쌍에 대해 중복 감지 방지
        }
      }
    }
  }
  return contradictions;
}

// ── 오래된 사실 감지 ──────────────────────────────────────────────────────────

function detectStale(facts) {
  const today = new Date(todayKST());
  const stale = [];
  for (const fact of facts) {
    const d = new Date(fact.date);
    if (isNaN(d.getTime())) continue;
    const ageDays = Math.floor((today - d) / 86_400_000);
    if (ageDays >= STALE_DAYS) {
      stale.push({
        date: fact.date,
        ageDays,
        lineNum: fact.lineNum,
        file: fact.file,
        snippet: fact.body.slice(0, 80),
      });
    }
  }
  return stale;
}

// ── 멱등성: 오늘 이미 기록했으면 스킵 ────────────────────────────────────────

function alreadyRecordedToday() {
  if (!existsSync(LEDGER_FILE)) return false;
  const today = todayKST();
  const lines = readFileSync(LEDGER_FILE, 'utf-8').split('\n').filter(Boolean);
  return lines.some(l => {
    try {
      const e = JSON.parse(l);
      return e.type === 'scan_result' && e.date === today;
    } catch {
      return false;
    }
  });
}

// ── ledger 기록 ───────────────────────────────────────────────────────────────

function appendLedger(result) {
  if (DRY_RUN) {
    log(`[DRY] ledger 기록 건너뜀`);
    return;
  }
  mkdirSync(join(BOT_HOME, 'ledger'), { recursive: true });
  const entry = {
    ts: nowKST(),
    date: todayKST(),
    type: 'scan_result',
    duplicates: result.duplicates.length,
    contradictions: result.contradictions.length,
    stale: result.stale.length,
    totalFacts: result.totalFacts,
    // 상세 내용은 저장하지 않음 (건수만 — 보안·크기 절감)
  };
  appendFileSync(LEDGER_FILE, JSON.stringify(entry) + '\n');
}

// ── Discord 알림 ──────────────────────────────────────────────────────────────

function notify(result) {
  const title = 'wiki 모순·중복 주간 스캔';
  const kvObj = {
    전체사실: result.totalFacts,
    중복: result.duplicates.length,
    모순: result.contradictions.length,
    오래된항목: result.stale.length,
  };

  if (DRY_RUN || !existsSync(DISCORD_ROUTE_SH)) {
    log(`[NOTIFY] info / ${title} / ${JSON.stringify(kvObj)}`);
    return;
  }

  const kv = Object.entries(kvObj)
    .map(([k, v]) => `${String(k).replace(/[,=]/g, '_')}=${String(v).replace(/[,=]/g, '_')}`)
    .join(',');
  const snippet = `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; source "${DISCORD_ROUTE_SH}"; discord_route "$1" "$2" "$3"`;
  try {
    execFileSync('/bin/bash', ['-c', snippet, 'bash', 'info', title, kv], {
      stdio: ['ignore', 'inherit', 'inherit'], timeout: 30_000,
    });
  } catch (e) {
    log(`WARN: Discord 알림 실패: ${e.message}`);
  }
}

// ── 메인 ─────────────────────────────────────────────────────────────────────

function main() {
  log(`시작 (dry-run=${DRY_RUN})`);

  // 멱등성 체크
  if (!DRY_RUN && alreadyRecordedToday()) {
    log(`오늘(${todayKST()}) 이미 스캔 완료 — 중복 기록 건너뜀`);
    // 마지막 기록 읽어서 stdout으로 재출력
    const lines = readFileSync(LEDGER_FILE, 'utf-8').split('\n').filter(Boolean);
    const today = todayKST();
    const last = [...lines]
      .reverse()
      .map(l => { try { return JSON.parse(l); } catch { return null; } })
      .find(e => e && e.type === 'scan_result' && e.date === today);
    if (last) {
      const out = {
        duplicates: Array(last.duplicates).fill(null),
        contradictions: Array(last.contradictions).fill(null),
        stale: Array(last.stale).fill(null),
        totalFacts: last.totalFacts,
        idempotent: true,
      };
      process.stdout.write(JSON.stringify(out) + '\n');
    }
    return;
  }

  // 파일 수집
  const allMdFiles = collectMdFiles(WIKI_ROOT);
  log(`wiki .md 파일 수: ${allMdFiles.length}`);

  // _facts.md 파싱 (primary — 깊이 분석)
  let allFacts = [];
  if (existsSync(FACTS_FILE)) {
    const text = readFileSync(FACTS_FILE, 'utf-8');
    allFacts = parseFacts(text, FACTS_FILE);
    log(`_facts.md 사실 항목 수: ${allFacts.length}`);
  } else {
    log(`WARN: _facts.md 없음 — ${FACTS_FILE}`);
  }

  // 감지 실행
  const duplicates = detectDuplicates(allFacts);
  const contradictions = detectContradictions(allFacts);
  const stale = detectStale(allFacts);

  log(`중복: ${duplicates.length}건, 모순: ${contradictions.length}건, 오래된항목: ${stale.length}건`);

  const result = {
    duplicates,
    contradictions,
    stale,
    totalFacts: allFacts.length,
  };

  // ledger 기록
  appendLedger(result);

  // Discord 알림
  notify(result);

  log(`완료`);
  process.stdout.write(JSON.stringify(result) + '\n');
}

main();
