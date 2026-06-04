/**
 * gemini-flash-lite-client.mjs — Google Gemini 2.0 Flash-Lite API 클라이언트
 *
 * 경량 서브태스크(분류, 요약, 태깅 등) 전용 저가 모델 클라이언트.
 *
 * 모델: gemini-2.0-flash-lite
 *   - 가격: $0.075/1M input tokens, $0.30/1M output tokens
 *   - 컨텍스트: 1M 토큰
 *   - 응답 속도: gemini-2.0-flash 대비 약 2.5배 빠름
 *
 * 비교:
 *   | 모델                   | Input/1M   | Output/1M  |
 *   |------------------------|------------|------------|
 *   | gemini-2.0-flash-lite  | $0.075     | $0.30      |  ← 이 클라이언트
 *   | gemini-2.0-flash       | $1.50      | $9.00      |
 *   | Claude Haiku 3.5       | $0.80      | $4.00      |
 *   | Claude Sonnet 3.7      | $3.00      | $15.00     |
 *
 * 환경변수: GEMINI_API_KEY (필수)
 *
 * 사용법:
 *   import { flashLiteChat, classify, summarizeLite } from './gemini-flash-lite-client.mjs';
 *   const label = await classify("텍스트...", ["긍정", "부정", "중립"]);
 *
 * ADR: ADR-011 (Multi-model orchestration policy)
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

// ── 상수 ─────────────────────────────────────────────────────────────────────
const GEMINI_API_BASE = 'https://generativelanguage.googleapis.com/v1beta/models';
const MODEL_ID        = 'gemini-2.0-flash-lite';
const DEFAULT_TIMEOUT = 30_000;   // 30초 (경량 태스크용)

// 가격 (USD per token) — 2025-06 기준
const PRICE_INPUT  = 0.075 / 1_000_000;  // $0.075/1M tokens
const PRICE_OUTPUT = 0.30  / 1_000_000;  // $0.30/1M tokens

// ── API 키 로드 ───────────────────────────────────────────────────────────────
function loadApiKey() {
  if (process.env.GEMINI_API_KEY) return process.env.GEMINI_API_KEY;
  const envPaths = [
    join(homedir(), 'jarvis', 'runtime', 'discord', '.env'),
    join(homedir(), 'jarvis', 'runtime', '.env'),
    join(homedir(), '.jarvis', 'discord', '.env'),
  ];
  for (const p of envPaths) {
    try {
      const content = readFileSync(p, 'utf-8');
      for (const line of content.split('\n')) {
        if (line.startsWith('GEMINI_API_KEY=')) {
          const val = line.slice('GEMINI_API_KEY='.length).trim();
          if (val) return val;
        }
      }
    } catch { /* 파일 없으면 스킵 */ }
  }
  return null;
}

// ── 비용 계산 ─────────────────────────────────────────────────────────────────
function calcCost(usage) {
  const inputTokens  = usage.prompt_token_count ?? 0;
  const outputTokens = usage.candidates_token_count ?? 0;
  return inputTokens * PRICE_INPUT + outputTokens * PRICE_OUTPUT;
}

// ── 핵심 API 호출 ─────────────────────────────────────────────────────────────
/**
 * Gemini Flash-Lite 채팅 완성 호출.
 *
 * @param {Array<{role:string, parts:Array}>} messages
 * @param {object} [opts]
 * @param {number} [opts.maxTokens]   - 기본 1024
 * @param {number} [opts.temperature] - 기본 0.1
 * @param {number} [opts.timeout]     - ms, 기본 30000
 * @param {string} [opts.apiKey]      - 명시적 키
 * @returns {Promise<{text:string, usage:object, cost_usd:number, model:string, latency_ms:number}>}
 */
export async function flashLiteChat(messages, opts = {}) {
  const apiKey = opts.apiKey ?? loadApiKey();
  if (!apiKey) {
    throw new Error(
      'GEMINI_API_KEY가 설정되지 않았습니다. ' +
      '~/jarvis/runtime/runtime/discord/.env 에 GEMINI_API_KEY=... 를 추가하세요.'
    );
  }

  const url = new URL(`${GEMINI_API_BASE}/${MODEL_ID}:generateContent`);
  url.searchParams.append('key', apiKey);

  const requestBody = {
    contents: messages,
    generationConfig: {
      maxOutputTokens: opts.maxTokens ?? 1024,
      temperature:     opts.temperature ?? 0.1,
      topP:            0.95,
    },
  };

  const controller = new AbortController();
  const timerId = setTimeout(() => controller.abort(), opts.timeout ?? DEFAULT_TIMEOUT);

  const start = Date.now();
  let resp;
  try {
    resp = await fetch(url.toString(), {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(requestBody),
      signal:  controller.signal,
    });
  } finally {
    clearTimeout(timerId);
  }
  const latency_ms = Date.now() - start;

  if (!resp.ok) {
    const errText = await resp.text().catch(() => '');
    throw new Error(`Gemini Flash-Lite API 오류 (${resp.status}): ${errText.slice(0, 300)}`);
  }

  const data = await resp.json();

  if (data.error) {
    throw new Error(`Gemini Flash-Lite API 오류: ${data.error.message ?? JSON.stringify(data.error)}`);
  }

  const candidates = data.candidates ?? [];
  if (!candidates.length) throw new Error('Gemini Flash-Lite API: candidates 없음');

  const parts = candidates[0]?.content?.parts ?? [];
  const text  = parts.map((p) => p.text ?? '').join('');

  const usage = data.usageMetadata ?? {};
  const cost  = calcCost(usage);

  return {
    text,
    usage: {
      input_tokens:  usage.prompt_token_count ?? 0,
      output_tokens: usage.candidates_token_count ?? 0,
    },
    cost_usd:   Math.round(cost * 1e8) / 1e8,
    model:      MODEL_ID,
    latency_ms,
  };
}

// ── 고수준 헬퍼: 분류 ─────────────────────────────────────────────────────────
/**
 * 텍스트 분류 — 주어진 레이블 중 하나를 반환.
 *
 * @param {string}   text    - 분류할 텍스트
 * @param {string[]} labels  - 후보 레이블 배열 (예: ["긍정", "부정", "중립"])
 * @param {object}   [opts]
 * @returns {Promise<{label:string, cost_usd:number, latency_ms:number, usage:object}>}
 */
export async function classify(text, labels, opts = {}) {
  const labelList = labels.join(', ');
  const result = await flashLiteChat(
    [{
      role: 'user',
      parts: [{
        text: `다음 텍스트를 [${labelList}] 중 하나로 분류하세요.\n` +
              `반드시 레이블 이름만 출력하고 다른 설명을 추가하지 마세요.\n\n텍스트:\n${text}`,
      }],
    }],
    { maxTokens: 32, temperature: 0.0, ...opts }
  );

  const label = result.text.trim().replace(/["']/g, '');
  return { label, cost_usd: result.cost_usd, latency_ms: result.latency_ms, usage: result.usage };
}

// ── 고수준 헬퍼: 경량 요약 ───────────────────────────────────────────────────
/**
 * 짧은 텍스트 요약 — 1~3문장 핵심 요약.
 *
 * @param {string} text
 * @param {object} [opts]
 * @returns {Promise<{summary:string, cost_usd:number, latency_ms:number, usage:object}>}
 */
export async function summarizeLite(text, opts = {}) {
  const result = await flashLiteChat(
    [{
      role: 'user',
      parts: [{ text: `다음 텍스트를 1~3문장으로 핵심만 요약하세요:\n\n${text}` }],
    }],
    { maxTokens: 256, temperature: 0.1, ...opts }
  );
  return { summary: result.text, cost_usd: result.cost_usd, latency_ms: result.latency_ms, usage: result.usage };
}

// ── 고수준 헬퍼: 태깅 ─────────────────────────────────────────────────────────
/**
 * 텍스트에서 태그(키워드) 추출.
 *
 * @param {string} text
 * @param {number} [maxTags=5]
 * @param {object} [opts]
 * @returns {Promise<{tags:string[], cost_usd:number, latency_ms:number, usage:object}>}
 */
export async function extractTags(text, maxTags = 5, opts = {}) {
  const result = await flashLiteChat(
    [{
      role: 'user',
      parts: [{
        text: `다음 텍스트에서 핵심 키워드 최대 ${maxTags}개를 콤마로 구분하여 나열하세요.\n` +
              `키워드만 출력하고 다른 설명을 추가하지 마세요.\n\n${text}`,
      }],
    }],
    { maxTokens: 128, temperature: 0.0, ...opts }
  );
  const tags = result.text.split(',').map((t) => t.trim()).filter(Boolean);
  return { tags, cost_usd: result.cost_usd, latency_ms: result.latency_ms, usage: result.usage };
}

// ── CLI 직접 실행 지원 ────────────────────────────────────────────────────────
if (process.argv[1]?.endsWith('gemini-flash-lite-client.mjs')) {
  const [,, command, text, ...rest] = process.argv;

  if (!command || !text) {
    console.error('사용법: node gemini-flash-lite-client.mjs <classify|summarize|tags> "<text>" [labels...]');
    process.exit(1);
  }

  (async () => {
    try {
      let result;
      if (command === 'classify') {
        const labels = rest.length ? rest : ['긍정', '부정', '중립'];
        result = await classify(text, labels);
        console.log(`분류: ${result.label}`);
      } else if (command === 'summarize') {
        result = await summarizeLite(text);
        console.log(`요약: ${result.summary}`);
      } else if (command === 'tags') {
        result = await extractTags(text, 5);
        console.log(`태그: ${result.tags.join(', ')}`);
      } else {
        console.error(`알 수 없는 명령: ${command}`);
        process.exit(1);
      }
      console.log(`\n비용: $${result.cost_usd} | 지연: ${result.latency_ms}ms | 입력: ${result.usage.input_tokens}tok | 출력: ${result.usage.output_tokens}tok`);
    } catch (err) {
      console.error('오류:', err.message);
      process.exit(1);
    }
  })();
}
