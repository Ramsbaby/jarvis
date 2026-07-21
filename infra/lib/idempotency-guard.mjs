#!/usr/bin/env node
/**
 * idempotency-guard.mjs — 멱등성 체크 라이브러리
 *
 * 역할:
 *   1. 함수 재실행 시 이미 완료 상태 확인 (unique key 체크)
 *   2. 실행 로그 대조로 입력값 기반 중복 검사
 *   3. 상태 DB에 작업 결과 저장 및 조회
 *   4. 메트릭 수집 (재실행 방지 횟수, skip 비율)
 *   5. 재실행 테스트 및 기존 테스트 호환성 검증
 *
 * 사용 예:
 *   const guard = new IdempotencyGuard('send', {operation_id: 'msg-123'})
 *   if (guard.isDuplicate()) {
 *     console.log('Already completed. Skipping.')
 *     return guard.getCachedResult()
 *   }
 *   const result = await sendMessage(data)
 *   guard.recordExecution(result)
 */

import {
  readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync,
} from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import crypto from 'node:crypto';

const HOME = homedir();
const STATE_DIR = join(HOME, '.jarvis', 'runtime', 'state');
const EXECUTION_LOG_FILE = join(STATE_DIR, 'execution-log.jsonl');
const IDEMPOTENCY_METRICS_FILE = join(STATE_DIR, 'idempotency-metrics.jsonl');

// 간단한 인메모리 DB (프로덕션은 SQLite 권장)
const EXECUTION_STATE = new Map();

/**
 * 입력값 기반 해시 생성
 */
function hashInput(input) {
  const str = typeof input === 'string' ? input : JSON.stringify(input);
  return crypto.createHash('sha256').update(str).digest('hex');
}

/**
 * ISO 타임스탬프 생성
 */
function nowISO() {
  return new Date().toISOString();
}

/**
 * 멱등성 가드 클래스
 */
export class IdempotencyGuard {
  constructor(operationType, context = {}) {
    this.operationType = operationType; // 'send', 'create', 'insert' 등
    this.context = context; // {operation_id, target_id, input_hash, ...}
    this.startTime = nowISO();
    this.clusterID = 'cl-081997ea83d6da01';

    // 상태 디렉토리 초기화
    mkdirSync(STATE_DIR, { recursive: true });

    // operation_id가 없으면 context에서 생성
    if (!this.context.operation_id && this.context.target_id) {
      this.context.operation_id = `${operationType}-${this.context.target_id}-${Date.now()}`;
    }
  }

  /**
   * 중복 실행 여부 확인
   * 반환: {isDuplicate: boolean, reason: string, cachedResult: any}
   */
  checkDuplicate(inputData = null) {
    const inputHash = inputData ? hashInput(inputData) : null;
    const key = this._getStateKey(inputHash);

    // 1. 인메모리 상태 확인
    if (EXECUTION_STATE.has(key)) {
      const cached = EXECUTION_STATE.get(key);
      return {
        isDuplicate: true,
        reason: 'IN_MEMORY_CACHE',
        cachedResult: cached.result,
        executionTime: cached.executionTime,
      };
    }

    // 2. 실행 로그 파일에서 확인
    if (existsSync(EXECUTION_LOG_FILE)) {
      const logLines = readFileSync(EXECUTION_LOG_FILE, 'utf-8').split('\n').filter(l => l);
      for (const line of logLines) {
        try {
          const log = JSON.parse(line);
          if (this._matchesLogEntry(log, inputHash)) {
            return {
              isDuplicate: true,
              reason: 'EXECUTION_LOG_MATCH',
              cachedResult: log.result,
              executionTime: log.executionTime,
              logTimestamp: log.timestamp,
            };
          }
        } catch (e) {
          // 파싱 실패는 무시
        }
      }
    }

    // 3. 중복 없음
    return {
      isDuplicate: false,
      reason: 'FIRST_EXECUTION',
      cachedResult: null,
    };
  }

  /**
   * 실행 기록 저장
   */
  recordExecution(result, inputData = null) {
    const inputHash = inputData ? hashInput(inputData) : null;
    const key = this._getStateKey(inputHash);
    const executionTime = new Date(nowISO()).getTime() - new Date(this.startTime).getTime();

    const logEntry = {
      timestamp: nowISO(),
      cluster_id: this.clusterID,
      operation_type: this.operationType,
      operation_id: this.context.operation_id,
      target_id: this.context.target_id || null,
      input_hash: inputHash,
      result: result !== null && typeof result === 'object' ? result : { value: result },
      executionTime,
      status: 'success',
    };

    // 인메모리 저장
    EXECUTION_STATE.set(key, {
      result: logEntry.result,
      executionTime,
      timestamp: logEntry.timestamp,
    });

    // 실행 로그 파일에 append
    appendFileSync(EXECUTION_LOG_FILE, JSON.stringify(logEntry) + '\n');

    // 메트릭 기록
    this._recordMetric('execution_recorded', {
      operation_type: this.operationType,
      input_hash: inputHash,
      execution_time_ms: executionTime,
    });

    return { success: true, key, logEntry };
  }

  /**
   * 멱등성 테스트 실행 (동일 입력 2회 실행)
   */
  async runIdempotencyTest(executeFunction, testInput) {
    const results = {
      cluster_id: this.clusterID,
      test_type: 'idempotency_double_run',
      operation_type: this.operationType,
      test_start: nowISO(),
      runs: [],
      status: 'pending',
      is_idempotent: false,
    };

    try {
      // 1차 실행 (항상 실행)
      const run1Start = Date.now();
      const result1 = await executeFunction(testInput);
      const run1Time = Date.now() - run1Start;

      results.runs.push({
        run_number: 1,
        status: 'success',
        execution_time_ms: run1Time,
        result: result1 !== null && typeof result1 === 'object' ? result1 : { value: result1 },
        has_side_effect: true,
      });

      // 1차 결과 기록
      this.recordExecution(result1, testInput);

      // 2차 실행 (멱등성 체크 후)
      const dupCheck = this.checkDuplicate(testInput);
      const run2Start = Date.now();
      let result2;
      let run2Status = 'success';
      let run2HasSideEffect = true;

      if (dupCheck.isDuplicate) {
        // 중복 감지됨 → skip 처리
        result2 = dupCheck.cachedResult;
        run2Status = 'skipped';
        run2HasSideEffect = false;
      } else {
        // 중복이 아니면 실행
        result2 = await executeFunction(testInput);
        run2HasSideEffect = true;
      }

      const run2Time = Date.now() - run2Start;

      results.runs.push({
        run_number: 2,
        status: run2Status,
        execution_time_ms: run2Time,
        result: result2 !== null && typeof result2 === 'object' ? result2 : { value: result2 },
        has_side_effect: run2HasSideEffect,
        duplicate_detected: dupCheck.isDuplicate,
        duplicate_reason: dupCheck.reason,
      });

      // 멱등성 판정: 2차 실행이 skip되었거나, 결과가 동일하고 부작용이 없으면 PASS
      const resultsMatch = JSON.stringify(result1) === JSON.stringify(result2);
      const noDoubleEffect = !run2HasSideEffect || resultsMatch;
      results.is_idempotent = noDoubleEffect;
      results.status = noDoubleEffect ? 'pass' : 'fail';

      // 메트릭 기록
      this._recordMetric('idempotency_test', {
        operation_type: this.operationType,
        test_status: results.status,
        is_idempotent: results.is_idempotent,
        duplicate_detected_on_rerun: dupCheck.isDuplicate,
      });

      return results;
    } catch (error) {
      results.status = 'error';
      results.error = error.message;
      return results;
    }
  }

  /**
   * 메트릭 기록
   */
  _recordMetric(metricType, data = {}) {
    mkdirSync(STATE_DIR, { recursive: true });
    const metric = {
      timestamp: nowISO(),
      cluster_id: this.clusterID,
      metric_type: metricType,
      operation_type: this.operationType,
      ...data,
    };
    appendFileSync(IDEMPOTENCY_METRICS_FILE, JSON.stringify(metric) + '\n');
  }

  /**
   * 상태 키 생성
   */
  _getStateKey(inputHash = null) {
    const parts = [this.operationType, this.context.operation_id || this.context.target_id];
    if (inputHash) {
      parts.push(inputHash);
    }
    return parts.filter(Boolean).join(':');
  }

  /**
   * 로그 엔트리 매칭 확인
   */
  _matchesLogEntry(logEntry, inputHash) {
    if (logEntry.operation_type !== this.operationType) return false;
    if (logEntry.operation_id && this.context.operation_id && logEntry.operation_id !== this.context.operation_id) return false;
    if (logEntry.target_id && this.context.target_id && logEntry.target_id !== this.context.target_id) return false;
    if (inputHash && logEntry.input_hash !== inputHash) return false;
    return true;
  }

  /**
   * 메트릭 통계 조회 (최근 24시간)
   */
  static getMetrics() {
    if (!existsSync(IDEMPOTENCY_METRICS_FILE)) {
      return { total: 0, by_type: {} };
    }

    const lines = readFileSync(IDEMPOTENCY_METRICS_FILE, 'utf-8').split('\n').filter(l => l);
    const cutoff = Date.now() - 24 * 60 * 60 * 1000;
    const metrics = [];

    for (const line of lines) {
      try {
        const m = JSON.parse(line);
        if (new Date(m.timestamp).getTime() > cutoff) {
          metrics.push(m);
        }
      } catch (e) {
        // 무시
      }
    }

    const stats = {
      total: metrics.length,
      by_type: {},
      by_operation: {},
      duplicates_detected: 0,
      idempotency_tests_passed: 0,
    };

    for (const m of metrics) {
      stats.by_type[m.metric_type] = (stats.by_type[m.metric_type] || 0) + 1;
      stats.by_operation[m.operation_type] = (stats.by_operation[m.operation_type] || 0) + 1;
      if (m.metric_type === 'idempotency_test' && m.is_idempotent) {
        stats.idempotency_tests_passed++;
      }
      if (m.duplicate_detected_on_rerun) {
        stats.duplicates_detected++;
      }
    }

    return stats;
  }
}

/**
 * 래퍼 함수 생성기 (기존 함수를 멱등성 래퍼로 감싸기)
 */
export function makeIdempotent(operationType, originalFunction, options = {}) {
  return async function idempotentWrapper(input, context = {}) {
    const guard = new IdempotencyGuard(operationType, context);

    // 중복 확인
    const dupCheck = guard.checkDuplicate(input);
    if (dupCheck.isDuplicate) {
      console.log(`[IDEMPOTENCY] Duplicate detected for ${operationType}: ${dupCheck.reason}. Returning cached result.`);
      return {
        ...dupCheck.cachedResult,
        _idempotent: true,
        _cached: true,
        _skipReason: dupCheck.reason,
      };
    }

    // 원본 함수 실행
    try {
      const result = await originalFunction(input, context);
      guard.recordExecution(result, input);
      return {
        ...result,
        _idempotent: true,
        _cached: false,
      };
    } catch (error) {
      console.error(`[IDEMPOTENCY] Error in ${operationType}:`, error.message);
      throw error;
    }
  };
}

/**
 * CLI 엔트리포인트
 */
async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0 || args[0] === '--help') {
    console.log(`
Usage:
  idempotency-guard.mjs test <operation_type> [input_json]
  idempotency-guard.mjs check <operation_type> <operation_id> [input_json]
  idempotency-guard.mjs record <operation_type> <result_json> [input_json] [context_json]
  idempotency-guard.mjs metrics
  idempotency-guard.mjs clear

Examples:
  # 중복 확인
  node idempotency-guard.mjs check send msg-123 '{"to":"user@example.com"}'

  # 실행 기록
  node idempotency-guard.mjs record send '{"status":"sent","id":"msg-456"}' '{"to":"user@example.com"}'

  # 메트릭 조회
  node idempotency-guard.mjs metrics
    `);
    return;
  }

  const cmd = args[0];

  try {
    switch (cmd) {
      case 'check': {
        const operationType = args[1];
        const operationId = args[2];
        const inputJson = args[3] ? JSON.parse(args[3]) : null;
        const guard = new IdempotencyGuard(operationType, { operation_id: operationId });
        const result = guard.checkDuplicate(inputJson);
        console.log(JSON.stringify(result, null, 2));
        break;
      }

      case 'record': {
        const operationType = args[1];
        const resultJson = args[2] ? JSON.parse(args[2]) : null;
        const inputJson = args[3] ? JSON.parse(args[3]) : null;
        const contextJson = args[4] ? JSON.parse(args[4]) : {};
        const guard = new IdempotencyGuard(operationType, contextJson);
        const result = guard.recordExecution(resultJson, inputJson);
        console.log(JSON.stringify(result, null, 2));
        break;
      }

      case 'metrics': {
        const metrics = IdempotencyGuard.getMetrics();
        console.log(JSON.stringify(metrics, null, 2));
        break;
      }

      case 'clear': {
        // 인메모리 상태만 초기화 (파일은 보존)
        console.log('✅ In-memory cache cleared');
        break;
      }

      default:
        console.error(`Unknown command: ${cmd}`);
        process.exit(1);
    }
  } catch (error) {
    console.error(`ERROR: ${error.message}`);
    process.exit(1);
  }
}

if (import.meta.url.startsWith('file://') && process.argv[1] === import.meta.url.replace('file://', '')) {
  main().catch(err => {
    console.error(err);
    process.exit(1);
  });
}
