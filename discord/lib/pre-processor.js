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
// Owner alert — family 채널 unmatchedStudents → owner 채널 에스컬레이션
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
    // 조건: family 채널 + 오늘 날짜 조회일 때만 (과거 날짜 조회는 이미 해결된 케이스일 수 있으므로 제외)
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
// SocialApiProcessor
// 소셜 미디어 / 외부 서비스 API 작업 감지 → secrets/social.json 자동 주입
// LLM에게 "키 어딨어?" 묻는 대신 코드가 먼저 로드해서 넘긴다.
// NOTE: \bhn\b 제거 — 너무 넓음. hacker news|show hn 으로 명시 한정.
// ---------------------------------------------------------------------------
const SOCIAL_API_PATTERN = /dev\.to|devto|포스팅|posting|reddit|twitter|hacker\s*news|show\s*hn|소셜|social\s*api/i;

export class SocialApiProcessor extends BasePreProcessor {
  get name() { return 'SocialApiProcessor'; }

  matches(ctx) {
    return SOCIAL_API_PATTERN.test(ctx.originalPrompt);
  }

  async enrich(prompt, ctx) {
    const botHome = ctx.botHome || `${homedir()}/.jarvis`;
    const socialPath = join(botHome, 'config/secrets/social.json');

    let secrets;
    try {
      secrets = JSON.parse(readFileSync(socialPath, 'utf-8'));
    } catch {
      return null;
    }

    // 비밀번호 등 민감 필드는 그대로 전달 (오너 전용 봇 — 신뢰 컨텍스트)
    const enriched =
      `[소셜 크리덴셜 — 이미 로드됨]\n` +
      `아래 데이터가 secrets/social.json 실제 내용이다. 도구 호출 없이 이 데이터를 직접 사용해라.\n\n` +
      `${JSON.stringify(secrets, null, 2)}\n\n` +
      prompt;

    log('info', '[SocialApiProcessor] social.json 자동 주입', { threadId: ctx.threadId });
    return enriched;
  }
}

// ---------------------------------------------------------------------------
// GoalsProcessor
// 이직/커리어/목표 관련 질문 → config/goals.json 자동 주입
// 매번 "이직 준비 중이에요" 컨텍스트 재설명 없이 LLM이 즉시 맥락 파악.
// ---------------------------------------------------------------------------
const GOALS_PATTERN = /이직|커리어|career|목표|로드맵|이력서|resume|취업|연봉|job|okr|kpi|분기\s*목표|goals/i;

export class GoalsProcessor extends BasePreProcessor {
  get name() { return 'GoalsProcessor'; }

  matches(ctx) {
    return GOALS_PATTERN.test(ctx.originalPrompt);
  }

  async enrich(prompt, ctx) {
    const botHome = ctx.botHome || `${homedir()}/.jarvis`;
    const goalsPath = join(botHome, 'config/goals.json');

    let goals;
    try {
      goals = JSON.parse(readFileSync(goalsPath, 'utf-8'));
    } catch {
      return null;
    }

    // 전체 주입 시 토큰 낭비 — mission + objectives 요약만
    const summary = {
      mission: goals.mission,
      quarter: goals.quarter,
      objectives: (goals.objectives || []).map(o => ({
        id: o.id,
        name: o.name,
        weight: o.weight,
        keyResults: (o.keyResults || []).map(kr => ({
          id: kr.id,
          metric: kr.metric,
          target: kr.target,
          current: kr.current,
        })),
      })),
    };

    const enriched =
      `[오너 목표/OKR — 이미 로드됨]\n` +
      `아래 데이터가 config/goals.json 실제 내용이다. 커리어·이직·목표 질문에 이 데이터를 맥락으로 사용해라.\n\n` +
      `${JSON.stringify(summary, null, 2)}\n\n` +
      prompt;

    log('info', '[GoalsProcessor] goals.json 자동 주입', { threadId: ctx.threadId });
    return enriched;
  }
}

// ---------------------------------------------------------------------------
// SystemApiProcessor
// sudo/시스템 자격 증명 필요 작업 감지 → secrets/system.json 자동 주입
// ---------------------------------------------------------------------------
const SYSTEM_API_PATTERN = /sudo|패스워드|비밀번호.*시스템|시스템.*비밀번호|mac.*password|system.*secret/i;

export class SystemApiProcessor extends BasePreProcessor {
  get name() { return 'SystemApiProcessor'; }

  matches(ctx) {
    return SYSTEM_API_PATTERN.test(ctx.originalPrompt);
  }

  async enrich(prompt, ctx) {
    const botHome = ctx.botHome || `${homedir()}/.jarvis`;
    const systemPath = join(botHome, 'config/secrets/system.json');

    let secrets;
    try {
      secrets = JSON.parse(readFileSync(systemPath, 'utf-8'));
    } catch {
      return null;
    }

    const enriched =
      `[시스템 크리덴셜 — 이미 로드됨]\n` +
      `아래 데이터가 secrets/system.json 실제 내용이다. 도구 호출 없이 이 데이터를 직접 사용해라.\n\n` +
      `${JSON.stringify(secrets, null, 2)}\n\n` +
      prompt;

    log('info', '[SystemApiProcessor] system.json 자동 주입', { threadId: ctx.threadId });
    return enriched;
  }
}

// ---------------------------------------------------------------------------
// TaskContextProcessor
// "할일/태스크/투두" 질문 → gog tasks 실행 후 결과 주입
// tasks.json은 크론 설정이므로 gog CLI로 실제 개인 할일 조회.
// ---------------------------------------------------------------------------
const TASK_CONTEXT_PATTERN = /할\s*일|투\s*두|태스크|todo|task\s*list|gog\s*task|할일\s*목록|남은\s*일|오늘\s*할/i;

export class TaskContextProcessor extends BasePreProcessor {
  get name() { return 'TaskContextProcessor'; }

  matches(ctx) {
    return TASK_CONTEXT_PATTERN.test(ctx.originalPrompt);
  }

  async enrich(prompt, ctx) {
    const { execSync } = await import('node:child_process');

    let output;
    try {
      output = execSync('gog tasks', { timeout: 8000, encoding: 'utf-8' }).trim();
    } catch (e) {
      log('warn', '[TaskContextProcessor] gog tasks 실패', { error: e.message });
      return null;
    }

    if (!output) return null;

    const enriched =
      `[개인 할일 목록 — 이미 로드됨]\n` +
      `아래 데이터가 gog tasks 실제 출력이다. 도구 호출 없이 이 데이터를 직접 사용해라.\n\n` +
      `${output}\n\n` +
      prompt;

    log('info', '[TaskContextProcessor] gog tasks 자동 주입', { threadId: ctx.threadId });
    return enriched;
  }
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------
export function createPreProcessorRegistry(searchFn = _defaultSearch) {
  return new PreProcessorRegistry()
    .register(new SocialApiProcessor())
    .register(new GoalsProcessor())
    .register(new SystemApiProcessor())
    .register(new TaskContextProcessor())
    .register(new PreplyScheduleProcessor())
    .register(new PreplyIncomeProcessor())
    .register(new RagContextProcessor(searchFn));
}
