#!/usr/bin/env node
/**
 * insight-distill.mjs — 2nd-layer Insight Extraction
 *
 * Reads entity-graph clusters + LanceDB chunks + conversation summaries,
 * then uses ask-claude.sh (claude -p) to extract high-level user insights.
 *
 * Output: insights written to LanceDB 'insights' table (via RAGEngine)
 *
 * Run: node rag/bin/insight-distill.mjs
 * Cron: daily 04:00 (after entity-graph at 03:45)
 */

import { join } from 'node:path';
import { homedir } from 'node:os';
import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { RAGEngine } from '../lib/rag-engine.mjs';
import { LANCEDB_PATH, ENTITY_GRAPH_PATH, INFRA_HOME, ensureDirs } from '../lib/paths.mjs';
import { collectMetrics } from './insight-metrics.mjs';

const _require = createRequire(import.meta.url);

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const SQLITE_DB_PATH = process.env.JARVIS_DB_PATH
  || join(process.env.XDG_DATA_HOME || join(homedir(), '.local', 'share'), 'jarvis', 'jarvis.db');
const ASK_CLAUDE_SH = join(BOT_HOME, 'bin', 'ask-claude.sh');

// Minimum entity co-occurrence count to form a meaningful cluster
const MIN_ENTITY_COUNT = 3;
// Max chunks to sample per entity cluster
const MAX_CHUNKS_PER_CLUSTER = 5;
// Max conversation summaries to include
const MAX_SUMMARIES = 14;
// Insight expiry: 30 days (ms)
const INSIGHT_TTL_MS = 30 * 24 * 60 * 60 * 1000;

function log(msg) {
  const ts = new Date().toISOString().slice(0, 19).replace('T', ' ');
  process.stderr.write(`[insight-distill ${ts}] ${msg}\n`);
}

// ── Load entity graph ──

function loadEntityGraph() {
  if (!existsSync(ENTITY_GRAPH_PATH)) {
    log('entity-graph.json not found — skipping graph clusters');
    return null;
  }
  try {
    return JSON.parse(readFileSync(ENTITY_GRAPH_PATH, 'utf-8'));
  } catch (err) {
    log(`Failed to parse entity-graph.json: ${err.message?.slice(0, 80)}`);
    return null;
  }
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

// ── Build entity clusters from graph ──

function buildEntityClusters(graph) {
  if (!graph?.nodes) return [];

  const clusters = [];
  const visited = new Set();

  // Sort entities by count (most referenced first)
  const sortedEntities = Object.entries(graph.nodes)
    .filter(([, info]) => info.count >= MIN_ENTITY_COUNT)
    .sort((a, b) => b[1].count - a[1].count);

  for (const [entity, info] of sortedEntities) {
    if (visited.has(entity)) continue;
    visited.add(entity);

    // Collect related entities via edges
    const related = [];
    if (graph.edges) {
      for (const [edgeKey, edgeInfo] of Object.entries(graph.edges)) {
        if (edgeInfo.weight < 3) continue;
        const [e1, e2] = edgeKey.split('|');
        if (e1 === entity && !visited.has(e2)) {
          related.push(e2);
          visited.add(e2);
        } else if (e2 === entity && !visited.has(e1)) {
          related.push(e1);
          visited.add(e1);
        }
      }
    }

    clusters.push({
      entities: [entity, ...related.slice(0, 5)],
      topics: [...(info.topics || [])],
      sources: [...(info.sources || [])].slice(0, MAX_CHUNKS_PER_CLUSTER),
      count: info.count,
    });
  }

  return clusters.slice(0, 10); // Cap at 10 clusters to control LLM input size
}

// ── Sample chunk texts from LanceDB for each cluster ──

async function sampleChunksForClusters(engine, clusters) {
  const clusterTexts = [];

  for (const cluster of clusters) {
    const entityQuery = cluster.entities.join(' ');
    try {
      const results = await engine.search(entityQuery, MAX_CHUNKS_PER_CLUSTER, {
        useHybrid: true,
      });
      const texts = results.map(r => r.text.slice(0, 300)).join('\n---\n');
      const sources = results.map(r => r.source);
      clusterTexts.push({
        entities: cluster.entities,
        topics: cluster.topics,
        sampleText: texts || '(no matching chunks)',
        sources,
      });
    } catch {
      clusterTexts.push({
        entities: cluster.entities,
        topics: cluster.topics,
        sampleText: '(search failed)',
      });
    }
  }

  return clusterTexts;
}

// ── Load upcoming Google Calendar events (7 days) ──

function loadUpcomingEvents() {
  try {
    const toDate = new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10);
    const result = execFileSync('gog', [
      'cal', 'list',
      '--from', 'today',
      '--to', toDate,
      '--account', 'yuiopnm1931@gmail.com',
    ], { encoding: 'utf-8', timeout: 15_000 });
    return result.trim() || '(no upcoming events)';
  } catch {
    return '(calendar unavailable)';
  }
}

// ── Call Claude via ask-claude.sh for insight extraction ──

async function extractInsightsViaLLM(clusterTexts, summaries, existingInsights, upcomingEvents) {
  const clusterSection = clusterTexts.map((c, i) =>
    `### Cluster ${i + 1}: ${c.entities.join(', ')}
Topics: ${c.topics.join(', ') || 'none'}
Sample content:
${c.sampleText}`
  ).join('\n\n');

  const summarySection = summaries.length > 0
    ? summaries.map(s => `[${s.date_utc}] ${s.summary} (topics: ${s.topics || 'none'})`).join('\n')
    : '(no recent conversation summaries available)';

  const existingSection = existingInsights.length > 0
    ? existingInsights.map(ins =>
        `- [${ins.id}] "${ins.insight_text}" (category: ${ins.category}, confidence: ${ins.confidence})`
      ).join('\n')
    : '(no existing insights)';

  const prompt = `아래 데이터는 한 사용자의 지식 베이스와 최근 대화에서 추출한 것이다.
이 데이터를 종합하여 "이 사람은 지금 어떤 상황에 있는가?"를 추론하라.

## 절대 금지
- 이력서/경력 내용을 요약하지 마라 (예: "Kafka 경험이 있다", "Spring 잘 쓴다" → 이건 RAG에 이미 있음)
- 기술 스킬을 나열하지 마라
- 관찰 가능한 사실을 반복하지 마라 (예: "자동화를 좋아한다")

## 반드시 해야 할 것
- 흩어진 단서들을 조합해서 **현재 상황, 임박한 이벤트, 감정 상태, 진행 중인 전환기**를 추론하라
- "왜 이 데이터들이 동시에 존재하는가?"를 생각하라

## 좋은 인사이트 예시
- "현재 이직 활동이 면접 단계에 진입했으며, 특정 회사에 집중하고 있다"
- "면접 준비 강도로 보아 D-day가 1-2주 이내로 추정된다"
- "금융 도메인 미경험에 대한 불안감이 있으며, 이를 기술 경험으로 보상하려는 전략을 쓰고 있다"
- "최근 블로그와 포트폴리오 정비 활동이 증가 — 이직 준비의 마무리 단계"

## 나쁜 인사이트 예시 (이런 거 쓰면 안 됨)
- "Kafka Saga에 대한 깊은 이해가 있다" → 스킬 요약일 뿐
- "성능 최적화에 관심이 있다" → 이력서에 이미 있는 내용
- "자동화 인프라를 구축하고 있다" → 관찰 가능한 사실

## 카테고리
- life_phase: 생애 단계 전환 (이직 준비, 학습기, 안정기 등)
- goal: 단기 목표 (특정 회사 면접 통과, 프로젝트 완성 등)
- concern: 우려/불안 (도메인 미경험, 시간 부족 등)
- momentum: 활동 추세 (면접 준비 강도 증가/감소, 블로그 활동 증가 등)

## 엔티티 클러스터별 증거
${clusterSection}

## 최근 대화 요약 (${MAX_SUMMARIES}일)
${summarySection}

## 기존 인사이트 (갱신/폐기 판단)
${existingSection}

## 향후 7일 일정 (Google Calendar)
${upcomingEvents}

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

  // 1. Initialise RAG engine
  const engine = new RAGEngine(LANCEDB_PATH);
  await engine.init();
  await engine.initInsightsTable();

  // 2. Load entity graph and build clusters
  const graph = loadEntityGraph();
  const clusters = graph ? buildEntityClusters(graph) : [];
  log(`Built ${clusters.length} entity cluster(s)`);

  // 3. Sample chunk texts for each cluster
  const clusterTexts = clusters.length > 0
    ? await sampleChunksForClusters(engine, clusters)
    : [];

  // 4. Load conversation summaries
  const summaries = loadConversationSummaries();
  log(`Loaded ${summaries.length} conversation summarie(s)`);

  // 5. Load upcoming calendar events (7 days)
  const upcomingEvents = loadUpcomingEvents();
  log(`Loaded calendar events: ${upcomingEvents.length} chars`);

  // 5b. Collect behavioural metrics (LLM-free data analysis)
  let metrics = null;
  try {
    metrics = await collectMetrics();
    log(`Metrics collected: ${Object.keys(metrics.topicTrends || {}).length} topics, ${(metrics.risingEntities || []).length} rising entities`);
  } catch (err) {
    log(`Metrics collection failed (non-fatal): ${err.message?.slice(0, 80)}`);
  }

  // 6. Skip if no evidence at all
  if (clusterTexts.length === 0 && summaries.length === 0) {
    log('No evidence available — nothing to distil. Exiting.');
    process.exit(0);
  }

  // 7. Load existing active insights
  const existingInsights = await engine.getActiveInsights();
  log(`Found ${existingInsights.length} existing active insight(s)`);

  // 8. Expire stale insights
  const expired = await engine.expireStaleInsights();
  if (expired > 0) log(`Expired ${expired} stale insight(s)`);

  // 9. Extract new insights via LLM
  const newInsights = await extractInsightsViaLLM(clusterTexts, summaries, existingInsights, upcomingEvents, metrics);
  log(`LLM extracted ${newInsights.length} insight(s)`);

  if (newInsights.length === 0) {
    log('No new insights extracted. Done.');
    process.exit(0);
  }

  // 10. Collect unique evidence sources from cluster search results
  const allSources = [...new Set(clusterTexts.flatMap(c => c.sources || []))].slice(0, 10);

  // 11. Upsert: semantic dedup via vector similarity
  // LLM produces different text for same meaning each run, so exact-match dedup is useless.
  // Instead: embed the new insight, search existing insights, if distance < threshold → supersede.
  const DEDUP_DISTANCE = 0.8;  // L2 distance — same meaning threshold
  let added = 0;
  let superseded = 0;
  let skipped = 0;
  for (const ins of newInsights) {
    const datePrefix = `[${new Date().toISOString().slice(0,10)} 기준] `;
    const fullText = datePrefix + ins.insight_text;

    // Semantic dedup: find existing insight with same meaning
    const similar = await engine.searchInsights(ins.insight_text, 1, {
      distanceThreshold: DEDUP_DISTANCE,
      confidenceThreshold: 0,  // match any confidence
    });

    if (similar.length > 0) {
      // Same meaning exists — supersede the old one with updated version
      const oldId = similar[0].id;
      const newId = await engine.addInsight({
        insight_text: fullText,
        category: ins.category,
        confidence: ins.confidence,
        evidence_sources: allSources,
        evidence_summary: ins.evidence_summary,
        expires_at: Date.now() + INSIGHT_TTL_MS,
      });
      await engine.supersedeInsight(oldId, newId);
      superseded++;
      added++;
    } else {
      // Genuinely new insight
      await engine.addInsight({
        insight_text: fullText,
        category: ins.category,
        confidence: ins.confidence,
        evidence_sources: allSources,
        evidence_summary: ins.evidence_summary,
        expires_at: Date.now() + INSIGHT_TTL_MS,
      });
      added++;
    }
  }

  log(`Done: ${added} insight(s) added, ${superseded} superseded`);
}

main().catch(err => {
  log(`FATAL: ${err.message || err}`);
  process.exit(1);
});
