/**
 * model-router.mjs — Jarvis 멀티 모델 라우팅 엔진
 *
 * 작업 특성에 따라 최적의 LLM 모델을 자동 선택:
 * - Claude (고비용, 고성능): 복잡한 논리, 의사결정
 * - Gemini Flash (중비용, 1M 컨텍스트): 대용량 문서, 장문 분석
 * - DeepSeek (초저가): 간단한 분류, 요약, 태깅
 *
 * ADR-011: Multi-model orchestration policy
 *
 * 사용법:
 *   import { selectModel, estimateCost } from './model-router.mjs';
 *   const model = selectModel(task);
 *   const cost = estimateCost(model, inputTokens, outputTokens);
 */

// ── 모델 가격표 (2025-05 기준, USD per 1M tokens) ─────────────────────────

const MODEL_PRICES = {
  'claude-opus': {
    name: 'Claude Opus 4.8',
    input: 15.00,
    output: 75.00,
    contextWindow: 200_000,
    features: ['extended-reasoning', 'tools', 'vision', 'code-review'],
    tier: 'ultra-premium',
  },
  'claude-sonnet': {
    name: 'Claude Sonnet 4',
    input: 3.00,
    output: 15.00,
    contextWindow: 200_000,
    features: ['reasoning', 'tools', 'vision', 'code-review'],
    tier: 'premium',
  },
  'claude-haiku': {
    name: 'Claude Haiku 4.5',
    modelId: 'claude-haiku-4-5-20251001',  // models.json "fast" 키와 동일
    input: 0.80,
    output: 4.00,
    contextWindow: 200_000,
    features: ['fast', 'low-cost'],
    tier: 'standard',
  },
  'gemini-2-flash': {
    name: 'Gemini 2.0 Flash',
    input: 1.50,
    output: 9.00,
    contextWindow: 1_000_000,  // 핵심 차이점: 1M 컨텍스트
    features: ['long-context', 'fast', 'cost-effective'],
    tier: 'standard',
  },
  'gemini-3-5-flash': {
    name: 'Gemini 3.5 Flash',
    modelId: 'gemini-3.5-flash-latest',
    input: 1.50,
    output: 9.00,
    contextWindow: 1_000_000,
    features: ['ultra-fast', 'long-context', 'non-core-tasks', 'cost-effective'],
    tier: 'standard',
    optimizedFor: ['summarize', 'classify', 'log-analysis', 'news-briefing'],
    responseTimeMs: 50,
  },
  'deepseek-chat': {
    name: 'DeepSeek V4 Flash',
    input: 0.14,
    output: 0.28,
    contextWindow: 1_000_000,  // 캐시 미스 기준
    features: ['ultra-low-cost', 'streaming'],
    tier: 'budget',
  },
};

// ── 라우팅 규칙 (우선순위 순) ─────────────────────────────────────────────

/**
 * 작업 특성에 기반한 모델 선택 규칙
 *
 * @typedef {Object} Task
 * @property {string} [type] - 작업 타입 (summarize, analyze, classify, etc)
 * @property {number} [inputTokens] - 입력 토큰 수 (예상)
 * @property {number} [outputTokens] - 출력 토큰 수 (예상)
 * @property {string} [complexity] - 작업 복잡도 (low|medium|high)
 * @property {boolean} [needsReasoning] - 복잡한 논리 필요
 * @property {boolean} [needsVision] - 이미지 처리
 * @property {boolean} [timeConstraint] - 긴급 (30초 이내)
 * @property {number} [maxBudget] - 최대 예산 (USD)
 */

export function selectModel(task = {}) {
  // Rule 0: 비핵심 태스크용 Gemini 3.5 Flash 우선 라우팅
  // news-briefing, daily-summary, system-health, memory-cleanup, log-analysis 등
  const nonCoreTaskIds = ['news-briefing', 'daily-summary', 'system-health', 'memory-cleanup', 'log-analysis', 'github-monitor'];
  if (task.taskId && nonCoreTaskIds.includes(task.taskId)) {
    // taskRoutingConfig.enabled 확인 필요 (런타임에서 처리)
    // 여기서는 규칙만 정의
    if (task.allowGemini35Flash) {
      return 'gemini-3-5-flash';  // 비용 효율적, 응답 빠름
    }
  }

  // Rule 1: 문맥 윈도우 초과 방지
  if ((task.inputTokens ?? 0) > 200_000 && (task.inputTokens ?? 0) <= 1_000_000) {
    // Claude는 200K까지만 (일부), Gemini는 1M까지 지원
    return 'gemini-2-flash';
  }

  // Rule 2: 대용량 문서 처리 (100K+)
  if ((task.inputTokens ?? 0) > 100_000) {
    return 'gemini-2-flash';  // 비용 효율적 + 충분한 성능
  }

  // Rule 3: 복잡한 논리/의사결정 필요
  if (task.needsReasoning || task.complexity === 'high') {
    // 단, 입력 크기가 크면 Gemini 우선
    if ((task.inputTokens ?? 0) > 50_000) return 'gemini-2-flash';
    return 'claude-sonnet';  // 최고 성능
  }

  // Rule 4: 이미지/시각 처리
  if (task.needsVision) {
    return 'claude-sonnet';  // 현재 Claude만 지원
  }

  // Rule 5: 긴급 작업 (≤30초)
  if (task.timeConstraint) {
    if ((task.inputTokens ?? 0) > 50_000) return 'gemini-3-5-flash';  // 가장 빠름
    return 'claude-haiku';  // 표준 빠른 응답
  }

  // Rule 6: 저가 작업 (요약, 분류, 태깅, 뉴스 브리핑)
  if (task.type === 'summarize' || task.type === 'classify' || task.type === 'tag' || task.type === 'news-briefing') {
    // 중간 크기 문서는 Gemini 3.5 Flash, 작은 문서는 DeepSeek
    if ((task.inputTokens ?? 0) > 50_000) return 'gemini-3-5-flash';
    return 'deepseek-chat';  // 가장 저렴
  }

  // Rule 7: RAG 전처리
  if (task.type === 'rag-preprocess') {
    if ((task.inputTokens ?? 0) > 50_000) return 'gemini-3-5-flash';
    return 'deepseek-chat';
  }

  // Rule 8: 예산 제약
  if (task.maxBudget && task.inputTokens && task.outputTokens) {
    const costs = {
      'claude-sonnet': estimateCost('claude-sonnet', task.inputTokens, task.outputTokens),
      'gemini-2-flash': estimateCost('gemini-2-flash', task.inputTokens, task.outputTokens),
      'gemini-3-5-flash': estimateCost('gemini-3-5-flash', task.inputTokens, task.outputTokens),
      'deepseek-chat': estimateCost('deepseek-chat', task.inputTokens, task.outputTokens),
    };
    // 가장 저렴한 모델 선택
    return Object.entries(costs)
      .sort(([, a], [, b]) => a - b)[0][0];
  }

  // 기본값: 중간 수준의 성능과 가격의 균형
  if ((task.inputTokens ?? 0) > 50_000) return 'gemini-2-flash';
  return 'claude-haiku';
}

// ── 비용 계산 ─────────────────────────────────────────────────────────────

/**
 * 주어진 모델과 토큰 수로 예상 비용 계산
 *
 * @param {string} modelId - 모델 ID (claude-sonnet|gemini-flash|deepseek-chat 등)
 * @param {number} inputTokens - 입력 토큰 수
 * @param {number} outputTokens - 출력 토큰 수
 * @returns {number} 예상 비용 (USD)
 */
export function estimateCost(modelId, inputTokens = 0, outputTokens = 0) {
  // 모델 ID 정규화 (full model ID → short key 변환)
  const normalizeModelId = (id) => {
    const map = {
      'claude-haiku-4-5-20251001': 'claude-haiku',
      'claude-sonnet-4-6': 'claude-sonnet',
      'claude-opus-4-8': 'claude-opus',
      'gemini-3.5-flash-latest': 'gemini-3-5-flash',
      'gemini-2.0-flash': 'gemini-2-flash',
      'deepseek-chat': 'deepseek-chat',
    };
    return map[id] || id;
  };

  const normalizedId = normalizeModelId(modelId);
  const model = MODEL_PRICES[normalizedId];
  if (!model) throw new Error(`알 수 없는 모델: ${modelId} (정규화: ${normalizedId})`);

  const cost = (
    (inputTokens * model.input) +
    (outputTokens * model.output)
  ) / 1_000_000;

  return Math.round(cost * 1e8) / 1e8;  // 0.00000001 자리까지 정확도
}

// ── 모델 비교 분석 ────────────────────────────────────────────────────────

/**
 * 주어진 작업에 대해 모든 모델의 비용과 성능을 비교
 *
 * @param {Task} task
 * @returns {Array<{model: string, cost: number, name: string, recommended: boolean}>}
 */
export function compareModels(task = {}) {
  const inputTokens = task.inputTokens ?? 100_000;
  const outputTokens = task.outputTokens ?? 1_000;

  const selectedModel = selectModel(task);

  return Object.entries(MODEL_PRICES)
    .map(([modelId, info]) => ({
      model: modelId,
      name: info.name,
      cost: estimateCost(modelId, inputTokens, outputTokens),
      contextWindow: info.contextWindow,
      features: info.features,
      tier: info.tier,
      recommended: modelId === selectedModel,
    }))
    .sort((a, b) => a.cost - b.cost);
}

// ── 라우터 통계 및 모니터링 ────────────────────────────────────────────────

class RouterStats {
  constructor() {
    this.decisions = {};  // modelId → count
    this.costs = {};      // modelId → total cost
    this.tasks = [];      // 최근 결정 이력
  }

  record(modelId, cost, taskType) {
    this.decisions[modelId] = (this.decisions[modelId] ?? 0) + 1;
    this.costs[modelId] = (this.costs[modelId] ?? 0) + cost;
    this.tasks.push({
      model: modelId,
      cost,
      taskType,
      timestamp: new Date().toISOString(),
    });

    // 최근 100개만 유지
    if (this.tasks.length > 100) {
      this.tasks.shift();
    }
  }

  summary() {
    const totalCost = Object.values(this.costs).reduce((a, b) => a + b, 0);
    return {
      totalDecisions: Object.values(this.decisions).reduce((a, b) => a + b, 0),
      totalCost: Math.round(totalCost * 1e8) / 1e8,
      byModel: Object.entries(this.decisions).map(([modelId, count]) => ({
        model: modelId,
        count,
        cost: Math.round((this.costs[modelId] ?? 0) * 1e8) / 1e8,
        percentage: ((count / Object.values(this.decisions).reduce((a, b) => a + b)) * 100).toFixed(1),
      })),
      recentTasks: this.tasks.slice(-5),
    };
  }
}

export const routerStats = new RouterStats();

// ── CLI 사용 예 ───────────────────────────────────────────────────────────

if (process.argv[1] && process.argv[1].endsWith('model-router.mjs')) {
  const [,, command, taskJson] = process.argv;

  try {
    let task = {};
    if (taskJson) {
      task = JSON.parse(taskJson);
    }

    switch (command) {
      case 'select': {
        const model = selectModel(task);
        console.log(JSON.stringify({ model, info: MODEL_PRICES[model] }, null, 2));
        break;
      }

      case 'compare': {
        const comparison = compareModels(task);
        comparison.forEach(m => {
          const marker = m.recommended ? ' ← 추천' : '';
          console.log(`${m.name.padEnd(20)} | $${m.cost.toFixed(6).padEnd(10)} | ${m.tier}${marker}`);
        });
        break;
      }

      case 'estimate': {
        const { inputTokens = 100_000, outputTokens = 1_000 } = task;
        const models = ['claude-sonnet', 'gemini-2-flash', 'gemini-3-5-flash', 'deepseek-chat'];
        console.log(`\n입력: ${inputTokens}, 출력: ${outputTokens}`);
        models.forEach(m => {
          const cost = estimateCost(m, inputTokens, outputTokens);
          console.log(`${MODEL_PRICES[m].name.padEnd(20)}: $${cost.toFixed(6)}`);
        });
        break;
      }

      default:
        console.error('사용법: node model-router.mjs <select|compare|estimate> [task-json]');
        console.error('예: node model-router.mjs select \'{"type":"summarize","inputTokens":100000}\'');
        process.exit(1);
    }
  } catch (err) {
    console.error('오류:', err.message);
    process.exit(1);
  }
}

export { MODEL_PRICES, RouterStats };
