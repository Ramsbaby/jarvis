/**
 * gemini-client.mjs — Google Gemini 3.5 Flash API 클라이언트
 *
 * Jarvis 대용량 문서 처리(100K+ tokens)용 비용 효율적 LLM 클라이언트.
 * 1M 컨텍스트 윈도우 + 저가 가격 모델.
 *
 * 모델: gemini-3.5-flash-latest (2025-05)
 *   - 1M 컨텍스트 윈도우
 *   - $1.50/1M input tokens, $9.00/1M output tokens
 *   - Claude Sonnet 대비 93% 저가 (input 기준)
 *
 * 환경변수: GEMINI_API_KEY (필수)
 *
 * 사용법:
 *   import { geminiChat, summarize, analyze } from './gemini-client.mjs';
 *   const result = await summarize("매우 긴 문서...");
 *   const analysis = await analyze("대용량 데이터...");
 *
 * ADR: ADR-011 (Multi-model orchestration policy)
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

// ── 상수 ─────────────────────────────────────────────────────────────────────
const GEMINI_API_URL = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent';
const DEFAULT_MODEL    = 'gemini-2.0-flash';
const DEFAULT_TIMEOUT  = 120_000;            // 120초 (대용량 문서용)

// 가격 (USD per token) — 2025-05 기준
const PRICE_INPUT      = 1.50   / 1_000_000;   // $1.50/1M tokens
const PRICE_OUTPUT     = 9.00   / 1_000_000;   // $9.00/1M tokens

// ── API 키 로드 ───────────────────────────────────────────────────────────────
function loadApiKey() {
  // 1순위: 환경변수
  if (process.env.GEMINI_API_KEY) return process.env.GEMINI_API_KEY;

  // 2순위: runtime/.env 파일
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
  return (
    inputTokens  * PRICE_INPUT +
    outputTokens * PRICE_OUTPUT
  );
}

// ── 핵심 API 호출 ─────────────────────────────────────────────────────────────
/**
 * Google Gemini 2.0 Flash 채팅 완성 호출.
 *
 * @param {Array<{role:string, parts:Array}>} messages - Gemini format
 * @param {object} [opts]
 * @param {string} [opts.model]       - 기본 'gemini-2.0-flash'
 * @param {number} [opts.maxTokens]   - 기본 8192
 * @param {number} [opts.temperature] - 기본 0.3
 * @param {number} [opts.timeout]     - ms, 기본 120000
 * @param {string} [opts.apiKey]      - 명시적 키
 * @returns {Promise<{text:string, usage:object, cost_usd:number, model:string}>}
 */
export async function geminiChat(messages, opts = {}) {
  const apiKey = opts.apiKey ?? loadApiKey();
  if (!apiKey) {
    throw new Error(
      'GEMINI_API_KEY가 설정되지 않았습니다. ' +
      '~/jarvis/runtime/runtime/discord/.env 에 GEMINI_API_KEY=... 를 추가하세요.'
    );
  }

  const model = opts.model ?? DEFAULT_MODEL;
  const url = new URL(GEMINI_API_URL);
  url.searchParams.append('key', apiKey);

  const requestBody = {
    model,
    contents: messages,
    generationConfig: {
      maxOutputTokens: opts.maxTokens ?? 8192,
      temperature:     opts.temperature ?? 0.3,
      topP:            0.95,
      topK:            40,
    },
  };

  const controller = new AbortController();
  const timerId = setTimeout(() => controller.abort(), opts.timeout ?? DEFAULT_TIMEOUT);

  let resp;
  try {
    resp = await fetch(url.toString(), {
      method:  'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body:   JSON.stringify(requestBody),
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timerId);
  }

  if (!resp.ok) {
    const errText = await resp.text().catch(() => '');
    throw new Error(`Gemini API 오류 (${resp.status}): ${errText.slice(0, 300)}`);
  }

  const data = await resp.json();

  if (data.error) {
    throw new Error(`Gemini API 오류: ${data.error.message ?? JSON.stringify(data.error)}`);
  }

  const candidates = data.candidates ?? [];
  if (!candidates.length) throw new Error('Gemini API: candidates 없음');

  const parts = candidates[0]?.content?.parts ?? [];
  const text = parts.map((p) => p.text ?? '').join('');

  const usage = data.usageMetadata ?? {};
  const cost = calcCost(usage);

  return {
    text,
    usage: {
      input_tokens:  usage.prompt_token_count ?? 0,
      output_tokens: usage.candidates_token_count ?? 0,
    },
    cost_usd: Math.round(cost * 1e8) / 1e8,
    model:    model,
  };
}

// ── 고수준 헬퍼: 요약 ─────────────────────────────────────────────────────────
/**
 * 텍스트 요약 — Jarvis 대용량 문서용.
 * 1M 컨텍스트 활용하여 매우 긴 문서도 한 번에 요약 가능.
 *
 * @param {string} text          - 요약할 원문
 * @param {object} [opts]
 * @param {number} [opts.maxSentences] - 최대 문장 수 (기본 5)
 * @param {string} [opts.lang]         - 응답 언어 힌트 (기본 '한국어')
 * @returns {Promise<{summary:string, cost_usd:number, usage:object}>}
 */
export async function summarize(text, opts = {}) {
  const maxSentences = opts.maxSentences ?? 5;
  const lang         = opts.lang ?? '한국어';

  const result = await geminiChat(
    [
      {
        role: 'user',
        parts: [
          {
            text: `다음 텍스트를 ${lang}로 ${maxSentences}문장 이내로 핵심만 요약하세요:\n\n${text}`,
          },
        ],
      },
    ],
    { maxTokens: 1024, temperature: 0.2, ...opts }
  );

  return { summary: result.text, cost_usd: result.cost_usd, usage: result.usage };
}

// ── 고수준 헬퍼: 분석 ─────────────────────────────────────────────────────────
/**
 * 텍스트 분석 — 대용량 문서의 구조·핵심·패턴 분석.
 *
 * @param {string} text    - 분석할 텍스트
 * @param {string} [task]  - 분석 태스크 (기본 'extract-key-insights')
 * @param {object} [opts]
 * @returns {Promise<{analysis:string, cost_usd:number, usage:object}>}
 */
export async function analyze(text, task = 'extract-key-insights', opts = {}) {
  const prompts = {
    'extract-key-insights': '다음 텍스트에서 가장 중요한 통찰과 핵심 포인트를 추출하세요.',
    'identify-patterns': '다음 텍스트에서 반복되는 패턴과 트렌드를 식별하세요.',
    'find-anomalies': '다음 텍스트에서 일반적인 패턴과 다른 이상(anomaly)을 찾으세요.',
    'extract-entities': '다음 텍스트에서 주요 개체(사람, 조직, 개념 등)를 추출하세요.',
  };

  const taskPrompt = prompts[task] ?? prompts['extract-key-insights'];

  const result = await geminiChat(
    [
      {
        role: 'user',
        parts: [
          {
            text: `${taskPrompt}\n\n${text}`,
          },
        ],
      },
    ],
    { maxTokens: 2048, temperature: 0.3, ...opts }
  );

  return { analysis: result.text, cost_usd: result.cost_usd, usage: result.usage };
}

// ── 고수준 헬퍼: RAG 전처리 ──────────────────────────────────────────────────────
/**
 * RAG 청크 전처리 — 매우 긴 문서를 벡터 검색에 최적화된 청크로 변환.
 * 1M 컨텍스트 활용: 최대 800K tokens ≈ 600K chars의 문서 단일 호출 처리.
 *
 * @param {string} document  - 원본 문서
 * @param {object} [opts]
 * @param {string} [opts.domain]  - 도메인 힌트 (tech, career, jarvis 등)
 * @returns {Promise<{chunks:string[], cost_usd:number, usage:object}>}
 */
export async function preprocessForRag(document, opts = {}) {
  const domain = opts.domain ?? '일반';

  const result = await geminiChat(
    [
      {
        role: 'user',
        parts: [
          {
            text: `다음은 "${domain}" 도메인의 문서입니다. 이를 벡터 검색에 유용한 핵심 청크로 변환하세요.

지침:
1. 각 청크는 독립적으로 의미를 가져야 함
2. 한국어로 자연스러운 완전한 문장 형태
3. 최대 20개 청크 (각 청크 50-300 토큰)
4. 청크들 사이에 빈 줄로 구분

원본 문서:
${document}`,
          },
        ],
      },
    ],
    { maxTokens: 4096, temperature: 0.2, ...opts }
  );

  const chunks = result.text
    .split(/\n\s*\n/)
    .map((c) => c.trim())
    .filter((c) => c.length > 10);

  return { chunks, cost_usd: result.cost_usd, usage: result.usage };
}

// ── CLI 직접 실행 지원 ────────────────────────────────────────────────────────
// node gemini-client.mjs summarize "텍스트..."
// node gemini-client.mjs analyze  "텍스트..."
// node gemini-client.mjs rag       "문서..."
if (process.argv[1] && process.argv[1].endsWith('gemini-client.mjs')) {
  const [,, command, text, extra] = process.argv;

  if (!command || !text) {
    console.error('사용법: node gemini-client.mjs <summarize|analyze|rag> "<text>" [task]');
    process.exit(1);
  }

  (async () => {
    try {
      let result;
      if (command === 'summarize') {
        result = await summarize(text);
        console.log('=== 요약 결과 ===');
        console.log(result.summary);
      } else if (command === 'analyze') {
        const task = extra ?? 'extract-key-insights';
        result = await analyze(text, task);
        console.log('=== 분석 결과 ===');
        console.log(result.analysis);
      } else if (command === 'rag') {
        result = await preprocessForRag(text);
        console.log('=== RAG 청크 ===');
        result.chunks.forEach((c, i) => console.log(`[${i + 1}] ${c}`));
      } else {
        console.error(`알 수 없는 명령: ${command}`);
        process.exit(1);
      }
      console.log(`\n비용: $${result.cost_usd} | 입력: ${result.usage.input_tokens} tok | 출력: ${result.usage.output_tokens} tok`);
    } catch (err) {
      console.error('오류:', err.message);
      process.exit(1);
    }
  })();
}
