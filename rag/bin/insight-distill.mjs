#!/usr/bin/env node
/**
 * insight-distill.mjs — 2nd-layer Insight Extraction
 *
 * Reads behavioural metrics + conversation summaries,
 * then uses ask-claude.sh (claude -p) to extract high-level user insights.
 *
 * Output: ~/.jarvis/context/insight-report.md
 *
 * Run: node rag/bin/insight-distill.mjs
 * Cron: daily 04:00 (after entity-graph at 03:45)
 */

import { join } from 'node:path';
import { homedir } from 'node:os';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { ensureDirs } from '../lib/paths.mjs';
import { collectMetrics } from './insight-metrics.mjs';

const _require = createRequire(import.meta.url);

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const SQLITE_DB_PATH = process.env.JARVIS_DB_PATH
  || join(process.env.XDG_DATA_HOME || join(homedir(), '.local', 'share'), 'jarvis', 'jarvis.db');
const ASK_CLAUDE_SH = join(BOT_HOME, 'bin', 'ask-claude.sh');

// Max conversation summaries to include
const MAX_SUMMARIES = 14;

function log(msg) {
  const ts = new Date().toISOString().slice(0, 19).replace('T', ' ');
  process.stderr.write(`[insight-distill ${ts}] ${msg}\n`);
}

// ── Load conversation summaries (read-only SQLite) ──

function loadConversationSummaries() {
  if (!existsSync(SQLITE_DB_PATH)) {
    log(`jarvis.db not found at ${SQLITE_DB_PATH} — skipping conversations`);
    return [];
  }
  try {
    // Use Node.js native sqlite (node:sqlite)
    const { DatabaseSync } = _require('node:sqlite');
    const db = new DatabaseSync(SQLITE_DB_PATH, { open: true, readOnly: true });
    const rows = db.prepare(
      `SELECT date_utc, summary, topics FROM conversation_summaries
       ORDER BY date_utc DESC LIMIT ${MAX_SUMMARIES}`
    ).all();
    db.close();
    return rows;
  } catch (err) {
    log(`SQLite read failed: ${err.message?.slice(0, 80)}`);
    return [];
  }
}

// ── Load upcoming Google Calendar events (7 days) ──

function loadUpcomingEvents() {
  try {
    const toDate = new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10);
    const result = execFileSync('gog', [
      'calendar', 'list',
      '--from', 'today',
      '--to', toDate,
      '--account', process.env.GOOGLE_ACCOUNT || '',
    ], { encoding: 'utf-8', timeout: 15_000 });
    return result.trim() || '(no upcoming events)';
  } catch {
    return '(calendar unavailable)';
  }
}

// ── Load existing insights from .md file ──

function loadExistingInsights() {
  const reportPath = join(BOT_HOME, 'context', 'insight-report.md');
  try {
    return readFileSync(reportPath, 'utf-8');
  } catch { return ''; }
}

// ── Write insight report as .md file ──

function saveInsightReport(metrics, insights, upcomingEvents) {
  const lines = [];
  lines.push('# Jarvis Insight Report');
  lines.push(`> 자동 생성: ${new Date().toISOString().slice(0,10)} | 다음 갱신: 매일 04:15`);
  lines.push('');

  // Metrics section
  lines.push('## 행동 메트릭 (최근 2주 vs 2-4주 전)');
  if (metrics?.topicTrends) {
    for (const [topic, t] of Object.entries(metrics.topicTrends)) {
      lines.push(`- ${topic}: ${t.previous} → ${t.recent} (${t.trend}, x${t.ratio})`);
    }
  }
  lines.push('');

  // Rising/declining entities
  if (metrics?.risingEntities?.length > 0) {
    lines.push('## 급상승 엔티티');
    metrics.risingEntities.forEach(e => lines.push(`- ${e.entity}: ${e.previous} → ${e.recent} (x${e.ratio})`));
    lines.push('');
  }

  // Insights section
  lines.push('## 상황 인사이트');
  insights.forEach(ins => {
    lines.push(`- ${ins.insight_text}`);
    if (ins.evidence_summary) lines.push(`  근거: ${ins.evidence_summary}`);
  });
  lines.push('');

  // Calendar
  if (upcomingEvents && upcomingEvents !== '(calendar unavailable)') {
    lines.push('## 향후 일정');
    lines.push(upcomingEvents);
    lines.push('');
  }

  const reportPath = join(BOT_HOME, 'context', 'insight-report.md');
  writeFileSync(reportPath, lines.join('\n'), 'utf-8');
  return reportPath;
}

// ── Call Claude via ask-claude.sh for insight extraction ──

async function extractInsightsViaLLM(metrics, summaries, existingReport, upcomingEvents) {
  const summarySection = summaries.length > 0
    ? summaries.map(s => `[${s.date_utc}] ${s.summary} (topics: ${s.topics || 'none'})`).join('\n')
    : '(no recent conversation summaries available)';

  const existingSection = existingReport || '(no existing insights)';

  // ── Format metrics for prompt ──
  let metricsSection = '(metrics unavailable)';
  if (metrics && !metrics.error) {
    const topicLines = Object.entries(metrics.topicTrends || {})
      .map(([t, v]) => `  ${t}: ${v.previous} → ${v.recent} (${v.trend}, x${v.ratio})`)
      .join('\n');
    const domainLines = Object.entries(metrics.domainTrends || {})
      .map(([d, v]) => `  ${d}: ${v.previous} → ${v.recent} (x${v.ratio})`)
      .join('\n');
    const risingLines = (metrics.risingEntities || [])
      .map(e => `  ↑ ${e.entity}: ${e.previous} → ${e.recent} (x${e.ratio})`)
      .join('\n');
    const decliningLines = (metrics.decliningEntities || [])
      .map(e => `  ↓ ${e.entity}: ${e.previous} → ${e.recent} (x${e.ratio})`)
      .join('\n');
    const dailyLines = Object.entries(metrics.dailyActivity || {}).sort()
      .map(([d, c]) => `  ${d}: ${c}건`)
      .join('\n');

    metricsSection = `토픽 빈도 변화 (최근 2주 vs 2-4주 전):
${topicLines}

도메인별 활동 변화:
${domainLines}

급상승 엔티티:
${risingLines || '  (없음)'}

하락 엔티티:
${decliningLines || '  (없음)'}

일별 문서 생성량 (최근 14일):
${dailyLines}

전체 활동량: ${metrics.activityOverview?.previousChunks || 0} → ${metrics.activityOverview?.recentChunks || 0} (x${metrics.activityOverview?.ratio || 0})`;
  }

  const prompt = `아래는 한 사용자의 **행동 데이터 분석 결과**다. 숫자를 해석하여 현재 상황을 추론하라.

## 핵심 규칙
- 아래 메트릭(숫자)을 근거로 사용하라. 숫자 없는 추측 금지.
- 이력서/경력 내용 요약 금지 (RAG에 이미 있음)
- 기술 스킬 나열 금지
- "왜 이 숫자들이 이렇게 변하고 있는가?"를 해석하라

## 좋은 인사이트 예시
- "커리어 토픽이 534배 급증 — 면접 준비에 집중 전환한 것으로 보임"
- "AI/자비스 토픽 하락(x0.36) + 커리어 급등 → 시스템 구축에서 이직 준비로 focus shift"
- "4/1-4 소강기 후 4/5 활동 폭발 → 면접 날짜 확정 후 집중 모드"

## 카테고리
- life_phase: 생애 단계 전환 (이직, 학습기, 안정기)
- goal: 단기 목표 (면접 통과, 프로젝트 완성)
- concern: 우려/불안 (도메인 미경험, 시간 부족)
- momentum: 활동 추세 변화 (증가/감소/전환)

## 계산된 행동 메트릭 (이것이 핵심 입력)
${metricsSection}

## 향후 7일 일정 (Google Calendar)
${upcomingEvents}

## 최근 대화 요약 (${MAX_SUMMARIES}일)
${summarySection}

## 기존 인사이트 보고서 (갱신/폐기 판단)
${existingSection}

## 출력 형식
반드시 JSON 배열만 출력. 5-8개. 설명문 없이 JSON만.
[{"insight_text":"현재 이직 활동이 면접 단계에 진입했다","category":"life_phase","confidence":0.9,"evidence_summary":"면접 준비 문서, 이력서 최종 수정, 도메인 Q&A 작성","supersedes":null}]`;

  try {
    // ask-claude.sh: TASK_ID PROMPT [ALLOWED_TOOLS] [TIMEOUT]
    const result = execFileSync(ASK_CLAUDE_SH, [
      'insight-distill',
      prompt,
      'Read',      // allowed tools (minimal)
      '120',       // timeout seconds
      '0.50',      // max budget USD
    ], {
      encoding: 'utf-8',
      timeout: 180_000,  // Node.js level timeout
      env: { ...process.env, BOT_HOME },
      stdio: ['pipe', 'pipe', 'pipe'],
    }).trim();

    if (!result) {
      log('ask-claude.sh returned empty result');
      return [];
    }

    // Extract JSON array from Claude's response
    // Use non-greedy match to avoid capturing trailing text after the array
    let insights;
    const jsonMatch = result.match(/\[[\s\S]*?\](?=\s*$|\s*[^,\]\}\w])/);
    if (!jsonMatch) {
      // Fallback: try parsing the entire result as JSON
      try {
        const parsed = JSON.parse(result);
        insights = Array.isArray(parsed) ? parsed : [];
      } catch {
        log(`Claude response has no JSON array: "${result.slice(0, 150)}"`);
        return [];
      }
    }

    if (!insights) {
      try {
        insights = JSON.parse(jsonMatch[0]);
      } catch {
        log(`JSON parse failed: "${jsonMatch[0].slice(0, 100)}"`);
        return [];
      }
    }
    if (!Array.isArray(insights)) return [];

    // Validate and sanitise
    return insights
      .filter(i => i.insight_text && typeof i.insight_text === 'string')
      .map(i => ({
        insight_text: i.insight_text.slice(0, 500),
        category: ['life_phase', 'goal', 'concern', 'momentum', 'interest', 'skill', 'routine'].includes(i.category)
          ? i.category : 'general',
        confidence: Math.max(0, Math.min(1, Number(i.confidence) || 0.5)),
        evidence_summary: String(i.evidence_summary || '').slice(0, 300),
        supersedes: i.supersedes || null,
      }));
  } catch (err) {
    log(`ask-claude.sh failed: ${err.message?.slice(0, 150)}`);
    return [];
  }
}

// ── Main ──

async function main() {
  log('Starting insight distillation...');
  ensureDirs();

  // 1. Collect metrics (LLM-free)
  const metrics = await collectMetrics();
  log(`Metrics: ${Object.keys(metrics.topicTrends || {}).length} topics`);

  // 2. Load supplementary data
  const summaries = loadConversationSummaries();
  const upcomingEvents = loadUpcomingEvents();
  const existingReport = loadExistingInsights();

  // 3. Extract insights via Claude
  const insights = await extractInsightsViaLLM(metrics, summaries, existingReport, upcomingEvents);
  log(`Extracted ${insights.length} insight(s)`);

  if (insights.length === 0) {
    log('No insights extracted. Done.');
    process.exit(0);
  }

  // 4. Write .md report
  const path = saveInsightReport(metrics, insights, upcomingEvents);
  log(`Report saved: ${path}`);
}

main().catch(err => {
  log(`FATAL: ${err.message || err}`);
  process.exit(1);
});
