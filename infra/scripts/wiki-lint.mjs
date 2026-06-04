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

// [2026-05-31 세컨브레인 벤치마킹] --fix 자가치유 모드:
//   oversized _facts.md의 오래된 fact를 분기별 archive/_facts-{YYYY-Q}.md로 이동(원본 보존, 활성만 슬림화).
//   DRYRUN 기본(미리보기) — 실제 이동은 --apply 동반 시에만. append-only 철학: 삭제 아닌 이동.
const FIX_MODE       = process.argv.includes('--fix');
const APPLY_MODE     = process.argv.includes('--apply');
const ACTIVE_MONTHS  = parseInt(process.env.WIKI_ACTIVE_MONTHS || '3', 10); // 활성 보존 개월 (env 오버라이드)

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

// ── [2026-05-31] --fix 자가치유: oversized _facts.md 분기 아카이빙 ─────────────
// 오래된 fact를 archive/_facts-{YYYY-Q}.md로 이동(원본 보존). 활성 파일은 최근 ACTIVE_MONTHS만.
// dryRun=true면 미리보기만. 삭제 아닌 이동이라 가역(Iron Law 3 결재권 비침범).
function archiveOversizedFacts(pages, dryRun) {
  const cutoff = new Date();
  cutoff.setMonth(cutoff.getMonth() - ACTIVE_MONTHS);
  const cutoffStr = cutoff.toLocaleDateString('sv-SE', { timeZone: 'Asia/Seoul' }); // YYYY-MM-DD

  const results = [];
  for (const p of pages) {
    if (!p.file.startsWith('_facts')) continue;
    if (p.size <= MAX_PAGE_CHARS) continue; // oversized만 대상

    const lines = p.content.split('\n');
    const header = [];
    const active = [];
    const archived = {}; // 'YYYY-QN' -> [lines]
    let sawFact = false;

    for (const line of lines) {
      const m = line.match(/^- \[(\d{4})-(\d{2})-(\d{2})\]/);
      if (m) {
        sawFact = true;
        const date = `${m[1]}-${m[2]}-${m[3]}`;
        if (date >= cutoffStr) {
          active.push(line);
        } else {
          const q = Math.ceil(parseInt(m[2], 10) / 3);
          (archived[`${m[1]}-Q${q}`] ||= []).push(line);
        }
      } else if (!sawFact) {
        header.push(line); // fact 시작 전 frontmatter/제목 보존
      } else {
        active.push(line); // fact 사이 빈줄·연속줄은 활성 유지
      }
    }

    const archivedCount = Object.values(archived).reduce((s, a) => s + a.length, 0);
    if (archivedCount === 0) continue;

    const result = {
      page: p.relativePath,
      activeFacts: active.filter(l => l.startsWith('- [')).length,
      archivedFacts: archivedCount,
      quarters: Object.keys(archived).sort(),
      applied: false,
    };

    if (!dryRun) {
      const archiveDir = join(WIKI_ROOT, p.domain, 'archive');
      mkdirSync(archiveDir, { recursive: true });
      for (const [q, qlines] of Object.entries(archived)) {
        const archivePath = join(archiveDir, `_facts-${q}.md`);
        const banner = existsSync(archivePath) ? '' : `# ${p.domain} facts archive — ${q}\n\n`;
        appendFileSync(archivePath, banner + qlines.join('\n') + '\n');
      }
      writeFileSync(p.fullPath, [...header, ...active].join('\n'), 'utf-8');
      result.applied = true;
    }

    results.push(result);
  }
  return results;
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

  if (FIX_MODE) {
    // [2026-05-31 CRITICAL 가드] archive 분할 시 검색 경로 손실 차단.
    // 위키 직접 주입(prompt-sections.js L533/762, wiki-engine getWikiContext)은 _facts.md만 읽고
    // archive를 무시한다. archive로 옮긴 오래된 fact는 위키 빠른 검색에서 증발한다.
    // 사고(2026-05-31): --apply로 career 4월 fact 4343개를 archive로 옮겼더니 위키 주입·RAG(미재색인)
    //   모두에서 검색 불가 → 즉시 롤백. 검색 경로가 archive를 처리하도록 보강(Phase 2: summary 색인화
    //   + 위키 주입 archive fallback)하기 전엔 --apply 영구 차단.
    if (APPLY_MODE && process.env.WIKI_FIX_SEARCH_READY !== '1') {
      log('🔴 --apply 차단: 검색 경로가 archive 미지원 — 분할 시 오래된 fact 검색 증발(05-31 4343개 손실 사고). Phase 2 보강 후 WIKI_FIX_SEARCH_READY=1로만 실행.');
      console.error('BLOCKED: archive 분할 시 위키 검색에서 fact 증발. 검색 경로 보강(prompt-sections archive fallback + RAG 재색인) 후 WIKI_FIX_SEARCH_READY=1 재시도.');
      return;
    }
    const dryRun = !APPLY_MODE;
    const fixResults = archiveOversizedFacts(pages, dryRun);
    const mode = dryRun ? 'DRYRUN(미리보기)' : 'APPLY(실제 이동)';
    log(`--fix ${mode}: oversized _facts.md ${fixResults.length}개 대상`);
    for (const r of fixResults) {
      log(`  [FIX] ${r.page}: ${r.archivedFacts}개 fact → archive(${r.quarters.join(',')}) 이동${r.applied ? ' 완료' : ' 예정'}, 활성 ${r.activeFacts}개 유지`);
    }
    if (fixResults.length) {
      console.log(`\n[wiki-lint --fix ${mode}] ${fixResults.length}개 oversized 파일 정리${dryRun ? ' 예정' : ' 완료'}:`);
      for (const r of fixResults) {
        console.log(`  - ${r.page}: ${r.archivedFacts}개 fact → archive(${r.quarters.join(', ')}), 활성 ${r.activeFacts}개 유지`);
      }
      if (dryRun) console.log('  실제 이동하려면: node wiki-lint.mjs --fix --apply');
    } else {
      console.log('[wiki-lint --fix] 아카이빙 대상 없음 (oversized _facts.md 없거나 전부 최근 3개월 이내)');
    }
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