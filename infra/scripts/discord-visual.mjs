#!/usr/bin/env node
// discord-visual.mjs — Jarvis Discord 시각화 카드 전송 유틸리티
// 사용: node discord-visual.mjs --type <type> --data '<json>' [--channel <ch>] [--message '<text>']
// 타입: system-doctor | disk | rag-health | stats

import puppeteer from 'puppeteer-core';
import { readFileSync, writeFileSync, unlinkSync, existsSync } from 'fs';
import { tmpdir, homedir } from 'os';
import { join } from 'path';

// ── CLI 인수 파싱 ──────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const getArg = (flag) => { const i = args.indexOf(flag); return i !== -1 ? args[i + 1] : null; };

const TYPE    = getArg('--type');
const DATA_RAW = getArg('--data');
const CHANNEL = getArg('--channel') || 'jarvis-system';
const CAPTION = getArg('--message') || '';

if (!TYPE || !DATA_RAW) {
  console.error('Usage: discord-visual.mjs --type <type> --data \'<json>\' [--channel <ch>] [--message <text>]');
  process.exit(1);
}

let DATA;
try { DATA = JSON.parse(DATA_RAW); }
catch (e) { console.error('ERROR: --data must be valid JSON:', e.message); process.exit(1); }

// ── 웹훅 URL 로드 ─────────────────────────────────────────────────────────
const CONFIG_PATH = join(homedir(), 'jarvis/runtime', 'config', 'monitoring.json');
const config = JSON.parse(readFileSync(CONFIG_PATH, 'utf-8'));
const WEBHOOK_URL = config.webhooks?.[CHANNEL] ?? config.webhook?.url;
if (!WEBHOOK_URL) { console.error(`ERROR: No webhook for channel '${CHANNEL}'`); process.exit(1); }

// ── 공통 스타일 ────────────────────────────────────────────────────────────
const BASE_STYLE = `
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Apple SD Gothic Neo','Noto Sans KR',-apple-system,sans-serif;
         background: #0f1117; color: #e2e8f0; padding: 24px 22px; }
  .title    { font-size: 17px; font-weight: 700; color: #7dd3fc; }
  .subtitle { font-size: 11px; color: #64748b; margin-top: 3px; margin-bottom: 16px; }
`;

// ── HTML 템플릿: system-doctor ─────────────────────────────────────────────
function buildSystemDoctorHTML(d) {
  const COLOR = { OK: '#22c55e', WARN: '#f59e0b', FAIL: '#ef4444' };
  const BG    = { OK: '#14532d1a', WARN: '#78350f1a', FAIL: '#7f1d1d1a' };
  const ICON  = { OK: '✅', WARN: '⚠️', FAIL: '❌' };

  // 스키마 유연성: doctor 스킬은 summary.findings/healthy 문자열 배열을 보냄 → items로 합성
  let items = Array.isArray(d.items) ? d.items : null;
  if (!items && d.summary) {
    items = [];
    for (const f of (d.summary.findings || [])) {
      const status = f.startsWith('🔴') ? 'FAIL' : 'WARN';
      items.push({ item: f.replace(/^[🔴🟡⚠️❌]\s*/, ''), status, note: '' });
    }
    for (const h of (d.summary.healthy || [])) {
      items.push({ item: h.replace(/^[✅]\s*/, ''), status: 'OK', note: '' });
    }
  }
  items = items || [];

  const okN   = items.filter(i => i.status === 'OK').length;
  const warnN = items.filter(i => i.status === 'WARN').length;
  const failN = items.filter(i => i.status === 'FAIL').length;
  const overIcon = failN > 0 ? '❌' : warnN > 0 ? '⚠️' : '✅';

  const rows = items.map(({ item, status, note }) => `
    <div style="display:flex;align-items:center;gap:10px;padding:8px 12px;border-radius:7px;
                margin-bottom:5px;background:${BG[status]||'#1e293b'};border-left:3px solid ${COLOR[status]||'#475569'}">
      <span style="flex:1;font-size:12px;color:#cbd5e1;font-family:monospace">${item}</span>
      <span style="font-size:11px;font-weight:700;color:${COLOR[status]||'#94a3b8'};white-space:nowrap">${ICON[status]||''} ${status}</span>
      <span style="flex:2;font-size:11px;color:#94a3b8;text-align:right">${note}</span>
    </div>`).join('');

  return `<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8"><style>${BASE_STYLE}
  .chips { display:flex; gap:10px; flex-wrap:wrap; margin-bottom:14px; }
  .chip  { padding:5px 12px; border-radius:16px; font-size:12px; font-weight:600; }
  </style></head><body>
  <div class="title">${overIcon} Jarvis 시스템 점검</div>
  <div class="subtitle">${d.timestamp || ''}</div>
  <div class="chips">
    <span class="chip" style="background:#14532d33;color:#4ade80">✅ 정상 ${okN}</span>
    ${warnN > 0 ? `<span class="chip" style="background:#78350f33;color:#fbbf24">⚠️ 경고 ${warnN}</span>` : ''}
    ${failN > 0 ? `<span class="chip" style="background:#7f1d1d33;color:#f87171">❌ 실패 ${failN}</span>` : ''}
  </div>
  ${rows}
  </body></html>`;
}

// ── HTML 템플릿: disk ──────────────────────────────────────────────────────
function buildDiskHTML(d) {
  const pct = d.pct || 0;
  const barColor = pct > 90 ? '#ef4444' : pct > 80 ? '#f59e0b' : '#22c55e';
  const icon = pct > 90 ? '🔴' : '⚠️';
  return `<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8"><style>${BASE_STYLE}
  body { padding: 24px 28px; }
  .pct { font-size: 52px; font-weight: 800; color: ${barColor}; line-height: 1; margin-bottom: 4px; }
  .bar-track { background:#1e293b; border-radius:6px; height:14px; overflow:hidden; margin:12px 0; }
  .bar-fill  { height:100%; background:${barColor}; border-radius:6px; width:${pct}%; }
  .stats { display:flex; gap:20px; margin-top:10px; }
  .stat-val { font-size:16px; font-weight:700; color:#e2e8f0; }
  .stat-key { font-size:11px; color:#64748b; margin-top:2px; }
  </style></head><body>
  <div class="title">${icon} 디스크 사용률 경보</div>
  <div class="subtitle">${d.timestamp || ''}</div>
  <div class="pct">${pct}%</div>
  <div style="font-size:12px;color:#94a3b8">루트 파티션 사용 중</div>
  <div class="bar-track"><div class="bar-fill"></div></div>
  <div class="stats">
    <div><div class="stat-val">${d.used || '?'}</div><div class="stat-key">사용됨</div></div>
    <div><div class="stat-val">${d.total || '?'}</div><div class="stat-key">전체</div></div>
    <div><div class="stat-val">${d.free || '?'}</div><div class="stat-key">여유</div></div>
  </div>
  </body></html>`;
}

// ── HTML 템플릿: rag-health ────────────────────────────────────────────────
function buildRagHealthHTML(d) {
  const status = d.status || 'OK';
  const ICON = { OK: '✅', WARN: '⚠️', FAIL: '❌' };
  const icon = ICON[status] || '❓';
  const elapsedColor = (d.elapsed_min || 0) > 60 ? '#f59e0b' : '#4ade80';
  const deletedColor = (d.deleted_pct || 0) > 30 ? '#f59e0b' : '#4ade80';

  return `<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8"><style>${BASE_STYLE}
  .cards { display:flex; gap:12px; flex-wrap:wrap; }
  .card  { background:#1e293b; border-radius:10px; padding:14px 16px; flex:1; min-width:90px; }
  .val   { font-size:22px; font-weight:700; color:#e2e8f0; }
  .unit  { font-size:12px; color:#94a3b8; }
  .key   { font-size:11px; color:#64748b; margin-top:4px; }
  </style></head><body>
  <div class="title">${icon} RAG 인덱서 상태</div>
  <div class="subtitle">${d.timestamp || ''}</div>
  <div class="cards">
    <div class="card">
      <div class="val" style="color:#7dd3fc">${(d.chunks || 0).toLocaleString()}</div>
      <div class="key">청크 수</div>
    </div>
    <div class="card">
      <div class="val" style="color:${elapsedColor}">${d.elapsed_min || 0}<span class="unit">분</span></div>
      <div class="key">마지막 인덱싱</div>
    </div>
    <div class="card">
      <div class="val">${d.db_mb || 0}<span class="unit">MB</span></div>
      <div class="key">DB 크기</div>
    </div>
    <div class="card">
      <div class="val" style="color:${deletedColor}">${d.deleted_pct || 0}<span class="unit">%</span></div>
      <div class="key">삭제됨 비율</div>
    </div>
  </div>
  </body></html>`;
}

// ── HTML 템플릿: stats (범용 키-값 수치 카드) ──────────────────────────────
// DATA: { title?: string, data: { [label]: value }, channel?: string }
// value가 숫자형 퍼센트(0-100 or "XX%")이면 자동 색상, 그 외는 흰색
function buildStatsHTML(d) {
  const title = d.title || '📊 상태 요약';
  const entries = Object.entries(d.data || {});
  if (entries.length === 0) return null;

  // 자동 색상: 퍼센트 계열, 분(시간), 그 외
  const colorForValue = (key, val) => {
    const str = String(val);
    const num = parseFloat(str.replace(/[^0-9.]/g, ''));
    const isPct = str.includes('%') || /사용률|usage|disk|cpu|mem/i.test(key);
    const isMin = /분 전|min|elapsed/i.test(key) || /분$/.test(str);
    if (isNaN(num)) return '#e2e8f0';
    if (isPct) return num > 90 ? '#ef4444' : num > 75 ? '#f59e0b' : '#4ade80';
    if (isMin) return num > 60 ? '#f59e0b' : num > 120 ? '#ef4444' : '#4ade80';
    return '#7dd3fc'; // 기본: 파란 계열 (청크수, 크기 등)
  };

  const cols = entries.length <= 3 ? entries.length : Math.min(4, Math.ceil(entries.length / 2));
  const cards = entries.map(([k, v]) => `
    <div style="background:#1e293b;border-radius:10px;padding:14px 16px;flex:1;min-width:110px;max-width:180px">
      <div style="font-size:22px;font-weight:700;color:${colorForValue(k, v)}">${v}</div>
      <div style="font-size:11px;color:#64748b;margin-top:4px">${k}</div>
    </div>`).join('');

  return `<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8"><style>${BASE_STYLE}
  .cards { display:flex; gap:12px; flex-wrap:wrap; }
  </style></head><body>
  <div class="title">${title}</div>
  <div class="subtitle">${d.timestamp || new Date().toLocaleString('ko-KR')}</div>
  <div class="cards">${cards}</div>
  </body></html>`;
}

// ── HTML 생성 ──────────────────────────────────────────────────────────────
let html;
try {
  switch (TYPE) {
    case 'system-doctor': html = buildSystemDoctorHTML(DATA); break;
    case 'disk':          html = buildDiskHTML(DATA); break;
    case 'rag-health':    html = buildRagHealthHTML(DATA); break;
    case 'stats':         html = buildStatsHTML(DATA); break;
    default:
      console.error(`ERROR: Unknown type '${TYPE}'. Valid: system-doctor, disk, rag-health, stats`);
      process.exit(1);
  }
} catch (e) { console.error('ERROR building HTML:', e.message); process.exit(1); }

if (!html) { console.error('ERROR: template returned null (no data?)'); process.exit(1); }

// ── 텍스트 폴백 전송 ──────────────────────────────────────────────────────
async function sendTextFallback(text) {
  try {
    const payload = JSON.stringify({ content: text.slice(0, 1990) });
    const res = await fetch(WEBHOOK_URL, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: payload,
    });
    if (!res.ok) console.error(`WARN: text fallback ${res.status}`);
  } catch (e) { console.error('WARN: text fallback failed:', e.message); }
}

// ── 스크린샷 → Discord ────────────────────────────────────────────────────
const TS = Date.now();
const HTML_TMP = join(tmpdir(), `jarvis-visual-${TS}.html`);
const IMG_TMP  = join(tmpdir(), `jarvis-visual-${TS}.png`);

async function sendVisual() {
  writeFileSync(HTML_TMP, html);
  let browser;
  try {
    browser = await puppeteer.launch({
      executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      headless: 'new',
      args: ['--no-sandbox', '--disable-setuid-sandbox'],
    });
    const page = await browser.newPage();
    await page.setViewport({ width: 700, height: 400, deviceScaleFactor: 2 });
    await page.goto(`file://${HTML_TMP}`, { waitUntil: 'networkidle0' });
    const h = await page.evaluate(() => document.body.scrollHeight);
    await page.setViewport({ width: 700, height: h + 16, deviceScaleFactor: 2 });
    await page.screenshot({ path: IMG_TMP, fullPage: true });
    await browser.close(); browser = null;

    const imgBuf = readFileSync(IMG_TMP);
    const form = new FormData();
    if (CAPTION) form.append('content', CAPTION);
    form.append('file', new Blob([imgBuf], { type: 'image/png' }), `${TYPE}.png`);
    const res = await fetch(WEBHOOK_URL, { method: 'POST', body: form });
    if (!res.ok) { const t = await res.text(); throw new Error(`Discord ${res.status}: ${t}`); }
    console.log(`✅ Discord visual sent [${TYPE}]`);
  } catch (e) {
    if (browser) await browser.close().catch(() => {});
    console.error(`WARN: visual failed (${e.message}) — text fallback`);
    const fallback = CAPTION || `[${TYPE}] ${JSON.stringify(DATA).slice(0, 400)}`;
    await sendTextFallback(fallback);
  } finally {
    for (const f of [HTML_TMP, IMG_TMP]) {
      try { if (existsSync(f)) unlinkSync(f); } catch {}
    }
  }
}

await sendVisual();