// stat-visual.js — 수치 질문 감지 → Discord embed 카드 전송 (discord.js native)
// execSync 없음 — 모든 수집은 비동기. EmbedBuilder 직접 사용, 추가 프로세스 없음.

import { exec } from 'child_process';
import { promisify } from 'util';
import discordPkg from 'discord.js';
const { EmbedBuilder } = discordPkg;
import { join } from 'path';
import { homedir } from 'os';

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

// ── 색상 / UI 헬퍼 ────────────────────────────────────────────────────────
const C = { GREEN: 0x22c55e, YELLOW: 0xf59e0b, RED: 0xef4444 };
const pctColor = (p) => p > 90 ? C.RED : p > 75 ? C.YELLOW : C.GREEN;
const diskBar  = (p) => '█'.repeat(Math.round(p / 10)) + '░'.repeat(10 - Math.round(p / 10)) + ` ${p}%`;
const minStr   = (m) => m > 60 ? `${Math.floor(m / 60)}시간 ${m % 60}분 전` : `${m}분 전`;

// ── 데이터 수집 ────────────────────────────────────────────────────────────
async function getDiskEmbed() {
  const out = await safeExec('df -h /');
  if (!out) return null;
  const p = out.split('\n')[1]?.trim().split(/\s+/);
  if (!p || p.length < 5) return null;
  const pct = parseInt(p[4], 10);
  const icon = pct > 90 ? '🔴' : pct > 75 ? '⚠️' : '✅';
  return new EmbedBuilder()
    .setTitle(`${icon} 디스크 사용률`)
    .setColor(pctColor(pct))
    .setDescription(diskBar(pct))
    .addFields(
      { name: '사용됨', value: p[2], inline: true },
      { name: '전체',   value: p[1], inline: true },
      { name: '여유',   value: p[3], inline: true },
    )
    .setFooter({ text: new Date().toLocaleString('ko-KR') });
}

async function getRagEmbed() {
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
  const color = isBuilding ? C.YELLOW : elapsedMin > 90 ? C.YELLOW : C.GREEN;
  const icon  = isBuilding ? '🔨' : elapsedMin > 90 ? '⚠️' : '✅';

  const fields = [
    { name: '청크 수',       value: chunks.toLocaleString() + '개', inline: true },
    { name: '마지막 인덱싱', value: elapsedMin > 0 ? minStr(elapsedMin) : '진행 중', inline: true },
    { name: 'DB 크기',       value: `${dbMB} MB`, inline: true },
  ];
  if (isBuilding) fields.push({ name: '상태', value: '🔨 리빌드 진행 중', inline: true });

  return new EmbedBuilder()
    .setTitle(`${icon} RAG 인덱서 상태`)
    .setColor(color)
    .addFields(...fields)
    .setFooter({ text: new Date().toLocaleString('ko-KR') });
}

async function getSystemEmbed() {
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

  const worstColor = diskPct > 90 || !botOk ? C.RED
    : diskPct > 75 || elapsedMin > 90        ? C.YELLOW
    : C.GREEN;

  return new EmbedBuilder()
    .setTitle('📊 Jarvis 시스템 현황')
    .setColor(worstColor)
    .addFields(
      { name: '디스크',       value: diskBar(diskPct), inline: false },
      { name: '여유 공간',    value: diskFree,         inline: true },
      { name: 'RAG 청크',    value: chunks.toLocaleString() + '개', inline: true },
      { name: 'RAG 인덱싱',  value: elapsedMin > 0 ? minStr(elapsedMin) : '진행 중', inline: true },
      { name: 'RAG DB',      value: `${dbMB} MB`,     inline: true },
      { name: 'Discord 봇',  value: botOk ? `✅ PID ${pidOut}` : '❌ 오프라인', inline: true },
    )
    .setFooter({ text: new Date().toLocaleString('ko-KR') });
}

// ── 메인 export ───────────────────────────────────────────────────────────
export async function sendStatVisual(queryText, thread) {
  const type = detectStatType(queryText);
  if (!type || !thread) return;
  try {
    let embed;
    switch (type) {
      case 'disk':   embed = await getDiskEmbed();   break;
      case 'rag':    embed = await getRagEmbed();    break;
      case 'system': embed = await getSystemEmbed(); break;
      default: return;
    }
    if (embed) await thread.send({ embeds: [embed] });
  } catch { /* silent — 시각화 실패가 봇 응답 차단 금지 */ }
}
