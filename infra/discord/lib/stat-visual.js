// stat-visual.js — 수치 질문 감지 → Discord 평문 카드 전송
// EmbedBuilder 제거 → formatters.js 평문 포맷터 사용 (모바일/데스크톱 동일 렌더)

import { exec } from 'child_process';
import { promisify } from 'util';
import { join } from 'path';
import { homedir } from 'os';
import { alertFormat, reportFormat, kstFooter } from './formatters.js';

const execAsync = promisify(exec);
const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');

// ── 질문 패턴 → 타입 ──────────────────────────────────────────────────────
const TRIGGERS = [
  { re: /디스크|disk.*(용량|사용|얼마)|공간.*사용|저장.?공간/i,                         type: 'disk' },
  { re: /rag.*(상태|현황|청크|얼마|어때)|청크.*(몇|얼마|수|개)|lancedb|인덱싱.*상태/i,  type: 'rag' },
  { re: /사용량|시스템.*(상태|현황|어때)|상태.*알려|현황.*알려|전반적.*상태/i,           type: 'system' },
];

export function detectStatType(text) {
  for (const { re, type } of TRIGGERS) {
    if (re.test(text)) return type;
  }
  return null;
}

// ── 비동기 exec (실패 시 null) ────────────────────────────────────────────
async function safeExec(cmd) {
  try { const { stdout } = await execAsync(cmd, { timeout: 3000 }); return stdout.trim(); }
  catch { return null; }
}

// ── UI 헬퍼 ────────────────────────────────────────────────────────────────
const diskBar  = (p) => '█'.repeat(Math.round(p / 10)) + '░'.repeat(10 - Math.round(p / 10)) + ` ${p}%`;
const minStr   = (m) => m > 60 ? `${Math.floor(m / 60)}시간 ${m % 60}분 전` : `${m}분 전`;
const pctState = (p) => p > 90 ? 'error' : p > 75 ? 'warn' : 'ok';

// ── 데이터 수집 → 평문 ────────────────────────────────────────────────────
async function getDiskText() {
  const out = await safeExec('df -h /');
  if (!out) return null;
  const p = out.split('\n')[1]?.trim().split(/\s+/);
  if (!p || p.length < 5) return null;
  const pct = parseInt(p[4], 10);
  return alertFormat({
    title: '디스크 사용률',
    state: pctState(pct),
    summary: diskBar(pct),
    detail: `💾 사용: **${p[2]}** / 전체: **${p[1]}** / 여유: **${p[3]}**`,
    footer: kstFooter(),
  });
}

async function getRagText() {
  const [lastLine, sizeOut, sentinel] = await Promise.all([
    safeExec(`grep -E 'total chunks' "${BOT_HOME}/logs/rag-index.log" 2>/dev/null | tail -1`),
    safeExec(`du -sm "${BOT_HOME}/rag/lancedb" 2>/dev/null`),
    safeExec(`test -f "${BOT_HOME}/state/rag-rebuilding.json" && echo yes`),
  ]);

  let chunks = 0, elapsedMin = 0;
  if (lastLine) {
    const mC = lastLine.match(/(\d+) total chunks/);
    if (mC) chunks = parseInt(mC[1], 10);
    const mT = lastLine.match(/\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/);
    if (mT) elapsedMin = Math.round((Date.now() - new Date(mT[1] + 'Z').getTime()) / 60000);
  }
  const dbMB = sizeOut ? parseInt(sizeOut.split('\t')[0], 10) || 0 : 0;
  const isBuilding = sentinel?.includes('yes');
  const ragState = isBuilding ? 'warn' : elapsedMin > 90 ? 'warn' : 'ok';

  const items = [
    { state: 'info', label: '📦 청크 수', value: chunks.toLocaleString() + '개' },
    { state: elapsedMin > 90 ? 'warn' : 'ok', label: '🕐 마지막 인덱싱', value: elapsedMin > 0 ? minStr(elapsedMin) : '진행 중' },
    { state: 'info', label: '🗄️ DB 크기', value: `${dbMB} MB` },
  ];
  if (isBuilding) items.push({ state: 'warn', label: '🔨 상태', value: '리빌드 진행 중' });

  return reportFormat({
    title: '🧠 RAG 인덱서 상태',
    state: ragState,
    items,
    footer: kstFooter(),
  });
}

async function getSystemText() {
  const [diskOut, sizeOut, ragLine, pidOut] = await Promise.all([
    safeExec('df -h /'),
    safeExec(`du -sm "${BOT_HOME}/rag/lancedb" 2>/dev/null`),
    safeExec(`grep -E 'total chunks' "${BOT_HOME}/logs/rag-index.log" 2>/dev/null | tail -1`),
    safeExec("launchctl list 2>/dev/null | awk '/ai\\.jarvis\\.discord-bot/{print $1}'"),
  ]);

  let diskPct = 0, diskFree = '?';
  if (diskOut) {
    const p = diskOut.split('\n')[1]?.trim().split(/\s+/);
    if (p?.length >= 5) { diskPct = parseInt(p[4], 10); diskFree = p[3]; }
  }

  let chunks = 0, elapsedMin = 0;
  if (ragLine) {
    const mC = ragLine.match(/(\d+) total chunks/);
    if (mC) chunks = parseInt(mC[1], 10);
    const mT = ragLine.match(/\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/);
    if (mT) elapsedMin = Math.round((Date.now() - new Date(mT[1] + 'Z').getTime()) / 60000);
  }
  const dbMB = sizeOut ? parseInt(sizeOut.split('\t')[0], 10) || 0 : 0;
  const botOk = pidOut && /^\d+$/.test(pidOut);

  return reportFormat({
    title: '📊 Jarvis 시스템 현황',
    sections: [
      {
        heading: '💾 디스크',
        items: [
          { state: pctState(diskPct), label: '사용률', value: diskBar(diskPct) },
          { state: 'info', label: '여유 공간', value: diskFree },
        ],
      },
      {
        heading: '🧠 RAG',
        items: [
          { state: 'info', label: '청크 수', value: chunks.toLocaleString() + '개' },
          { state: elapsedMin > 90 ? 'warn' : 'ok', label: '인덱싱', value: elapsedMin > 0 ? minStr(elapsedMin) : '진행 중' },
          { state: 'info', label: 'DB 크기', value: `${dbMB} MB` },
        ],
      },
      {
        heading: '⚙️ 프로세스',
        items: [
          { state: botOk ? 'ok' : 'error', label: 'Discord 봇', value: botOk ? `PID ${pidOut}` : '오프라인' },
        ],
      },
    ],
    footer: kstFooter(),
  });
}

// ── 메인 export ───────────────────────────────────────────────────────────
export async function sendStatVisual(queryText, thread) {
  const type = detectStatType(queryText);
  if (!type || !thread) return;
  try {
    let text;
    switch (type) {
      case 'disk':   text = await getDiskText();   break;
      case 'rag':    text = await getRagText();    break;
      case 'system': text = await getSystemText(); break;
      default: return;
    }
    if (text) await thread.send(text);
  } catch { /* silent — 시각화 실패가 봇 응답 차단 금지 */ }
}
