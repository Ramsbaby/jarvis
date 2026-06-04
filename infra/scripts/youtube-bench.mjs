#!/usr/bin/env node
/**
 * youtube-bench.mjs — YouTube 영상 → LLM Wiki 적재 파이프라인
 *
 * geeknews-bench.mjs 패턴을 YouTube에 적용.
 * 기존 인프라(addFactToWiki, callHaiku, discord-notify) 100% 재사용.
 *
 * Usage:
 *   node youtube-bench.mjs <youtube-url> [options]
 *
 * Options:
 *   --dry-run           wiki/discord 미기록, stdout 출력만
 *   --domain <domain>   도메인 강제 지정 (기본: LLM 자동 판별)
 *   --notify            Discord #jarvis-dev 요약 알림 전송
 *   --lang <ko|en>      자막 언어 우선순위 (기본: ko, 폴백 en)
 *
 * Wiki 항목 형식:
 *   - [date] [source:youtube-bench] [제목]: [핵심 인사이트] (원문: url)
 *
 * Ledger: ~/jarvis/runtime/state/youtube-bench-ledger.jsonl
 *   — 처리된 videoId를 기록해 중복 적재 방지.
 *
 * Log: ~/jarvis/runtime/logs/youtube-bench.log
 */

import { existsSync, mkdirSync, appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir, tmpdir } from 'node:os';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { addFactToWiki } from '../discord/lib/wiki-engine.mjs';
import { discordSend } from '../lib/discord-notify.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const HOME     = homedir();
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis/runtime');

const LEDGER_PATH  = join(BOT_HOME, 'state', 'youtube-bench-ledger.jsonl');
const LOG_PATH     = join(BOT_HOME, 'logs',  'youtube-bench.log');
const CLAUDE_BIN   = process.env.CLAUDE_BINARY || join(HOME, '.local/bin/claude');
const YT_DLP_BIN   = process.env.YT_DLP_BINARY || '/opt/homebrew/bin/yt-dlp';

const MAX_TRANSCRIPT_CHARS = 8000;  // Haiku 컨텍스트 절약
const MAX_FACTS_PER_VIDEO  = 7;     // 영상 1편당 최대 wiki 항목 수
const HAIKU_TIMEOUT_MS     = 90_000;

// Discord 알림 채널 — #jarvis-dev
const NOTIFY_CHANNEL_ID = process.env.YOUTUBE_BENCH_CHANNEL || '1299975878607130788';

// ── CLI 파싱 ─────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const urlArg   = args.find(a => a.startsWith('http'));
const dryRun   = args.includes('--dry-run');
const notify   = args.includes('--notify');
const langArg  = (() => { const i = args.indexOf('--lang'); return i >= 0 ? args[i+1] : 'ko'; })();
const domainForced = (() => { const i = args.indexOf('--domain'); return i >= 0 ? args[i+1] : null; })();

if (!urlArg) {
  process.stderr.write('Usage: node youtube-bench.mjs <youtube-url> [--dry-run] [--domain <d>] [--notify]\n');
  process.exit(1);
}

// ── 로거 (KST) ───────────────────────────────────────────────────────────────

function kstNow() {
  return new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' }).slice(0, 19);
}

function log(level, msg, meta = {}) {
  const ts = kstNow();
  const metaStr = Object.keys(meta).length ? ' ' + JSON.stringify(meta) : '';
  const line = `[${ts} KST] [youtube-bench] [${level.toUpperCase()}] ${msg}${metaStr}\n`;
  process.stderr.write(line);
  try {
    mkdirSync(dirname(LOG_PATH), { recursive: true });
    appendFileSync(LOG_PATH, line);
  } catch { /* best-effort */ }
}

// ── Ledger (중복 방지) ────────────────────────────────────────────────────────

function loadLedger() {
  const seen = new Set();
  if (!existsSync(LEDGER_PATH)) return seen;
  for (const line of readFileSync(LEDGER_PATH, 'utf-8').split('\n')) {
    try {
      const obj = JSON.parse(line);
      if (obj.videoId) seen.add(obj.videoId);
    } catch { /* skip */ }
  }
  return seen;
}

function appendLedger(entry) {
  mkdirSync(dirname(LEDGER_PATH), { recursive: true });
  appendFileSync(LEDGER_PATH, JSON.stringify(entry) + '\n', 'utf-8');
}

// ── YouTube 유틸 ─────────────────────────────────────────────────────────────

/**
 * URL에서 videoId 추출.
 * 지원 형식: youtu.be/ID, youtube.com/watch?v=ID, youtube.com/shorts/ID
 */
function extractVideoId(url) {
  const patterns = [
    /[?&]v=([A-Za-z0-9_-]{11})/,
    /youtu\.be\/([A-Za-z0-9_-]{11})/,
    /shorts\/([A-Za-z0-9_-]{11})/,
  ];
  for (const p of patterns) {
    const m = url.match(p);
    if (m) return m[1];
  }
  return null;
}

/**
 * yt-dlp로 자막 VTT 파일 다운로드.
 * 한국어 우선 → 영어 폴백 → 자동생성 자막 폴백.
 * Returns: { vttPath, lang } or null
 */
function downloadSubtitles(videoId, tmpDir, lang = 'ko') {
  const outTemplate = join(tmpDir, 'yt_sub');
  const langs = lang === 'ko' ? ['ko', 'en'] : ['en', 'ko'];

  for (const tryLang of langs) {
    // 수동 자막 먼저 시도
    for (const subFlag of ['--write-sub', '--write-auto-sub']) {
      const result = spawnSync(YT_DLP_BIN, [
        subFlag,
        '--sub-lang', tryLang,
        '--skip-download',
        '--output', outTemplate,
        '--quiet',
        `https://www.youtube.com/watch?v=${videoId}`,
      ], { timeout: 30_000, encoding: 'utf-8' });

      const vttPath = `${outTemplate}.${tryLang}.vtt`;
      if (existsSync(vttPath)) {
        return { vttPath, lang: tryLang };
      }
    }
  }
  return null;
}

/**
 * VTT → 중복 없는 정제 텍스트 변환.
 */
function parseVtt(vttPath) {
  const raw = readFileSync(vttPath, 'utf-8');
  const lines = raw.split('\n');
  const texts = [];
  let prev = '';
  for (const line of lines) {
    if (line.includes('-->') || line.startsWith('WEBVTT') ||
        line.startsWith('Kind:') || line.startsWith('Language:') ||
        line.trim() === '') continue;
    // HTML 태그 제거
    const clean = line.replace(/<[^>]+>/g, '').trim();
    if (clean && clean !== prev) {
      texts.push(clean);
      prev = clean;
    }
  }
  return texts.join(' ');
}

/**
 * yt-dlp로 영상 제목 메타데이터 조회.
 */
function fetchVideoTitle(videoId) {
  const result = spawnSync(YT_DLP_BIN, [
    '--get-title', '--quiet',
    `https://www.youtube.com/watch?v=${videoId}`,
  ], { timeout: 15_000, encoding: 'utf-8' });
  return (result.stdout || '').trim() || `YouTube 영상 (${videoId})`;
}

// ── LLM 분류 (geeknews-bench 동일 패턴) ─────────────────────────────────────

function callHaiku(prompt, timeoutMs = HAIKU_TIMEOUT_MS) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const proc = spawn(
      CLAUDE_BIN,
      ['--model', 'claude-haiku-4-5-20251001', '--output-format', 'text',
       '--max-turns', '1', '--tools', '', '--dangerously-skip-permissions'],
      { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env } },
    );
    let out = '';
    let err = '';
    proc.stdout.on('data', d => { out += d; });
    proc.stderr.on('data', d => { err += d; });
    proc.stdin.write(prompt, 'utf-8');
    proc.stdin.end();

    const timer = setTimeout(() => {
      if (!settled) { settled = true; proc.kill('SIGTERM'); reject(new Error(`haiku timeout (${timeoutMs}ms)`)); }
    }, timeoutMs);

    proc.on('close', code => {
      clearTimeout(timer);
      if (settled) return;
      settled = true;
      if (code === 0) resolve(out.trim());
      else reject(new Error(`haiku exit ${code}: ${err.slice(0, 200)}`));
    });
    proc.on('error', e => { clearTimeout(timer); if (!settled) { settled = true; reject(e); } });
  });
}

/**
 * 트랜스크립트에서 wiki 항목으로 적합한 핵심 인사이트 추출.
 * Returns: { useful: bool, domain: string, facts: string[], title_ko: string }
 */
async function extractInsights({ title, transcript, videoUrl }) {
  const truncated = transcript.length > MAX_TRANSCRIPT_CHARS
    ? transcript.slice(0, MAX_TRANSCRIPT_CHARS) + ' ...(이하 생략)'
    : transcript;

  const prompt = `당신은 Jarvis LLM Wiki 콘텐츠 큐레이터입니다.
Jarvis 오너: 한국인 시니어 백엔드 개발자(Java/Spring/Kafka/AWS), AI 자동화 관심, 커리어 성장 중.

아래 YouTube 영상 트랜스크립트에서 오너에게 유용한 핵심 인사이트를 추출하세요.

영상 제목: ${title}
URL: ${videoUrl}

트랜스크립트:
${truncated}

응답 형식 — JSON만 (다른 텍스트 없이):
{
  "useful": true/false,
  "domain": "ops|career|knowledge|trading|health",
  "title_ko": "영상 제목 (한국어 1줄 요약)",
  "facts": [
    "핵심 인사이트 1 (1~2문장, 구체적·행동 가능한 내용)",
    "핵심 인사이트 2",
    ...
  ]
}

규칙:
- facts는 ${MAX_FACTS_PER_VIDEO}개 이내, 각각 완결된 문장
- useful=false면 facts는 빈 배열
- 모든 텍스트는 한국어
- 일반론·뻔한 내용 제외, 주인님이 즉시 적용 가능한 구체 인사이트만

도메인 기준:
- ops: 인프라, AI 자동화, LLM 도구, Second Brain, Claude Code
- career: 개발 커리어, 기술 역량, 면접, 이직
- knowledge: 아키텍처, 기술 트렌드, AI/LLM 개념, 오픈소스
- trading: 금융, 투자, 시장 분석
- health: 개발자 건강, 습관, 루틴`;

  try {
    const raw = await callHaiku(prompt);
    const jsonMatch = raw.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      log('warn', 'LLM 응답에 JSON 없음', { raw: raw.slice(0, 200) });
      return { useful: false, domain: 'knowledge', title_ko: title, facts: [] };
    }
    return JSON.parse(jsonMatch[0]);
  } catch (e) {
    log('warn', `LLM 인사이트 추출 실패: ${e.message}`);
    return { useful: false, domain: 'knowledge', title_ko: title, facts: [] };
  }
}

// ── 임시 디렉토리 관리 ────────────────────────────────────────────────────────

function makeTmpDir() {
  const dir = join(tmpdir(), `jarvis-ytbench-${Date.now()}`);
  mkdirSync(dir, { recursive: true });
  return dir;
}

function cleanTmpDir(dir) {
  try { spawnSync('rm', ['-rf', dir]); } catch { /* best-effort */ }
}

// ── 메인 ─────────────────────────────────────────────────────────────────────

async function main() {
  log('info', `시작: ${urlArg}`, { dryRun, lang: langArg, domainForced });

  // 1. videoId 추출
  const videoId = extractVideoId(urlArg);
  if (!videoId) {
    log('error', '유효한 YouTube URL이 아닙니다', { url: urlArg });
    process.exit(1);
  }
  log('info', `videoId: ${videoId}`);

  // 2. 중복 체크
  const seen = loadLedger();
  if (seen.has(videoId)) {
    log('info', '이미 처리된 영상 — 스킵', { videoId });
    process.exit(0);
  }

  // 3. 자막 다운로드
  const tmpDir = makeTmpDir();
  let transcriptText = '';
  let subtitleLang = 'unknown';
  try {
    log('info', '자막 다운로드 중...');
    const subResult = downloadSubtitles(videoId, tmpDir, langArg);
    if (!subResult) {
      log('warn', '자막 없음 — 영상 제목만으로 분류 진행', { videoId });
    } else {
      transcriptText = parseVtt(subResult.vttPath);
      subtitleLang = subResult.lang;
      log('info', `자막 확보: ${transcriptText.length}자 (${subtitleLang})`);
    }
  } finally {
    cleanTmpDir(tmpDir);
  }

  // 4. 영상 제목 조회
  log('info', '영상 제목 조회 중...');
  const title = fetchVideoTitle(videoId);
  log('info', `제목: ${title}`);

  // 5. LLM 인사이트 추출
  log('info', 'LLM 인사이트 추출 중...');
  const result = await extractInsights({
    title,
    transcript: transcriptText,
    videoUrl: urlArg,
  });
  log('info', `분류 결과`, {
    useful: result.useful,
    domain: result.domain,
    factsCount: result.facts?.length ?? 0,
  });

  // 6. wiki 적재
  const domain = domainForced || result.domain || 'knowledge';
  const addedFacts = [];

  if (result.useful && result.facts && result.facts.length > 0) {
    if (!dryRun) {
      for (const fact of result.facts.slice(0, MAX_FACTS_PER_VIDEO)) {
        const factText = `[${result.title_ko || title}] ${fact} (원문: ${urlArg})`;
        addFactToWiki(null, factText, { domainOverride: domain, source: 'youtube-bench' });
        addedFacts.push(factText);
        log('info', `wiki 적재: ${fact.slice(0, 60)}...`);
      }
    } else {
      for (const fact of result.facts.slice(0, MAX_FACTS_PER_VIDEO)) {
        console.log(`[DRY-RUN] [${domain}] ${fact}`);
        addedFacts.push(fact);
      }
    }
  } else {
    log('info', '유용 판정 실패 — wiki 미적재');
  }

  // 7. Ledger 기록 (dry-run이 아닐 때만)
  if (!dryRun) {
    appendLedger({
      videoId,
      url: urlArg,
      title,
      title_ko: result.title_ko || title,
      domain,
      useful: result.useful,
      factsAdded: addedFacts.length,
      processedAt: new Date().toISOString(),
    });
  }

  // 8. Discord 알림 (--notify 옵션)
  if (notify && !dryRun && addedFacts.length > 0) {
    const summary = [
      `📺 **YouTube Bench 완료**`,
      `영상: ${result.title_ko || title}`,
      `도메인: \`${domain}\` · 적재: ${addedFacts.length}건`,
      '',
      addedFacts.slice(0, 3).map(f => `• ${f.replace(/ \(원문:.*\)$/, '')}`).join('\n'),
      addedFacts.length > 3 ? `... 외 ${addedFacts.length - 3}건` : '',
    ].filter(Boolean).join('\n');

    try {
      await discordSend(NOTIFY_CHANNEL_ID, summary);
      log('info', 'Discord 알림 전송 완료');
    } catch (e) {
      log('warn', `Discord 알림 실패: ${e.message}`);
    }
  }

  // 9. 결과 출력
  const status = result.useful ? `✅ ${addedFacts.length}건 적재` : '⏭️  유용하지 않음 — 스킵';
  log('info', `완료: ${status}`, { videoId, domain, dryRun });

  console.log(JSON.stringify({
    videoId,
    title: result.title_ko || title,
    domain,
    useful: result.useful,
    factsAdded: addedFacts.length,
    dryRun,
  }, null, 2));
}

main().catch(e => {
  log('error', `예상치 못한 오류: ${e.message}`, { stack: e.stack?.slice(0, 300) });
  process.exit(1);
});
