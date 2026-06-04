#!/usr/bin/env node

/**
 * Model Selector for Qwen/DeepSeek Budget Routing
 *
 * Task ID → Model 라우팅 로직:
 * - LOW 난이도: deepseek-v4-flash ($0.14-0.28/M tokens)
 * - MEDIUM 난이도: qwen-3.6-plus ($0.325-1.95/M tokens)
 * - HIGH 난이도: claude-sonnet-4-6 (기존 유지)
 */

const PILOT_ROUTES = {
  // Phase 1: Health Checks → DeepSeek V4-Flash
  'system-health': { model: 'deepseek-v4-flash', difficulty: 'LOW', phase: 1 },
  'disk-alert': { model: 'deepseek-v4-flash', difficulty: 'LOW', phase: 1 },
  'bot-watchdog': { model: 'deepseek-v4-flash', difficulty: 'LOW', phase: 1 },

  // Phase 2: Log & Data Management → DeepSeek V4-Flash
  'log-rotate': { model: 'deepseek-v4-flash', difficulty: 'LOW', phase: 2 },
  'system-cleanup': { model: 'deepseek-v4-flash', difficulty: 'LOW', phase: 2 },
  'db-backup': { model: 'deepseek-v4-flash', difficulty: 'LOW-MEDIUM', phase: 2 },
  'retention-jsonl': { model: 'deepseek-v4-flash', difficulty: 'LOW', phase: 3 },

  // Phase 3: Summary & Reporting → Qwen 3.6-Plus
  'vault-daily-digest': { model: 'qwen-3.6-plus', difficulty: 'MEDIUM', phase: 3 },
  'measure-kpi': { model: 'qwen-3.6-plus', difficulty: 'MEDIUM', phase: 3 },
  'brand-visibility-check': { model: 'qwen-3.6-plus', difficulty: 'MEDIUM', phase: 3 },
  'audit-cross-surface-learning': { model: 'qwen-3.6-plus', difficulty: 'MEDIUM', phase: 3 },
  'langfuse-report': { model: 'qwen-3.6-plus', difficulty: 'MEDIUM', phase: 3 }
};

const CONFIG = {
  'deepseek-v4-flash': {
    apiEndpoint: 'https://api.deepseek.com/chat/completions',
    apiKeyEnv: 'DEEPSEEK_API_KEY',
    priceInput: 0.14 / 1e6,
    priceOutput: 0.28 / 1e6,
    timeout: 30
  },
  'qwen-3.6-plus': {
    apiEndpoint: 'https://dashscope.aliyuncs.com/api/v1/services/aigc/text-generation/generation',
    apiKeyEnv: 'QWEN_API_KEY',
    priceInput: 0.325 / 1e6,
    priceOutput: 1.95 / 1e6,
    timeout: 45
  }
};

async function selectModel(taskId) {
  const route = PILOT_ROUTES[taskId];

  if (!route) {
    // 라우팅되지 않은 태스크는 기존 Haiku 유지
    return {
      taskId,
      model: 'claude-haiku-4-5-20251001',
      reason: 'not_in_pilot',
      phase: 0
    };
  }

  const apiKey = process.env[CONFIG[route.model].apiKeyEnv];

  if (!apiKey) {
    // API 키 없으면 Haiku로 fallback
    return {
      taskId,
      model: 'claude-haiku-4-5-20251001',
      reason: `${route.model}_api_key_missing`,
      phase: route.phase,
      originalModel: route.model
    };
  }

  return {
    taskId,
    model: route.model,
    reason: 'pilot_routing',
    phase: route.phase,
    difficulty: route.difficulty,
    config: CONFIG[route.model]
  };
}

async function getModelApiEndpoint(model) {
  const config = CONFIG[model];
  if (!config) {
    throw new Error(`Unknown model: ${model}`);
  }
  return config.apiEndpoint;
}

async function calculateCost(model, inputTokens, outputTokens) {
  const config = CONFIG[model];
  if (!config) {
    throw new Error(`Unknown model: ${model}`);
  }

  return {
    model,
    inputCost: inputTokens * config.priceInput,
    outputCost: outputTokens * config.priceOutput,
    totalCost: (inputTokens * config.priceInput) + (outputTokens * config.priceOutput)
  };
}

function getPilotStats() {
  const stats = {
    totalPilotTasks: Object.keys(PILOT_ROUTES).length,
    byPhase: { 1: 0, 2: 0, 3: 0 },
    byModel: {},
    byDifficulty: {}
  };

  for (const [taskId, route] of Object.entries(PILOT_ROUTES)) {
    // Phase 집계
    stats.byPhase[route.phase]++;

    // 모델별 집계
    stats.byModel[route.model] = (stats.byModel[route.model] || 0) + 1;

    // 난이도별 집계
    stats.byDifficulty[route.difficulty] = (stats.byDifficulty[route.difficulty] || 0) + 1;
  }

  return stats;
}

export { selectModel, getModelApiEndpoint, calculateCost, getPilotStats, PILOT_ROUTES, CONFIG };
