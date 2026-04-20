/**
 * wiki-engine.mjs — LLM Wiki CRUD 엔진
 *
 * Karpathy LLM Wiki 패턴 구현 — 전역 도메인 기반 단일 구조.
 * devming 원본 설계 + 전역 도메인 통합 (SSoT).
 *
 * 저장 구조:
 *   ~/jarvis/runtime/wiki/
 *     schema.json              — 위키 스키마 (도메인 규칙)
 *     {domain}/
 *       _summary.md            — 야간 크론(wiki-ingest.mjs)이 합성하는 종합 요약
 *       _facts.md              — 실시간 fact 추가 (이 엔진이 기록)
 *       *.md                   — 기타 상세 페이지
 *
 * 역할 분리:
 *   - wiki-engine.mjs (이 파일): 실시간 CRUD (키워드 기반 즉시 반영)
 *   - wiki-ingest.mjs (크론):    야간 배치 합성 (LLM으로 _summary.md 갱신)
 *   - wiki-ingester.mjs:         LLM 소화 (세션 전체를 분석해 페이지 업데이트)
 */

import {
  readFileSync, writeFileSync, mkdirSync,
  existsSync, readdirSync, statSync,
} from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
export const WIKI_ROOT = join(BOT_HOME, 'wiki');
const SCHEMA_PATH = join(WIKI_ROOT, 'schema.json');

// ── 도메인 스키마 (devming 7개 → 전역 8개 도메인 통합) ──────────────────────

const DEFAULT_SCHEMA = {
  version: '2.0',
  domains: {
    career: {
      title: '커리어 & 기술',
      description: '직장, 기술 스택, 면접, 커리어 목표, 개인 프로필',
      keywords: ['spring', 'kafka', 'redis', 'aws', 'backend', '백엔드', '개발',
                 '회사', 'grpc', '면접', '이력서', '채용', '핀테크', '이름', '직업',
                 '나이', '거주', 'star'],
    },
    trading: {
      title: '투자 & 금융',
      description: '주식/코인 포트폴리오, 투자 전략, 관심 종목',
      keywords: ['주식', '코인', '비트코인', 'etf', '레버리지', '매수', '매도',
                 '포트폴리오', 'nasdaq', 's&p', '코스피', '금리', 'tqqq', '수익률'],
    },
    ops: {
      title: '운영 & 인프라',
      description: '크론, 장애, 인프라, Jarvis 봇, 자동화 프로젝트',
      keywords: ['jarvis', '봇', '디스코드', '자동화', '프로젝트', 'claude', 'mcp',
                 '크론', 'cron', '디스크', '장애', '서킷', '에러', 'rag', '모니터링',
                 'watchdog', '배포'],
    },
    knowledge: {
      title: '기술 지식 & 트렌드',
      description: '아키텍처, 기술 트렌드, 학습, 오픈소스',
      keywords: ['아키텍처', '디자인패턴', '기술트렌드', '오픈소스', 'github', '블로그', '학습'],
    },
    family: {
      title: '가족 & 생활',
      description: '가족, 여행, 선호도, 습관, 루틴',
      keywords: ['아내', '와이프', '가족', '부모님', '아이', '육아',
                 '좋아', '싫어', '선호', '습관', '루틴',
                 '여행', '해외', '항공', '숙소', '휴가'],
    },
    health: {
      title: '건강 & 운동',
      description: '건강 상태, 운동 루틴, 식단',
      keywords: ['운동', '건강', '병원', '다이어트', '수면', '피로', '자전거', '사이클'],
    },
    briefings: {
      title: '일일/주간 브리핑',
      description: '스탠드업, 모닝 브리핑, 주간 요약',
      keywords: ['스탠드업', '브리핑', '모닝', '주간'],
    },
    meta: {
      title: '위키 관리',
      description: '위키 자체 관리 — 모순, 린트, 통합 이력',
      keywords: [],
    },
  },
  crossRefEnabled: true,
  maxPageSizeKb: 3,
};

// ── 초기화 (lazy-init) ──────────────────────────────────────────────────────

let _initialized = false;

function ensureInit() {
  if (_initialized) return;
  mkdirSync(WIKI_ROOT, { recursive: true });
  if (!existsSync(SCHEMA_PATH)) {
    writeFileSync(SCHEMA_PATH, JSON.stringify(DEFAULT_SCHEMA, null, 2));
  }
  _initialized = true;
}

export function initWiki() { ensureInit(); }

export function getSchema() {
  try {
    return JSON.parse(readFileSync(SCHEMA_PATH, 'utf-8'));
  } catch {
    return DEFAULT_SCHEMA;
  }
}

// ── 페이지 경로 (전역 도메인 기반) ──────────────────────────────────────────

function domainDir(domain) {
  return join(WIKI_ROOT, domain);
}

function factsPath(domain) {
  return join(WIKI_ROOT, domain, '_facts.md');
}

// ── CRUD ─────────────────────────────────────────────────────────────────────

/**
 * 도메인의 _facts.md 읽기. 없으면 null.
 * userId 파라미터는 하위 호환용 — 무시됨 (전역 도메인 단일 구조).
 */
export function getPage(_userId, domain) {
  const path = factsPath(domain);
  if (!existsSync(path)) return null;
  try {
    return readFileSync(path, 'utf-8');
  } catch {
    return null;
  }
}

/**
 * 도메인의 _facts.md 저장.
 */
export function savePage(_userId, domain, content) {
  ensureInit();
  const dir = domainDir(domain);
  mkdirSync(dir, { recursive: true });
  const path = factsPath(domain);
  const timestamp = new Date().toISOString().slice(0, 19).replace('T', ' ');
  const schema = getSchema();
  const domainDef = schema.domains?.[domain] || schema.pages?.[domain];
  const title = domainDef?.title || domain;
  const header = `# ${title} — 실시간 기록\n> 마지막 업데이트: ${timestamp}\n\n`;
  const finalContent = content.startsWith('#') ? content : header + content;
  writeFileSync(path, finalContent);
}

/**
 * 전체 도메인의 _facts.md 목록 반환.
 */
export function listPages(_userId) {
  if (!existsSync(WIKI_ROOT)) return [];
  try {
    return readdirSync(WIKI_ROOT)
      .filter(d => {
        const p = join(WIKI_ROOT, d);
        return statSync(p).isDirectory() && !d.startsWith('.') && d !== 'meta' && d !== 'pages';
      })
      .filter(d => existsSync(factsPath(d)));
  } catch {
    return [];
  }
}

/**
 * 텍스트가 어느 도메인에 속하는지 키워드 기반으로 판단.
 */
export function detectPageKey(text, schema = null) {
  const s = schema || getSchema();
  const lText = text.toLowerCase();
  const scores = {};
  const domains = s.domains || s.pages || {};

  for (const [key, def] of Object.entries(domains)) {
    let score = 0;
    for (const kw of (def.keywords || [])) {
      if (lText.includes(kw.toLowerCase())) score++;
    }
    if (score > 0) scores[key] = score;
  }

  if (Object.keys(scores).length === 0) return 'career'; // 기본값 (구 profile → career)
  return Object.entries(scores).sort((a, b) => b[1] - a[1])[0][0];
}

/**
 * fact를 적절한 도메인의 _facts.md에 추가.
 * 3번째 인자는 백워드 호환: string이면 domainOverride, object면 { domainOverride, source }
 * source는 기록 라인에 `[source:X]` 태그로 삽입됨. 기본값 'discord'.
 * @returns {string} 추가된 도메인 키
 */
export function addFactToWiki(_userId, fact, opts = null) {
  let domainOverride = null;
  let source = 'discord';
  if (typeof opts === 'string') {
    domainOverride = opts;
  } else if (opts && typeof opts === 'object') {
    domainOverride = opts.domainOverride ?? null;
    if (typeof opts.source === 'string' && opts.source.length > 0) source = opts.source;
  }

  ensureInit();
  const schema = getSchema();
  const domain = domainOverride || detectPageKey(fact, schema);
  const existing = getPage(null, domain) || '';
  const timestamp = new Date().toISOString().slice(0, 10);

  // 중복 체크 (fact 문자열이 이미 기록되어 있으면 source 무관하게 skip — 첫 주입이 SSoT)
  if (existing.includes(fact.trim())) return domain;

  const newEntry = `- [${timestamp}] [source:${source}] ${fact.trim()}\n`;

  if (!existing) {
    const domains = schema.domains || schema.pages || {};
    const domainDef = domains[domain];
    const title = domainDef?.title || domain;
    const content = `# ${title} — 실시간 기록\n> 마지막 업데이트: ${timestamp}\n\n## 기록\n${newEntry}`;
    savePage(null, domain, content);
  } else {
    const updatedContent = appendToSection(existing, '## 기록', newEntry, timestamp);
    savePage(null, domain, updatedContent);
  }

  return domain;
}

/**
 * 섹션에 항목 추가. 섹션 없으면 생성.
 */
function appendToSection(content, sectionHeader, newEntry, timestamp) {
  const updated = content.replace(
    /> 마지막 업데이트:.*/,
    `> 마지막 업데이트: ${timestamp}`
  );

  if (updated.includes(sectionHeader)) {
    const parts = updated.split(sectionHeader);
    const afterSection = parts[1] || '';
    const nextSectionIdx = afterSection.search(/\n## /);
    if (nextSectionIdx === -1) {
      return updated + newEntry;
    }
    const before = afterSection.slice(0, nextSectionIdx);
    const after = afterSection.slice(nextSectionIdx);
    return parts[0] + sectionHeader + before + newEntry + after;
  }

  return updated.trimEnd() + `\n\n${sectionHeader}\n${newEntry}`;
}

/**
 * 위키 전체 내용을 프롬프트용으로 반환.
 * _summary.md (야간 합성) + _facts.md (실시간) 모두 포함.
 */
export function getWikiContext(_userId, relevantQuery = '') {
  if (!existsSync(WIKI_ROOT)) return '';
  const schema = getSchema();
  const domains = schema.domains || schema.pages || {};
  const lines = ['## 위키 지식베이스'];

  // 쿼리 관련 도메인 우선
  const allDomains = Object.keys(domains).filter(d => d !== 'meta');
  let orderedDomains = allDomains;
  if (relevantQuery) {
    const primary = detectPageKey(relevantQuery, schema);
    orderedDomains = [primary, ...allDomains.filter(d => d !== primary)];
  }

  for (const domain of orderedDomains) {
    const dir = domainDir(domain);
    if (!existsSync(dir)) continue;

    // _summary.md 우선 (야간 합성 결과)
    const summaryPath = join(dir, '_summary.md');
    if (existsSync(summaryPath)) {
      let content = readFileSync(summaryPath, 'utf-8');
      content = content.replace(/^---[\s\S]*?---\n*/m, '');
      const snippet = content.length > 500 ? content.slice(0, 500) + '...' : content;
      lines.push(`\n### [${domains[domain]?.title || domain}]\n${snippet}`);
      continue; // summary가 있으면 facts는 스킵 (summary가 더 구조화됨)
    }

    // _facts.md 폴백 (실시간 기록)
    const facts = getPage(null, domain);
    if (facts) {
      const snippet = facts.length > 500 ? facts.slice(0, 500) + '...' : facts;
      lines.push(`\n### [${domains[domain]?.title || domain}]\n${snippet}`);
    }
  }

  if (lines.length <= 1) return '';
  return lines.join('\n') + '\n\n';
}

/**
 * 위키 통계 반환.
 */
export function getWikiStats(_userId) {
  if (!existsSync(WIKI_ROOT)) return { totalPages: 0, pages: {} };
  const stats = { totalPages: 0, pages: {} };
  try {
    const domains = readdirSync(WIKI_ROOT).filter(d => {
      const p = join(WIKI_ROOT, d);
      return statSync(p).isDirectory() && !d.startsWith('.');
    });
    for (const domain of domains) {
      const dir = domainDir(domain);
      const files = readdirSync(dir).filter(f => f.endsWith('.md'));
      stats.totalPages += files.length;
      for (const f of files) {
        const fp = join(dir, f);
        try {
          const { size, mtimeMs } = statSync(fp);
          stats.pages[`${domain}/${f}`] = {
            sizeKb: (size / 1024).toFixed(1),
            lastModified: new Date(mtimeMs).toISOString().slice(0, 10),
          };
        } catch {}
      }
    }
  } catch {}
  return stats;
}