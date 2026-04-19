/**
 * ab-experiment.js — Discord 봇 포맷/스트리밍 옵션 A/B 실험 프레임워크 (P3-3)
 *
 * 목적:
 *   스트리밍 throttle, 포맷팅 버전, 프롬프트 전략 등의 변종(variant)을
 *   사용자 ID 기반 deterministic 해시로 50/50 분산하고,
 *   선택된 variant와 응답 메타(만족도/길이/지연)를 ledger에 적재하여
 *   주관이 아닌 데이터로 품질 개선 방향을 결정할 수 있게 한다.
 *
 * 설계:
 *   - 실험 정의: { name, variants: [A, B, ...], default, enabled, targetChannels? }
 *   - 분산 방식: SHA-256(userId + experimentName) mod variants.length — 같은 사용자는 항상 동일 variant
 *   - Ledger: $BOT_HOME/state/experiments/<name>.jsonl 에 JSON Lines로 누적
 *   - 비활성 시: 항상 default variant 반환
 *
 * 사용 예:
 *   import { pickVariant, recordOutcome } from './ab-experiment.js';
 *
 *   // streaming.js throttle:
 *   const variant = pickVariant('throttle', userId);
 *   const interval = variant === 'aggressive' ? 300 : 700;
 *   ...
 *   // finalize 시점:
 *   recordOutcome('throttle', userId, { elapsedMs, editCount, variant });
 *
 * Exports:
 *   - defineExperiment(name, variants, opts)
 *   - pickVariant(name, userId) → string
 *   - recordOutcome(name, userId, data)
 *   - getExperimentReport(name) → { total, perVariant }
 *   - listExperiments() → string[]
 */

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { log } from './claude-runner.js';

const BOT_HOME = process.env.BOT_HOME || `${homedir()}/jarvis/runtime`;
const EXP_DIR = join(BOT_HOME, 'state', 'experiments');

// ---------------------------------------------------------------------------
// 실험 레지스트리 — 코드 내 정의. 추가는 이 파일의 _BUILTIN 또는 defineExperiment().
// ---------------------------------------------------------------------------
const _registry = new Map();

/**
 * 실험 등록. 동일 name 재등록 시 덮어씀.
 * @param {string} name 실험 식별자 (file-safe: a-z0-9-_)
 * @param {string[]} variants 최소 2개
 * @param {{default?: string, enabled?: boolean, targetChannels?: string[], description?: string}} opts
 */
export function defineExperiment(name, variants, opts = {}) {
  if (!/^[a-z0-9_-]{1,40}$/.test(name)) {
    throw new Error(`Invalid experiment name: ${name}`);
  }
  if (!Array.isArray(variants) || variants.length < 2) {
    throw new Error('variants must be array with >=2 entries');
  }
  const def = {
    name,
    variants,
    default: opts.default ?? variants[0],
    enabled: opts.enabled !== false, // 기본 활성
    targetChannels: opts.targetChannels ?? null, // null = 모든 채널
    description: opts.description ?? '',
  };
  if (!def.variants.includes(def.default)) {
    throw new Error(`default "${def.default}" not in variants ${JSON.stringify(variants)}`);
  }
  _registry.set(name, def);
  return def;
}

/**
 * deterministic 변종 선택.
 * @param {string} name
 * @param {string} userId
 * @param {{ channelName?: string }} [ctx]
 * @returns {string} variant 값
 */
export function pickVariant(name, userId, ctx = {}) {
  const def = _registry.get(name);
  if (!def || !def.enabled) return def?.default ?? null;

  // 채널 타겟 필터
  if (def.targetChannels && ctx.channelName && !def.targetChannels.includes(ctx.channelName)) {
    return def.default;
  }

  const uid = userId || 'anon';
  const hash = createHash('sha256').update(`${name}:${uid}`).digest();
  const bucket = hash[0] % def.variants.length;
  return def.variants[bucket];
}

/**
 * outcome 기록 — 실험 결과 ledger에 append.
 * 실패해도 silent (응답 차단 금지).
 * @param {string} name
 * @param {string} userId
 * @param {object} data { variant, elapsedMs, editCount, ... }
 */
export function recordOutcome(name, userId, data = {}) {
  const def = _registry.get(name);
  if (!def || !def.enabled) return;
  try {
    if (!existsSync(EXP_DIR)) mkdirSync(EXP_DIR, { recursive: true });
    const entry = JSON.stringify({
      ts: new Date().toISOString(),
      experiment: name,
      userId: userId || 'anon',
      ...data,
    }) + '\n';
    appendFileSync(join(EXP_DIR, `${name}.jsonl`), entry);
  } catch (err) {
    log('debug', 'ab-experiment: recordOutcome failed (non-blocking)', { name, error: err.message });
  }
}

/**
 * 실험 리포트 — ledger 읽어서 variant별 통계 집계.
 * 대용량 파일에서도 stream 없이 한 번에 읽어 집계 (< 10MB 가정).
 * @param {string} name
 * @returns {{ total: number, perVariant: Record<string, { count: number, avgElapsedMs?: number }> }}
 */
export function getExperimentReport(name) {
  const empty = { total: 0, perVariant: {} };
  const def = _registry.get(name);
  if (!def) return empty;
  const file = join(EXP_DIR, `${name}.jsonl`);
  if (!existsSync(file)) return empty;
  let total = 0;
  const per = {};
  try {
    const raw = readFileSync(file, 'utf-8');
    const lines = raw.split('\n').filter(Boolean);
    for (const line of lines) {
      try {
        const row = JSON.parse(line);
        const v = row.variant ?? 'unknown';
        if (!per[v]) per[v] = { count: 0, totalElapsed: 0, elapsedN: 0 };
        per[v].count++;
        if (typeof row.elapsedMs === 'number') {
          per[v].totalElapsed += row.elapsedMs;
          per[v].elapsedN++;
        }
        total++;
      } catch { /* malformed line — skip */ }
    }
    const perVariant = {};
    for (const [k, v] of Object.entries(per)) {
      perVariant[k] = {
        count: v.count,
        avgElapsedMs: v.elapsedN > 0 ? Math.round(v.totalElapsed / v.elapsedN) : null,
      };
    }
    return { total, perVariant };
  } catch (err) {
    log('warn', 'ab-experiment: report read failed', { name, error: err.message });
    return empty;
  }
}

/** 등록된 실험 목록 반환 */
export function listExperiments() {
  return [...(_registry.keys())];
}

/** 실험 정의 반환 (디버깅) */
export function getExperimentDef(name) {
  return _registry.get(name) ?? null;
}

// ---------------------------------------------------------------------------
// 기본 내장 실험 — 비활성 상태로 등록 (명시적으로 enabled=true 로 전환 시 활성)
// ---------------------------------------------------------------------------
// 환경변수로 실험 활성화 제어 (기본 비활성 — recordOutcome 부하 방지)
//   AB_EXPERIMENT_ENABLED=1 → 모든 내장 실험 활성
//   AB_EXPERIMENT_ENABLED=throttle-v1,citation-v1 → 지정 실험만 활성
function _isBuiltinEnabled(name) {
  const val = (process.env.AB_EXPERIMENT_ENABLED || '').trim();
  if (!val || val === '0' || val === 'false') return false;
  if (val === '1' || val === 'true' || val === 'all') return true;
  return val.split(',').map(s => s.trim()).includes(name);
}
const _BUILTIN = [
  {
    name: 'throttle-v1',
    variants: ['adaptive', 'fixed-700'],
    default: 'adaptive',
    description: 'streaming.js adaptive vs. 700ms 고정 간격 비교',
  },
  {
    name: 'citation-v1',
    variants: ['formatted', 'raw'],
    default: 'formatted',
    description: '각주 포맷팅 적용 여부 비교',
  },
  {
    name: 'thread-v1',
    variants: ['auto', 'disabled'],
    default: 'auto',
    description: '긴 응답 자동 Thread 생성 vs 비활성',
  },
];
for (const b of _BUILTIN) {
  defineExperiment(b.name, b.variants, {
    default: b.default,
    enabled: _isBuiltinEnabled(b.name),
    description: b.description,
  });
}

// 테스트용 내부 상태 노출
export const _internals = { _registry, EXP_DIR };
