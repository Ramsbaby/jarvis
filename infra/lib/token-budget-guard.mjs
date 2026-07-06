/**
 * token-budget-guard.mjs — Jarvis 에이전트 토큰 예산 가드
 *
 * 목적:
 *   - 에이전틱 루프에서 토큰 소비가 사전 설정 예산 상한을 초과하기 전에 조기 종료
 *   - token-ledger.jsonl 기반 실시간 누적 집계
 *   - 예산 초과 시 경고 로그 기록 후 비정상 종료 없이 안전하게 중단
 *
 * 사용 방법 (Node.js ESM):
 *   import { TokenBudgetGuard } from './token-budget-guard.mjs';
 *
 *   const guard = new TokenBudgetGuard({ taskId: 'my-task', maxBudgetUsd: 1.0 });
 *   guard.check();  // 예산 초과 시 BudgetExceededError throw
 *
 * CLI (bash에서 직접 호출):
 *   node token-budget-guard.mjs check --task <id> --max-budget <usd>
 *   node token-budget-guard.mjs report --task <id>
 *   node token-budget-guard.mjs daily-total
 *
 * 설계 결정:
 *   - token-ledger.jsonl SSoT 사용 (별도 DB 불필요, 기존 인프라 재사용)
 *   - 하드 한도(hard limit) + 경고 한도(warn at 80%) 이중 레이어
 *   - 예산 초과 시 exit code 2 (기존 error=1, timeout=124와 구분)
 *   - 일일 전체 누적 한도와 태스크별 한도 모두 지원
 *
 * ADR-013: Token Budget Guard
 */

import { readFileSync, appendFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const LEDGER_PATH = join(BOT_HOME, 'state', 'token-ledger.jsonl');
const GUARD_LOG_PATH = join(BOT_HOME, 'logs', 'token-budget-guard.log');

// ──────────────────────────────────────────────
// 기본 임계값 설정
// ──────────────────────────────────────────────
export const DEFAULTS = {
  /** 태스크별 기본 최대 예산 (USD). tasks.json의 maxBudget이 우선 */
  maxBudgetUsd: 1.0,
  /** 일일 전체 누적 상한 (USD) */
  dailyCapUsd: 10.0,
  /** 경고 발생 임계값 (예산 대비 비율, 0~1) */
  warnThreshold: 0.8,
  /** 집계 시 고려할 최근 시간 범위 (시간 단위) */
  windowHours: 24,
  /**
   * Sonnet 5 신규 토크나이저 보정 계수 (ADR-014)
   *
   * Sonnet 5 토크나이저는 동일 텍스트를 약 30% 더 많은 토큰으로 분할한다.
   * token-ledger.jsonl에 기록된 비용(cost_usd)은 실제 청구 기준이므로
   * 직접 영향은 없으나, 사전 버짓 추정(예측 비용)이 과소평가될 수 있다.
   * 이 계수를 적용해 실측 비용 집계를 상향 보정함으로써 초과 위험을 조기 감지한다.
   *
   * 근거: claude-sonnet-5 / claude-sonnet-5-20260615 모델 기준 측정값 ~1.3×
   */
  tokenizerCorrectionFactor: 1.3,
};

/**
 * 예산 초과 시 throw되는 에러
 * exit code 2로 처리하여 기존 error(1), timeout(124)와 구분
 */
export class BudgetExceededError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = 'BudgetExceededError';
    this.details = details;
    this.exitCode = 2;
  }
}

/**
 * token-ledger.jsonl 파싱
 * @param {string} [taskId] - 특정 태스크만 필터 (없으면 전체)
 * @param {number} [windowHours] - 최근 N시간 이내 항목만 (없으면 전체)
 * @returns {{ entries: object[], totalCostUsd: number, totalInputTokens: number, totalOutputTokens: number }}
 */
export function readLedger(taskId = null, windowHours = null) {
  let lines = [];
  try {
    lines = readFileSync(LEDGER_PATH, 'utf8').split('\n').filter(Boolean);
  } catch {
    return { entries: [], totalCostUsd: 0, totalInputTokens: 0, totalOutputTokens: 0 };
  }

  const cutoff = windowHours
    ? Date.now() - windowHours * 3600 * 1000
    : 0;

  const entries = [];
  for (const line of lines) {
    try {
      const entry = JSON.parse(line);
      if (taskId && entry.task !== taskId) continue;
      if (windowHours) {
        const ts = new Date(entry.ts).getTime();
        if (ts < cutoff) continue;
      }
      entries.push(entry);
    } catch {
      // 손상된 줄 스킵
    }
  }

  const totalCostUsd = entries.reduce((s, e) => s + (Number(e.cost_usd) || 0), 0);
  const totalInputTokens = entries.reduce((s, e) => s + (Number(e.input) || 0), 0);
  const totalOutputTokens = entries.reduce((s, e) => s + (Number(e.output) || 0), 0);

  return { entries, totalCostUsd, totalInputTokens, totalOutputTokens };
}

/**
 * 가드 로그 기록 (JSONL)
 */
function writeGuardLog(level, taskId, message, details = {}) {
  try {
    mkdirSync(join(BOT_HOME, 'logs'), { recursive: true });
    const entry = JSON.stringify({
      ts: new Date().toISOString(),
      level,
      task: taskId || 'unknown',
      msg: message,
      ...details,
    });
    appendFileSync(GUARD_LOG_PATH, entry + '\n');
  } catch {
    // 로그 실패는 무시 (가드 자체는 계속)
  }
}

/**
 * TokenBudgetGuard 클래스
 *
 * 사용 예:
 *   const guard = new TokenBudgetGuard({
 *     taskId: 'system-health',
 *     maxBudgetUsd: 0.5,
 *     dailyCapUsd: 10.0,
 *   });
 *   guard.check(); // 초과 시 BudgetExceededError
 */
export class TokenBudgetGuard {
  /**
   * @param {object} opts
   * @param {string} opts.taskId
   * @param {number} [opts.maxBudgetUsd]
   * @param {number} [opts.dailyCapUsd]
   * @param {number} [opts.warnThreshold]
   * @param {number} [opts.tokenizerCorrectionFactor] - Sonnet 5 토크나이저 보정 계수 (기본 1.3)
   */
  constructor(opts = {}) {
    this.taskId = opts.taskId || process.env.TASK_ID || 'unknown';
    this.maxBudgetUsd = Number(opts.maxBudgetUsd ?? DEFAULTS.maxBudgetUsd);
    this.dailyCapUsd = Number(opts.dailyCapUsd ?? DEFAULTS.dailyCapUsd);
    this.warnThreshold = Number(opts.warnThreshold ?? DEFAULTS.warnThreshold);
    this.tokenizerCorrectionFactor = Number(
      opts.tokenizerCorrectionFactor
      ?? process.env.JARVIS_TOKENIZER_CORRECTION_FACTOR
      ?? DEFAULTS.tokenizerCorrectionFactor
    );
  }

  /**
   * 현재 태스크의 누적 비용을 집계하고 예산 초과 여부 판단
   *
   * - 태스크별 예산 초과 → BudgetExceededError (exit 2)
   * - 일일 전체 한도 초과 → BudgetExceededError (exit 2)
   * - 경고 임계값 도달 → stderr 경고 출력 (종료 없음)
   *
   * @returns {{ taskCostUsd: number, dailyCostUsd: number, withinBudget: boolean }}
   */
  check() {
    const taskLedger = readLedger(this.taskId, DEFAULTS.windowHours);
    const dailyLedger = readLedger(null, 24);

    // Sonnet 5 토크나이저 보정: 레져 실측값에 보정 계수를 곱해 예상 비용 상향 조정
    // 동일 텍스트 기준 ~30% 더 많은 토큰 → 비용 과소평가 위험 완화
    const factor = this.tokenizerCorrectionFactor;
    const taskCostUsd = taskLedger.totalCostUsd * factor;
    const dailyCostUsd = dailyLedger.totalCostUsd * factor;

    const result = {
      taskId: this.taskId,
      taskCostUsd: +taskCostUsd.toFixed(6),
      taskCostRawUsd: +taskLedger.totalCostUsd.toFixed(6),
      dailyCostUsd: +dailyCostUsd.toFixed(6),
      dailyCostRawUsd: +dailyLedger.totalCostUsd.toFixed(6),
      tokenizerCorrectionFactor: factor,
      maxBudgetUsd: this.maxBudgetUsd,
      dailyCapUsd: this.dailyCapUsd,
      withinBudget: true,
    };

    // ── 일일 전체 한도 초과 체크 ──
    if (dailyCostUsd >= this.dailyCapUsd) {
      const msg = `[TOKEN_BUDGET_GUARD] DAILY_CAP_EXCEEDED: daily=${dailyCostUsd.toFixed(4)} USD >= cap=${this.dailyCapUsd} USD`;
      writeGuardLog('ERROR', this.taskId, msg, result);
      process.stderr.write(msg + '\n');
      throw new BudgetExceededError(msg, { ...result, reason: 'daily_cap_exceeded' });
    }

    // ── 태스크별 예산 초과 체크 ──
    if (this.maxBudgetUsd > 0 && taskCostUsd >= this.maxBudgetUsd) {
      const msg = `[TOKEN_BUDGET_GUARD] TASK_BUDGET_EXCEEDED: task=${this.taskId} cost=${taskCostUsd.toFixed(4)} USD >= budget=${this.maxBudgetUsd} USD`;
      writeGuardLog('ERROR', this.taskId, msg, result);
      process.stderr.write(msg + '\n');
      throw new BudgetExceededError(msg, { ...result, reason: 'task_budget_exceeded' });
    }

    // ── 경고 임계값 체크 (태스크) ──
    if (this.maxBudgetUsd > 0 && taskCostUsd >= this.maxBudgetUsd * this.warnThreshold) {
      const pct = ((taskCostUsd / this.maxBudgetUsd) * 100).toFixed(1);
      const msg = `[TOKEN_BUDGET_GUARD] WARN: task=${this.taskId} cost=${taskCostUsd.toFixed(4)} USD (${pct}% of budget ${this.maxBudgetUsd} USD)`;
      writeGuardLog('WARN', this.taskId, msg, result);
      process.stderr.write(msg + '\n');
    }

    // ── 경고 임계값 체크 (일일) ──
    if (dailyCostUsd >= this.dailyCapUsd * this.warnThreshold) {
      const pct = ((dailyCostUsd / this.dailyCapUsd) * 100).toFixed(1);
      const msg = `[TOKEN_BUDGET_GUARD] DAILY_WARN: daily=${dailyCostUsd.toFixed(4)} USD (${pct}% of daily cap ${this.dailyCapUsd} USD)`;
      writeGuardLog('WARN', this.taskId, msg, result);
      process.stderr.write(msg + '\n');
    }

    writeGuardLog('INFO', this.taskId, 'budget_ok', result);
    return { ...result, withinBudget: true };
  }

  /**
   * 현재 누적 비용 리포트 (종료 없음)
   * @returns {object}
   */
  report() {
    const taskLedger = readLedger(this.taskId, DEFAULTS.windowHours);
    const dailyLedger = readLedger(null, 24);
    const factor = this.tokenizerCorrectionFactor;
    const adjustedTaskCost = taskLedger.totalCostUsd * factor;
    const adjustedDailyCost = dailyLedger.totalCostUsd * factor;
    return {
      taskId: this.taskId,
      taskCostUsd: +adjustedTaskCost.toFixed(6),
      taskCostRawUsd: +taskLedger.totalCostUsd.toFixed(6),
      taskInputTokens: taskLedger.totalInputTokens,
      taskOutputTokens: taskLedger.totalOutputTokens,
      taskCallCount: taskLedger.entries.length,
      dailyCostUsd: +adjustedDailyCost.toFixed(6),
      dailyCostRawUsd: +dailyLedger.totalCostUsd.toFixed(6),
      dailyCallCount: dailyLedger.entries.length,
      tokenizerCorrectionFactor: factor,
      maxBudgetUsd: this.maxBudgetUsd,
      dailyCapUsd: this.dailyCapUsd,
      budgetUsedPct: this.maxBudgetUsd > 0
        ? +((adjustedTaskCost / this.maxBudgetUsd) * 100).toFixed(1)
        : null,
    };
  }
}

// ──────────────────────────────────────────────
// CLI 진입점
// ──────────────────────────────────────────────
if (process.argv[1] && process.argv[1].endsWith('token-budget-guard.mjs')) {
  const [,, command, ...rest] = process.argv;

  // 인자 파싱 헬퍼
  const getArg = (flag) => {
    const idx = rest.indexOf(flag);
    return idx !== -1 ? rest[idx + 1] : null;
  };

  switch (command) {
    case 'check': {
      const taskId = getArg('--task') || process.env.TASK_ID;
      const maxBudget = parseFloat(getArg('--max-budget') || process.env.JARVIS_MAX_BUDGET_USD || DEFAULTS.maxBudgetUsd);
      const dailyCap = parseFloat(getArg('--daily-cap') || process.env.JARVIS_DAILY_CAP_USD || DEFAULTS.dailyCapUsd);

      if (!taskId) {
        process.stderr.write('[TOKEN_BUDGET_GUARD] ERROR: --task <id> required\n');
        process.exit(1);
      }

      try {
        const guard = new TokenBudgetGuard({ taskId, maxBudgetUsd: maxBudget, dailyCapUsd: dailyCap });
        const result = guard.check();
        process.stdout.write(JSON.stringify(result) + '\n');
        process.exit(0);
      } catch (err) {
        if (err instanceof BudgetExceededError) {
          process.stdout.write(JSON.stringify({ withinBudget: false, reason: err.details.reason, ...err.details }) + '\n');
          process.exit(err.exitCode); // exit 2
        }
        process.stderr.write(`[TOKEN_BUDGET_GUARD] UNEXPECTED: ${err.message}\n`);
        process.exit(1);
      }
    }

    case 'report': {
      const taskId = getArg('--task') || process.env.TASK_ID;
      const maxBudget = parseFloat(getArg('--max-budget') || process.env.JARVIS_MAX_BUDGET_USD || DEFAULTS.maxBudgetUsd);
      const guard = new TokenBudgetGuard({ taskId, maxBudgetUsd: maxBudget });
      const report = guard.report();
      process.stdout.write(JSON.stringify(report, null, 2) + '\n');
      process.exit(0);
    }

    case 'daily-total': {
      const dailyCap = parseFloat(getArg('--daily-cap') || process.env.JARVIS_DAILY_CAP_USD || DEFAULTS.dailyCapUsd);
      const factor = parseFloat(getArg('--correction-factor') || process.env.JARVIS_TOKENIZER_CORRECTION_FACTOR || DEFAULTS.tokenizerCorrectionFactor);
      const dailyLedger = readLedger(null, 24);
      const adjustedCost = dailyLedger.totalCostUsd * factor;
      const output = {
        dailyCostUsd: +adjustedCost.toFixed(6),
        dailyCostRawUsd: +dailyLedger.totalCostUsd.toFixed(6),
        tokenizerCorrectionFactor: factor,
        dailyCallCount: dailyLedger.entries.length,
        dailyCapUsd: dailyCap,
        dailyUsedPct: +((adjustedCost / dailyCap) * 100).toFixed(1),
      };
      process.stdout.write(JSON.stringify(output) + '\n');
      process.exit(0);
    }

    default:
      process.stderr.write(
        'Usage:\n' +
        '  node token-budget-guard.mjs check --task <id> [--max-budget <usd>] [--daily-cap <usd>]\n' +
        '  node token-budget-guard.mjs report --task <id> [--max-budget <usd>]\n' +
        '  node token-budget-guard.mjs daily-total [--daily-cap <usd>]\n'
      );
      process.exit(1);
  }
}
