/**
 * pre-processor.js — Message pre-processors: enrich userPrompt before Claude is called.
 * Each processor: matches(ctx) → bool, enrich(prompt, ctx) → string|null
 *
 * Inspired by Omni's ToolHandler Protocol pattern.
 */

import { homedir } from 'node:os';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { log } from './claude-runner.js';
import { PAST_REF_PATTERN, searchRagForContext as _defaultSearch } from './rag-helper.js';
import { isPreplyQuery } from './prompt-sections.js';

// ---------------------------------------------------------------------------
// Patterns (processor-specific; isPreplyQuery() used for combined check)
// ---------------------------------------------------------------------------
const PREPLY_INCOME_PATTERN = /수입|매출|레슨\s*금액|얼마|정산|취소\s*보상|오늘\s*얼마/i;
const PREPLY_SCHEDULE_PATTERN = /프레플리|preply|오늘\s*수업|내일\s*수업|이번\s*주\s*수업|수업\s*일정|수업\s*몇|레슨|오늘\s*일정|내일\s*일정|이번\s*주\s*일정/i;

const BORAM_CHANNEL_IDS = process.env.FAMILY_CHANNEL_IDS
  ? process.env.FAMILY_CHANNEL_IDS.split(',')
  : [];

// ---------------------------------------------------------------------------
// ProcessorContext — immutable snapshot passed to every processor
// ---------------------------------------------------------------------------
export class ProcessorContext {
  constructor({ originalPrompt, channelId, threadId, botHome, client }) {
    this.originalPrompt = originalPrompt; // immutable original
    this.channelId = channelId;
    this.threadId = threadId;
    this.botHome = botHome;
    this.client = client || null; // Discord.js client (optional)
  }
}

// ---------------------------------------------------------------------------
// Owner alert — boram 채널 unmatchedStudents → 정우님 채널 에스컬레이션
// 하루 한 번만 알림 (state 파일로 debounce)
// ---------------------------------------------------------------------------
// 진행 중인 알림 추적 — race condition 방지 (동일 학생 동시 이중 전송 차단)
const _notifyInProgress = new Set();

async function _notifyOwnerUnmatched(unmatchedStudents, botHome, client) {
  if (!unmatchedStudents?.length || !client) return;

  const ownerChannelId = process.env.OWNER_ALERT_CHANNEL_ID;
  if (!ownerChannelId) return;

  // 오늘 날짜 (KST)
  const kstDate = new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10);
  const stateDir = join(botHome, 'state');
  const statePath = join(stateDir, 'unmatched-notified.json');

  // 이미 오늘 알림 보냈거나 현재 진행 중인 학생 제외 (race condition 방지)
  let notified = {};
  try {
    notified = JSON.parse(readFileSync(statePath, 'utf-8'));
  } catch { /* 파일 없으면 빈 객체 */ }

  const newStudents = unmatchedStudents.filter(s =>
    notified[s] !== kstDate && !_notifyInProgress.has(s),
  );
  if (!newStudents.length) return;

  // 진행 중 표시 (동시 호출 중복 차단)
  for (const s of newStudents) _notifyInProgress.add(s);

  try {
    // 오너 채널 가져오기
    const ch = client.channels.cache.get(ownerChannelId)
      || await client.channels.fetch(ownerChannelId).catch(() => null);
    if (!ch) {
      log('warn', '[owner-alert] OWNER_ALERT_CHANNEL_ID 채널을 찾을 수 없음', { ownerChannelId });
      return;
    }

    const studentList = newStudents.map(s => `• **${s}**`).join('\n');
    const msg = `📌 **${process.env.FAMILY_MEMBER_NAME || '가족'} Preply 단가 미확인 학생**\n${studentList}\n\n단가가 등록되지 않아 수입 계산에서 제외됩니다.\nPreply 예약 메일이 오면 자동 반영되니, 수업이 확정된 경우 메일 수신 여부를 확인해 주세요.`;

    // 전송 성공 시에만 state 업데이트
    await ch.send(msg);
    log('info', '[owner-alert] 오너 채널에 단가 미확인 알림 전송', { students: newStudents });

    for (const s of newStudents) notified[s] = kstDate;
    // 30일 이상 지난 항목 정리
    const cutoff = new Date(Date.now() - 30 * 86400 * 1000 + 9 * 3600 * 1000).toISOString().slice(0, 10);
    for (const [k, v] of Object.entries(notified)) {
      if (v < cutoff) delete notified[k];
    }
    try {
      mkdirSync(stateDir, { recursive: true });
      writeFileSync(statePath, JSON.stringify(notified, null, 2));
    } catch (e) {
      log('warn', '[owner-alert] state 저장 실패', { error: e.message });
    }
  } catch (err) {
    log('warn', '[owner-alert] 메시지 전송 실패 (state 미업데이트)', { error: err.message });
  } finally {
    for (const s of newStudents) _notifyInProgress.delete(s);
  }
}

// ---------------------------------------------------------------------------
// BasePreProcessor — processors extend this
// ---------------------------------------------------------------------------
export class BasePreProcessor {
  get name() { return 'BasePreProcessor'; }
  matches(_ctx) { return false; }
  async enrich(_prompt, _ctx) { return null; } // null = no change
}

// ---------------------------------------------------------------------------
// PreprocessorRegistry — runs processors sequentially, threading prompt through
// ---------------------------------------------------------------------------
export class PreProcessorRegistry {
  #processors = [];

  register(processor) {
    this.#processors.push(processor);
    return this; // fluent
  }

  // Run all matching processors in order, threading prompt through each
  async run(prompt, ctx) {
    let result = prompt;
    for (const p of this.#processors) {
      if (p.matches(ctx)) {
        try {
          const enriched = await p.enrich(result, ctx);
          if (enriched != null) result = enriched;
        } catch (err) {
          log('warn', `[pre-processor] ${p.name} failed`, { error: err.message });
        }
      }
    }
    return result;
  }
}

// ---------------------------------------------------------------------------
// PreplyScheduleProcessor
// Mirrors handlers.js lines 831–883: cal-preply.sh injection for Boram channel
// ---------------------------------------------------------------------------
export class PreplyScheduleProcessor extends BasePreProcessor {
  get name() { return 'PreplyScheduleProcessor'; }

  matches(ctx) {
    return PREPLY_SCHEDULE_PATTERN.test(ctx.originalPrompt) &&
           BORAM_CHANNEL_IDS.includes(ctx.channelId);
  }

  async enrich(prompt, ctx) {
    const { execSync } = await import('node:child_process');
    const botHome = ctx.botHome || `${homedir()}/.jarvis`;

    // 날짜 범위 추출 (handlers.js lines 839–864)
    const kstNow = new Date(Date.now() + 9 * 3600 * 1000);
    const todayStr = kstNow.toISOString().slice(0, 10);
    let dateFrom = todayStr;
    let dateTo = todayStr;
    if (/어제/.test(ctx.originalPrompt)) {
      const d = new Date(kstNow); d.setDate(d.getDate() - 1);
      dateFrom = dateTo = d.toISOString().slice(0, 10);
    } else if (/내일/.test(ctx.originalPrompt)) {
      const d = new Date(kstNow); d.setDate(d.getDate() + 1);
      dateFrom = dateTo = d.toISOString().slice(0, 10);
    } else if (/이번\s*주/.test(ctx.originalPrompt)) {
      const dow = kstNow.getUTCDay(); // 0=Sun
      const mon = new Date(kstNow); mon.setUTCDate(kstNow.getUTCDate() - (dow === 0 ? 6 : dow - 1));
      const sun = new Date(mon); sun.setUTCDate(mon.getUTCDate() + 6);
      dateFrom = mon.toISOString().slice(0, 10);
      dateTo = sun.toISOString().slice(0, 10);
    } else {
      const isoMatch = ctx.originalPrompt.match(/(\d{4}-\d{2}-\d{2})/);
      const krMatch = ctx.originalPrompt.match(/(\d{1,2})월\s*(\d{1,2})일/);
      if (isoMatch) {
        dateFrom = dateTo = isoMatch[1];
      } else if (krMatch) {
        const yr = kstNow.getUTCFullYear();
        dateFrom = dateTo = `${yr}-${String(krMatch[1]).padStart(2,'0')}-${String(krMatch[2]).padStart(2,'0')}`;
      }
    }

    const raw = execSync(`bash "${botHome}/scripts/cal-preply.sh" ${dateFrom} ${dateTo}`, { timeout: 15000 }).toString().trim();
    const calJson = JSON.parse(raw);
    if (calJson.error) return null;

    const items = (calJson.items || []).map(e => ({
      time: (e.start?.dateTime || '').slice(11, 16),
      summary: e.summary || '?',
    }));
    const label = dateFrom === dateTo ? dateFrom : `${dateFrom} ~ ${dateTo}`;
    const enriched = `[Google Calendar Preply 수업 일정 — 이미 로드됨] 날짜: ${label}\n` +
      `아래 데이터가 실제 캘린더 조회 결과다. 도구 호출 없이 이 데이터만 보고 바로 답해라.\n\n` +
      `수업 수: ${items.length}건\n` +
      items.map(i => `- ${i.time} ${i.summary}`).join('\n') +
      `\n\n질문: ${ctx.originalPrompt}`;

    log('info', 'Preply schedule pre-injected (Google Calendar)', { threadId: ctx.threadId, dateFrom, dateTo, count: items.length });
    return enriched;
  }
}

// ---------------------------------------------------------------------------
// PreplyIncomeProcessor
// Mirrors handlers.js lines 885–913: preply-today.sh injection
// ---------------------------------------------------------------------------
export class PreplyIncomeProcessor extends BasePreProcessor {
  get name() { return 'PreplyIncomeProcessor'; }

  matches(ctx) {
    return PREPLY_INCOME_PATTERN.test(ctx.originalPrompt) &&
           BORAM_CHANNEL_IDS.includes(ctx.channelId);
  }

  async enrich(prompt, ctx) {
    const { execSync } = await import('node:child_process');
    const botHome = ctx.botHome || `${homedir()}/.jarvis`;

    // 날짜 인자 추출: "3월 5일", "5일", "어제", "2026-03-05" 등 → YYYY-MM-DD (handlers.js lines 892–903)
    const dateMatch = ctx.originalPrompt.match(/(\d{4}-\d{2}-\d{2})|(\d{1,2})월\s*(\d{1,2})일|어제/);
    let dateArg = '';
    if (dateMatch) {
      if (dateMatch[1]) {
        dateArg = dateMatch[1];
      } else if (dateMatch[0] === '어제') {
        const d = new Date(); d.setDate(d.getDate() - 1);
        dateArg = d.toISOString().slice(0, 10);
      } else if (dateMatch[2] && dateMatch[3]) {
        const year = new Date().getFullYear();
        dateArg = `${year}-${String(dateMatch[2]).padStart(2, '0')}-${String(dateMatch[3]).padStart(2, '0')}`;
      }
    }

    const raw = execSync(`bash "${botHome}/scripts/preply-today.sh" ${dateArg}`, { timeout: 10000 }).toString().trim();
    const json = JSON.parse(raw);
    const dateLabel = dateArg || '오늘';
    const enriched = `[Preply ${dateLabel} 수입 데이터 — 이미 로드됨]\n아래 JSON이 실제 Preply 수입 데이터다. 도구 호출 없이 이 데이터만 보고 바로 답해라. Google Calendar, MCP, 세션 재시작 언급 절대 금지.\n\n${JSON.stringify(json, null, 2)}\n\n질문: ${ctx.originalPrompt}`;

    log('info', 'Preply income data pre-injected', { threadId: ctx.threadId, dateArg, count: json.scheduledCount });

    // unmatchedStudents 있으면 오너 채널로 에스컬레이션 (비동기, 응답 blocking 안 함)
    // 조건: 보람 채널 + 오늘 날짜 조회일 때만 (과거 날짜 조회는 이미 해결된 케이스일 수 있으므로 제외)
    const kstToday = new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10);
    const isToday = !dateArg || dateArg === kstToday;
    if (json.unmatchedStudents?.length && ctx.client && BORAM_CHANNEL_IDS.includes(ctx.channelId) && isToday) {
      _notifyOwnerUnmatched(json.unmatchedStudents, botHome, ctx.client);
    }

    return enriched;
  }
}

// ---------------------------------------------------------------------------
// RagContextProcessor
// Mirrors handlers.js lines 915–924: RAG context prepend for past-reference queries
// ---------------------------------------------------------------------------
export class RagContextProcessor extends BasePreProcessor {
  #searchFn;

  constructor(searchFn) {
    super();
    this.#searchFn = searchFn;
  }

  get name() { return 'RagContextProcessor'; }

  matches(ctx) {
    return PAST_REF_PATTERN.test(ctx.originalPrompt) &&
           !isPreplyQuery(ctx.originalPrompt);
  }

  async enrich(prompt, ctx) {
    // PAST_REF_PATTERN 매칭 → episodic:true로 discord-history 소스 우선 검색
    const ragContext = await this.#searchFn(ctx.originalPrompt, 3, { sourceFilter: 'episodic' }).catch(() => null);
    if (!ragContext) return null;
    const ragSnippet = ragContext.length > 600 ? ragContext.slice(0, 600) + '...' : ragContext;
    log('info', 'RAG injected (past-ref, episodic)', { threadId: ctx.threadId, ragLen: ragSnippet.length });
    return ragSnippet + '\n\n' + prompt;
  }
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------
export function createPreProcessorRegistry(searchFn = _defaultSearch) {
  return new PreProcessorRegistry()
    .register(new PreplyScheduleProcessor())
    .register(new PreplyIncomeProcessor())
    .register(new RagContextProcessor(searchFn));
}
