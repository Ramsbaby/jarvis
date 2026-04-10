// visual-gen.js — 데이터 → HTML 시각화 생성 → Puppeteer → Discord
// Claude SDK 없이 JS 템플릿으로 직접 차트 생성 (타임아웃 없음, 품질 보장)

import puppeteer from 'puppeteer-core';
import { exec } from 'child_process';
import { promisify } from 'util';
import { writeFileSync, unlinkSync, existsSync } from 'fs';
import { tmpdir, homedir } from 'os';
import { join } from 'path';

const execAsync = promisify(exec);
const HOME = homedir();
const BOT_HOME = process.env.BOT_HOME || join(HOME, '.jarvis');

// ── 분석 질문 감지 ────────────────────────────────────────────────────────
const ANALYTICAL_TRIGGERS = [
  { re: /rag.*(추이|트렌드|히스토리|지난|최근.*[0-9]|변화)/i,               type: 'rag-trend' },
  { re: /크론.*(에러|실패|분석|패턴)|에러.*(패턴|분석|추이)/i,               type: 'cron-errors' },
  { re: /지난\s*[0-9]+(일|시간)|최근\s*[0-9]+(일|시간)/i,                  type: 'auto' },
  { re: /종합.*리포트|리포트.*종합|전체.*분석|분석.*전체|오늘.*있었|어제.*있었/i, type: 'overview' },
];

export function detectAnalyticalType(text) {
  for (const { re, type } of ANALYTICAL_TRIGGERS) {
    if (re.test(text)) return type === 'auto' ? _inferAutoType(text) : type;
  }
  return null;
}

function _inferAutoType(text) {
  if (/rag|청크|인덱싱/i.test(text)) return 'rag-trend';
  if (/크론|에러|실패/i.test(text)) return 'cron-errors';
  return 'overview';
}

// ── 비동기 exec ───────────────────────────────────────────────────────────
async function safeExec(cmd) {
  try { const { stdout } = await execAsync(cmd, { timeout: 5000 }); return stdout.trim(); }
  catch { return ''; }
}

// ── 데이터 수집 ────────────────────────────────────────────────────────────
async function gatherData(type) {
  const now = new Date();

  if (type === 'rag-trend') {
    const lines = await safeExec(
      `grep -E 'RAG index:.*total chunks' "${BOT_HOME}/logs/rag-index.log" 2>/dev/null | tail -48`
    );
    const points = lines.split('\n').filter(Boolean).map(l => {
      const ts  = l.match(/\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/)?.[1];
      const neu = l.match(/(\d+) new/)?.[1];
      const tot = l.match(/(\d+) total chunks/)?.[1];
      return ts && tot ? { time: ts, new: parseInt(neu || 0), total: parseInt(tot) } : null;
    }).filter(Boolean);
    return { type: 'rag-trend', points, title: 'RAG 인덱싱 추이', now: now.toLocaleString('ko-KR') };
  }

  if (type === 'cron-errors') {
    const lines = await safeExec(
      `grep -E 'FAILED|ERROR|CRITICAL' "${BOT_HOME}/logs/cron.log" 2>/dev/null | tail -100`
    );
    const counts = {};
    const recent = [];
    lines.split('\n').filter(Boolean).forEach(l => {
      // 포맷: [timestamp] [task-name] ... → 두 번째 [] 값이 태스크명
      const task = l.match(/\]\s*\[([^\]]+)\]/)?.[1] || l.match(/\[([^\]]+)\]/)?.[1] || 'unknown';
      counts[task] = (counts[task] || 0) + 1;
      if (recent.length < 10) recent.push(l.replace(BOT_HOME, '~').slice(0, 120));
    });
    return { type: 'cron-errors', counts, recent, title: '크론 에러 분석', now: now.toLocaleString('ko-KR') };
  }

  // overview: 여러 소스 병렬 수집
  const [disk, ragLine, cronErr, ragSize] = await Promise.all([
    safeExec('df -h /'),
    safeExec(`grep -E 'RAG index:.*total chunks' "${BOT_HOME}/logs/rag-index.log" 2>/dev/null | tail -1`),
    safeExec(`grep -cE 'FAILED|ERROR' "${BOT_HOME}/logs/cron.log" 2>/dev/null || echo 0`),
    safeExec(`du -sm "${BOT_HOME}/rag/lancedb" 2>/dev/null`),
  ]);

  const dp = disk.split('\n')[1]?.trim().split(/\s+/) || [];
  const chunks = ragLine.match(/(\d+) total chunks/)?.[1] || '?';
  const lastTs  = ragLine.match(/\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/)?.[1];
  const elapsed = lastTs ? Math.round((Date.now() - new Date(lastTs + 'Z').getTime()) / 60000) : null;

  return {
    type: 'overview',
    title: 'Jarvis 종합 현황',
    now: now.toLocaleString('ko-KR'),
    disk: { pct: dp[4] || '?', used: dp[2] || '?', free: dp[3] || '?', total: dp[1] || '?' },
    rag:  { chunks, elapsed_min: elapsed, db_mb: parseInt(ragSize?.split('\t')[0] || '0', 10) },
    cron: { errors_total: parseInt(cronErr || '0', 10) },
  };
}

// ── 공통 베이스 스타일 ─────────────────────────────────────────────────────
const BASE_STYLE = `
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: 'Apple SD Gothic Neo', 'Noto Sans KR', system-ui, -apple-system, sans-serif;
    background: #0f1117; color: #e2e8f0;
    padding: 24px 26px; max-width: 780px;
  }
  .title   { font-size: 17px; font-weight: 700; color: #7dd3fc; margin-bottom: 4px; }
  .subtitle { font-size: 11px; color: #64748b; margin-bottom: 16px; }
`;

// ── HTML 생성: rag-trend ──────────────────────────────────────────────────
function buildRagTrendHTML({ points, title, now }) {
  if (!points || points.length === 0) {
    return buildMessageHTML('📈 ' + title, now, '데이터 없음', 'RAG 인덱싱 로그를 찾을 수 없습니다.', '#64748b');
  }

  const W = 720, CHART_H = 260;
  const ML = 75, MR = 20, MT = 16, MB = 70; // margins: left, right, top, bottom
  const CW = W - ML - MR;

  const maxY = Math.max(...points.map(p => p.total), 1);
  const yTop = Math.ceil(maxY * 1.1 / 500) * 500 || Math.ceil(maxY * 1.1);

  // Y axis ticks (5 steps)
  const rawStep = yTop / 5;
  const yStep = rawStep >= 1000 ? Math.ceil(rawStep / 1000) * 1000
    : rawStep >= 100  ? Math.ceil(rawStep / 100) * 100
    : Math.ceil(rawStep / 10) * 10 || 1;

  // X label step — avoid overlap (min 40px per label)
  const labelStep = Math.max(1, Math.ceil(points.length / Math.floor(CW / 44)));

  const gap = CW / points.length;
  const barW = Math.max(3, gap * 0.7);

  let yGrid = '', yLabels = '';
  for (let v = 0; v <= yTop; v += yStep) {
    const y = MT + CHART_H - (v / yTop) * CHART_H;
    yGrid   += `<line x1="${ML}" y1="${y}" x2="${ML + CW}" y2="${y}" stroke="#1e293b" stroke-width="1"/>`;
    yLabels += `<text x="${ML - 6}" y="${y + 4}" text-anchor="end" font-size="10" fill="#64748b">${v.toLocaleString()}</text>`;
  }

  let bars = '', xLabels = '', valLabels = '';
  points.forEach((p, i) => {
    const cx = ML + i * gap + gap / 2;

    // total bar
    const th = Math.max(2, (p.total / yTop) * CHART_H);
    const ty = MT + CHART_H - th;
    bars += `<rect x="${cx - barW / 2}" y="${ty}" width="${barW}" height="${th}" fill="#7dd3fc" opacity="0.85" rx="2"/>`;

    // new chunks bar (narrower, overlaid)
    if (p.new > 0) {
      const nh = Math.max(2, (p.new / yTop) * CHART_H);
      const ny = MT + CHART_H - nh;
      const nw = Math.max(3, barW * 0.45);
      bars += `<rect x="${cx - nw / 2}" y="${ny}" width="${nw}" height="${nh}" fill="#22c55e" opacity="0.95" rx="2"/>`;
    }

    // value label above bar
    valLabels += `<text x="${cx}" y="${ty - 3}" text-anchor="middle" font-size="9" fill="#94a3b8">${p.total.toLocaleString()}</text>`;

    // X axis label (rotated)
    if (i % labelStep === 0) {
      const hhmm = p.time.slice(11, 16);
      const lx = cx, ly = MT + CHART_H + 14;
      xLabels += `<text x="${lx}" y="${ly}" text-anchor="end" font-size="10" fill="#94a3b8"
        transform="rotate(-45,${lx},${ly})">${hhmm}</text>`;
    }
  });

  const svgH = MT + CHART_H + MB;
  const legend = `
    <div style="display:flex;gap:16px;margin-bottom:10px;font-size:12px;color:#94a3b8">
      <span><span style="display:inline-block;width:10px;height:10px;background:#7dd3fc;border-radius:2px;vertical-align:middle;margin-right:4px"></span>전체 청크</span>
      <span><span style="display:inline-block;width:10px;height:10px;background:#22c55e;border-radius:2px;vertical-align:middle;margin-right:4px"></span>신규 청크</span>
    </div>`;

  return `<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8"><style>${BASE_STYLE}</style></head><body>
  <div class="title">📈 ${title}</div>
  <div class="subtitle">${now} · 최근 ${points.length}건</div>
  ${legend}
  <svg width="${W}" height="${svgH}" style="overflow:visible;display:block">
    <!-- 배경 그리드 -->
    ${yGrid}
    <!-- 막대 -->
    ${bars}
    <!-- 값 레이블 -->
    ${valLabels}
    <!-- X축 -->
    <line x1="${ML}" y1="${MT + CHART_H}" x2="${ML + CW}" y2="${MT + CHART_H}" stroke="#475569" stroke-width="1.5"/>
    <!-- X축 레이블 -->
    ${xLabels}
    <!-- X축 제목 -->
    <text x="${ML + CW / 2}" y="${MT + CHART_H + MB - 4}" text-anchor="middle" font-size="11" fill="#475569">시간 (HH:MM)</text>
    <!-- Y축 -->
    <line x1="${ML}" y1="${MT}" x2="${ML}" y2="${MT + CHART_H}" stroke="#475569" stroke-width="1.5"/>
    <!-- Y축 레이블 -->
    ${yLabels}
    <!-- Y축 제목 -->
    <text transform="rotate(-90,18,${MT + CHART_H / 2})" x="18" y="${MT + CHART_H / 2}"
      text-anchor="middle" font-size="11" fill="#475569">chunks</text>
  </svg>
  </body></html>`;
}

// ── HTML 생성: cron-errors ────────────────────────────────────────────────
function buildCronErrorsHTML({ counts, recent, title, now }) {
  const allEntries = Object.entries(counts).sort((a, b) => b[1] - a[1]);
  const entries = allEntries.slice(0, 20); // 상위 20개만 표시
  const truncated = allEntries.length > 20 ? allEntries.length - 20 : 0;

  if (allEntries.length === 0) {
    return buildMessageHTML('✅ ' + title, now, '에러 없음', '최근 로그에서 에러를 찾을 수 없습니다.', '#22c55e');
  }

  const BAR_H = 26, GAP = 7;
  const LABEL_W = 190, BAR_AREA_W = 340, NUM_W = 50;
  const W = LABEL_W + BAR_AREA_W + NUM_W + 20;
  const maxCount = entries[0][1];

  // X axis ticks
  const rawXStep = maxCount / 4;
  const xStep = rawXStep >= 100 ? Math.ceil(rawXStep / 100) * 100
    : rawXStep >= 10 ? Math.ceil(rawXStep / 10) * 10
    : Math.ceil(rawXStep) || 1;

  let xGrid = '', xTickLabels = '';
  for (let v = 0; v <= maxCount; v += xStep) {
    const x = LABEL_W + (v / maxCount) * BAR_AREA_W;
    xGrid      += `<line x1="${x}" y1="0" x2="${x}" y2="${entries.length * (BAR_H + GAP)}" stroke="#1e293b" stroke-width="1"/>`;
    xTickLabels += `<text x="${x}" y="${entries.length * (BAR_H + GAP) + 14}" text-anchor="middle" font-size="10" fill="#64748b">${v}</text>`;
  }

  const bars = entries.map(([task, count], i) => {
    const y = i * (BAR_H + GAP);
    const bw = Math.max(4, (count / maxCount) * BAR_AREA_W);
    const ratio = count / maxCount;
    // ef4444 → fca5a5 gradient by ratio
    const red = Math.round(239 - ratio * 50);
    const gb  = Math.round(68 + (1 - ratio) * 90);
    const col = `rgb(${red},${gb},${gb})`;

    const display = task.length > 26 ? task.slice(0, 23) + '…' : task;

    return `
      <text x="${LABEL_W - 8}" y="${y + BAR_H / 2 + 4}" text-anchor="end"
        font-size="11" fill="#cbd5e1" font-family="monospace">${display}</text>
      <rect x="${LABEL_W}" y="${y}" width="${bw}" height="${BAR_H}" fill="${col}" rx="3"/>
      <text x="${LABEL_W + bw + 5}" y="${y + BAR_H / 2 + 4}"
        font-size="11" font-weight="700" fill="#f87171">${count}</text>`;
  }).join('');

  const CHART_H = entries.length * (BAR_H + GAP);
  const SVG_H = CHART_H + 30;

  const recentSection = recent.length > 0 ? `
    <div style="margin-top:20px;border-top:1px solid #1e293b;padding-top:14px">
      <div style="font-size:12px;font-weight:600;color:#64748b;margin-bottom:8px">최근 에러 ${Math.min(10, recent.length)}건</div>
      ${recent.slice(0, 10).map(l =>
        `<div style="font-size:10px;font-family:monospace;color:#64748b;padding:3px 0;border-bottom:1px solid #0f1117;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${escapeHtml(l)}</div>`
      ).join('')}
    </div>` : '';

  return `<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8"><style>${BASE_STYLE}</style></head><body>
  <div class="title">⚠️ ${title}</div>
  <div class="subtitle">${now} · ${allEntries.length}개 태스크${truncated > 0 ? ` (상위 20개 표시)` : ''}</div>
  <svg width="${W}" height="${SVG_H}" style="overflow:visible;display:block">
    ${xGrid}
    ${bars}
    <!-- X축 -->
    <line x1="${LABEL_W}" y1="${CHART_H}" x2="${LABEL_W + BAR_AREA_W}" y2="${CHART_H}" stroke="#475569" stroke-width="1.5"/>
    <!-- X축 눈금 레이블 -->
    ${xTickLabels}
    <!-- X축 제목 -->
    <text x="${LABEL_W + BAR_AREA_W / 2}" y="${CHART_H + 28}" text-anchor="middle" font-size="11" fill="#475569">횟수</text>
    <!-- Y축 -->
    <line x1="${LABEL_W}" y1="0" x2="${LABEL_W}" y2="${CHART_H}" stroke="#475569" stroke-width="1.5"/>
  </svg>
  ${recentSection}
  </body></html>`;
}

// ── HTML 생성: overview ───────────────────────────────────────────────────
function buildOverviewHTML({ disk, rag, cron, title, now }) {
  const diskPct  = parseInt(disk.pct) || 0;
  const diskCol  = diskPct > 90 ? '#ef4444' : diskPct > 75 ? '#f59e0b' : '#22c55e';
  const diskIcon = diskPct > 90 ? '🔴' : diskPct > 75 ? '⚠️' : '✅';

  const cronCol  = cron.errors_total > 0 ? '#ef4444' : '#22c55e';
  const cronIcon = cron.errors_total > 0 ? '❌' : '✅';

  const ragE   = rag.elapsed_min;
  const ragCol = ragE === null ? '#64748b' : ragE > 90 ? '#f59e0b' : '#22c55e';
  const ragIcon = ragE === null ? '❓' : ragE > 90 ? '⚠️' : '✅';
  const ragStr  = ragE === null ? '알 수 없음'
    : ragE > 60  ? `${Math.floor(ragE / 60)}시간 ${ragE % 60}분 전`
    : `${ragE}분 전`;
  const chunksNum = parseInt(rag.chunks) || 0;

  return `<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8"><style>
  ${BASE_STYLE}
  .section { background:#1e293b;border-radius:10px;padding:16px;margin-bottom:12px }
  .sec-title { font-size:12px;color:#64748b;margin-bottom:10px;font-weight:600 }
  .bar-track { background:#0f1117;border-radius:5px;height:14px;position:relative;overflow:hidden }
  .bar-fill  { height:100%;border-radius:5px }
  .bar-pct   { position:absolute;right:8px;top:50%;transform:translateY(-50%);font-size:10px;font-weight:700;color:#fff }
  .disk-stats { display:flex;gap:20px;margin-top:10px }
  .stat-val { font-size:15px;font-weight:700 }
  .stat-key { font-size:10px;color:#64748b;margin-top:2px }
  .cards { display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px }
  .card { background:#1e293b;border-radius:10px;padding:14px 16px }
  .card-lbl { font-size:11px;color:#64748b;margin-bottom:6px }
  .card-val { font-size:26px;font-weight:800;line-height:1 }
  .card-sub { font-size:11px;color:#475569;margin-top:5px }
  </style></head><body>
  <div class="title">📊 ${title}</div>
  <div class="subtitle">${now}</div>

  <div class="section">
    <div class="sec-title">${diskIcon} 디스크</div>
    <div class="bar-track">
      <div class="bar-fill" style="width:${diskPct}%;background:${diskCol}"></div>
      <span class="bar-pct">${diskPct}%</span>
    </div>
    <div class="disk-stats">
      <div><div class="stat-val" style="color:${diskCol}">${disk.used}</div><div class="stat-key">사용됨</div></div>
      <div><div class="stat-val">${disk.total}</div><div class="stat-key">전체</div></div>
      <div><div class="stat-val" style="color:#22c55e">${disk.free}</div><div class="stat-key">여유</div></div>
    </div>
  </div>

  <div class="cards">
    <div class="card">
      <div class="card-lbl">${ragIcon} RAG 청크</div>
      <div class="card-val" style="color:#7dd3fc">${chunksNum.toLocaleString()}</div>
      <div class="card-sub">마지막 인덱싱: ${ragStr}</div>
    </div>
    <div class="card">
      <div class="card-lbl">💾 DB 크기</div>
      <div class="card-val" style="color:#94a3b8">${rag.db_mb}<span style="font-size:14px;font-weight:400"> MB</span></div>
      <div class="card-sub" style="color:${ragCol}">● LanceDB</div>
    </div>
    <div class="card">
      <div class="card-lbl">${cronIcon} 크론 에러</div>
      <div class="card-val" style="color:${cronCol}">${cron.errors_total.toLocaleString()}</div>
      <div class="card-sub">${cron.errors_total === 0 ? '이상 없음' : '건 (총 누적)'}</div>
    </div>
  </div>
  </body></html>`;
}

// ── 안내 메시지 HTML (데이터 없음 / 에러 없음 등) ─────────────────────────
function buildMessageHTML(title, now, heading, body, color) {
  return `<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8"><style>
  ${BASE_STYLE}
  .msg { font-size:28px;font-weight:800;margin-top:16px }
  .body { font-size:13px;color:#475569;margin-top:8px }
  </style></head><body>
  <div class="title">${title}</div>
  <div class="subtitle">${now}</div>
  <div class="msg" style="color:${color}">${heading}</div>
  <div class="body">${body}</div>
  </body></html>`;
}

function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// ── HTML 생성 디스패처 ─────────────────────────────────────────────────────
function generateHTML(data) {
  switch (data.type) {
    case 'rag-trend':   return buildRagTrendHTML(data);
    case 'cron-errors': return buildCronErrorsHTML(data);
    case 'overview':    return buildOverviewHTML(data);
    default: return buildMessageHTML('❌ 알 수 없는 타입', '', data.type, '', '#ef4444');
  }
}

// ── Puppeteer 렌더 → Discord 전송 ────────────────────────────────────────
async function renderAndSend(html, thread) {
  const ts       = Date.now();
  const htmlPath = join(tmpdir(), `jv-${ts}.html`);
  const imgPath  = join(tmpdir(), `jv-${ts}.png`);
  writeFileSync(htmlPath, html);

  let browser;
  try {
    browser = await puppeteer.launch({
      executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      headless: 'new',
      args: ['--no-sandbox', '--disable-setuid-sandbox'],
    });
    const page = await browser.newPage();
    await page.setViewport({ width: 800, height: 600, deviceScaleFactor: 2 });
    await page.goto(`file://${htmlPath}`, { waitUntil: 'networkidle0' });
    const h = await page.evaluate(() => document.body.scrollHeight);
    await page.setViewport({ width: 800, height: h + 24, deviceScaleFactor: 2 });
    await page.screenshot({ path: imgPath, fullPage: true });
    await browser.close(); browser = null;

    await thread.send({ files: [{ attachment: imgPath, name: 'visual.png' }] });
  } finally {
    if (browser) await browser.close().catch(() => {});
    for (const f of [htmlPath, imgPath]) try { if (existsSync(f)) unlinkSync(f); } catch {}
  }
}

// ── 메인 export ───────────────────────────────────────────────────────────
export async function generateAndSendVisual(queryText, analyticalType, thread) {
  try {
    const data = await gatherData(analyticalType);
    const html = generateHTML(data);
    await renderAndSend(html, thread);
  } catch (e) {
    // 실패해도 Claude 텍스트 응답이 이어서 오므로 사용자 영향 없음
    console.error('[visual-gen] failed:', e.message);
  }
}
