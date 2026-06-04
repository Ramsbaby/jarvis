#!/usr/bin/env node

/**
 * Gemini 3.5 Flash 라우팅 E2E 테스트
 *
 * 테스트 항목:
 * 1. 태스크 라우팅 설정 파일 검증
 * 2. 비핵심 태스크 라우팅 규칙 확인
 * 3. 핵심 태스크 보호 확인
 * 4. 토큰/비용 추적 로깅 확인
 *
 * 사용법:
 *   node gemini-routing-test.mjs [--output-log <file>]
 */

import fs from 'fs';
import path from 'path';

const BOT_HOME = process.env.BOT_HOME || path.join(process.env.HOME, '.jarvis');
const CONFIG_FILE = path.join(BOT_HOME, 'infra', 'config', 'task-routing-config.json');
const METRICS_FILE = path.join(BOT_HOME, 'logs', 'routing-metrics.jsonl');

// ── 테스트 결과 저장소 ────────────────────────────────────────────────────────

const testResults = {
  timestamp: new Date().toISOString(),
  tests: [],
  summary: {
    total: 0,
    passed: 0,
    failed: 0
  }
};

/**
 * 테스트 등록 및 실행
 */
function test(name, fn) {
  testResults.summary.total++;

  try {
    const result = fn();

    if (result === true || result === undefined) {
      testResults.tests.push({
        name,
        status: 'passed',
        error: null
      });
      testResults.summary.passed++;
      return true;
    } else {
      testResults.tests.push({
        name,
        status: 'failed',
        error: result
      });
      testResults.summary.failed++;
      return false;
    }
  } catch (error) {
    testResults.tests.push({
      name,
      status: 'failed',
      error: error.message
    });
    testResults.summary.failed++;
    return false;
  }
}

/**
 * 테스트 케이스들
 */

function testConfigFileExists() {
  if (!fs.existsSync(CONFIG_FILE)) {
    return `config 파일이 없음: ${CONFIG_FILE}`;
  }
}

function testConfigIsValidJSON() {
  try {
    const content = fs.readFileSync(CONFIG_FILE, 'utf-8');
    JSON.parse(content);
  } catch (e) {
    return `JSON 파싱 실패: ${e.message}`;
  }
}

function testRoutingRulesExist() {
  const config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf-8'));

  if (!config.routing_rules || !config.routing_rules.rules) {
    return '라우팅 규칙이 정의되지 않음';
  }

  if (config.routing_rules.rules.length === 0) {
    return '라우팅 규칙이 비어있음';
  }
}

function testNonCoreTasksListed() {
  const config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf-8'));
  const rule = config.routing_rules.rules.find(r => r.rule_id === 'non_core_to_gemini');

  if (!rule) {
    return '비핵심 태스크 라우팅 규칙(non_core_to_gemini)이 없음';
  }

  const expectedTasks = ['news-briefing', 'daily-summary', 'system-health', 'log-analysis'];
  const missing = expectedTasks.filter(t => !rule.task_ids.includes(t));

  if (missing.length > 0) {
    return `누락된 비핵심 태스크: ${missing.join(', ')}`;
  }
}

function testCoreTaskProtection() {
  const config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf-8'));
  const protection = config.core_task_protection;

  if (!protection || !protection.enabled) {
    return '핵심 태스크 보호가 활성화되지 않음';
  }

  const expectedProtected = ['council', 'reasoning', 'morning-standup'];
  const missing = expectedProtected.filter(t => !protection.protected_task_ids.includes(t));

  if (missing.length > 0) {
    return `보호되지 않는 핵심 태스크: ${missing.join(', ')}`;
  }
}

function testFallbackPolicyExists() {
  const config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf-8'));

  if (!config.fallback_policy || !config.fallback_policy.enabled) {
    return '폴백 정책이 활성화되지 않음';
  }
}

function testCostTrackingConfigured() {
  const config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf-8'));

  if (!config.cost_tracking || !config.cost_tracking.enabled) {
    return '비용 추적이 활성화되지 않음';
  }

  if (!config.cost_tracking.log_file) {
    return '비용 추적 로그 파일 경로가 정의되지 않음';
  }
}

function testMetricsFileExists() {
  if (!fs.existsSync(METRICS_FILE)) {
    return `메트릭 파일이 없음: ${METRICS_FILE}`;
  }
}

function testMetricsContainRoutedTasks() {
  if (!fs.existsSync(METRICS_FILE)) {
    return '메트릭 파일이 없음';
  }

  const content = fs.readFileSync(METRICS_FILE, 'utf-8');
  const lines = content.split('\n').filter(l => l.trim());

  if (lines.length === 0) {
    return '메트릭 데이터가 없음';
  }

  let routedCount = 0;
  let totalCount = 0;

  for (const line of lines) {
    try {
      const entry = JSON.parse(line);
      totalCount++;

      if (entry.target_model === 'gemini-3-5-flash') {
        routedCount++;
      }
    } catch (e) {
      // skip malformed lines
    }
  }

  if (routedCount === 0 && totalCount > 0) {
    return `라우팅된 Gemini 태스크가 없음 (총 ${totalCount}건)`;
  }
}

function testCostCalculationsCorrect() {
  if (!fs.existsSync(METRICS_FILE)) {
    return '메트릭 파일이 없음';
  }

  const content = fs.readFileSync(METRICS_FILE, 'utf-8');
  const lines = content.split('\n').filter(l => l.trim());

  for (const line of lines) {
    try {
      const entry = JSON.parse(line);

      // cost_saved가 올바르게 계산되었는지 확인
      if (typeof entry.cost_source === 'number' && typeof entry.cost_target === 'number') {
        const expectedSaved = entry.cost_source - entry.cost_target;
        const actualSaved = entry.cost_saved || 0;

        if (Math.abs(expectedSaved - actualSaved) > 0.0001) {
          return `비용 계산 오류: expected ${expectedSaved}, got ${actualSaved}`;
        }
      }
    } catch (e) {
      // skip
    }
  }
}

function testGeminiClientExists() {
  const clientPath = path.join(BOT_HOME, 'infra', 'lib', 'gemini-3-5-flash-client.mjs');
  if (!fs.existsSync(clientPath)) {
    return `Gemini 클라이언트가 없음: ${clientPath}`;
  }
}

function testRoutingIntegrationExists() {
  const integrationPath = path.join(BOT_HOME, 'infra', 'lib', 'model-routing-integration.sh');
  if (!fs.existsSync(integrationPath)) {
    return `라우팅 통합 스크립트가 없음: ${integrationPath}`;
  }
}

/**
 * 메인 함수
 */
function main() {
  console.log('🧪 Gemini 3.5 Flash 라우팅 E2E 테스트 시작\n');

  // 테스트 실행
  test('Config 파일 존재', testConfigFileExists);
  test('Config 유효한 JSON', testConfigIsValidJSON);
  test('라우팅 규칙 정의됨', testRoutingRulesExist);
  test('비핵심 태스크 목록', testNonCoreTasksListed);
  test('핵심 태스크 보호', testCoreTaskProtection);
  test('폴백 정책 설정', testFallbackPolicyExists);
  test('비용 추적 활성화', testCostTrackingConfigured);
  test('메트릭 파일 존재', testMetricsFileExists);
  test('라우팅된 태스크 확인', testMetricsContainRoutedTasks);
  test('비용 계산 정확성', testCostCalculationsCorrect);
  test('Gemini 클라이언트 존재', testGeminiClientExists);
  test('라우팅 통합 스크립트 존재', testRoutingIntegrationExists);

  // 결과 출력
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log(`테스트 결과: ${testResults.summary.passed}/${testResults.summary.total} 통과`);
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  for (const result of testResults.tests) {
    const status = result.status === 'passed' ? '✓' : '✗';
    console.log(`${status} ${result.name}`);
    if (result.error) {
      console.log(`  └─ ${result.error}`);
    }
  }

  // 결과 저장
  const outputLog = process.argv.find(arg => arg === '--output-log');
  if (outputLog) {
    const logIdx = process.argv.indexOf(outputLog);
    const logFile = process.argv[logIdx + 1];
    if (logFile) {
      fs.writeFileSync(logFile, JSON.stringify(testResults, null, 2), 'utf-8');
      console.log(`\n✓ 테스트 결과 저장: ${logFile}`);
    }
  }

  // Exit code
  process.exit(testResults.summary.failed > 0 ? 1 : 0);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}

export { testResults };
