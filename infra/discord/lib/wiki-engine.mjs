/**
 * wiki-engine.mjs — LLM Wiki 엔진
 *
 * Karpathy의 LLM Wiki 패턴 구현.
 * 기존 flat facts JSON 대신 주제별 .md 위키 페이지로 지식을 관리.
 *
 * 저장 구조:
 *   ~/.jarvis/wiki/
 *     schema.json              — 위키 스키마 (카테고리/페이지 규칙)
 *     pages/{userId}/
 *       profile.md             — 사용자 기본 프로필
 *       work.md                — 업무/기술 컨텍스트
 *       trading.md             — 투자/금융
 *       projects.md            — 진행 중인 프로젝트
 *       preferences.md         — 선호도/습관
 *       health.md              — 건강/생활
 *       travel.md              — 여행 계획/기록
 *
 * 핵심 철학: Stateful 지식 축적 — 새 정보가 기존 페이지를 업데이트한다.
 */

import {
  readFileSync, writeFileSync, mkdirSync,
  existsSync, readdirSync, statSync,
} from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
export const WIKI_ROOT = join(BOT_HOME, 'wiki');
const SCHEMA_PATH = join(WIKI_ROOT, 'schema.json');

// ── 기본 위키 스키마 ──────────────────────────────────────────────────────────

const DEFAULT_SCHEMA = {
  version: '1.0',
  pages: {
    profile: {
      title: '사용자 프로필',
      description: '이름, 직업, 거주지, 가족 등 기본 신상 정보',
      keywords: ['이름', '직업', '나이', '거주', '가족', '아내', '부모님'],
    },
    work: {
      title: '업무 & 기술',
      description: '현재 직장, 기술 스택, 프로젝트, 커리어 목표',
      keywords: ['spring', 'kafka', 'redis', 'aws', 'backend', '백엔드', '개발', '이직', '회사', 'sk', 'grpc'],
    },
    trading: {
      title: '투자 & 금융',
      description: '주식/코인 포트폴리오, 투자 전략, 관심 종목',
      keywords: ['주식', '코인', '비트코인', 'etf', '레버리지', '매수', '매도', '포트폴리오', 'nasdaq', 's&p', '코스피', '금리'],
    },
    projects: {
      title: '진행 중인 프로젝트',
      description: 'Jarvis 봇, 사이드 프로젝트, 자동화 작업 등',
      keywords: ['jarvis', '봇', '디스코드', '자동화', '프로젝트', 'claude', 'mcp'],
    },
    preferences: {
      title: '선호도 & 습관',
      description: '음식, 생활 패턴, 좋아하는 것/싫어하는 것',
      keywords: ['좋아', '싫어', '선호', '즐겨', '매일', '습관', '루틴'],
    },
    health: {
      title: '건강 & 운동',
      description: '건강 상태, 운동 루틴, 식단',
      keywords: ['운동', '건강', '병원', '다이어트', '수면', '피로'],
    },
    travel: {
      title: '여행 & 계획',
      description: '여행 기록, 다음 여행 계획',
      keywords: ['여행', '해외', '항공', '숙소', '휴가'],
    },
  },
  crossRefEnabled: true,
  maxPageSizeKb: 20,
};

// ── 초기화 ───────────────────────────────────────────────────────────────────

export function initWiki() {
  mkdirSync(WIKI_ROOT, { recursive: true });
  if (!existsSync(SCHEMA_PATH)) {
    writeFileSync(SCHEMA_PATH, JSON.stringify(DEFAULT_SCHEMA, null, 2));
  }
}

export function getSchema() {
  try {
    return JSON.parse(readFileSync(SCHEMA_PATH, 'utf-8'));
  } catch {
    return DEFAULT_SCHEMA;
  }
}

// ── 페이지 경로 ───────────────────────────────────────────────────────────────

function pagePath(userId, pageKey) {
  return join(WIKI_ROOT, 'pages', userId, `${pageKey}.md`);
}

function userPagesDir(userId) {
  return join(WIKI_ROOT, 'pages', userId);
}

// ── CRUD 기본 ─────────────────────────────────────────────────────────────────

/**
 * 위키 페이지 읽기. 없으면 null.
 */
export function getPage(userId, pageKey) {
  const path = pagePath(userId, pageKey);
  if (!existsSync(path)) return null;
  try {
    return readFileSync(path, 'utf-8');
  } catch {
    return null;
  }
}

/**
 * 위키 페이지 저장. 없으면 생성.
 */
export function savePage(userId, pageKey, content) {
  const dir = userPagesDir(userId);
  mkdirSync(dir, { recursive: true });
  const path = pagePath(userId, pageKey);
  const timestamp = new Date().toISOString().slice(0, 19).replace('T', ' ');
  // 헤더가 없으면 자동 추가
  const schema = getSchema();
  const pageDef = schema.pages[pageKey];
  const title = pageDef?.title || pageKey;
  const header = `# ${title}\n> 마지막 업데이트: ${timestamp}\n\n`;
  const finalContent = content.startsWith('#') ? content : header + content;
  writeFileSync(path, finalContent);
}

/**
 * 모든 위키 페이지 목록 반환.
 */
export function listPages(userId) {
  const dir = userPagesDir(userId);
  if (!existsSync(dir)) return [];
  try {
    return readdirSync(dir)
      .filter(f => f.endsWith('.md'))
      .map(f => f.replace('.md', ''));
  } catch {
    return [];
  }
}

/**
 * 텍스트가 어느 페이지에 속하는지 키워드 기반으로 판단.
 * 복수 매칭 시 점수 높은 페이지 반환.
 */
export function detectPageKey(text, schema = null) {
  const s = schema || getSchema();
  const lText = text.toLowerCase();
  const scores = {};

  for (const [key, def] of Object.entries(s.pages)) {
    let score = 0;
    for (const kw of (def.keywords || [])) {
      if (lText.includes(kw.toLowerCase())) score++;
    }
    if (score > 0) scores[key] = score;
  }

  if (Object.keys(scores).length === 0) return 'profile'; // 기본값
  return Object.entries(scores).sort((a, b) => b[1] - a[1])[0][0];
}

/**
 * 하나의 fact를 적절한 위키 페이지에 추가.
 * 기존 페이지가 있으면 병합, 없으면 생성.
 *
 * @returns {string} 추가된 pageKey
 */
export function addFactToWiki(userId, fact, pageKeyOverride = null) {
  const schema = getSchema();
  const pageKey = pageKeyOverride || detectPageKey(fact, schema);
  const existing = getPage(userId, pageKey) || '';
  const timestamp = new Date().toISOString().slice(0, 10);

  // 중복 체크
  if (existing.includes(fact.trim())) return pageKey;

  const newEntry = `- [${timestamp}] ${fact.trim()}\n`;

  if (!existing) {
    // 새 페이지 생성
    const pageDef = schema.pages[pageKey];
    const title = pageDef?.title || pageKey;
    const content = `# ${title}\n> 마지막 업데이트: ${timestamp}\n\n## 기록\n${newEntry}`;
    savePage(userId, pageKey, content);
  } else {
    // 기존 페이지에 항목 추가
    const updatedContent = appendToSection(existing, '## 기록', newEntry, timestamp);
    savePage(userId, pageKey, updatedContent);
  }

  return pageKey;
}

/**
 * 섹션에 항목 추가. 섹션 없으면 생성.
 */
function appendToSection(content, sectionHeader, newEntry, timestamp) {
  // 마지막 업데이트 타임스탬프 갱신
  const updated = content.replace(
    /> 마지막 업데이트:.*/,
    `> 마지막 업데이트: ${timestamp}`
  );

  if (updated.includes(sectionHeader)) {
    // 섹션 끝에 추가
    const parts = updated.split(sectionHeader);
    const afterSection = parts[1] || '';
    // 다음 섹션 시작 전에 삽입
    const nextSectionIdx = afterSection.search(/\n## /);
    if (nextSectionIdx === -1) {
      return updated + newEntry;
    }
    const before = afterSection.slice(0, nextSectionIdx);
    const after = afterSection.slice(nextSectionIdx);
    return parts[0] + sectionHeader + before + newEntry + after;
  }

  // 섹션 없으면 끝에 추가
  return updated.trimEnd() + `\n\n${sectionHeader}\n${newEntry}`;
}

/**
 * 위키 전체 내용을 프롬프트용으로 반환.
 * 모든 페이지를 연결해 요약본으로.
 */
export function getWikiContext(userId, relevantQuery = '') {
  const pages = listPages(userId);
  if (pages.length === 0) return '';

  const schema = getSchema();
  const lines = ['## 위키 지식베이스'];

  // 쿼리와 관련도 높은 페이지 우선
  let orderedPages = pages;
  if (relevantQuery) {
    const pageKey = detectPageKey(relevantQuery, schema);
    orderedPages = [pageKey, ...pages.filter(p => p !== pageKey)];
  }

  for (const pk of orderedPages) {
    const content = getPage(userId, pk);
    if (!content) continue;
    const pageDef = schema.pages[pk];
    const title = pageDef?.title || pk;
    // 각 페이지에서 최대 500자만 포함 (컨텍스트 절약)
    const snippet = content.length > 500 ? content.slice(0, 500) + '...' : content;
    lines.push(`\n### [${title}]\n${snippet}`);
  }

  return lines.join('\n') + '\n\n';
}

/**
 * 위키 페이지 통계 반환.
 */
export function getWikiStats(userId) {
  const pages = listPages(userId);
  const stats = { totalPages: pages.length, pages: {} };
  for (const pk of pages) {
    const path = pagePath(userId, pk);
    try {
      const { size, mtimeMs } = statSync(path);
      stats.pages[pk] = {
        sizeKb: (size / 1024).toFixed(1),
        lastModified: new Date(mtimeMs).toISOString().slice(0, 10),
      };
    } catch {
      stats.pages[pk] = { sizeKb: 0, lastModified: null };
    }
  }
  return stats;
}

// 초기화 실행
initWiki();
