#!/usr/bin/env node

/**
 * Cost Summary Daily Report
 *
 * routing-metrics.jsonl을 읽고 일별/주별 비용 집계
 * 출력: cost-summary.jsonl에 누적 기록
 *
 * 사용법:
 *   node cost-summary-daily.mjs [--output-json | --output-csv | --output-text]
 *
 * 환경변수:
 *   BOT_HOME: Jarvis 홈 디렉토리 (기본값: ~/.jarvis)
 */

import fs from 'fs';
import path from 'path';
import readline from 'readline';

const BOT_HOME = process.env.BOT_HOME || path.join(process.env.HOME, '.jarvis');
const METRICS_FILE = path.join(BOT_HOME, 'logs', 'routing-metrics.jsonl');
const SUMMARY_FILE = path.join(BOT_HOME, 'logs', 'cost-summary.jsonl');

/**
 * routing-metrics.jsonl 읽기 및 파싱
 */
async function readMetrics() {
  if (!fs.existsSync(METRICS_FILE)) {
    return { lines: [], entries: [] };
  }

  const entries = [];
  const fileStream = fs.createReadStream(METRICS_FILE);
  const rl = readline.createInterface({
    input: fileStream,
    crlfDelay: Infinity
  });

  for await (const line of rl) {
    if (line.trim()) {
      try {
        entries.push(JSON.parse(line));
      } catch (e) {
        console.error(`[경고] 파싱 오류 (라인 스킵): ${line.substring(0, 50)}...`);
      }
    }
  }

  return { entries };
}

/**
 * 날짜 기준으로 엔트리 그룹화
 */
function groupByDate(entries) {
  const grouped = {};

  for (const entry of entries) {
    const ts = entry.ts || entry.timestamp || new Date().toISOString();
    const date = ts.split('T')[0]; // YYYY-MM-DD

    if (!grouped[date]) {
      grouped[date] = [];
    }
    grouped[date].push(entry);
  }

  return grouped;
}

/**
 * 일별 요약 계산
 */
function calculateDailySummary(entries) {
  if (entries.length === 0) {
    return null;
  }

  const stats = {
    total_tasks: entries.length,
    routed_tasks: 0,
    non_routed_tasks: 0,
    total_input_tokens: 0,
    total_output_tokens: 0,
    total_cost_source: 0,
    total_cost_target: 0,
    total_cost_saved: 0,
    success_count: 0,
    failure_count: 0,
    models: {}
  };

  for (const entry of entries) {
    const isRouted = entry.target_model !== entry.source_model;

    if (isRouted) {
      stats.routed_tasks++;
    } else {
      stats.non_routed_tasks++;
    }

    stats.total_input_tokens += entry.input_tokens || 0;
    stats.total_output_tokens += entry.output_tokens || 0;
    stats.total_cost_source += entry.cost_source || 0;
    stats.total_cost_target += entry.cost_target || 0;
    stats.total_cost_saved += entry.cost_saved || 0;

    if (entry.success === 'true' || entry.success === true) {
      stats.success_count++;
    } else {
      stats.failure_count++;
    }

    // 모델별 통계
    if (!stats.models[entry.target_model]) {
      stats.models[entry.target_model] = { count: 0, cost: 0 };
    }
    stats.models[entry.target_model].count++;
    stats.models[entry.target_model].cost += entry.cost_target || 0;
  }

  return stats;
}

/**
 * 출력 생성
 */
function formatOutput(groupedByDate, format) {
  const dates = Object.keys(groupedByDate).sort();
  const results = [];

  for (const date of dates) {
    const entries = groupedByDate[date];
    const stats = calculateDailySummary(entries);

    if (!stats) continue;

    const successRate = stats.total_tasks > 0 
      ? ((stats.success_count / stats.total_tasks) * 100).toFixed(1)
      : 0;

    const savingsPercent = stats.total_cost_source > 0
      ? ((stats.total_cost_saved / stats.total_cost_source) * 100).toFixed(1)
      : 0;

    const summary = {
      date,
      period: 'daily',
      total_tasks: stats.total_tasks,
      routed_tasks: stats.routed_tasks,
      non_routed_tasks: stats.non_routed_tasks,
      total_input_tokens: stats.total_input_tokens,
      total_output_tokens: stats.total_output_tokens,
      total_cost_before: parseFloat(stats.total_cost_source.toFixed(4)),
      total_cost_after: parseFloat(stats.total_cost_target.toFixed(4)),
      total_savings: parseFloat(stats.total_cost_saved.toFixed(4)),
      savings_percent: parseFloat(savingsPercent),
      success_rate_percent: parseFloat(successRate),
      success_count: stats.success_count,
      failure_count: stats.failure_count,
      models: stats.models,
      week_projection: parseFloat((stats.total_cost_target * 7).toFixed(4)),
      status: stats.failure_count > 0 ? 'warning' : 'healthy',
      timestamp: new Date().toISOString()
    };

    results.push(summary);
  }

  if (format === 'csv') {
    return formatCSV(results);
  } else if (format === 'text') {
    return formatText(results);
  } else {
    return formatJSON(results);
  }
}

function formatJSON(results) {
  return results.map(r => JSON.stringify(r)).join('\n');
}

function formatText(results) {
  let output = '';

  for (const r of results) {
    output += `\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n`;
    output += `📅 ${r.date}\n`;
    output += `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n`;
    output += `태스크: ${r.routed_tasks}/${r.total_tasks} 라우팅됨\n`;
    output += `토큰: 입력 ${r.total_input_tokens} + 출력 ${r.total_output_tokens}\n`;
    output += `💰 비용: $${r.total_cost_before.toFixed(4)} → $${r.total_cost_after.toFixed(4)}\n`;
    output += `✓ 절감: $${r.total_savings.toFixed(4)} (${r.savings_percent}%)\n`;
    output += `성공률: ${r.success_rate_percent}% (${r.success_count}/${r.total_tasks})\n`;
    output += `주간 예측: $${r.week_projection.toFixed(4)}\n`;
    output += `상태: ${r.status === 'healthy' ? '🟢 정상' : '🟡 경고'}\n`;
  }

  return output;
}

function formatCSV(results) {
  if (results.length === 0) return '';

  const headers = Object.keys(results[0]);
  const csv = headers.join(',') + '\n';

  return csv + results.map(r => {
    return headers.map(h => {
      const val = r[h];
      if (typeof val === 'object') {
        return JSON.stringify(val).replace(/"/g, '""');
      }
      return typeof val === 'string' && val.includes(',') ? `"${val}"` : val;
    }).join(',');
  }).join('\n');
}

/**
 * 메인 함수
 */
async function main() {
  try {
    const format = process.argv[2]?.replace('--output-', '') || 'json';

    console.error('📊 비용 요약 리포트 생성 중...');
    console.error(`- 메트릭 파일: ${METRICS_FILE}`);

    const { entries } = await readMetrics();
    console.error(`- 읽음: ${entries.length}건 엔트리`);

    if (entries.length === 0) {
      console.error('⚠ 메트릭 데이터가 없습니다.');
      process.exit(0);
    }

    const grouped = groupByDate(entries);
    const output = formatOutput(grouped, format);

    // 콘솔에 출력
    console.log(output);

    // 파일에 누적 저장 (JSON 형식만)
    if (format === 'json') {
      const lines = output.split('\n').filter(l => l.trim());
      for (const line of lines) {
        try {
          fs.appendFileSync(SUMMARY_FILE, line + '\n', { encoding: 'utf8' });
        } catch (e) {
          console.error(`[경고] 파일 쓰기 실패: ${e.message}`);
        }
      }
      console.error(`\n✓ 요약 저장: ${SUMMARY_FILE}`);
    }
  } catch (error) {
    console.error(`오류: ${error.message}`);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}

export { readMetrics, groupByDate, calculateDailySummary };
