#!/usr/bin/env node
// server.mjs — Jarvis Virtual Office Backend API
import express from 'express';
import cors from 'cors';
import { readFileSync, readdirSync, existsSync } from 'fs';
import { execSync, spawn } from 'child_process';
import { homedir } from 'os';
import path from 'path';

const HOME = homedir();
const JARVIS = process.env.BOT_HOME || path.join(HOME, '.jarvis');
const PORT = process.env.OFFICE_PORT || 7780;

const app = express();
app.use(cors());
app.use(express.json());

// ── 유틸 ─────────────────────────────────────────────────────────────────────
function readSafe(p) { try { return readFileSync(p, 'utf8'); } catch { return ''; } }
function readJson(p, fb) { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return fb; } }

// ── 팀 레지스트리 ────────────────────────────────────────────────────────────
const TEAMS = [
  { id: 'council', name: 'CEO실', room: 'CEO Office', emoji: '👔', role: 'Executive oversight', keywords: ['board-meeting', 'ceo-daily-digest', 'council'], schedule: '매일 08:10, 21:55', channel: 'jarvis-ceo', x: 2, y: 2 },
  { id: 'infra', name: '인프라팀', room: 'Infra Ops', emoji: '🖥️', role: 'System health & monitoring', keywords: ['infra-daily', 'system-doctor', 'health', 'disk', 'glances', 'scorecard'], schedule: '매일 09:00', channel: 'jarvis-system', x: 6, y: 2 },
  { id: 'trend', name: '정보팀', room: 'Trend Lab', emoji: '📰', role: 'News, market & tech trends', keywords: ['trend', 'market-alert', 'news', 'tqqq', 'stock', 'macro', 'github-monitor'], schedule: '평일 07:30', channel: 'jarvis', x: 10, y: 2 },
  { id: 'finance', name: '재무팀', room: 'Finance Desk', emoji: '📊', role: 'Stock & ETF monitoring', keywords: ['finance', 'stock', 'tqqq', 'macro-briefing'], schedule: '평일 08:00', channel: 'jarvis-market', x: 14, y: 2 },
  { id: 'record', name: '기록팀', room: 'Record Archive', emoji: '📁', role: 'Daily logging & archival', keywords: ['record-daily', 'memory', 'session-sum', 'rag'], schedule: '매일 22:30', channel: 'jarvis-system', x: 2, y: 8 },
  { id: 'security', name: '감사팀', room: 'Security Vault', emoji: '🔒', role: 'Audit & quality', keywords: ['audit', 'cron-failure', 'kpi', 'e2e', 'regression'], schedule: '매일 23:00', channel: 'jarvis-system', x: 6, y: 8 },
  { id: 'academy', name: '학습팀', room: 'Academy Library', emoji: '📚', role: 'Study & learning curation', keywords: ['academy', 'learning', 'study'], schedule: '매주 일 20:00', channel: 'jarvis-ceo', x: 10, y: 8 },
  { id: 'brand', name: '브랜드팀', room: 'Brand Studio', emoji: '🎨', role: 'OSS & content strategy', keywords: ['brand', 'openclaw', 'blog', 'oss'], schedule: '매주 화 08:00', channel: 'jarvis-blog', x: 14, y: 8 },
  { id: 'standup', name: '스탠드업', room: 'Standup Stage', emoji: '🎤', role: 'Morning briefing', keywords: ['morning-standup', 'standup'], schedule: '매일 09:15', channel: 'jarvis', x: 6, y: 14 },
  { id: 'career', name: '커리어팀', room: 'Career Lounge', emoji: '💼', role: 'Job market & skill tracking', keywords: ['career', 'commitment', 'growth', 'job'], schedule: '매주 금 18:00', channel: 'jarvis-ceo', x: 10, y: 14 },
  { id: 'recon', name: '정찰팀', room: 'Recon HQ', emoji: '🔍', role: 'Deep research', keywords: ['recon', 'weekly'], schedule: '매주 월 09:00', channel: 'jarvis-ceo', x: 14, y: 14 },
  { id: 'ceo-digest', name: 'CEO Digest', room: 'Board Meeting Room', emoji: '🏢', role: 'Weekly CEO review', keywords: ['ceo-daily-digest', 'board-meeting'], schedule: '매주 월 09:00', channel: 'jarvis-ceo', x: 8, y: 18 },
];

// ── 크론 로그 파싱 ───────────────────────────────────────────────────────────
function parseCronLog(keywords = [], limit = 20) {
  const raw = readSafe(path.join(JARVIS, 'logs', 'cron.log'));
  if (!raw) return [];
  const lines = raw.split('\n').filter(Boolean).slice(-3000);
  const LOG_RE = /^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] \[([^\]]+)\] (.+)$/;
  const entries = [];
  for (const line of lines) {
    const m = line.match(LOG_RE);
    if (!m) continue;
    const [, ts, task, msg] = m;
    if (/^task_\d+_/.test(task)) continue;
    const lower = task.toLowerCase();
    if (keywords.length > 0 && !keywords.some(kw => lower.includes(kw))) continue;
    let result = 'unknown';
    if (/\bDONE\b|\bSUCCESS\b/.test(line)) result = 'SUCCESS';
    else if (/FAILED|ERROR|CRITICAL/.test(line)) result = 'FAILED';
    else if (/\bSKIPPED\b/.test(line)) result = 'SKIPPED';
    else if (/\bSTARTED?\b|\bRUNNING\b/.test(line)) result = 'RUNNING';
    if (result !== 'unknown') entries.push({ time: ts, task, result, message: msg.slice(0, 120) });
  }
  return entries.reverse().slice(0, limit);
}

function getCronStats24h(keywords = []) {
  const raw = readSafe(path.join(JARVIS, 'logs', 'cron.log'));
  if (!raw) return { total: 0, success: 0, failed: 0, rate: 0 };
  const lines = raw.split('\n').filter(Boolean).slice(-3000);
  const cutoff = new Date(Date.now() - 86400_000).toISOString().replace('T', ' ').slice(0, 19);
  let success = 0, failed = 0;
  for (const line of lines) {
    const m = line.match(/^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] \[([^\]]+)\]/);
    if (!m || m[1] < cutoff || /^task_\d+_/.test(m[2])) continue;
    const lower = m[2].toLowerCase();
    if (keywords.length > 0 && !keywords.some(kw => lower.includes(kw))) continue;
    if (/\bSUCCESS\b|\bDONE\b/.test(line)) success++;
    else if (/FAILED|ERROR|CRITICAL/.test(line)) failed++;
  }
  const total = success + failed;
  return { total, success, failed, rate: total > 0 ? Math.round((success / total) * 100) : 0 };
}

// ── API 엔드포인트 ───────────────────────────────────────────────────────────

// 전체 팀 + 라이브 상태
app.get('/api/teams', (_req, res) => {
  const teams = TEAMS.map(t => {
    const stats = getCronStats24h(t.keywords);
    const recent = parseCronLog(t.keywords, 1);
    const lastStatus = recent[0]?.result || 'idle';
    return {
      ...t,
      status: stats.failed > 3 ? 'RED' : stats.rate >= 80 ? 'GREEN' : 'YELLOW',
      lastActivity: recent[0] || null,
      stats,
      currentTask: lastStatus === 'RUNNING' ? recent[0]?.task : null,
    };
  });
  res.json({ teams, generatedAt: new Date().toISOString() });
});

// 팀 상세 브리핑
app.get('/api/team/:id/briefing', (req, res) => {
  const team = TEAMS.find(t => t.id === req.params.id);
  if (!team) return res.status(404).json({ error: 'Unknown team' });

  const stats = getCronStats24h(team.keywords);
  const recent = parseCronLog(team.keywords, 15);
  const boardMinutes = getLatestBoardMinutes(team.keywords);

  res.json({
    ...team,
    status: stats.failed > 3 ? 'RED' : stats.rate >= 80 ? 'GREEN' : 'YELLOW',
    summary: stats.total > 0
      ? `오늘 ${stats.total}건, 성공 ${stats.success}건, 실패 ${stats.failed}건 (${stats.rate}%)`
      : '오늘 실행 이력 없음',
    stats,
    recentActivity: recent,
    boardMinutes,
  });
});

// 시스템 헬스
app.get('/api/health', (_req, res) => {
  const disk = (() => {
    try {
      const out = execSync("df -h / | awk 'NR==2{print $3,$2,$5}'", { timeout: 3000 }).toString().trim();
      const [used, total, pct] = out.split(/\s+/);
      return { percent: parseInt(pct) || 0, used, total };
    } catch { return { percent: 0, used: '?', total: '?' }; }
  })();

  const bot = (() => {
    try {
      const pid = execSync('pgrep -f "discord-bot.js" 2>/dev/null || true', { timeout: 3000 }).toString().trim().split('\n')[0];
      return { running: !!pid, pid: pid || null };
    } catch { return { running: false, pid: null }; }
  })();

  const cronStats = getCronStats24h();

  res.json({ disk, bot, cron: cronStats, generatedAt: new Date().toISOString() });
});

// /btw 대화
app.post('/api/chat', async (req, res) => {
  const { teamId, message } = req.body;
  if (!message) return res.status(400).json({ error: 'message required' });
  const team = TEAMS.find(t => t.id === teamId);
  const systemPrompt = team
    ? `You are the ${team.name} (${team.role}) team lead at Jarvis Company. Answer in Korean, concisely. Current schedule: ${team.schedule}.`
    : 'You are a Jarvis Company employee. Answer in Korean, concisely.';

  try {
    const claude = spawn('claude', ['-p', message, '--no-input', '--output-format', 'text', '--system-prompt', systemPrompt], {
      env: { ...process.env, TERM: 'dumb' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '';
    claude.stdout.on('data', d => { output += d.toString(); });
    claude.stderr.on('data', d => { output += d.toString(); });
    claude.on('close', () => res.json({ response: output.trim(), teamId }));
    claude.on('error', err => res.status(500).json({ error: err.message }));
  } catch (err) {
    res.status(500).json({ error: String(err) });
  }
});

// 보드 회의록
function getLatestBoardMinutes(keywords = []) {
  const dir = path.join(JARVIS, 'state', 'board-minutes');
  try {
    if (!existsSync(dir)) return null;
    const files = readdirSync(dir).filter(f => f.endsWith('.md')).sort().reverse();
    if (!files.length) return null;
    const content = readFileSync(path.join(dir, files[0]), 'utf8');
    if (keywords.length === 0) return { date: files[0].replace('.md', ''), content: content.slice(0, 1000) };
    const lines = content.split('\n');
    const excerpts = [];
    for (let i = 0; i < lines.length && excerpts.length < 5; i++) {
      if (keywords.some(kw => lines[i].toLowerCase().includes(kw))) {
        excerpts.push(lines.slice(Math.max(0, i - 1), Math.min(lines.length, i + 3)).join('\n'));
      }
    }
    return { date: files[0].replace('.md', ''), content: excerpts.join('\n---\n').slice(0, 800) };
  } catch { return null; }
}

app.get('/api/board-minutes', (_req, res) => {
  res.json(getLatestBoardMinutes() || { date: null, content: null });
});

// Vite 빌드 정적 파일 서빙 (프로덕션)
app.use(express.static('dist'));

app.listen(PORT, () => {
  console.log(`[jarvis-office] API server on http://localhost:${PORT}`);
});
