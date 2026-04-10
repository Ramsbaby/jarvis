#!/usr/bin/env node
/**
 * insight-metrics.mjs — Layer 1: Compute behavioural metrics from LanceDB
 *
 * NO LLM calls. Pure data analysis on existing indexed chunks.
 * Output: JSON metrics object to stdout (consumed by insight-distill.mjs)
 *
 * Metrics computed:
 *   1. Topic frequency trends (recent 2 weeks vs previous 2 weeks)
 *   2. Cross-domain activity correlation
 *   3. Entity momentum (new/growing/declining entities)
 *   4. Activity heatmap (daily chunk creation rate)
 *
 * Run: node rag/bin/insight-metrics.mjs
 * Or:  import { collectMetrics } from './insight-metrics.mjs'
 */

import * as lancedb from '@lancedb/lancedb';
import { LANCEDB_PATH } from '../lib/paths.mjs';

const TABLE_NAME = 'documents';
const MS_PER_DAY = 86_400_000;
const MS_PER_WEEK = 7 * MS_PER_DAY;

// ── Domain inference from source path ──
function inferDomain(source) {
  const s = String(source).toLowerCase();
  if (s.includes('interview') || s.includes('career') || s.includes('resume'))  return '커리어';
  if (s.includes('finance') || s.includes('stock') || s.includes('투자'))        return '금융';
  if (s.includes('discord'))                                                      return 'Discord';
  if (s.includes('blog') || s.includes('netlify') || s.includes('gatsby'))       return '블로그';
  if (s.includes('jarvis') || s.includes('cron') || s.includes('infra'))         return '인프라';
  if (s.includes('board') || s.includes('dashboard'))                             return '보드';
  return '기타';
}

// ── ISO week string from timestamp ──
function getWeekKey(tsMs) {
  const d = new Date(tsMs);
  return `${d.getFullYear()}-W${String(Math.ceil((d.getDate() + new Date(d.getFullYear(), d.getMonth(), 1).getDay()) / 7)).padStart(2, '0')}`;
}

// ── Date string from timestamp ──
function getDateKey(tsMs) {
  return new Date(tsMs).toISOString().slice(0, 10);
}

// ── Extract date from source path (filename often contains YYYY-MM-DD) ──
// Falls back to modified_at if no date found in path.
function extractDateFromSource(source, modifiedAt) {
  const match = String(source).match(/(\d{4}-\d{2}-\d{2})/);
  if (match) return match[1];
  // Fallback: use modified_at
  return modifiedAt ? getDateKey(modifiedAt) : null;
}

// ── Convert date string to week bucket ──
function dateToWeekKey(dateStr) {
  if (!dateStr) return null;
  const d = new Date(dateStr + 'T00:00:00Z');
  const jan1 = new Date(d.getFullYear(), 0, 1);
  const weekNum = Math.ceil(((d - jan1) / MS_PER_DAY + jan1.getDay() + 1) / 7);
  return `${d.getFullYear()}-W${String(weekNum).padStart(2, '0')}`;
}

/**
 * Collect all metrics from LanceDB. Returns a structured metrics object.
 * @returns {Promise<object>} Metrics JSON
 */
export async function collectMetrics() {
  const db = await lancedb.connect(LANCEDB_PATH);
  let table;
  try {
    table = await db.openTable(TABLE_NAME);
  } catch {
    return { error: 'documents table not found', timestamp: new Date().toISOString() };
  }

  const now = Date.now();
  const twoWeeksAgo = now - 2 * MS_PER_WEEK;
  const fourWeeksAgo = now - 4 * MS_PER_WEEK;

  // Fetch all data with topics/entities (filter by source-date, not modified_at which is indexing time)
  let rows;
  try {
    rows = await table.query()
      .select(['modified_at', 'topics', 'source', 'importance', 'entities'])
      .where('deleted IS NULL OR deleted = false')
      .toArray();
  } catch {
    rows = await table.query()
      .select(['modified_at', 'topics', 'source', 'importance', 'entities'])
      .toArray();
  }

  // Extract actual content date from source filename (not indexing timestamp)
  // Filter to recent 4 weeks only
  const todayStr = new Date(now).toISOString().slice(0, 10);
  const fourWeeksAgoStr = new Date(fourWeeksAgo).toISOString().slice(0, 10);
  const twoWeeksAgoStr = new Date(twoWeeksAgo).toISOString().slice(0, 10);

  const datedRows = rows
    .map(row => ({ ...row, contentDate: extractDateFromSource(row.source, row.modified_at) }))
    .filter(row => row.contentDate && row.contentDate >= fourWeeksAgoStr && row.contentDate <= todayStr);

  // ── 1. Topic frequency trends ──
  const recentTopics = {};   // last 2 weeks
  const previousTopics = {}; // 2-4 weeks ago
  const topicTrends = {};

  for (const row of datedRows) {
    let topics = [];
    try { topics = JSON.parse(row.topics || '[]'); } catch { /* skip */ }
    const bucket = row.contentDate >= twoWeeksAgoStr ? recentTopics : previousTopics;
    for (const t of topics) {
      bucket[t] = (bucket[t] || 0) + 1;
    }
  }

  const allTopics = new Set([...Object.keys(recentTopics), ...Object.keys(previousTopics)]);
  for (const topic of allTopics) {
    const recent = recentTopics[topic] || 0;
    const previous = previousTopics[topic] || 0;
    const ratio = previous > 0 ? +(recent / previous).toFixed(2) : (recent > 0 ? 999 : 0);
    let trend = 'stable';
    if (ratio >= 2.0) trend = 'surging';
    else if (ratio >= 1.3) trend = 'increasing';
    else if (ratio <= 0.5) trend = 'declining';
    else if (ratio <= 0.7) trend = 'decreasing';
    else if (recent === 0 && previous > 0) trend = 'stopped';
    topicTrends[topic] = { recent, previous, ratio, trend };
  }

  // ── 2. Domain activity & cross-correlation ──
  const domainWeekly = {};  // { domain: { weekKey: count } }
  const domainRecent = {};
  const domainPrevious = {};

  for (const row of datedRows) {
    const domain = inferDomain(row.source);
    const week = dateToWeekKey(row.contentDate);
    if (!domainWeekly[domain]) domainWeekly[domain] = {};
    if (week) domainWeekly[domain][week] = (domainWeekly[domain][week] || 0) + 1;

    if (row.contentDate >= twoWeeksAgoStr) {
      domainRecent[domain] = (domainRecent[domain] || 0) + 1;
    } else {
      domainPrevious[domain] = (domainPrevious[domain] || 0) + 1;
    }
  }

  const domainTrends = {};
  for (const domain of Object.keys({ ...domainRecent, ...domainPrevious })) {
    const r = domainRecent[domain] || 0;
    const p = domainPrevious[domain] || 0;
    const ratio = p > 0 ? +(r / p).toFixed(2) : (r > 0 ? 999 : 0);
    domainTrends[domain] = { recent: r, previous: p, ratio };
  }

  // ── 3. Entity momentum (top rising/declining) ──
  const entityRecent = {};
  const entityPrevious = {};

  for (const row of datedRows) {
    let entities = [];
    try { entities = JSON.parse(row.entities || '[]'); } catch { /* skip */ }
    const bucket = row.contentDate >= twoWeeksAgoStr ? entityRecent : entityPrevious;
    for (const e of entities) {
      bucket[e] = (bucket[e] || 0) + 1;
    }
  }

  const entityMomentum = [];
  const allEntities = new Set([...Object.keys(entityRecent), ...Object.keys(entityPrevious)]);
  for (const entity of allEntities) {
    const r = entityRecent[entity] || 0;
    const p = entityPrevious[entity] || 0;
    if (r + p < 3) continue; // skip rare entities
    const ratio = p > 0 ? +(r / p).toFixed(2) : (r > 0 ? 999 : 0);
    entityMomentum.push({ entity, recent: r, previous: p, ratio });
  }
  entityMomentum.sort((a, b) => b.ratio - a.ratio);
  const risingEntities = entityMomentum.filter(e => e.ratio >= 1.5).slice(0, 5);
  const decliningEntities = entityMomentum.filter(e => e.ratio <= 0.5).slice(0, 5);

  // ── 4. Daily activity heatmap (last 14 days) ──
  const dailyActivity = {};
  for (const row of datedRows) {
    if (row.contentDate < twoWeeksAgoStr) continue;
    dailyActivity[row.contentDate] = (dailyActivity[row.contentDate] || 0) + 1;
  }

  // ── 5. Summary stats ──
  const totalRecentChunks = datedRows.filter(r => r.contentDate >= twoWeeksAgoStr).length;
  const totalPreviousChunks = datedRows.filter(r => r.contentDate < twoWeeksAgoStr).length;
  const avgImportance = datedRows.length > 0
    ? +(datedRows.reduce((s, r) => s + (r.importance || 0), 0) / datedRows.length).toFixed(3)
    : 0;

  return {
    timestamp: new Date().toISOString(),
    window: { recent: '최근 2주', previous: '2-4주 전', totalRows: rows.length },
    activityOverview: {
      recentChunks: totalRecentChunks,
      previousChunks: totalPreviousChunks,
      ratio: totalPreviousChunks > 0 ? +(totalRecentChunks / totalPreviousChunks).toFixed(2) : 0,
      avgImportance,
    },
    topicTrends,
    domainTrends,
    risingEntities,
    decliningEntities,
    dailyActivity,
  };
}

// ── CLI mode ──
if (import.meta.url === `file://${process.argv[1]}`) {
  collectMetrics()
    .then(m => console.log(JSON.stringify(m, null, 2)))
    .catch(err => {
      console.error(`[insight-metrics] ERROR: ${err.message}`);
      process.exit(1);
    });
}
