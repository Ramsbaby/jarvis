#!/usr/bin/env node
// discord-visual.mjs — Jarvis Discord 시각화 카드 전송 유틸리티
// 사용: node discord-visual.mjs --type <type> --data '<json>' [--channel <ch>] [--message '<text>']
// 타입: system-doctor | disk | rag-health | stats

import puppeteer from 'puppeteer-core';
import { readFileSync, writeFileSync, unlinkSync, existsSync, appendFileSync, mkdirSync } from 'fs';
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
// [2026-09-11] 옛 경로(~/jarvis)를 그대로 들고 있어 2026-09-10 이관 뒤 ENOTDIR 로 죽었다.
// BOT_HOME 을 먼저 존중하고, 없으면 정본 루트를 쓴다.
const RUNTIME_HOME = process.env.BOT_HOME
  // [회차8 2026-09-12] JARVIS_HOME 하위 runtime 파생 금지 — 저장소에 runtime 이 없다(장벽 파일).
  || join(homedir(), '.openclaw-data', 'runtime');
const CONFIG_PATH = join(RUNTIME_HOME, 'config', 'monitoring.json');
const config = JSON.parse(readFileSync(CONFIG_PATH, 'utf-8'));
const WEBHOOK_URL = config.webhooks?.[CHANNEL] ?? config.webhook?.url;
// 2026-09-10 오픈클로 이식: 디스코드를 전면 제거했다. 웹훅이 "고장나서 없는 것"과 "일부러 없앤 것"을
// 가르지 않으면 호출자마다 가짜 실패가 쌓인다. 비활성 표지가 있으면 조용히 성공으로 끝낸다.
// 복구: monitoring.json 의 _webhook_disabled_20260910 을 webhook 으로 되돌린다.
if (!WEBHOOK_URL && config._webhook_disabled_20260910) {
  // 억제된 알림은 반드시 한 곳(no-external.log)에 남긴다. 안 남기면 감시 잡 35개의 산출물이
  // 통째로 사라진다 — 오픈클로 jarvis-suppressed-digest 가 이 파일을 읽어 메인 세션에 배달한다.
  let title = '';
  try {
    const parsed = JSON.parse(DATA_RAW || '{}');
    title = parsed.title || parsed.message || '';
  } catch { /* 제목 없는 페이로드는 type 만으로 식별한다 */ }
  try {
    const dir = join(RUNTIME_HOME, 'logs');
    mkdirSync(dir, { recursive: true });
    appendFileSync(join(dir, 'no-external.log'),
      `${new Date().toISOString()} [NO_EXTERNAL] src=discord-visual.mjs ch=${CHANNEL} type=${TYPE} title=${title || '(제목없음)'} len=${DATA_RAW.length}\n`);
  } catch { /* 기록 실패는 무시 — 억제 자체가 목적 */ }
  // 문자열에 [NO_EXTERNAL] 을 유지한다 — test-no-external.sh 가 "외부로 안 나갔다"를 이 토큰으로 판정하고,
  // 토큰을 빼면 억제 경로가 회귀 테스트에서 통째로 안 보인다.
  console.log(`[NO_EXTERNAL] SKIP: 디스코드 송출은 2026-09-10 의도적으로 비활성화됐다 (channel='${CHANNEL}'). no-external.log 에 기록됨.`);
  process.exit(0);
}
if (!WEBHOOK_URL) { console.error(`ERROR: No webhook for channel '${CHANNEL}'`); process.exit(1); }
// JARVIS_NO_EXTERNAL=1 (2026-09-04, SELF-HEAL-PLAN 1d): 테스트·dry-run 은 외부로 나가지 않는다 — 파일 기록 후 종료.
// 브라우저 렌더링 전에 끊어야 puppeteer 비용도 들지 않는다.
if (process.env.JARVIS_NO_EXTERNAL === '1') {
  try {
    const dir = join(RUNTIME_HOME, 'logs');
    mkdirSync(dir, { recursive: true });
    appendFileSync(join(dir, 'no-external.log'),
      `${new Date().toISOString()} [NO_EXTERNAL] src=discord-visual.mjs ch=${CHANNEL} type=${TYPE} len=${DATA_RAW.length}\n`);
  } catch { /* 기록 실패는 무시 — 억제 자체가 목적 */ }
  console.log(`[NO_EXTERNAL] discord-visual 송출 억제 (ch=${CHANNEL}, type=${TYPE})`);
  process.exit(0);
}
// 미등록 채널명이 조용히 기본 웹훅으로 빠지던 결함 가시화 (2026-06-11) — 동작은 유지, 경고만 명시
if (!config.webhooks?.[CHANNEL]) {
  console.error(`WARN: channel '${CHANNEL}' not in monitoring.json webhooks — falling back to default webhook`);
}

// ── 송출 감사 원장 (2026-06-11 신설) ──────────────────────────────────────
// 모든 카드/폴백 송출 시도를 JSONL로 기록 — 채널별 송출량·실패율의 30일 추이 측정 기반.
function auditLog(result) {
  try {
    const dir = join(RUNTIME_HOME, 'ledger');
    mkdirSync(dir, { recursive: true });
    const entry = {
      ts: new Date().toISOString(), source: 'discord-visual', type: TYPE,
      channel: CHANNEL, title: DATA?.title ?? null, result,
    };
    appendFileSync(join(dir, 'discord-send-audit.jsonl'), JSON.stringify(entry) + '\n');
  } catch { /* 원장 실패가 송출을 막으면 안 됨 */ }
}

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

  // 스키마 유연성: doctor 스킬은 두 형식 보낼 수 있음
  //   (a) summary.findings/healthy = 문자열 배열  ["🔴 ...", "✅ ..."]
  //   (b) summary.findings/healthy = 객체 배열    [{level, icon, title, detail}, ...]
  // 2026-04-25: (b) 호출 시 f.startsWith TypeError 발생 → 양쪽 정규화 처리
  let items = Array.isArray(d.items) ? d.items : null;
  if (!items && d.summary) {
    items = [];
    const LEVEL_TO_STATUS = { red: 'FAIL', yellow: 'WARN', orange: 'WARN' };
    const normalizeFinding = (f) => {
      if (typeof f === 'string') {
        const status = f.startsWith('🔴') ? 'FAIL' : 'WARN';
        return { item: f.replace(/^[🔴🟡⚠️❌]\s*/, ''), status, note: '' };
      }
      if (f && typeof f === 'object') {
        const status = LEVEL_TO_STATUS[(f.level || '').toLowerCase()] || 'WARN';
        return { item: String(f.title || f.item || ''), status, note: String(f.detail || f.note || '') };
      }
      return { item: String(f), status: 'WARN', note: '' };
    };
    const normalizeHealthy = (h) => {
      if (typeof h === 'string') {
        return { item: h.replace(/^[✅]\s*/, ''), status: 'OK', note: '' };
      }
      if (h && typeof h === 'object') {
        return { item: String(h.title || h.item || ''), status: 'OK', note: String(h.detail || h.note || '') };
      }
      return { item: String(h), status: 'OK', note: '' };
    };
    for (const f of (d.summary.findings || [])) items.push(normalizeFinding(f));
    for (const h of (d.summary.healthy || [])) items.push(normalizeHealthy(h));
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
    auditLog('sent');
  } catch (e) {
    if (browser) await browser.close().catch(() => {});
    console.error(`WARN: visual failed (${e.message}) — text fallback`);
    const fallback = CAPTION || `[${TYPE}] ${JSON.stringify(DATA).slice(0, 400)}`;
    await sendTextFallback(fallback);
    auditLog(`fallback:${e.message.slice(0, 80)}`);
  } finally {
    for (const f of [HTML_TMP, IMG_TMP]) {
      try { if (existsSync(f)) unlinkSync(f); } catch {}
    }
  }
}

await sendVisual();