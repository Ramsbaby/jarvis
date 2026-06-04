#!/usr/bin/env node

/**
 * task-router.mjs — Gemini 3.5 Flash 비핵심 태스크 라우팅 엔진
 *
 * 역할:
 *   - task-routing-config.json의 규칙을 읽어 각 태스크에 최적 모델 지정
 *   - Claude(핵심) vs Gemini 3.5 Flash(비핵심) 자동 선택
 *   - 비용 절감 추적 및 로깅
 *
 * 사용법:
 *   import { shouldRouteToGemini, getTargetModel, logCostMetrics } from './task-router.mjs';
 *
 *   const isGemini = shouldRouteToGemini('news-briefing');
 *   const model = getTargetModel('news-briefing');  // → 'gemini-3-5-flash'
 *
 * CLI:
 *   node task-router.mjs decide <task_id>
 *   node task-router.mjs log-cost <task_id> <source_model> <target_model> <input_tokens> <output_tokens> <success>
 *   node task-router.mjs validate
 *
 * ADR: ADR-011 (Multi-model orchestration policy)
 */

import { readFileSync, appendFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

// ── 상수 ─────────────────────────────────────────────────────────────────────

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis', 'runtime');
const CONFIG_PATH = join(process.env.BOT_HOME || join(homedir(), 'jarvis', 'infra'), 'config', 'task-routing-config.json');

// 비용 계산 (per 1M tokens)
const COST_MODEL = {
  'gemini-3-5-flash': {
    input: 1.50,
    output: 9.00,
  },
  'gemini-2-flash': {
    input: 0.075,
    output: 0.30,
  },
  'claude-haiku-4-5-20251001': {
    input: 0.80,
    output: 4.00,
  },
  'claude-sonnet-4-6': {
    input: 3.00,
    output: 15.00,
  },
  'deepseek-chat': {
    input: 0.14,
    output: 0.28,
  },
};

// ── 설정 로드 ──────────────────────────────────────────────────────────────────

let _config = null;

function getConfig() {
  if (_config) return _config;
  try {
    const content = readFileSync(CONFIG_PATH, 'utf-8');
    _config = JSON.parse(content);
    if (!_config.enabled && process.env.DEBUG_ROUTING !== '1') {
      console.warn('[task-router] 라우팅이 비활성화되어 있습니다 (enabled: false)');
      console.warn('[task-router] 승인 후 enabled를 true로 변경하거나 DEBUG_ROUTING=1로 테스트하세요');
    }
    return _config;
  } catch (err) {
    console.error(`[task-router] 설정 로드 실패: ${CONFIG_PATH}`);
    console.error(err.message);
    throw err;
  }
}

// ── 라우팅 의사결정 ──────────────────────────────────────────────────────────

/**
 * 주어진 태스크가 Gemini로 라우팅되어야 하는지 판단
 * @param {string} taskId - 태스크 ID
 * @param {Object} context - { inputTokens, sourceModel, ... } 추가 컨텍스트
 * @returns {boolean} - true if should route to Gemini
 */
export function shouldRouteToGemini(taskId, context = {}) {
  const config = getConfig();

  // 라우팅 비활성화 시 항상 false (DEBUG 모드 제외)
  if (!config.enabled && process.env.DEBUG_ROUTING !== '1') {
    return false;
  }

  // 핵심 태스크 보호: 보호 목록에 있으면 라우팅하지 않음
  if (config.core_task_protection?.enabled) {
    const protectedIds = config.core_task_protection.protected_task_ids || [];
    if (protectedIds.includes(taskId)) {
      return false;
    }

    // 보호 키워드 매칭
    const keywords = config.core_task_protection.protected_keywords || [];
    for (const kw of keywords) {
      if (taskId.toLowerCase().includes(kw.toLowerCase())) {
        return false;
      }
    }
  }

  // 규칙 매칭
  if (config.routing_rules?.rules) {
    for (const rule of config.routing_rules.rules) {
      if (!rule.enabled) continue;

      // task_ids 기반 매칭
      if (rule.task_ids && rule.task_ids.includes(taskId)) {
        return true;
      }

      // task_condition 기반 매칭 (inputTokens, etc.)
      if (rule.task_condition && context.inputTokens) {
        const cond = rule.task_condition;
        if (cond.inputTokens?.['>'] && context.inputTokens > cond.inputTokens['>']) {
          return true;
        }
        if (cond.inputTokens?.['<'] && context.inputTokens < cond.inputTokens['<']) {
          return true;
        }
      }
    }
  }

  return false;
}

/**
 * 태스크의 대상 모델 반환
 * @param {string} taskId - 태스크 ID
 * @param {Object} context - 추가 컨텍스트
 * @returns {string} - 모델명 (e.g., 'gemini-3-5-flash', 'claude-haiku-4-5-20251001')
 */
export function getTargetModel(taskId, context = {}) {
  const config = getConfig();

  // 비활성화 시 기본값 (Claude Haiku)
  if (!config.enabled && process.env.DEBUG_ROUTING !== '1') {
    return 'claude-haiku-4-5-20251001';
  }

  if (shouldRouteToGemini(taskId, context)) {
    // 규칙에서 명시한 target_model 찾기
    if (config.routing_rules?.rules) {
      for (const rule of config.routing_rules.rules) {
        if (!rule.enabled) continue;
        if (rule.task_ids?.includes(taskId) || rule.task_ids?.length === 0) {
          return rule.target_model || 'gemini-3-5-flash';
        }
      }
    }
    return 'gemini-3-5-flash';
  }

  // 기본값: Claude Haiku
  return 'claude-haiku-4-5-20251001';
}

/**
 * 모델 간 비용 계산
 * @param {string} sourceModel - 원본 모델
 * @param {string} targetModel - 대상 모델
 * @param {number} inputTokens - 입력 토큰 수
 * @param {number} outputTokens - 출력 토큰 수
 * @returns {Object} - { sourceCost, targetCost, savedCost, savingsPercent }
 */
export function calculateSavings(sourceModel, targetModel, inputTokens = 0, outputTokens = 0) {
  const sourceCost = getModelCost(sourceModel, inputTokens, outputTokens);
  const targetCost = getModelCost(targetModel, inputTokens, outputTokens);

  return {
    sourceCost: parseFloat(sourceCost.toFixed(6)),
    targetCost: parseFloat(targetCost.toFixed(6)),
    savedCost: parseFloat((sourceCost - targetCost).toFixed(6)),
    savingsPercent: sourceCost > 0 ? parseFloat((((sourceCost - targetCost) / sourceCost) * 100).toFixed(2)) : 0,
  };
}

/**
 * 모델의 비용 계산
 * @param {string} model - 모델명
 * @param {number} inputTokens - 입력 토큰 수
 * @param {number} outputTokens - 출력 토큰 수
 * @returns {number} - USD
 */
export function getModelCost(model, inputTokens = 0, outputTokens = 0) {
  const costs = COST_MODEL[model] || COST_MODEL['claude-haiku-4-5-20251001'];
  const inputCost = (inputTokens * costs.input) / 1_000_000;
  const outputCost = (outputTokens * costs.output) / 1_000_000;
  return inputCost + outputCost;
}

/**
 * 라우팅 메트릭 로깅
 * @param {Object} metrics - { taskId, sourceModel, targetModel, inputTokens, outputTokens, success, latencyMs, error }
 */
export function logCostMetrics(metrics) {
  const config = getConfig();
  if (!config.cost_tracking?.enabled) return;

  // 로그 경로 해석
  let logPath = config.cost_tracking.log_file || '${BOT_HOME}/logs/routing-metrics.jsonl';
  logPath = logPath
    .replace('${BOT_HOME}', BOT_HOME)
    .replace('${HOME}', homedir());

  // 디렉토리 생성
  const logDir = logPath.substring(0, logPath.lastIndexOf('/'));
  mkdirSync(logDir, { recursive: true });

  // 비용 계산
  const { sourceCost, targetCost, savedCost, savingsPercent } = calculateSavings(
    metrics.sourceModel,
    metrics.targetModel,
    metrics.inputTokens || 0,
    metrics.outputTokens || 0
  );

  // 로그 레코드
  const record = {
    ts: new Date().toISOString(),
    task_id: metrics.taskId,
    source_model: metrics.sourceModel,
    target_model: metrics.targetModel,
    input_tokens: metrics.inputTokens || 0,
    output_tokens: metrics.outputTokens || 0,
    cost_source: sourceCost,
    cost_target: targetCost,
    cost_saved: savedCost,
    savings_percent: savingsPercent,
    api_provider: metrics.targetModel.includes('gemini') ? 'google' : metrics.targetModel.includes('deepseek') ? 'deepseek' : 'anthropic',
    routing_reason: metrics.routingReason || 'auto',
    success: metrics.success !== false,
    latency_ms: metrics.latencyMs || 0,
    error: metrics.error || null,
  };

  // JSONL 형식으로 기록
  appendFileSync(logPath, JSON.stringify(record) + '\n');
}

/**
 * 설정 검증
 * @returns {Object} - { valid: boolean, errors: string[] }
 */
export function validateConfig() {
  const errors = [];
  const config = getConfig();

  // enabled 상태 확인
  if (!config.enabled) {
    errors.push('라우팅이 비활성화 상태입니다 (enabled: false)');
  }

  // 라우팅 규칙 확인
  if (!config.routing_rules?.rules || config.routing_rules.rules.length === 0) {
    errors.push('routing_rules가 비어있습니다');
  }

  for (const rule of config.routing_rules?.rules || []) {
    if (rule.enabled && !rule.task_ids?.length && !rule.task_condition) {
      errors.push(`규칙 '${rule.rule_id}'에 task_ids 또는 task_condition이 없습니다`);
    }
    if (!rule.target_model) {
      errors.push(`규칙 '${rule.rule_id}'에 target_model이 정의되지 않았습니다`);
    }
  }

  // 비용 추적 설정 확인
  if (config.cost_tracking?.enabled && !config.cost_tracking.log_file) {
    errors.push('cost_tracking이 활성화되었으나 log_file이 정의되지 않았습니다');
  }

  return {
    valid: errors.length === 0,
    errors,
  };
}

// ── CLI 모드 ──────────────────────────────────────────────────────────────────

if (process.argv[1]?.endsWith('task-router.mjs')) {
  const [, , cmd, ...args] = process.argv;

  try {
    switch (cmd) {
      case 'decide': {
        const taskId = args[0];
        if (!taskId) {
          process.stderr.write('Usage: node task-router.mjs decide <task_id>\n');
          process.exit(1);
        }
        const route = shouldRouteToGemini(taskId);
        const model = getTargetModel(taskId);
        console.log(JSON.stringify({ taskId, routeToGemini: route, targetModel: model }, null, 2));
        break;
      }

      case 'log-cost': {
        const [taskId, sourceModel, targetModel, inputStr, outputStr, successStr] = args;
        if (!taskId || !sourceModel || !targetModel) {
          process.stderr.write('Usage: node task-router.mjs log-cost <task_id> <source_model> <target_model> <input_tokens> <output_tokens> <success>\n');
          process.exit(1);
        }
        const metrics = {
          taskId,
          sourceModel,
          targetModel,
          inputTokens: parseInt(inputStr || '0', 10),
          outputTokens: parseInt(outputStr || '0', 10),
          success: successStr !== 'false',
        };
        logCostMetrics(metrics);
        const savings = calculateSavings(sourceModel, targetModel, metrics.inputTokens, metrics.outputTokens);
        console.log(JSON.stringify({ ok: true, savings }, null, 2));
        break;
      }

      case 'validate': {
        const validation = validateConfig();
        if (validation.valid) {
          console.log('✓ 설정이 유효합니다');
        } else {
          console.error('✗ 설정 오류:');
          validation.errors.forEach((err, i) => {
            console.error(`  ${i + 1}. ${err}`);
          });
          process.exit(1);
        }
        break;
      }

      default:
        process.stderr.write(`Unknown command: ${cmd}\n`);
        process.exit(1);
    }
  } catch (e) {
    process.stderr.write(e.message + '\n');
    process.exit(1);
  }
}

