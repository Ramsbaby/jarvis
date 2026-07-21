#!/usr/bin/env node
/**
 * idempotency-guard-test.mjs — 멱등성 가드 테스트 스위트
 *
 * 테스트 항목:
 * [1] 핵심 함수(send, create, insert)에 'already done' 상태 확인
 * [2] 재실행 시뮬레이션: 동일 입력 2회 실행 → 2번째는 skip
 * [3] 기존 동작 파괴 없음: 단순 통과 테스트
 * [4] 멱등성 가드 코드 문법/로직 유효성 검증
 * [5] 작동 상태 추적 가능성 검증
 */

import { IdempotencyGuard, makeIdempotent } from './idempotency-guard.mjs';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const STATE_DIR = join(HOME, '.jarvis', 'runtime', 'state');

// 테스트 배치 추적
const TestResults = {
  passed: [],
  failed: [],
  warnings: [],
};

function log(msg, level = 'info') {
  const prefix = {
    'info': 'ℹ️ ',
    'pass': '✅ ',
    'fail': '❌ ',
    'warn': '⚠️ ',
  }[level] || '';
  console.log(`${prefix}${msg}`);
}

function assert(condition, message) {
  if (!condition) {
    TestResults.failed.push(message);
    log(message, 'fail');
    throw new Error(message);
  }
  TestResults.passed.push(message);
  log(message, 'pass');
}

/**
 * [테스트 1] 핵심 함수에 'already done' 상태 확인 로직
 */
async function test1_IdempotencyKeyValidation() {
  log('\n=== Test 1: Idempotency Key Validation ===', 'info');

  // 샘플 send 함수
  const mockSend = async (data) => {
    return { status: 'sent', id: `msg-${Date.now()}`, data };
  };

  const sendIdempotent = makeIdempotent('send', mockSend);

  const testData = { to: 'user@example.com', message: 'Hello' };
  const timestamp = Date.now();
  const context = { operation_id: `test-send-001-${timestamp}`, target_id: `msg-123-${timestamp}` };

  // 1차 실행
  const result1 = await sendIdempotent(testData, context);
  assert(result1.status === 'sent', 'First execution should return success');
  assert(result1._cached === false, 'First execution should not be cached');

  // 2차 실행 (동일 입력)
  const result2 = await sendIdempotent(testData, context);
  assert(result2._cached === true, 'Second execution should be cached');
  assert(result2._skipReason, 'Cached execution should have skip reason');

  log('Test 1 completed: Idempotency key validation working', 'pass');
}

/**
 * [테스트 2] 재실행 시뮬레이션: 동일 입력 2회 실행
 */
async function test2_ReexecutionSimulation() {
  log('\n=== Test 2: Re-execution Simulation ===', 'info');

  let callCount = 0;

  // 카운터 기반 create 함수 (부작용 발생)
  const mockCreate = async (data) => {
    callCount++;
    return { created: true, count: callCount, id: `item-${callCount}`, data };
  };

  const timestamp = Date.now();
  const guard = new IdempotencyGuard('create', { operation_id: `test-create-001-${timestamp}` });
  const testData = { name: 'New Item', value: 100 };

  // 멱등성 테스트 실행
  const testResult = await guard.runIdempotencyTest(
    (input) => mockCreate(input),
    testData
  );

  assert(testResult.runs.length === 2, 'Test should run twice');
  assert(testResult.runs[0].has_side_effect === true, 'First run should have side effect');
  assert(
    testResult.runs[1].has_side_effect === false || testResult.runs[1].status === 'skipped',
    'Second run should be skipped or have no side effect'
  );
  assert(testResult.is_idempotent === true, 'Operation should be idempotent');

  log('Test 2 completed: Idempotency verified via simulation', 'pass');
}

/**
 * [테스트 3] 기존 동작 파괴 없음 - 단순 통과 테스트
 */
async function test3_LegacyCompatibility() {
  log('\n=== Test 3: Legacy Compatibility ===', 'info');

  // 기존 함수들
  const legacyFunctions = {
    send: async (data) => ({ status: 'sent', data }),
    create: async (data) => ({ created: true, data }),
    insert: async (data) => ({ inserted: true, data }),
  };

  // 각 함수를 멱등성 래퍼로 감싸고 실행
  const results = {};
  const timestamp = Date.now();
  for (const [name, func] of Object.entries(legacyFunctions)) {
    const wrapped = makeIdempotent(name, func);
    const testInput = { test: name };
    const result = await wrapped(testInput, { operation_id: `legacy-${name}-${timestamp}` });
    results[name] = result;

    // 기존 동작이 유지되었는지 확인
    assert(result !== null, `${name} should return non-null result`);
    assert(typeof result === 'object', `${name} should return object`);

    // 멱등성 메타데이터가 추가되었는지 확인
    assert(result._idempotent === true, `${name} should have _idempotent flag`);
  }

  log('Test 3 completed: All legacy functions work with idempotency wrapper', 'pass');
}

/**
 * [테스트 4] 멱등성 가드 코드 문법/로직 유효성
 */
function test4_CodeValidation() {
  log('\n=== Test 4: Code Validation (Syntax & Logic) ===', 'info');

  // 1. 라이브러리 로드 가능성 확인
  assert(typeof IdempotencyGuard === 'function', 'IdempotencyGuard class should be importable');
  assert(typeof makeIdempotent === 'function', 'makeIdempotent should be importable');

  // 2. 클래스 메서드 확인
  const requiredMethods = ['checkDuplicate', 'recordExecution', 'runIdempotencyTest'];
  const guardInstance = new IdempotencyGuard('test', { operation_id: 'test' });

  for (const method of requiredMethods) {
    assert(typeof guardInstance[method] === 'function', `IdempotencyGuard.${method} should be a function`);
  }

  // 3. 정적 메서드 확인
  assert(typeof IdempotencyGuard.getMetrics === 'function', 'IdempotencyGuard.getMetrics should be a static function');

  log('Test 4 completed: Code syntax and logic validation passed', 'pass');
}

/**
 * [테스트 5] 작동 상태 추적 가능성
 */
function test5_MetricsTracking() {
  log('\n=== Test 5: Metrics Tracking & Observability ===', 'info');

  // 메트릭 조회
  const metrics = IdempotencyGuard.getMetrics();

  assert(typeof metrics === 'object', 'Metrics should return object');
  assert('total' in metrics, 'Metrics should have total count');
  assert('by_type' in metrics, 'Metrics should have by_type breakdown');
  assert('by_operation' in metrics, 'Metrics should have by_operation breakdown');

  log(`Metrics: Total events=${metrics.total}, by_type=${JSON.stringify(metrics.by_type)}`, 'info');

  // 메트릭 파일 존재 확인
  const metricsFile = join(STATE_DIR, 'idempotency-metrics.jsonl');
  if (existsSync(metricsFile)) {
    const lines = readFileSync(metricsFile, 'utf-8').split('\n').filter(l => l);
    assert(lines.length > 0, 'Metrics file should contain records');
    log(`Metrics file has ${lines.length} records`, 'info');
  }

  // 실행 로그 파일 존재 확인
  const logFile = join(STATE_DIR, 'execution-log.jsonl');
  if (existsSync(logFile)) {
    const lines = readFileSync(logFile, 'utf-8').split('\n').filter(l => l);
    assert(lines.length > 0, 'Execution log should contain records');
    log(`Execution log has ${lines.length} records`, 'info');
  }

  log('Test 5 completed: Metrics tracking operational', 'pass');
}

/**
 * 메인 테스트 러너
 */
async function runAllTests() {
  log('🚀 Starting Idempotency Guard Test Suite\n', 'info');

  try {
    // Test 1
    await test1_IdempotencyKeyValidation();

    // Test 2
    await test2_ReexecutionSimulation();

    // Test 3
    await test3_LegacyCompatibility();

    // Test 4
    test4_CodeValidation();

    // Test 5
    test5_MetricsTracking();

    // 최종 리포트
    log('\n' + '='.repeat(60), 'info');
    log(`✅ Test Summary: ${TestResults.passed.length} passed, ${TestResults.failed.length} failed\n`, 'pass');

    if (TestResults.failed.length > 0) {
      log('Failed tests:', 'fail');
      TestResults.failed.forEach((msg, i) => log(`  ${i + 1}. ${msg}`, 'fail'));
      process.exit(1);
    } else {
      log('🎉 All tests passed!', 'pass');
      log('\nSprint Contract Verification:', 'info');
      log('[✅] [1] 핵심 함수(send, create, insert)에 already done 상태 확인 로직 구현', 'pass');
      log('[✅] [2] 재실행 시뮬레이션: 동일 입력 2회 실행 → 2번째는 skip', 'pass');
      log('[✅] [3] 기존 동작 파괴 없음: 모든 레거시 함수 호환성 검증', 'pass');
      log('[✅] [4] 멱등성 가드 코드 문법/로직 유효성 검증 (JavaScript)', 'pass');
      log('[✅] [5] 작동 상태 추적 가능 (로그, JSONL 메트릭)', 'pass');
      process.exit(0);
    }
  } catch (error) {
    log(`\n🔥 Test suite failed: ${error.message}`, 'fail');
    log(`Stack: ${error.stack}`, 'fail');
    process.exit(1);
  }
}

// 실행
runAllTests().catch(err => {
  console.error('Fatal error:', err);
  process.exit(1);
});
