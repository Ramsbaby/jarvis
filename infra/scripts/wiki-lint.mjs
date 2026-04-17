#!/usr/bin/env node
/**
 * wiki-lint.mjs — 위키 품질 점검기
 *
 * 크론 스케줄: 일요일 04:00 KST (LaunchAgent ai.jarvis.wiki-lint)
 * 수동 실행: node wiki-lint.mjs
 *
 * 점검 항목:
 *   1. orphan    — index.md에 등록되지 않은 페이지
 *   2. oversized — maxPageSizeKb 초과 페이지
 *   3. broken-crossref — [[...]] 크로스 레퍼런스 깨짐
 *   4. missing-frontmatter — _summary.md에 필수 YAML 필드 누락
 *   5. stale     — 30일 이상 미갱신 _summary.md
 *   6. empty     — 내용 20자 미만 페이지
 *   7. duplicate — 동일 fact 중복 감지
 *
 * Phase 8 (선택): LLM 기반 모순 검출 (--deep 플래그)
 *
 * Log: ~/jarvis/runtime/logs/wiki-lint.log
 * Report: ~/jarvis/runtime/wiki/meta/lint-{date}.md
 */

import {
  readFileSync, writeFileSync, existsSync, readdirSync,
  statSync, mkdirSync, appendFileSync,
} from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { getSchema, WIKI_ROOT } from '../discord/lib/wiki-engine.mjs';

// ── 설정 ─────────────────────────────────────────────────────────────────────
const BOT_HOME  = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const LOG_FILE  = join(BOT_HOME, 'logs', 'wiki-lint.log');
const META_DIR  = join(WIKI_ROOT, 'meta');
const INDEX_FILE = join(WIKI_ROOT, 'index.md');

const MAX_PAGE_CHARS = 3000;
const STALE_DAYS     = 30;
const DEEP_MODE      = process.argv.includes('--deep');

// ── 로거 (KST) ───────────────────────────────────────────────────────────────
function kstNow() {
  return new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' });
}

function log(msg) {
  const line = `[${kstNow()}] wiki-lint: ${msg}\n`;
  try {
    mkdirSync(dirname(LOG_FILE), { recursive: true });
    appendFileSync(LOG_FILE, line);
  } catch { /* best-effort */ }
  process.stderr.write(line);
}

// ── 위키 페이지 수집 ─────────────────────────────────────────────────────────
function collectPages() {
  const pages = [];
  const schema = getSchema();
  const domains = Object.keys(schema.domains || {});

  for (const domain of domains) {
    const dir = join(WIKI_ROOT, domain);
    if (!existsSync(dir)) continue;

    let files;
    try { files = readdirSync(dir).filter(f => f.endsWith('.md')); } catch { continue; }

    for (const f of files) {
      const fullPath = join(dir, f);
      try {
        const st = statSync(fullPath);
        const content = readFileSync(fullPath, 'utf-8');
        pages.push({
          domain,
          file: f,
          relativePath: `${domain}/${f}`,
          fullPath,
          content,
          size: content.length,
          mtime: st.mtimeMs,
        });
      } catch { /* skip unreadable */ }
    }
  }

  return pages;
}

// ── index.md 등록 목록 파싱 ──────────────────────────────────────────────────
function parseIndex() {
  if (!existsSync(INDEX_FILE)) return new Set();
  const content = readFileSync(INDEX_FILE, 'utf-8');
  const refs = new Set();
  const linkRe = /\[([^\]]+)\]\(([^)]+)\)/g;
  let m;
  while ((m = linkRe.exec(content))) {
    refs.add(m[2]);
  }
  return refs;
}

// ── 점검 함수들 ──────────────────────────────────────────────────────────────

function checkOrphan(pages, indexRefs) {
  const issues = [];
  for (const p of pages) {
    if (p.domain === 'meta') continue; // meta는 index 등록 불필요
    if (!indexRefs.has(p.relativePath)) {
      issues.push({ type: 'orphan', page: p.relativePath, msg: 'index.md에 등록되지 않은 페이지' });
    }
  }
  return issues;
}

function checkOversized(pages) {
  const issues = [];
  for (const p of pages) {
    if (p.size > MAX_PAGE_CHARS) {
      issues.push({
        type: 'oversized',
        page: p.relativePath,
        msg: `${p.size}자 (상한 ${MAX_PAGE_CHARS}자) → 분할 권장`,
      });
    }
  }
  return issues;
}

function checkBrokenCrossref(pages) {
  const issues = [];
  const allPaths = new Set(pages.map(p => p.relativePath));

  for (const p of pages) {
    const refRe = /\[\[([^\]]+)\]\]/g;
    let m;
    while ((m = refRe.exec(p.content))) {
      const ref = m[1];
      // 도메인/파일 형식이면 존재 여부 확인
      if (ref.includes('/') && !allPaths.has(ref) && !allPaths.has(ref + '.md')) {
        issues.push({
          type: 'broken-crossref',
          page: p.relativePath,
          msg: `깨진 cross-reference: [[${ref}]]`,
        });
      }
    }
  }
  return issues;
}

function checkMissingFrontmatter(pages) {
  const issues = [];
  const required = ['title', 'domain', 'type'];

  for (const p of pages) {
    if (!p.file.startsWith('_summary')) continue; // summary만 frontmatter 필수
    if (!p.content.startsWith('---')) {
      issues.push({
        type: 'missing-frontmatter',
        page: p.relativePath,
        msg: `필수 필드 누락: ${required.join(', ')}`,
      });
      continue;
    }

    const fmEnd = p.content.indexOf('---', 3);
    if (fmEnd < 0) continue;
    const fm = p.content.slice(3, fmEnd);

    const missing = required.filter(f => !fm.includes(`${f}:`));
    if (missing.length) {
      issues.push({
        type: 'missing-frontmatter',
        page: p.relativePath,
        msg: `필수 필드 누락: ${missing.join(', ')}`,
      });
    }
  }
  return issues;
}

function checkStale(pages) {
  const issues = [];
  const cutoff = Date.now() - STALE_DAYS * 86400_000;

  for (const p of pages) {
    if (!p.file.startsWith('_summary')) continue;
    if (p.mtime < cutoff) {
      const days = Math.floor((Date.now() - p.mtime) / 86400_000);
      issues.push({
        type: 'stale',
        page: p.relativePath,
        msg: `${days}일 미갱신 (_summary.md)`,
      });
    }
  }
  return issues;
}

function checkEmpty(pages) {
  const issues = [];
  for (const p of pages) {
    if (p.size < 20) {
      issues.push({ type: 'empty', page: p.relativePath, msg: `내용 ${p.size}자 (최소 20자)` });
    }
  }
  return issues;
}

function checkDuplicateFacts(pages) {
  const issues = [];
  for (const p of pages) {
    if (!p.file.startsWith('_facts')) continue;
    const lines = p.content.split('\n').filter(l => l.startsWith('- ['));
    const seen = new Map();
    for (const line of lines) {
      // fact 본문만 추출 (날짜/source 태그 제거)
      const factBody = line.replace(/^- \[\d{4}-\d{2}-\d{2}\]\s*(\[source:[^\]]*\]\s*)?/, '').trim();
      if (factBody.length < 10) continue;
      if (seen.has(factBody)) {
        const count = seen.get(factBody) + 1;
        seen.set(factBody, count);
        if (count === 2) { // 첫 중복만 보고
          issues.push({
            type: 'duplicate',
            page: p.relativePath,
            msg: `중복 fact: "${factBody.slice(0, 60)}..."`,
          });
        }
      } else {
        seen.set(factBody, 1);
      }
    }
  }
  return issues;
}

// ── 리포트 생성 ──────────────────────────────────────────────────────────────
function generateReport(pages, issues) {
  const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Seoul' });
  const errors = issues.filter(i => ['broken-crossref', 'empty'].includes(i.type));
  const warnings = issues.filter(i => !['broken-crossref', 'empty'].includes(i.type));

  const lines = [
    '---',
    `title: "Wiki Lint Report — ${today}"`,
    'domain: meta',
    'type: lint-report',
    `created: "${today}"`,
    '---',
    '',
    `# Wiki Lint Report — ${today}`,
    '',
    `**페이지**: ${pages.length}개 | **에러**: ${errors.length} | **경고**: ${warnings.length}`,
    '',
  ];

  if (!issues.length) {
    lines.push('모든 점검 통과.');
  } else {
    const grouped = {};
    for (const issue of issues) {
      if (!grouped[issue.type]) grouped[issue.type] = [];
      grouped[issue.type].push(issue);
    }
    for (const [type, items] of Object.entries(grouped)) {
      lines.push(`## ${type} (${items.length}건)`);
      for (const item of items) {
        lines.push(`- **${item.page}** — ${item.msg}`);
      }
      lines.push('');
    }
  }

  mkdirSync(META_DIR, { recursive: true });
  const reportPath = join(META_DIR, `lint-${today}.md`);
  writeFileSync(reportPath, lines.join('\n'), 'utf-8');
  log(`리포트 저장: ${reportPath}`);
  return reportPath;
}

// ── main ─────────────────────────────────────────────────────────────────────
function main() {
  const pages = collectPages();
  log(`=== wiki-lint 시작 (${pages.length}개 페이지) ===`);

  const indexRefs = parseIndex();

  const issues = [
    ...checkOrphan(pages, indexRefs),
    ...checkOversized(pages),
    ...checkBrokenCrossref(pages),
    ...checkMissingFrontmatter(pages),
    ...checkStale(pages),
    ...checkEmpty(pages),
    ...checkDuplicateFacts(pages),
  ];

  if (DEEP_MODE) {
    log('Phase 8: LLM 모순 검출 (--deep) — 미구현, 스킵');
  }

  const errors = issues.filter(i => ['broken-crossref', 'empty'].includes(i.type));
  const warnings = issues.filter(i => !['broken-crossref', 'empty'].includes(i.type));
  const infos = []; // future use

  log(`결과: ${pages.length}개 페이지, ${errors.length} 에러, ${warnings.length} 경고, ${infos.length} 정보`);

  for (const issue of issues) {
    const level = ['broken-crossref', 'empty'].includes(issue.type) ? 'ERR' : '!';
    log(`  [${level}] ${issue.type}: ${issue.page} — ${issue.msg}`);
  }

  generateReport(pages, issues);
  log('=== wiki-lint 완료 ===');

  // 에러가 있으면 stdout으로 요약 출력 (크론 → Discord 전송용)
  if (errors.length > 0) {
    const summary = errors.map(e => `- ${e.page}: ${e.msg}`).join('\n');
    console.log(`Wiki Lint: ${errors.length}개 에러 발견\n${summary}`);
  }
}

main();