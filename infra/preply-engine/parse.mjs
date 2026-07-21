#!/usr/bin/env node
// parse.mjs — 교재 HTML → content.json 역변환기 (preply-engine)
//
// 설계 원칙 (2026-07-11 · 529만 토큰/주 낭비 근절 프로젝트):
//   1. 아는 블록은 구조화(JSON), 모르는 블록은 raw HTML 통과 — 콘텐츠 소실 원리적 불가.
//   2. 텍스트 필드는 innerHTML 그대로 보존 (인라인 <strong>·이모지·엔티티 왕복 손실 방지).
//   3. 이 파서는 "읽기 전용" — 원본 HTML을 절대 수정하지 않는다.
//
// 사용: node parse.mjs <교재.html> <출력.content.json>

import { parse } from 'node-html-parser';
import { readFileSync, writeFileSync } from 'node:fs';

const [, , inFile, outFile] = process.argv;
if (!inFile || !outFile) {
  console.error('사용법: node parse.mjs <교재.html> <출력.content.json>');
  process.exit(1);
}

const html = readFileSync(inFile, 'utf-8');
const root = parse(html);

const cls = (el) => (el.getAttribute?.('class') || '').trim();
const hasCls = (el, name) => cls(el).split(/\s+/).includes(name);
const inner = (el) => (el ? el.innerHTML.trim() : null);
const styleAttr = (el) => el.getAttribute?.('style') || null;

// ─── 섹션 자식 블록 분류기 ───
function parseSectionChild(el) {
  if (el.nodeType !== 1) return null; // 요소 노드만
  const s = styleAttr(el);
  const withStyle = (obj) => (s ? { ...obj, style: s } : obj);

  if (hasCls(el, 'section-title')) return withStyle({ t: 'title', html: inner(el) });
  if (hasCls(el, 'section-sub')) return withStyle({ t: 'sub', html: inner(el) });
  if (hasCls(el, 'time-badge')) return withStyle({ t: 'badge', html: inner(el) });
  if (hasCls(el, 'flip-hint')) return withStyle({ t: 'hint', html: inner(el) });

  if (hasCls(el, 'word-grid')) {
    const items = el.querySelectorAll('.word-card').map((c) => ({
      kr: inner(c.querySelector('.word-kr')),
      rom: inner(c.querySelector('.word-rom')),
      en: inner(c.querySelector('.word-en')),
    }));
    return { t: 'words', items };
  }

  if (hasCls(el, 'gram-box')) {
    // :scope 미지원 파서 대응 — 직계 자식만 수동 필터 (h3 외 P/기타 순서 보존)
    const ps = [];
    for (const c of el.childNodes) {
      if (c.nodeType !== 1 || c.tagName === 'H3') continue;
      if (c.tagName === 'P') ps.push(inner(c));
      else ps.push({ raw: c.outerHTML }); // P 아닌 직계 자식(커스텀 div 등)도 순서대로 보존
    }
    return withStyle({ t: 'grambox', h3: inner(el.querySelector('h3')), ps });
  }
  if (hasCls(el, 'pattern')) return withStyle({ t: 'pattern', html: inner(el) });
  if (hasCls(el, 'gram-example')) {
    return {
      t: 'gexample',
      kr: inner(el.querySelector('.gem-kr')),
      en: inner(el.querySelector('.gem-en')),
    };
  }
  if (hasCls(el, 'gram-tip')) return withStyle({ t: 'gtip', html: inner(el) });

  if (hasCls(el, 'expr-box')) {
    return {
      t: 'expr',
      kr: inner(el.querySelector('.expr-kr')),
      rom: inner(el.querySelector('.expr-rom')),
      en: inner(el.querySelector('.expr-en')),
    };
  }

  if (hasCls(el, 'dialogue-box')) {
    return {
      t: 'dialogue',
      title: inner(el.querySelector('.dlg-title')),
      lines: el.querySelectorAll('.d-line').map((l) => ({
        who: inner(l.querySelector('.d-who')),
        kr: inner(l.querySelector('.d-kr')),
        en: inner(l.querySelector('.d-en')),
      })),
    };
  }

  if (hasCls(el, 'roleplay-box')) {
    const parts = [];
    for (const c of el.childNodes) {
      if (c.nodeType !== 1) continue;
      if (hasCls(c, 'roleplay-title')) continue; // title은 별도 필드
      if (hasCls(c, 'rp-prompt')) parts.push({ k: 'prompt', html: inner(c) });
      else if (hasCls(c, 'rp-hint')) parts.push({ k: 'hint', html: inner(c) });
      else parts.push({ k: 'raw', html: c.outerHTML });
    }
    return { t: 'roleplay', title: inner(el.querySelector('.roleplay-title')), parts };
  }

  if (hasCls(el, 'culture-box')) {
    const parts = [];
    for (const c of el.childNodes) {
      if (c.nodeType !== 1) continue;
      if (hasCls(c, 'culture-title')) continue;
      if (hasCls(c, 'culture-en')) parts.push({ k: 'en', html: inner(c) });
      else if (c.tagName === 'P') parts.push({ k: 'p', html: inner(c) });
      else parts.push({ k: 'raw', html: c.outerHTML });
    }
    return { t: 'culture', title: inner(el.querySelector('.culture-title')), parts };
  }

  if (hasCls(el, 'compare-box')) {
    const rows = [];
    const notes = [];
    for (const c of el.childNodes) {
      if (c.nodeType !== 1) continue;
      if (hasCls(c, 'compare-row')) {
        const flagEl = c.querySelector('.flag-kr, .flag-us');
        rows.push({
          flag: hasCls(flagEl, 'flag-kr') ? 'kr' : 'us',
          label: inner(flagEl),
          html: inner(c.querySelector('.compare-text')),
        });
      } else if (hasCls(c, 'compare-note')) notes.push(inner(c));
    }
    return { t: 'compare', title: inner(el.querySelector('.compare-title')), rows, notes };
  }

  if (hasCls(el, 'quiz-section')) {
    const items = el.querySelectorAll('.quiz-q').map((q) => {
      const item = { q: inner(q.querySelector('.q-text')) };
      const opts = q.querySelector('.quiz-options');
      if (opts) {
        item.opts = opts.querySelectorAll('.quiz-opt').map((o) => ({
          html: inner(o),
          correct: /checkQ\(this,\s*true\)/.test(o.getAttribute('onclick') || ''),
        }));
      }
      const reveal = q.querySelector('.ans-reveal');
      if (reveal) item.reveal = inner(reveal);
      return item;
    });
    return { t: 'quiz', items };
  }

  // 미분류 = 원문 통과 (member-grid·skz-banner·food-img-grid·인라인 스타일 커스텀 블록 등)
  return { t: 'raw', html: el.outerHTML };
}

// ─── 유닛 최상위 블록 분류기 ───
function parseUnitChild(el) {
  if (el.nodeType !== 1) return null;
  if (hasCls(el, 'unit-banner-wrap')) {
    const img = el.querySelector('img');
    const ov = el.querySelector('.unit-banner-overlay');
    return {
      t: 'banner',
      img_src: img?.getAttribute('src') || null,
      img_alt: img?.getAttribute('alt') || null,
      h2: inner(ov?.querySelector('h2')),
      p: inner(ov?.querySelector('p')),
    };
  }
  if (hasCls(el, 'section')) {
    const children = [];
    for (const c of el.childNodes) {
      const b = parseSectionChild(c);
      if (b) children.push(b);
    }
    const s = styleAttr(el);
    return s ? { t: 'section', style: s, children } : { t: 'section', children };
  }
  return { t: 'raw', html: el.outerHTML };
}

// ─── 본문 파싱 ───
const body = root.querySelector('body');
if (!body) { console.error('body 없음'); process.exit(1); }

const doc = { source: inFile, cover: null, tabs: [], units: [] };

for (const el of body.childNodes) {
  if (el.nodeType !== 1) continue;
  if (hasCls(el, 'cover')) {
    doc.cover = { html: inner(el) }; // 커버는 학생별 통짜 보존 (구조 단순·저빈도 수정)
  } else if (hasCls(el, 'unit-tabs')) {
    doc.tabs = el.querySelectorAll('.unit-tab').map((t) => ({
      label: inner(t),
      active: hasCls(t, 'active'),
    }));
  } else if (hasCls(el, 'unit-content')) {
    const blocks = [];
    for (const c of el.childNodes) {
      const b = parseUnitChild(c);
      if (b) blocks.push(b);
    }
    doc.units.push({ active: hasCls(el, 'active'), blocks });
  } else if (el.tagName === 'SCRIPT') {
    // JS 엔진은 템플릿(engine.tpl.js)이 담당 — content에 저장 안 함
  } else {
    doc.units.push({ _stray: true, blocks: [{ t: 'raw', html: el.outerHTML }] });
  }
}

// ─── 통계 출력 (검증용) ───
const stats = { units: doc.units.length, tabs: doc.tabs.length };
let words = 0, quizzes = 0, opts = 0, compares = 0, dialogues = 0, exprs = 0, raws = 0;
for (const u of doc.units) for (const b of u.blocks) {
  const walk = (blk) => {
    if (blk.t === 'words') words += blk.items.length;
    if (blk.t === 'quiz') { quizzes += blk.items.length; for (const i of blk.items) opts += (i.opts || []).length; }
    if (blk.t === 'compare') compares += 1;
    if (blk.t === 'dialogue') dialogues += 1;
    if (blk.t === 'expr') exprs += 1;
    if (blk.t === 'raw') raws += 1;
    if (blk.t === 'section') for (const c of blk.children) walk(c);
  };
  walk(b);
}
Object.assign(stats, { words, quizzes, quiz_opts: opts, compare_boxes: compares, dialogue_boxes: dialogues, expr_boxes: exprs, raw_passthrough: raws });

writeFileSync(outFile, JSON.stringify(doc, null, 1), 'utf-8');
console.log('✅ 역변환 완료:', JSON.stringify(stats));
