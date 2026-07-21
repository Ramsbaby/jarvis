#!/usr/bin/env node
// render.mjs — content.json → 교재 HTML 조립기 (preply-engine)
//
// 설계 원칙 (2026-07-11):
//   1. CSS·JS는 골드 스탠다드에서 바이트 그대로 추출한 템플릿(templates/) 사용 —
//      보람님이 승인한 스타일·채점 엔진을 LLM이 다시 쓰지 않는다 (재생성 사고 원천 차단).
//   2. 보람님 영구 규칙을 코드로 강제: 정답은 checkQ 불리언·ans-reveal로만 (텍스트 노출 불가),
//      italic 미사용(템플릿 CSS가 font-style:normal), 정적 HTML(+인쇄 CSS 템플릿 보존).
//   3. LLM은 content.json만 만들면 된다 — 100KB HTML은 이 스크립트가 찍는다.
//
// 사용: node render.mjs <content.json> <출력.html> [--head <head.tpl.html>] [--engine <engine.tpl.js>]

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const [inFile, outFile] = args;
if (!inFile || !outFile) {
  console.error('사용법: node render.mjs <content.json> <출력.html>');
  process.exit(1);
}
const opt = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : dflt;
};
const headTpl = readFileSync(opt('--head', join(HERE, 'templates', 'head.tpl.html')), 'utf-8');
const engineTpl = readFileSync(opt('--engine', join(HERE, 'templates', 'engine.tpl.js')), 'utf-8');
const doc = JSON.parse(readFileSync(inFile, 'utf-8'));

const styleAttr = (b) => (b.style ? ` style="${b.style}"` : '');

// ─── 섹션 자식 블록 렌더 ───
function renderSectionChild(b) {
  switch (b.t) {
    case 'title': return `    <div class="section-title"${styleAttr(b)}>${b.html}</div>`;
    case 'sub': return `    <div class="section-sub"${styleAttr(b)}>${b.html}</div>`;
    case 'badge': return `    <div class="time-badge"${styleAttr(b)}>${b.html}</div>`;
    case 'hint': return `    <div class="flip-hint"${styleAttr(b)}>${b.html}</div>`;
    case 'words': {
      const cards = b.items.map((w) =>
        `      <div class="word-card" onclick="this.classList.toggle('flipped')"><div class="word-kr">${w.kr}</div><div class="word-rom">${w.rom}</div><div class="word-en">${w.en}</div></div>`
      ).join('\n');
      return `    <div class="word-grid">\n${cards}\n    </div>`;
    }
    case 'grambox': {
      const ps = (b.ps || []).map((p) =>
        typeof p === 'string' ? `      <p>${p}</p>` : `      ${p.raw}`
      ).join('\n');
      return `    <div class="gram-box"${styleAttr(b)}>\n      <h3>${b.h3}</h3>\n${ps}\n    </div>`;
    }
    case 'pattern': return `    <div class="pattern"${styleAttr(b)}>${b.html}</div>`;
    case 'gexample': return `    <div class="gram-example"><div class="gem-kr">${b.kr}</div><div class="gem-en">${b.en}</div></div>`;
    case 'gtip': return `    <div class="gram-tip"${styleAttr(b)}>${b.html}</div>`;
    case 'expr': return `    <div class="expr-box"><div class="expr-kr">${b.kr}</div><div class="expr-rom">${b.rom}</div><div class="expr-en">${b.en}</div></div>`;
    case 'dialogue': {
      const lines = b.lines.map((l) =>
        `      <div class="d-line"><div class="d-who">${l.who}</div><div><div class="d-kr">${l.kr}</div><div class="d-en">${l.en}</div></div></div>`
      ).join('\n');
      return `    <div class="dialogue-box">\n      <div class="dlg-title">${b.title}</div>\n${lines}\n    </div>`;
    }
    case 'roleplay': {
      const parts = (b.parts || []).map((p) => {
        if (p.k === 'prompt') return `      <p class="rp-prompt">${p.html}</p>`;
        if (p.k === 'hint') return `      <p class="rp-hint">${p.html}</p>`;
        return `      ${p.html}`;
      }).join('\n');
      return `    <div class="roleplay-box">\n      <div class="roleplay-title">${b.title}</div>\n${parts}\n    </div>`;
    }
    case 'culture': {
      const parts = (b.parts || []).map((p) => {
        if (p.k === 'en') return `      <p class="culture-en">${p.html}</p>`;
        if (p.k === 'p') return `      <p>${p.html}</p>`;
        return `      ${p.html}`;
      }).join('\n');
      return `    <div class="culture-box">\n      <div class="culture-title">${b.title}</div>\n${parts}\n    </div>`;
    }
    case 'compare': {
      const rows = (b.rows || []).map((r) =>
        `      <div class="compare-row"><span class="flag-${r.flag}">${r.label}</span><span class="compare-text">${r.html}</span></div>`
      );
      const notes = (b.notes || []).map((n) => `      <p class="compare-note">${n}</p>`);
      return `    <div class="compare-box">\n      <div class="compare-title">${b.title}</div>\n${[...rows, ...notes].join('\n')}\n    </div>`;
    }
    case 'quiz': {
      const items = b.items.map((i) => {
        // 🛡️ 정답 노출 하드 가드: 보기 텍스트에 정답 마커 금지 (영구 규칙 — 렌더 단계 강제)
        for (const o of i.opts || []) {
          if (/✓|✅|\(정답\)|<strong>정답/.test(o.html)) {
            throw new Error(`정답 마커가 보기 텍스트에 있음 (영구 규칙 위반): ${o.html}`);
          }
        }
        const correctCount = (i.opts || []).filter((o) => o.correct).length;
        if (i.opts && correctCount !== 1) {
          throw new Error(`정답이 정확히 1개가 아님 (${correctCount}개): ${i.q}`);
        }
        let inner = `<div class="q-text">${i.q}</div>`;
        if (i.opts) {
          const opts = i.opts.map((o) =>
            `<button class="quiz-opt" onclick="checkQ(this,${o.correct ? 'true' : 'false'})">${o.html}</button>`
          ).join('');
          inner += `<div class="quiz-options">${opts}</div>`;
        }
        if (i.reveal !== undefined && i.reveal !== null) {
          inner += `<button class="ans-btn" onclick="toggleAns(this)">정답 보기 🔍</button><div class="ans-reveal">${i.reveal}</div>`;
        }
        return `      <div class="quiz-q">${inner}</div>`;
      }).join('\n');
      return `    <div class="quiz-section">\n${items}\n    </div>`;
    }
    case 'raw': return b.html.split('\n').map((l) => `    ${l}`).join('\n');
    default: throw new Error(`알 수 없는 블록 타입: ${b.t}`);
  }
}

// ─── 유닛 최상위 블록 렌더 ───
function renderUnitChild(b) {
  if (b.t === 'banner') {
    return [
      '<div class="unit-banner-wrap">',
      `  <img src="${b.img_src}" alt="${b.img_alt}" onerror="this.style.display='none'">`,
      '  <div class="unit-banner-overlay">',
      `    <h2>${b.h2}</h2>`,
      `    <p>${b.p}</p>`,
      '  </div>',
      '</div>',
    ].join('\n');
  }
  if (b.t === 'section') {
    const children = b.children.map(renderSectionChild).join('\n');
    return `  <div class="section"${styleAttr(b)}>\n${children}\n  </div>`;
  }
  if (b.t === 'raw') return b.html;
  throw new Error(`알 수 없는 유닛 블록: ${b.t}`);
}

// ─── 조립 ───
const parts = [];
parts.push(headTpl.trimEnd());
parts.push('<body>');
parts.push('');
if (doc.cover) parts.push(`<div class="cover">\n${doc.cover.html.split('\n').map((l) => `  ${l.trim() ? l : ''}`).join('\n')}\n</div>`);
parts.push('');
if (doc.tabs?.length) {
  const tabs = doc.tabs.map((t, i) =>
    `  <div class="unit-tab${t.active ? ' active' : ''}" onclick="showUnit(${i})">${t.label}</div>`
  ).join('\n');
  parts.push(`<div class="unit-tabs">\n${tabs}\n</div>`);
}
parts.push('');
for (const u of doc.units) {
  if (u._stray) { parts.push(u.blocks.map((b) => b.html).join('\n')); continue; }
  const blocks = u.blocks.map(renderUnitChild).join('\n');
  parts.push(`<div class="unit-content${u.active ? ' active' : ''}">\n${blocks}\n</div>`);
  parts.push('');
}
parts.push(`<script>\n${engineTpl.trimEnd()}\n</script>`);
parts.push('</body>');

writeFileSync(outFile, parts.join('\n') + '\n', 'utf-8');
console.log(`✅ 렌더 완료: ${outFile} (${Buffer.byteLength(parts.join('\n'))} bytes)`);
