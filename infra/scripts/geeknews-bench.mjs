#!/usr/bin/env node
/**
 * geeknews-bench.mjs — GeekNews 벤치마킹 파이프라인
 *
 * Discord #jarvis-news-webhook 채널의 GeekNews 웹훅 메시지를
 * 크롤링 → LLM 분류 → wiki/RAG 적재 → 주간 리포트 생성.
 *
 * Usage:
 *   node geeknews-bench.mjs --mode crawl           # 일일 크롤 + 분류 + 위키 주입
 *   node geeknews-bench.mjs --mode crawl --dry-run  # fetch만, wiki/discord 미기록
 *   node geeknews-bench.mjs --mode report           # 주간 리포트 → #jarvis-ceo
 *
 * Reuses:
 *   - addFactToWiki()    (wiki-engine.mjs)
 *   - discordSend()      (discord-notify.mjs)
 *   - callHaiku pattern  (wiki-ingester.mjs)
 *   - loadDiscordToken() (extras-gateway.mjs pattern)
 */

import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { addFactToWiki } from '../discord/lib/wiki-engine.mjs';
import { discordSend } from '../lib/discord-notify.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const LEDGER_PATH = join(BOT_HOME, 'state', 'geeknews-ledger.jsonl');
const CURSOR_PATH = join(BOT_HOME, 'state', 'geeknews-cursor.json');
const LOG_PATH = join(BOT_HOME, 'logs', 'geeknews-bench.log');
const RESULTS_DIR = join(BOT_HOME, 'results', 'geeknews-bench');
const CLAUDE_BINARY = process.env.CLAUDE_BINARY || join(homedir(), '.local/bin/claude');

const NEWS_CHANNEL_ID = '1474650972310605886'; // #jarvis-news-webhook
const MAX_CLASSIFY_PER_RUN = 30;               // 일일 예산 캡
const FETCH_TIMEOUT_MS = 10_000;

// SIGTERM graceful shutdown — 크론 timeout 시 부분 결과 보존
let _shutdownRequested = false;
let _pendingCursorId = null;
process.on('SIGTERM', () => {
  log('warn', 'SIGTERM 수신 — graceful shutdown');
  _shutdownRequested = true;
  // 현재까지 처리된 커서 저장
  if (_pendingCursorId) saveCursor(_pendingCursorId);
});

// ── Logging ──────────────────────────────────────────────────────────────────

function log(level, msg, meta = {}) {
  const ts = new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 19).replace('T', ' ');
  const metaStr = Object.keys(meta).length ? ' ' + JSON.stringify(meta) : '';
  const line = `[${ts} KST] [geeknews-bench] [${level.toUpperCase()}] ${msg}${metaStr}\n`;
  process.stderr.write(line);
  try { appendFileSync(LOG_PATH, line); } catch { /* best-effort */ }
}

// ── Discord REST API ─────────────────────────────────────────────────────────

let _cachedToken = null;
async function loadDiscordToken() {
  if (_cachedToken) return _cachedToken;
  const envPath = join(BOT_HOME, 'discord', '.env');
  try {
    const raw = readFileSync(envPath, 'utf-8');
    const m = raw.match(/^DISCORD_TOKEN=(.+)$/m);
    if (m) { _cachedToken = m[1].trim(); return _cachedToken; }
  } catch { /* fall through */ }
  _cachedToken = process.env.DISCORD_TOKEN || null;
  return _cachedToken;
}

/**
 * Discord REST API로 채널 메시지 히스토리 조회.
 * @param {string} channelId
 * @param {string|null} afterId - 이 메시지 ID 이후만 가져옴 (snowflake)
 * @param {number} limit - 최대 100
 * @returns {Promise<object[]>} Discord message objects (oldest-first)
 */
async function fetchChannelMessages(channelId, afterId = null, limit = 100) {
  const token = await loadDiscordToken();
  if (!token) throw new Error('DISCORD_TOKEN 미설정');

  const params = new URLSearchParams({ limit: String(Math.min(limit, 100)) });
  if (afterId) params.set('after', afterId);

  const res = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages?${params}`, {
    headers: { Authorization: `Bot ${token}` },
  });

  // 429 rate limit → Retry-After 대기 후 1회 재시도
  if (res.status === 429) {
    const retryAfter = Number(res.headers.get('retry-after') || '5');
    log('warn', `Discord 429 rate limit — ${retryAfter}s 대기 후 재시도`);
    await sleep(retryAfter * 1000);
    return fetchChannelMessages(channelId, afterId, limit); // 1회 재귀
  }

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`Discord API ${res.status}: ${body.slice(0, 200)}`);
  }

  const messages = await res.json();
  // Discord returns newest-first → reverse to oldest-first
  return messages.reverse();
}

/**
 * 페이징으로 afterId 이후의 모든 메시지를 가져옴.
 * Rate limit: 페이지 간 1초 sleep.
 *
 * 한계: 첫 실행(afterId=null)은 최신 100건만 반환.
 * Discord `after` 파라미터는 미래 방향만 페이징 가능 — 과거 backfill 불가.
 * 전체 히스토리가 필요하면 `before` 기반 역방향 페이징 별도 구현 필요.
 */
async function fetchAllMessagesSince(channelId, afterId = null) {
  const all = [];
  let cursor = afterId;

  for (let page = 0; page < 10; page++) { // 최대 1000건
    const batch = await fetchChannelMessages(channelId, cursor, 100);
    if (batch.length === 0) break;
    all.push(...batch);
    cursor = batch[batch.length - 1].id;
    if (batch.length < 100) break; // 마지막 페이지
    await sleep(1000); // rate limit
  }

  return all;
}

// ── GeekNews URL 추출 ────────────────────────────────────────────────────────

const GEEKNEWS_URL_RE = /https?:\/\/news\.hada\.io\/topic\?id=(\d+)/g;

/**
 * Discord 메시지 배열에서 GeekNews topic URL을 추출.
 * content + embeds 양쪽에서 탐색.
 */
function extractGeekNewsUrls(messages) {
  const results = [];
  const seen = new Set();

  for (const msg of messages) {
    const sources = [msg.content || ''];
    if (msg.embeds) {
      for (const e of msg.embeds) {
        if (e.url) sources.push(e.url);
        if (e.description) sources.push(e.description);
        if (e.title) sources.push(e.title);
      }
    }

    const combined = sources.join(' ');
    for (const match of combined.matchAll(GEEKNEWS_URL_RE)) {
      const topicId = match[1];
      if (seen.has(topicId)) continue;
      seen.add(topicId);

      results.push({
        messageId: msg.id,
        topicId,
        geekNewsUrl: `https://news.hada.io/topic?id=${topicId}`,
        embedTitle: msg.embeds?.[0]?.title || null,
        postedAt: msg.timestamp,
      });
    }
  }

  return results;
}

// ── GeekNews 페이지 스크래핑 ─────────────────────────────────────────────────

/**
 * GeekNews topic 페이지에서 원문 URL, 제목, 한글 요약, 포인트 추출.
 *
 * HTML 구조:
 *   <div class='topictitle link'>
 *     <a href='{originalUrl}' class='bold ud'><h1>{title}</h1></a>
 *     <span class=topicurl>({domain})</span>
 *   </div>
 *   <div class=topicinfo><span id='tp{id}'>{points}</span>P ...</div>
 *   <div class=topic_contents>...<ul><li>요약내용</li></ul>...</div>
 */
async function fetchGeekNewsArticle(topicId) {
  const url = `https://news.hada.io/topic?id=${topicId}`;
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': 'Jarvis-GeekNews-Bench/1.0' },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (!res.ok) return null;
    const html = await res.text();

    // 제목
    const titleMatch = html.match(/<h1>([^<]+)<\/h1>/);
    const title = titleMatch ? titleMatch[1].trim() : null;

    // 원문 URL (topictitle 내 외부 링크)
    const urlMatch = html.match(/<a href=['"]([^'"]+)['"]\s+class=['"]bold ud['"]/);
    let originalUrl = urlMatch ? urlMatch[1] : null;
    // self-post인 경우 (원문 URL이 자기 자신)
    if (originalUrl && originalUrl.includes('news.hada.io/topic')) {
      originalUrl = null;
    }

    // 포인트
    const pointsMatch = html.match(/<span id=['"]tp\d+['"]>(\d+)<\/span>P/);
    const points = pointsMatch ? parseInt(pointsMatch[1], 10) : 0;

    // 한글 요약 (topic_contents 내 텍스트)
    const contentsMatch = html.match(/<div id=['"]topic_contents['"]>([\s\S]*?)<\/div>/);
    let summary = '';
    if (contentsMatch) {
      summary = contentsMatch[1]
        .replace(/<[^>]+>/g, ' ')           // strip HTML tags
        .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))  // &#39; → '
        .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCharCode(parseInt(h, 16)))  // &#x27; → '
        .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
        .replace(/&[a-z]+;/g, ' ')          // 나머지 named entity
        .replace(/\s+/g, ' ')               // collapse whitespace
        .trim()
        .slice(0, 2000);
    }

    return { topicId, title, originalUrl, summary, points, geekNewsUrl: url };
  } catch (e) {
    log('warn', `GeekNews fetch 실패: topic ${topicId}`, { error: e.message });
    return null;
  }
}

// ── 원문 콘텐츠 Fetching ────────────────────────────────────────────────────

async function fetchArticleContent(url) {
  if (!url) return null;
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': 'Jarvis-GeekNews-Bench/1.0' },
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
      redirect: 'follow',
    });
    if (!res.ok) return null;
    const html = await res.text();

    // HTML → plain text
    const text = html
      .replace(/<script[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style[\s\S]*?<\/style>/gi, ' ')
      .replace(/<[^>]+>/g, ' ')
      .replace(/&[a-z]+;/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, 3000);

    return text.length > 100 ? text : null; // 너무 짧으면 무의미
  } catch {
    return null;
  }
}

// ── LLM 분류 (callHaiku) ────────────────────────────────────────────────────

function callHaiku(prompt, timeoutMs = 60_000) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const proc = spawn(
      CLAUDE_BINARY,
      ['--model', 'claude-haiku-4-5-20251001', '--output-format', 'text', '--max-turns', '1', '--tools', '', '--dangerously-skip-permissions'],
      { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env } },
    );
    let out = '';
    let err = '';
    proc.stdout.on('data', (d) => { out += d; });
    proc.stderr.on('data', (d) => { err += d; });
    proc.stdin.write(prompt, 'utf-8');
    proc.stdin.end();

    // spawn에는 timeout 옵션이 없으므로 수동 kill
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        proc.kill('SIGTERM');
        reject(new Error(`haiku timeout (${timeoutMs}ms)`));
      }
    }, timeoutMs);

    proc.on('close', (code) => {
      clearTimeout(timer);
      if (settled) return;
      settled = true;
      if (code === 0) resolve(out.trim());
      else reject(new Error(`haiku exit ${code}: ${err.slice(0, 200)}`));
    });
    proc.on('error', (e) => {
      clearTimeout(timer);
      if (!settled) { settled = true; reject(e); }
    });
  });
}

async function classifyArticle({ title, summary, content }) {
  const contentSection = content
    ? `원문 콘텐츠 (첫 2000자):\n${content.slice(0, 2000)}`
    : '(원문 fetch 실패 — 아래 요약만으로 판단)';

  const prompt = `당신은 Jarvis 콘텐츠 분류기입니다.
Jarvis 오너는 한국인 시니어 백엔드 개발자(Java/Spring/Kafka/AWS)이며,
관심 분야: 커리어 성장, 시스템 운영/자동화, 기술 트렌드, AI/LLM, 투자/금융, 건강.

아래 기사가 오너에게 유용한지 판단하세요.

기사 제목: ${title || '(없음)'}
GeekNews 한글 요약: ${summary || '(없음)'}
${contentSection}

JSON만 응답하세요 (다른 텍스트 없이):
{"useful":true/false,"domain":"ops|career|knowledge|trading|health","reason":"1줄 한국어 설명","keywords":["kw1","kw2","kw3"]}

도메인 기준:
- ops: 인프라, DevOps, 모니터링, 자동화, AI 운영, LLM 도구
- career: 백엔드 개발, Java/Spring/Kafka, 면접, 커리어 전략
- knowledge: 아키텍처 패턴, 기술 트렌드, 오픈소스, 프로그래밍 언어, AI/ML
- trading: 시장 트렌드, 핀테크, 투자 기술
- health: 개발자 건강, 에르고노믹스

판정 기준 (엄격하게 — 기대 useful 비율 25~35%):
- useful=true: 오너가 즉시 행동하거나 시스템에 적용할 수 있는 구체적 인사이트
- useful=false: 아래에 해당하면 기술 관련이라도 false
  * 하드웨어/물리 장치, OS 세부 커널 구현, 게임/엔터, 역사/인물, 일반 과학
  * "알면 좋지만 당장 쓸 데 없는" 교양 지식
  * 특정 언어/프레임워크의 튜토리얼 (Java/Spring/Kafka/AWS/LLM 제외)
  * 제품 출시 뉴스만 있고 기술적 인사이트가 없는 기사`;

  try {
    const raw = await callHaiku(prompt);
    // JSON 블록 추출 (코드펜스 감싸는 경우 대비)
    const jsonMatch = raw.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      log('warn', 'LLM 응답에 JSON 없음', { title, raw: raw.slice(0, 200) });
      return { useful: false, domain: 'knowledge', reason: 'classification_parse_error', keywords: [] };
    }
    return JSON.parse(jsonMatch[0]);
  } catch (e) {
    log('warn', `LLM 분류 실패: ${title}`, { error: e.message });
    return { useful: false, domain: 'knowledge', reason: 'classification_error', keywords: [] };
  }
}

// ── Ledger (JSONL) ──────────────────────────────────────────────────────────

function ensureDirs() {
  for (const dir of [dirname(LEDGER_PATH), RESULTS_DIR, dirname(LOG_PATH)]) {
    mkdirSync(dir, { recursive: true });
  }
}

const LEDGER_RETENTION_DAYS = 90;

function loadLedger() {
  if (!existsSync(LEDGER_PATH)) return [];
  const cutoff = new Date(Date.now() - LEDGER_RETENTION_DAYS * 86400_000).toISOString();
  return readFileSync(LEDGER_PATH, 'utf-8')
    .split('\n')
    .filter(Boolean)
    .map((line) => { try { return JSON.parse(line); } catch { return null; } })
    .filter((e) => e && e.ts >= cutoff);
}

/** dedup용 topicId Set — O(1) lookup */
function buildProcessedSet(ledger) {
  return new Set(ledger.map((e) => e.topicId).filter(Boolean));
}

function appendLedger(entry) {
  appendFileSync(LEDGER_PATH, JSON.stringify(entry) + '\n');
}

/** 마지막으로 본 Discord 메시지 ID (ledger와 별도 — 미분류 건도 커서 전진) */
function loadCursor() {
  try { return JSON.parse(readFileSync(CURSOR_PATH, 'utf-8')).lastMessageId || null; } catch { return null; }
}
function saveCursor(messageId) {
  writeFileSync(CURSOR_PATH, JSON.stringify({ lastMessageId: messageId, updatedAt: new Date().toISOString() }));
}

// ── Mode: Crawl ─────────────────────────────────────────────────────────────

async function modeCrawl(dryRun = false) {
  ensureDirs();
  const ledger = loadLedger();
  const lastMsgId = loadCursor();

  log('info', `크롤 시작 (cursor: ${lastMsgId || 'none'}, dryRun: ${dryRun})`);

  // 1. Discord 메시지 fetch
  const messages = await fetchAllMessagesSince(NEWS_CHANNEL_ID, lastMsgId);
  log('info', `Discord 메시지 ${messages.length}건 수신`);

  if (messages.length === 0) {
    log('info', '새 메시지 없음 — 종료');
    console.log('새 메시지 없음');
    return;
  }

  // 2. GeekNews URL 추출
  const topics = extractGeekNewsUrls(messages);
  const processedSet = buildProcessedSet(ledger);
  const newTopics = topics.filter((t) => !processedSet.has(t.topicId));
  log('info', `GeekNews 토픽 ${topics.length}건 추출, 신규 ${newTopics.length}건`);

  if (newTopics.length === 0) {
    log('info', '신규 토픽 없음 — 종료');
    console.log('신규 토픽 없음');
    return;
  }

  // 3-5. 각 토픽 처리
  let classified = 0;
  let usefulCount = 0;
  let lastProcessedMsgId = null;
  const results = [];

  for (const topic of newTopics) {
    if (_shutdownRequested) {
      log('info', 'SIGTERM으로 중단 — 다음 실행에서 나머지 처리');
      break;
    }
    if (classified >= MAX_CLASSIFY_PER_RUN) {
      log('info', `일일 분류 캡 도달 (${MAX_CLASSIFY_PER_RUN}건)`);
      break;
    }

    // 3. GeekNews 페이지 스크래핑
    const article = await fetchGeekNewsArticle(topic.topicId);
    if (!article) {
      appendLedger({
        ts: new Date().toISOString(), messageId: topic.messageId,
        topicId: topic.topicId, title: topic.embedTitle, fetchStatus: 'geeknews_fetch_error',
        useful: false, wikiInjected: false,
      });
      continue;
    }

    // 4. 원문 콘텐츠 fetch (실패해도 계속)
    const content = await fetchArticleContent(article.originalUrl);

    // 5. LLM 분류
    const classification = await classifyArticle({
      title: article.title,
      summary: article.summary,
      content,
    });
    classified++;

    // 6. 위키 주입 (useful + not dry-run)
    let wikiInjected = false;
    if (classification.useful && !dryRun) {
      const urlPart = article.originalUrl ? ` (원문: ${article.originalUrl})` : '';
      const fact = `GeekNews: ${article.title} — ${classification.reason}${urlPart}`;
      try {
        addFactToWiki(null, fact, { domainOverride: classification.domain, source: 'geeknews-bench' });
        wikiInjected = true;
      } catch (e) {
        log('warn', `위키 주입 실패: ${article.title}`, { error: e.message });
      }
    }

    if (classification.useful) usefulCount++;

    const entry = {
      ts: new Date().toISOString(),
      messageId: topic.messageId,
      topicId: topic.topicId,
      title: article.title,
      geekNewsUrl: article.geekNewsUrl,
      originalUrl: article.originalUrl,
      points: article.points,
      useful: classification.useful,
      domain: classification.domain,
      reason: classification.reason,
      keywords: classification.keywords,
      wikiInjected,
      fetchStatus: 'ok',
    };

    if (!dryRun) appendLedger(entry);
    results.push(entry);
    lastProcessedMsgId = topic.messageId;
    _pendingCursorId = lastProcessedMsgId; // SIGTERM 시 저장용

    log('info', `[${classification.useful ? 'O' : 'X'}] ${article.title} → ${classification.domain}`, {
      points: article.points,
    });

    await sleep(500); // rate limit between articles
  }

  // 커서 업데이트: 마지막 처리 완료 건까지만 전진 (��분류 건 보존)
  if (!dryRun && lastProcessedMsgId) saveCursor(lastProcessedMsgId);

  // 결과 요약
  const summary = [
    `GeekNews 크롤 완료: ${newTopics.length}건 중 ${classified}건 분류`,
    `유용 판정: ${usefulCount}건 / ${classified}건 (${classified ? Math.round(usefulCount / classified * 100) : 0}%)`,
    dryRun ? '(dry-run — 위키/레저 미기록)' : `위키 주입: ${results.filter(r => r.wikiInjected).length}건`,
  ].join('\n');

  log('info', summary.replace(/\n/g, ' | '));
  console.log(summary);
}

// ── Mode: Report ────────────────────────────────────────────────────────────

async function modeReport() {
  ensureDirs();
  const ledger = loadLedger();

  // 최근 7일 필터
  const weekAgo = new Date(Date.now() - 7 * 86400_000).toISOString();
  const recent = ledger.filter((e) => e.ts >= weekAgo);
  const useful = recent.filter((e) => e.useful);

  if (recent.length === 0) {
    log('info', '최근 7일 데이터 없음');
    console.log('최근 7일 데이터 없음 — 리포트 생략');
    return;
  }

  // 도메인별 집계
  const domainCounts = {};
  const domainKeywords = {};
  for (const e of useful) {
    domainCounts[e.domain] = (domainCounts[e.domain] || 0) + 1;
    if (e.keywords) {
      for (const kw of e.keywords) {
        domainKeywords[kw] = (domainKeywords[kw] || 0) + 1;
      }
    }
  }

  // 도메인별 정렬
  const domainSorted = Object.entries(domainCounts)
    .sort(([, a], [, b]) => b - a);

  // TOP 기사 (points 순)
  const topArticles = useful
    .filter((e) => e.title)
    .sort((a, b) => (b.points || 0) - (a.points || 0))
    .slice(0, 5);

  // 트렌드 키워드 (빈도 순)
  const trendKeywords = Object.entries(domainKeywords)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 10)
    .map(([kw]) => kw);

  // 주차 계산
  const now = new Date(Date.now() + 9 * 3600_000);
  const weekStart = new Date(now - 7 * 86400_000);
  const weekLabel = `${weekStart.toISOString().slice(5, 10).replace('-', '/')} ~ ${now.toISOString().slice(5, 10).replace('-', '/')}`;
  const yearWeek = getISOWeek(now);

  const usefulPct = recent.length ? Math.round(useful.length / recent.length * 100) : 0;

  // 리포트 생성
  let report = `## GeekNews 주간 벤치마크 (${yearWeek})\n`;
  report += `**기간**: ${weekLabel} | **처리**: ${recent.length}건 | **유용**: ${useful.length}건 (${usefulPct}%)\n\n`;

  if (domainSorted.length > 0) {
    report += '### 도메인별\n';
    for (const [domain, count] of domainSorted) {
      const domainArticles = useful.filter((e) => e.domain === domain);
      const kwSample = [...new Set(domainArticles.flatMap((e) => e.keywords || []))].slice(0, 3).join(', ');
      report += `- **${domain}** · ${count}건${kwSample ? ` (${kwSample})` : ''}\n`;
    }
    report += '\n';
  }

  if (topArticles.length > 0) {
    report += '### TOP 기사\n';
    for (let i = 0; i < topArticles.length; i++) {
      const a = topArticles[i];
      report += `${i + 1}. **${a.title}** — ${a.reason} (${a.domain}) [${a.points || 0}P]\n`;
    }
    report += '\n';
  }

  if (trendKeywords.length > 0) {
    report += `### 트렌드 키워드\n${trendKeywords.join(', ')}\n`;
  }

  // 파일 저장
  const resultFile = join(RESULTS_DIR, `${now.toISOString().slice(0, 10)}.md`);
  mkdirSync(RESULTS_DIR, { recursive: true });
  writeFileSync(resultFile, report);
  log('info', `리포트 저장: ${resultFile}`);

  // Discord 전송
  try {
    await discordSend(report, 'jarvis-ceo', { username: 'GeekNews Bench' });
    log('info', '#jarvis-ceo 리포트 전송 완료');
  } catch (e) {
    log('error', 'Discord 전송 실패', { error: e.message });
  }

  console.log(report);
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

function getISOWeek(date) {
  const d = new Date(date);
  d.setHours(0, 0, 0, 0);
  d.setDate(d.getDate() + 3 - ((d.getDay() + 6) % 7));
  const yearStart = new Date(d.getFullYear(), 0, 1);
  const weekNo = Math.ceil(((d - yearStart) / 86400_000 + 1) / 7);
  return `${d.getFullYear()}-W${String(weekNo).padStart(2, '0')}`;
}

// ── Main ─────────────────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const mode = args.includes('--mode') ? args[args.indexOf('--mode') + 1] : 'crawl';
const dryRun = args.includes('--dry-run');

(async () => {
  try {
    if (mode === 'crawl') await modeCrawl(dryRun);
    else if (mode === 'report') await modeReport();
    else { console.error(`Unknown mode: ${mode}`); process.exit(1); }
  } catch (e) {
    log('error', `치명적 오류: ${e.message}`, { stack: e.stack?.slice(0, 300) });
    console.error(e.message);
    process.exit(1);
  }
})();