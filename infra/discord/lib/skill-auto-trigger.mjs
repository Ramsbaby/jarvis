/**
 * skill-auto-trigger.mjs
 * ──────────────────────
 * 가드 #2: 사용자 발화 키워드 매칭 → 하네스 스크립트 자동 실행 → 결과를
 *          system prompt에 주입할 텍스트로 반환.
 *
 * 사고 사례 (2026-04-28):
 *   "동작 원리 / 메커니즘 / 어떻게 답 결정" 류 질문에서 자비스가 페르소나
 *   자연어 룰만 보고 코드 SSoT 누락 거짓 답변 → cross-check.sh 자동 실행
 *   결과를 prompt에 박아 LLM이 무시 못하게 강제.
 *
 * 사용법:
 *   import { autoTriggerHarness } from './skill-auto-trigger.mjs';
 *
 *   const injected = await autoTriggerHarness(userMessage);
 *   if (injected) {
 *     // injected 텍스트를 system prompt 상단에 prepend
 *   }
 */

import { execSync } from 'child_process';
import { existsSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';

// ────────────────────────────────────────────────────────────
// C10 가드 — 하네스 결과 5분 TTL LRU 캐시 (2026-04-28 추가)
// 동일 하네스 반복 호출 시 200~500ms 절감.
// 캐시 stale 위험 vs 정확도 트레이드오프: 5분 윈도우면 코드/페르소나 변경 즉시 반영 어려우나
// 채널 응답 latency 즉효 영향이 더 큼.
// ────────────────────────────────────────────────────────────
const HARNESS_CACHE = new Map();  // key: rule.name, value: { result, expiresAt }
const HARNESS_CACHE_TTL_MS = 5 * 60 * 1000;
const HARNESS_CACHE_MAX = 16;

function harnessCacheGet(name) {
  const entry = HARNESS_CACHE.get(name);
  if (!entry) return null;
  if (Date.now() > entry.expiresAt) {
    HARNESS_CACHE.delete(name);
    return null;
  }
  return entry.result;
}

function harnessCacheSet(name, result) {
  // LRU eviction
  if (HARNESS_CACHE.size >= HARNESS_CACHE_MAX) {
    const oldest = HARNESS_CACHE.keys().next().value;
    if (oldest) HARNESS_CACHE.delete(oldest);
  }
  HARNESS_CACHE.set(name, { result, expiresAt: Date.now() + HARNESS_CACHE_TTL_MS });
}

// ────────────────────────────────────────────────────────────
// 트리거 룰 — 사용자 키워드 → 하네스 매핑
// ────────────────────────────────────────────────────────────

const TRIGGER_RULES = [
  {
    name: 'interview-mechanism',
    keywords: [
      /동작\s*원리/, /메커니즘/, /어떻게\s*답/, /어떻게\s*결정/,
      /어떤\s*데이터/, /어떤\s*파일/, /무슨\s*데이터/,
      /어떤\s*플로우/, /어떻게\s*동작/, /흐름.*보여/,
      /채널.*어떻게/, /jarvis-interview/, /1497124568031301752/,
      /페르소나.*어떻게/, /답을\s*결정/,
    ],
    harnessPath: join(homedir(), 'projects/jarvis/infra/scripts/interview-mechanism-cross-check.sh'),
    label: '면접 채널 동작 원리 SSoT cross-check',
    timeoutMs: 8000,
  },
  // 향후 다른 도메인 추가 — 예:
  // {
  //   name: 'rag-health',
  //   keywords: [/RAG\s*상태/, /벡터\s*DB/, /임베딩.*동작/],
  //   harnessPath: '...rag-cross-check.sh',
  // },
];

/**
 * 사용자 발화에서 트리거 룰 매칭.
 * @param {string} userText
 * @returns {Array<object>} 매칭된 룰 (복수 매칭 가능)
 */
export function detectTriggers(userText) {
  if (!userText || typeof userText !== 'string') return [];
  const matched = [];
  for (const rule of TRIGGER_RULES) {
    const hit = rule.keywords.some(kw => kw.test(userText));
    if (hit) matched.push(rule);
  }
  return matched;
}

/**
 * 하네스 스크립트 실행 후 결과 캡처.
 * @param {object} rule - TRIGGER_RULES 항목
 * @returns {{success: boolean, output: string, exitCode: number, error?: string}}
 */
function runHarness(rule) {
  // C10 캐시 hit 우선 검사
  const cached = harnessCacheGet(rule.name);
  if (cached) {
    return { ...cached, _cacheHit: true };
  }

  if (!existsSync(rule.harnessPath)) {
    return {
      success: false,
      output: '',
      exitCode: -1,
      error: `harness 파일 없음: ${rule.harnessPath}`,
    };
  }
  try {
    const output = execSync(`bash ${rule.harnessPath}`, {
      timeout: rule.timeoutMs || 8000,
      encoding: 'utf-8',
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const result = { success: true, output, exitCode: 0 };
    harnessCacheSet(rule.name, result);
    return result;
  } catch (err) {
    // exit 1은 drift 발견 신호 — 정상 동작이므로 output 보존
    if (err.status === 1 && err.stdout) {
      const result = {
        success: true,
        output: err.stdout.toString(),
        exitCode: 1,
        driftDetected: true,
      };
      harnessCacheSet(rule.name, result);
      return result;
    }
    return {
      success: false,
      output: err.stdout?.toString() || '',
      exitCode: err.status || -1,
      error: err.message,
    };
  }
}

/**
 * 사용자 발화 받아서 매칭되는 모든 하네스 자동 실행 + system prompt 주입용 텍스트 반환.
 *
 * @param {string} userText
 * @param {object} opts - { maxRules=2, maxOutputChars=2500 }
 * @returns {Promise<string|null>} 주입할 텍스트 (없으면 null)
 */
export async function autoTriggerHarness(userText, opts = {}) {
  const { maxRules = 2, maxOutputChars = 2500 } = opts;

  const matched = detectTriggers(userText);
  if (matched.length === 0) return null;

  const sections = [];
  for (const rule of matched.slice(0, maxRules)) {
    const result = runHarness(rule);
    const cappedOutput = result.output.length > maxOutputChars
      ? result.output.slice(0, maxOutputChars) + '\n[...출력 cap]'
      : result.output;

    const status = result.success
      ? (result.driftDetected ? '⚠️ DRIFT 감지' : '✅ 정상')
      : `❌ 실행 실패: ${result.error}`;

    sections.push(
      `### 🔧 자동 하네스: ${rule.label}\n` +
      `상태: ${status} (exit ${result.exitCode})\n\n` +
      '```\n' + cappedOutput.trim() + '\n```'
    );
  }

  if (sections.length === 0) return null;

  return [
    '--- 🚨 자동 하네스 결과 (질문 매칭으로 자동 실행됨) ---',
    '이 결과를 답변에 반드시 반영하십시오. 무시 금지.',
    '',
    ...sections,
    '--- 자동 하네스 결과 끝 ---',
  ].join('\n');
}

// ────────────────────────────────────────────────────────────
// CLI 진입점
// ────────────────────────────────────────────────────────────
if (import.meta.url === `file://${process.argv[1]}`) {
  const test = process.argv[2] || 'jarvis-interview 채널이 어떻게 동작하나요?';
  const triggers = detectTriggers(test);
  console.log(`Input: "${test}"`);
  console.log(`Matched: ${triggers.length}건`);
  triggers.forEach(t => console.log(`  - ${t.name}: ${t.label}`));
  if (triggers.length > 0) {
    autoTriggerHarness(test).then(injected => {
      console.log('\n--- Injected text (preview) ---');
      console.log(injected ? injected.slice(0, 800) + '...' : '(none)');
    });
  }
}
