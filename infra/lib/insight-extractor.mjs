/**
 * insight-extractor.mjs — Synthesis Layer
 *
 * 최근 세션 요약 파일들을 Claude Opus로 분석해
 * decisions / patterns / open_items 를 추출하고:
 *   1) rag/auto-insights/YYYY-MM-DD.md 저장
 *   2) 결정사항은 rag/decisions.md 에 append
 *   3) auto-insights 파일을 lancedb에 재인덱싱
 *
 * 실행: node ~/.jarvis/lib/insight-extractor.mjs [--days N]
 * 크론: 30 3 * * * (session-summarizer 30분 후)
 */

import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync, statSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { query } from '@anthropic-ai/claude-agent-sdk';
import { addTask } from './task-store.mjs';

// nested session guard bypass
delete process.env.CLAUDECODE;

// ── 경로 설정 ──────────────────────────────────────────────────────────────
const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const SESSION_SUMMARY_DIR = join(BOT_HOME, 'state', 'session-summaries');
const AUTO_INSIGHTS_DIR   = join(BOT_HOME, 'rag', 'auto-insights');
// decisions는 주간 파일로 분리 (decisions-YYYY-WXX.md)
// 하나의 flat 파일 → 모순/무한증가 문제 해결
function getDecisionsFile(date) {
  const d = new Date(date);
  const startOfYear = new Date(d.getFullYear(), 0, 1);
  const week = Math.ceil(((d - startOfYear) / 86400_000 + startOfYear.getDay() + 1) / 7);
  const weekStr = String(week).padStart(2, '0');
  return join(BOT_HOME, 'rag', `decisions-${d.getFullYear()}-W${weekStr}.md`);
}
const DECISIONS_FILE      = join(BOT_HOME, 'rag', 'decisions.md'); // 레거시 (기존 데이터 보존용)
const MEMORY_FILE         = join(BOT_HOME, 'rag', 'memory.md');
const STATE_FILE          = join(BOT_HOME, 'state', 'insight-extractor-state.json');
const MODELS_FILE         = join(BOT_HOME, 'config', 'models.json');
const CLAUDE_BIN          = process.env.CLAUDE_BINARY || join(homedir(), '.local/bin/claude');
const LOGS_DIR            = join(BOT_HOME, 'logs');

const MODELS = JSON.parse(readFileSync(MODELS_FILE, 'utf-8'));
const OPUS_MODEL = MODELS.large || 'claude-opus-4-6';

// --days 인자
// 크론 자동 실행: 기본 1일 (어제 세션만 분석, 슬라이딩 윈도우 중복 방지)
// 수동 catch-up: --days 7 등으로 지정
const daysArg = (() => {
  const idx = process.argv.indexOf('--days');
  if (idx !== -1) return parseInt(process.argv[idx + 1], 10);
  // --force 없이 실행 = 크론 자동 실행 → 1일
  // --force 있으면 3일 (수동 재실행 catch-up)
  return process.argv.includes('--force') ? 3 : 1;
})();

// ── 로그 헬퍼 ──────────────────────────────────────────────────────────────
function log(level, msg) {
  const ts = new Date().toISOString().slice(0, 19).replace('T', ' ');
  const line = `[${ts}] [${level.toUpperCase()}] ${msg}`;
  // stdout만 사용 — crontab이 >> insight-extractor.log 로 리다이렉트
  // appendFileSync 제거: 이중 기록(stdout 리다이렉트 + 직접 쓰기) 방지
  process.stdout.write(line + '\n');
}

// ── 상태 관리 ──────────────────────────────────────────────────────────────
function loadState() {
  try { return JSON.parse(readFileSync(STATE_FILE, 'utf-8')); }
  catch { return { lastRun: null, processedDates: [] }; }
}
function saveState(state) {
  try {
    mkdirSync(join(BOT_HOME, 'state'), { recursive: true });
    writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
  } catch (err) { log('warn', `상태 저장 실패: ${err.message}`); }
}
function getTodayStr() { return new Date().toISOString().slice(0, 10); }

// ── Owner userId 목록 (세션 파일 필터링용) ────────────────────────────────
// 파일명 패턴: {channelId}-{userId}.md
// Family 등 다른 사용자 세션이 오염되지 않도록 owner userId만 포함
const OWNER_USER_IDS = (process.env.OWNER_USER_IDS || process.env.OWNER_DISCORD_ID || '').split(',').filter(Boolean);

// ── N일 이내 세션 요약 파일 수집 (채널별 메타데이터 포함) ─────��───────────
function getRecentSummaryFiles(days) {
  try {
    const cutoff = Date.now() - days * 86400_000;
    return readdirSync(SESSION_SUMMARY_DIR)
      .filter(f => f.endsWith('.md') && !f.endsWith('.bak'))
      .filter(f => {
        // {channelId}-{userId}.md 패턴에서 userId 추출하여 owner만 통과
        const parts = f.replace('.md', '').split('-');
        const userId = parts[parts.length - 1];
        return OWNER_USER_IDS.includes(userId);
      })
      .map(f => {
        const fp = join(SESSION_SUMMARY_DIR, f);
        const parts = f.replace('.md', '').split('-');
        const channelId = parts.slice(0, -1).join('-');
        return { file: fp, channelId, name: f };
      })
      .filter(({ file: fp }) => {
        try { return statSync(fp).mtimeMs >= cutoff; }
        catch { return false; }
      });
  } catch (err) {
    log('warn', `세션 파일 수집 실패: ${err.message}`);
    return [];
  }
}

// ── Claude Opus 호출 ────────────────────────────────────────────────────────
async function synthesizeWithOpus(combinedContent) {
  const prompt = `다음은 최근 ${daysArg}일간 자비스와 Owner의 대화 세션 요약입니다.

<sessions>
${combinedContent}
</sessions>

위 내용을 분석해서 다음 형식의 JSON 만 반환하세요. 추가 설명 없이 JSON만:

{
  "decisions": [
    { "date": "YYYY-MM-DD", "project": "프로젝트명", "decision": "결정 내용", "reason": "이유", "channel": "채널ID" }
  ],
  "open_items": [
    { "item": "미완료 항목", "context": "맥락", "priority": "high|medium|low", "channel": "채널ID" }
  ],
  "patterns": [
    { "pattern": "반복 패턴 설명", "frequency": "횟수 또는 빈도" }
  ],
  "summary": "이 기간 전체를 1-2문장으로 요약"
}

규칙:
- 각 <channel> 블록은 서로 다른 Discord 채널의 대화임. 채널 간 내용을 혼동하지 말 것
- decisions/open_items 각 항목에 해당 내용이 나온 channel ID를 반드시 포함할 것
- decisions: 명시적으로 "하기로 했다", "결정했다", "확정", "변경"이 있는 것만
- open_items: "해야 한다", "확인 필요", "미완료", "나중에", "TODO" 언급된 것
- patterns: 동일 유형 요청이 2회 이상 반복된 것 (채널 무관하게 통합 가능)
- 내용이 없는 항목은 빈 배열 []로`;

  const opts = {
    model: OPUS_MODEL,
    pathToClaudeCodeExecutable: CLAUDE_BIN,
    maxTurns: 1,
  };

  let result = '';
  try {
    for await (const msg of query({ prompt, options: opts })) {
      if (msg.type === 'assistant' && Array.isArray(msg.message?.content)) {
        for (const block of msg.message.content) {
          if (block.type === 'text') result += block.text;
        }
      }
    }
  } catch (err) {
    throw new Error(`Opus 호출 실패: ${err.message}`);
  }

  // JSON 파싱 (코드블록 제거)
  const cleaned = result.replace(/```json\n?/g, '').replace(/```\n?/g, '').trim();
  try {
    return JSON.parse(cleaned);
  } catch {
    // JSON 파싱 실패 시 raw 텍스트에서 JSON 추출 시도
    const match = cleaned.match(/\{[\s\S]+\}/);
    if (match) return JSON.parse(match[0]);
    throw new Error(`JSON 파싱 실패. 원본:\n${cleaned.slice(0, 200)}`);
  }
}

// ── auto-insights 파일 저장 ────────────────────────────────────────────────
function saveInsights(today, data) {
  mkdirSync(AUTO_INSIGHTS_DIR, { recursive: true });
  const fp = join(AUTO_INSIGHTS_DIR, `${today}.md`);

  // Obsidian YAML frontmatter
  const decisionCount = data.decisions?.length || 0;
  const openCount = data.open_items?.length || 0;
  const patternCount = data.patterns?.length || 0;
  let md = `---\ntitle: "Knowledge Synthesis — ${today}"\ndate: ${today}\ntags: [type/synthesis, area/jarvis, period/daily]\ndecisions: ${decisionCount}\nopen_items: ${openCount}\npatterns: ${patternCount}\nmodel: ${OPUS_MODEL}\n---\n\n`;
  md += `# Knowledge Synthesis — ${today}\n\n`;
  md += `> 생성: ${new Date().toISOString()} | 모델: ${OPUS_MODEL} | 분석 기간: 최근 ${daysArg}일\n\n`;

  if (data.summary) md += `## 요약\n${data.summary}\n\n`;

  if (data.decisions?.length) {
    md += `## 결정사항\n`;
    for (const d of data.decisions) {
      md += `- **[${d.project || '일반'}]** ${d.decision}`;
      if (d.reason) md += ` — *이유: ${d.reason}*`;
      md += '\n';
    }
    md += '\n';
  }

  if (data.open_items?.length) {
    md += `## 미완료 항목\n`;
    const sorted = [...data.open_items].sort((a, b) =>
      ['high','medium','low'].indexOf(a.priority) - ['high','medium','low'].indexOf(b.priority)
    );
    for (const o of sorted) {
      const badge = o.priority === 'high' ? '🔴' : o.priority === 'medium' ? '🟡' : '🟢';
      md += `- ${badge} **${o.item}**`;
      if (o.context) md += ` — ${o.context}`;
      md += '\n';
    }
    md += '\n';
  }

  if (data.patterns?.length) {
    md += `## 반복 패턴\n`;
    for (const p of data.patterns) {
      md += `- ${p.pattern}`;
      if (p.frequency) md += ` *(${p.frequency})*`;
      md += '\n';
    }
    md += '\n';
  }

  // Obsidian wikilinks 푸터
  md += `---\n\n**See also:** [[decisions]] | [[owner-profile]] | [[system-profile]]\n`;

  writeFileSync(fp, md, 'utf-8');
  log('info', `auto-insights 저장: ${fp}`);

  // user-insights/owner/ 에도 동일 파일 복사 (유저별 검색 지원)
  try {
    const userDir = join(BOT_HOME, 'rag', 'user-insights', 'owner');
    mkdirSync(userDir, { recursive: true });
    writeFileSync(join(userDir, `${today}.md`), md, 'utf-8');
  } catch (err) {
    log('warn', `user-insights 복사 실패 (non-fatal): ${err.message}`);
  }

  return fp;
}

// ── decisions.md append (중복 방지) ──────────────────────────────────────
function appendDecisions(today, decisions) {
  if (!decisions?.length) return;

  // 기존 내용 읽어서 이미 있는 결정 파악
  // key = 날짜 + 결정 앞 30자 (project 표현 변동 무시, Opus 재표현 방어)
  // 이번 주 파일 사용 (주간 분리로 모순/무한증가 해결)
  const weeklyFile = getDecisionsFile(today);
  let existing = '';
  try { existing = readFileSync(weeklyFile, 'utf-8'); } catch { /* 신규 주간 파일 */ }
  if (!existing) {
    existing = `# Decisions — ${today.slice(0, 7)}\n\n| 날짜 | 결정 | 이유 |\n|------|------|------|\n`;
  }

  const toKey = (d) =>
    `${d.date || today}|${(d.decision || '').slice(0, 30)}`;
  const existingKeys = new Set(
    existing.split('\n')
      .filter(l => l.startsWith('|'))
      .map(l => {
        const cols = l.split('|').map(s => s.trim());
        // decision 텍스트 추출: "[project] decision..." → decision 앞 30자
        const raw = (cols[2] || '').replace(/^\[[^\]]+\]\s*/, '');
        return `${cols[1]}|${raw.slice(0, 30)}`;
      })
  );

  const newLines = decisions
    .filter(d => !existingKeys.has(toKey(d)))
    .map(d =>
      `| ${d.date || today} | [${d.project || '일반'}] ${d.decision} | ${d.reason || '-'} |`
    );

  if (!newLines.length) {
    log('info', `decisions.md — 신규 없음 (${decisions.length}건 모두 중복)`);
    return;
  }

  try {
    writeFileSync(weeklyFile, existing.trimEnd() + '\n' + newLines.join('\n') + '\n');
    log('info', `${weeklyFile.split('/').pop()}에 ${newLines.length}건 추가 (${decisions.length - newLines.length}건 중복 건너뜀)`);
  } catch (err) {
    log('warn', `decisions.md append 실패: ${err.message}`);
  }
}

// ── lancedb 재인덱싱 ────────────────────────────────────────────────────────
// engine.indexFile() 직접 호출 대신 큐에 추가 — Single Writer pattern.
// rag-index.mjs가 /tmp/jarvis-rag-write.lock 을 보유한 채 실행 중일 수 있으므로
// 동시 쓰기 충돌 방지를 위해 rag-write-queue.jsonl 에 append 후 종료.
// rag-index.mjs 가 매 :30에 큐를 소비한다.
const QUEUE_FILE = join(BOT_HOME, 'state', 'rag-write-queue.jsonl');
async function reindexInsights(filePath) {
  try {
    mkdirSync(join(BOT_HOME, 'state'), { recursive: true });
    appendFileSync(QUEUE_FILE, JSON.stringify({ action: 'index', path: filePath, ts: Date.now() }) + '\n');
    log('info', `lancedb 재인덱싱 큐 등록: ${filePath} → ${QUEUE_FILE}`);
  } catch (err) {
    log('warn', `lancedb 재인덱싱 큐 등록 실패 (non-fatal): ${err.message}`);
  }
}

// ── Action Router ────────────────────────────────────────────────────────
// insights를 파일 저장에서 그치지 않고 자율 행동으로 전환

async function pushToDevQueue(items) {
  if (!items?.length) return;

  let added = 0;

  // 수동 개입이 필요하거나 자비스 자신의 버그/개선 항목은 dev-queue 제외
  // (dev-runner LLM이 처리 불가 → 재귀 오염 방지)
  const SKIP_PATTERNS = [
    /수동\s*(복붙|실행|처리|확인|제출)/,
    /oauth|recaptcha|인증\s*필요|터미널에서/i,
    /dev.?queue.*오염|자가.*오염|오염.*방지/,
    /knowledge.?synthesizer|session.?summarizer/,
    /자비스.*버그|봇.*버그|자비스.*개선|봇.*개선/,
  ];

  for (const item of items) {
    // 수동/자기참조 항목 건너뜀
    if (SKIP_PATTERNS.some(p => p.test(item.item + ' ' + (item.context || '')))) {
      log('info', `dev-queue skip (수동/자기참조): ${item.item.slice(0, 40)}`);
      continue;
    }

    const slug = 'synth-' + item.item
      .toLowerCase()
      .replace(/[^a-z0-9가-힣]/g, '-')
      .replace(/-+/g, '-')
      .slice(0, 40);

    addTask({
      id: slug,
      name: `[Auto] ${item.item}`,
      prompt: `다음 미완료 항목을 처리해주세요:\n\n**${item.item}**\n\n맥락: ${item.context || '없음'}\n우선순위: ${item.priority}\n\n가능한 범위에서 실제 구현 또는 조치를 취해주세요.`,
      status: 'pending',
      priority: item.priority === 'high' ? 10 : item.priority === 'medium' ? 5 : 1,
      depends: [],
      maxBudget: '1.00',
      timeout: 300,
      maxRetries: 2,
      retries: 0,
      allowedTools: 'Read,Bash,Write,Edit',
      createdAt: new Date().toISOString(),
      source: 'insight-extractor',
    });
    added++;
  }

  if (added > 0) {
    log('info', `dev-queue에 ${added}건 자동 등록`);
  }
}

async function updateUserProfile(userId, decisions, patterns) {
  const profileDir = join(BOT_HOME, 'rag', 'user-insights', userId);
  const profileFile = join(profileDir, 'profile.md');
  mkdirSync(profileDir, { recursive: true });

  let existing = '';
  try { existing = readFileSync(profileFile, 'utf-8'); } catch { /* 신규 */ }

  const today = getTodayStr();

  // 오늘 날짜 섹션 이미 있으면 skip (--force 재실행 중복 방지)
  if (existing.includes(`### ${today}`)) {
    log('info', `user-insights/${userId}/profile.md — 오늘(${today}) 이미 기록됨, skip`);
    return;
  }

  const lines = [];

  if (decisions?.length) {
    lines.push(`\n### ${today} 결정사항`);
    for (const d of decisions) {
      lines.push(`- [${d.project || '일반'}] ${d.decision}`);
    }
  }
  if (patterns?.length) {
    lines.push(`\n### ${today} 패턴`);
    for (const p of patterns) {
      lines.push(`- ${p.pattern} *(${p.frequency || '반복'})*`);
    }
  }

  if (!lines.length) return;

  const header = existing
    ? existing
    : `# ${userId} 프로파일\n\n> insight-extractor 자동 생성 | 매일 새벽 업데이트\n\n`;

  writeFileSync(profileFile, header + lines.join('\n') + '\n');
  log('info', `user-insights/${userId}/profile.md 업데이트`);
}

// ── memory.md 자동 업데이트 ──────────────────────────────────────────────
// 핵심 decisions와 open_items(high)를 memory.md의 "사용자 기억" 섹션에 주입
// → 다음 자비스 대화 시 시스템 프롬프트에 자동 포함됨
function updateMemoryMd(today, decisions, openItems) {
  let existing = '';
  try { existing = readFileSync(MEMORY_FILE, 'utf-8'); } catch { return; }

  // 오늘 이미 기록됐으면 skip
  if (existing.includes(`<!-- synth:${today} -->`)) {
    log('info', 'memory.md — 오늘 이미 기록됨, skip');
    return;
  }

  const importantDecisions = (decisions || []).slice(0, 5); // 최대 5건
  const highItems = (openItems || []).filter(o => o.priority === 'high').slice(0, 3); // 최대 3건

  if (!importantDecisions.length && !highItems.length) return;

  let block = `\n<!-- synth:${today} -->\n## ${today} 자동 요약 (insight-extractor)\n`;
  if (importantDecisions.length) {
    block += `### 최근 결정\n`;
    for (const d of importantDecisions) {
      block += `- [${d.project || '일반'}] ${d.decision}\n`;
    }
  }
  if (highItems.length) {
    block += `### 미완료 (high)\n`;
    for (const o of highItems) {
      block += `- 🔴 ${o.item}\n`;
    }
  }
  block += `<!-- /synth:${today} -->\n`;

  try {
    // 오래된 synth 블록 정리: 7일 이상 된 블록 제거 후 새 블록 추가
    const cutoff = new Date(Date.now() - 7 * 86400_000).toISOString().slice(0, 10);
    const cleaned = existing.replace(
      /\n<!-- synth:(\d{4}-\d{2}-\d{2}) -->[\s\S]*?<!-- \/synth:\1 -->\n/g,
      (match, date) => date < cutoff ? '' : match
    );
    writeFileSync(MEMORY_FILE, cleaned + block);
    log('info', `memory.md 업데이트: decisions ${importantDecisions.length}건, high 항목 ${highItems.length}건 (7일 초과 블록 정리)`);
  } catch (err) {
    log('warn', `memory.md 업데이트 실패: ${err.message}`);
  }
}

// ── Phase 3-B: Cross-session 패턴 연결 ──────────────────────────────────
// 과거 N주의 auto-insights 파일에서 패턴을 추출하고
// 현재 주 패턴과 키워드 오버랩으로 반복 패턴(메타 인사이트)을 생성.

function extractKeywords(text) {
  return text
    .split(/[\s,·*()\[\]→—\-]/g)
    .map(s => s.trim())
    .filter(s => s.length >= 2 && !/^[0-9]+$/.test(s) && !/^(이|를|을|의|가|은|는|에|과|와|로|으로|하|한|하는|있|없|때|후)$/.test(s));
}

function extractPatternsFromInsightFile(filePath) {
  try {
    const content = readFileSync(filePath, 'utf-8');
    const match = content.match(/## 반복 패턴\n([\s\S]+?)(?:\n##|---)/);
    if (!match) return [];
    return match[1]
      .split('\n')
      .filter(l => l.startsWith('- '))
      .map(l => l.replace(/^-\s*/, '').replace(/\s*\*\([^)]*\)\*$/, '').trim())
      .filter(Boolean);
  } catch { return []; }
}

function collectPastWeekPatterns(weeksBack = 4) {
  const results = []; // [{ weekOffset, patterns: string[] }]
  const now = Date.now();

  for (let w = 1; w <= weeksBack; w++) {
    const weekPatterns = [];
    for (let d = 0; d < 7; d++) {
      const dayMs = now - (w * 7 + d) * 86400_000;
      const dateStr = new Date(dayMs).toISOString().slice(0, 10);
      const fp = join(AUTO_INSIGHTS_DIR, `${dateStr}.md`);
      weekPatterns.push(...extractPatternsFromInsightFile(fp));
    }
    if (weekPatterns.length) {
      results.push({ weekOffset: w, patterns: weekPatterns });
    }
  }
  return results;
}

function findCrossSessionPatterns(currentPatterns, pastWeekData) {
  if (!currentPatterns?.length || !pastWeekData?.length) return [];

  const metaInsights = [];
  for (const cur of currentPatterns) {
    const curKeywords = extractKeywords(cur.pattern || '');
    if (curKeywords.length < 2) continue;

    const matchingWeeks = pastWeekData.filter(week =>
      week.patterns.some(past => {
        const pastKeywords = extractKeywords(past);
        const overlap = curKeywords.filter(k => pastKeywords.includes(k));
        return overlap.length >= 2;
      })
    );

    if (matchingWeeks.length >= 1) {
      metaInsights.push({
        pattern: cur.pattern,
        repeatedFor: `${matchingWeeks.length + 1}주 연속`,
        weekOffsets: matchingWeeks.map(w => w.weekOffset),
      });
    }
  }
  return metaInsights;
}

function saveCrossSessionInsights(today, metaInsights, insightFilePath) {
  if (!metaInsights?.length) {
    log('info', 'cross-session: 반복 패턴 없음');
    return;
  }

  let section = `\n## Cross-Session 반복 패턴\n`;
  section += `> ${metaInsights.length}개 패턴이 과거 주간과 반복 감지됨 (Phase 3-B)\n\n`;
  for (const m of metaInsights) {
    section += `- ⚠️ **${m.pattern}** — ${m.repeatedFor} 반복\n`;
  }
  section += '\n';

  try {
    appendFileSync(insightFilePath, section);
    log('info', `cross-session 메타 패턴 ${metaInsights.length}건 → ${insightFilePath}`);
  } catch (err) {
    log('warn', `cross-session 저장 실패: ${err.message}`);
  }

  // user-insights/owner 복사본에도 반영
  try {
    const userCopy = join(BOT_HOME, 'rag', 'user-insights', 'owner', `${today}.md`);
    appendFileSync(userCopy, section);
  } catch { /* non-fatal */ }
}

async function actionRouter(data, today) {
  log('info', '--- Action Router 시작 ---');

  // 1. high priority open_items → dev-queue 자동 등록
  const highItems = (data.open_items || []).filter(o => o.priority === 'high');
  if (highItems.length) {
    log('info', `high priority 항목 ${highItems.length}건 → dev-queue 등록`);
    await pushToDevQueue(highItems);
  }

  // 2. 핵심 결정 + high 미완료 → memory.md 주입 (시스템 프롬프트 자동 반영)
  updateMemoryMd(today, data.decisions, data.open_items);

  // 3. decisions + patterns → owner profile 업데이트
  await updateUserProfile('owner', data.decisions, data.patterns);

  // 4. 인프라/버그 패턴은 system profile에도 기록
  const systemPatterns = (data.patterns || []).filter(p =>
    /crontab|launchd|인프라|실패|에러|버그|오류|타임아웃/i.test(p.pattern)
  );
  if (systemPatterns.length) {
    await updateUserProfile('system', [], systemPatterns);
  }

  log('info', '--- Action Router 완료 ---');
}

// ── 메인 ──────────────────────────────────────────────────────────────────
async function main() {
  mkdirSync(LOGS_DIR, { recursive: true });
  const today = getTodayStr();
  log('info', `=== insight-extractor 시작 (날짜: ${today}, 분석기간: ${daysArg}일) ===`);

  // 오늘 이미 실행했으면 종료 (--force 플래그로 재실행 가능)
  const forceRun = process.argv.includes('--force');
  const state = loadState();
  if (!forceRun && state.processedDates?.includes(today)) {
    log('info', `오늘(${today}) 이미 처리 완료 — 재실행하려면 --force`);
    return;
  }

  // 세션 요약 파일 수집
  const files = getRecentSummaryFiles(daysArg);
  if (files.length === 0) {
    log('warn', `최근 ${daysArg}일 세션 요약 파일 없음`);
    return;
  }
  log('info', `세션 파일 ${files.length}개 로드`);

  // 파일 내용 합산 — 채널별 그룹핑 (최대 100KB 제한)
  const byChannel = new Map();
  for (const { file: fp, channelId, name } of files) {
    if (!byChannel.has(channelId)) byChannel.set(channelId, []);
    byChannel.get(channelId).push({ file: fp, name });
  }

  let combined = '';
  for (const [channelId, entries] of byChannel) {
    combined += `\n<channel id="${channelId}">\n`;
    for (const { file: fp, name } of entries) {
      try {
        const content = readFileSync(fp, 'utf-8');
        combined += `--- 파일: ${name} ---\n${content}\n`;
        if (combined.length > 100_000) { combined += '[이하 생략]'; break; }
      } catch { /* 읽기 실패 파일 스킵 */ }
    }
    combined += `</channel>\n`;
    if (combined.length > 100_000) break;
  }

  // Opus 분석
  log('info', `Opus 분석 시작 (${combined.length}자)...`);
  let data;
  try {
    data = await synthesizeWithOpus(combined);
    log('info', `분석 완료 — decisions:${data.decisions?.length || 0} open_items:${data.open_items?.length || 0} patterns:${data.patterns?.length || 0}`);
  } catch (err) {
    log('error', `Opus 분석 실패: ${err.message}`);
    process.exit(1);
  }

  // 결과 저장
  const insightFile = saveInsights(today, data);
  appendDecisions(today, data.decisions);

  // lancedb 재인덱싱
  await reindexInsights(insightFile);

  // Phase 3-B: cross-session 패턴 연결
  if (data.patterns?.length) {
    log('info', 'Phase 3-B: cross-session 패턴 연결 시작...');
    const pastWeekData = collectPastWeekPatterns(4);
    log('info', `과거 패턴 소스: ${pastWeekData.length}주 분량`);
    const metaPatterns = findCrossSessionPatterns(data.patterns, pastWeekData);
    saveCrossSessionInsights(today, metaPatterns, insightFile);
  }

  // Action Router: insights를 자율 행동으로 전환
  await actionRouter(data, today);

  // 상태 업데이트
  state.lastRun = new Date().toISOString();
  state.processedDates = [...new Set([...(state.processedDates || []), today])].slice(-30);
  saveState(state);

  log('info', `=== 완료: auto-insights/${today}.md 생성, decisions.md 업데이트 ===`);
}

main().catch(err => {
  log('error', `치명적 오류: ${err.message}`);
  process.exit(1);
});
