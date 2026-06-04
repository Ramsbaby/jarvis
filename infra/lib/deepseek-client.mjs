/**
 * deepseek-client.mjs — DeepSeek V4-Flash API 클라이언트
 *
 * Jarvis 비용 민감 태스크(요약·분류·RAG 전처리)용 경량 LLM 클라이언트.
 * OpenAI-호환 chat completions 엔드포인트 사용.
 *
 * 모델: deepseek-chat (DeepSeek V4-Flash)
 *   - MIT 오픈웨이트
 *   - 1M 컨텍스트 지원
 *   - $0.14/1M input tokens, $0.28/1M output tokens (cache miss)
 *   - 캐시 히트 시: $0.014/1M input (90% 절감)
 *
 * 환경변수: DEEPSEEK_API_KEY (필수)
 *
 * 사용법:
 *   import { deepseekChat, summarize, classify } from './deepseek-client.mjs';
 *   const result = await summarize("긴 텍스트...");
 *   const label  = await classify("에러 메시지...", ["SyntaxError","ENOENT","NetworkError"]);
 *
 * ADR: ADR-011 (Multi-model orchestration policy)
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

// ── 상수 ─────────────────────────────────────────────────────────────────────
const DEEPSEEK_API_URL = 'https://api.deepseek.com/chat/completions';
const DEFAULT_MODEL    = 'deepseek-chat';   // V4-Flash (2025-05)
const DEFAULT_TIMEOUT  = 30_000;            // 30초

// 가격 (USD per token)
const PRICE_INPUT_MISS   = 0.14  / 1_000_000;   // cache miss
const PRICE_OUTPUT_MISS  = 0.28  / 1_000_000;
const PRICE_INPUT_HIT    = 0.014 / 1_000_000;   // cache hit (90% 할인)
const PRICE_OUTPUT_HIT   = 0.28  / 1_000_000;   // 출력은 동일

// ── API 키 로드 ───────────────────────────────────────────────────────────────
function loadApiKey() {
  // 1순위: 환경변수
  if (process.env.DEEPSEEK_API_KEY) return process.env.DEEPSEEK_API_KEY;

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
        if (line.startsWith('DEEPSEEK_API_KEY=')) {
          const val = line.slice('DEEPSEEK_API_KEY='.length).trim();
          if (val) return val;
        }
      }
    } catch { /* 파일 없으면 스킵 */ }
  }
  return null;
}

// ── 비용 계산 ─────────────────────────────────────────────────────────────────
function calcCost(usage) {
  const inputCacheHit  = usage.prompt_cache_hit_tokens   ?? 0;
  const inputCacheMiss = usage.prompt_cache_miss_tokens  ?? (usage.prompt_tokens ?? 0);
  const output         = usage.completion_tokens ?? 0;
  return (
    inputCacheHit  * PRICE_INPUT_HIT  +
    inputCacheMiss * PRICE_INPUT_MISS +
    output         * PRICE_OUTPUT_MISS
  );
}

// ── 핵심 API 호출 ─────────────────────────────────────────────────────────────
/**
 * DeepSeek V4-Flash 채팅 완성 호출.
 *
 * @param {Array<{role:string, content:string}>} messages
 * @param {object} [opts]
 * @param {string} [opts.model]       - 기본 'deepseek-chat'
 * @param {number} [opts.maxTokens]   - 기본 4096
 * @param {number} [opts.temperature] - 기본 0.3 (요약/분류에 적합)
 * @param {number} [opts.timeout]     - ms, 기본 30000
 * @param {string} [opts.apiKey]      - 명시적 키 (환경변수 대신)
 * @returns {Promise<{text:string, usage:object, cost_usd:number, model:string}>}
 */
export async function deepseekChat(messages, opts = {}) {
  const apiKey = opts.apiKey ?? loadApiKey();
  if (!apiKey) {
    throw new Error(
      'DEEPSEEK_API_KEY가 설정되지 않았습니다. ' +
      '~/jarvis/runtime/runtime/discord/.env 에 DEEPSEEK_API_KEY=sk-... 를 추가하세요.'
    );
  }

  const body = {
    model:       opts.model       ?? DEFAULT_MODEL,
    max_tokens:  opts.maxTokens   ?? 4096,
    temperature: opts.temperature ?? 0.3,
    messages,
  };

  const controller = new AbortController();
  const timerId = setTimeout(() => controller.abort(), opts.timeout ?? DEFAULT_TIMEOUT);

  let resp;
  try {
    resp = await fetch(DEEPSEEK_API_URL, {
      method:  'POST',
      headers: {
        'Content-Type':  'application/json',
        'Authorization': `Bearer ${apiKey}`,
      },
      body:   JSON.stringify(body),
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timerId);
  }

  if (!resp.ok) {
    const errText = await resp.text().catch(() => '');
    throw new Error(`DeepSeek API 오류 (${resp.status}): ${errText.slice(0, 300)}`);
  }

  const data = await resp.json();

  if (data.error) {
    throw new Error(`DeepSeek API 오류: ${data.error.message ?? JSON.stringify(data.error)}`);
  }

  const choices = data.choices ?? [];
  if (!choices.length) throw new Error('DeepSeek API: choices 없음');

  const text  = choices[0]?.message?.content ?? '';
  const usage = data.usage ?? {};
  const cost  = calcCost(usage);

  return {
    text,
    usage: {
      input_tokens:  usage.prompt_tokens      ?? 0,
      output_tokens: usage.completion_tokens  ?? 0,
      cache_hit:     usage.prompt_cache_hit_tokens ?? 0,
    },
    cost_usd: Math.round(cost * 1e8) / 1e8,
    model:    data.model ?? body.model,
  };
}

// ── 고수준 헬퍼: 요약 ─────────────────────────────────────────────────────────
/**
 * 텍스트 요약 — Jarvis 요약 태스크 표준 인터페이스.
 *
 * @param {string} text          - 요약할 원문
 * @param {object} [opts]
 * @param {number} [opts.maxSentences] - 최대 문장 수 (기본 3)
 * @param {string} [opts.lang]         - 응답 언어 힌트 (기본 '한국어')
 * @returns {Promise<{summary:string, cost_usd:number, usage:object}>}
 */
export async function summarize(text, opts = {}) {
  const maxSentences = opts.maxSentences ?? 3;
  const lang         = opts.lang ?? '한국어';

  const result = await deepseekChat(
    [
      {
        role: 'system',
        content: `당신은 텍스트 요약 전문가입니다. ${lang}로 ${maxSentences}문장 이내로 핵심만 요약하세요.`,
      },
      { role: 'user', content: text },
    ],
    { maxTokens: 512, temperature: 0.2, ...opts }
  );

  return { summary: result.text, cost_usd: result.cost_usd, usage: result.usage };
}

// ── 고수준 헬퍼: 분류 ─────────────────────────────────────────────────────────
/**
 * 텍스트 분류 — 에러 로그·메시지 카테고리 분류.
 *
 * @param {string}   text       - 분류할 텍스트
 * @param {string[]} labels     - 가능한 레이블 목록
 * @param {object}   [opts]
 * @returns {Promise<{label:string, cost_usd:number, usage:object}>}
 */
export async function classify(text, labels, opts = {}) {
  const labelList = labels.join(' | ');
  const result = await deepseekChat(
    [
      {
        role: 'system',
        content: `텍스트를 분류합니다. 반드시 다음 레이블 중 하나만 출력하세요: ${labelList}`,
      },
      { role: 'user', content: text },
    ],
    { maxTokens: 64, temperature: 0.1, ...opts }
  );

  // 응답에서 레이블 추출 (가장 많이 매칭되는 레이블)
  const raw   = result.text.trim();
  const found = labels.find((l) => raw.toLowerCase().includes(l.toLowerCase())) ?? raw.split('\n')[0].trim();

  return { label: found, cost_usd: result.cost_usd, usage: result.usage };
}

// ── 고수준 헬퍼: RAG 전처리 (청크 요약) ──────────────────────────────────────
/**
 * RAG 청크 전처리 — 긴 문서를 인덱싱에 적합한 요약으로 변환.
 * 1M 컨텍스트 활용: 대용량 문서도 단일 호출 처리 가능.
 *
 * @param {string} document  - 원본 문서 (최대 ~800K tokens ≈ 600K chars)
 * @param {object} [opts]
 * @param {string} [opts.domain]  - 도메인 힌트 (tech, finance, jarvis, career 등)
 * @returns {Promise<{chunks:string[], cost_usd:number, usage:object}>}
 */
export async function preprocessForRag(document, opts = {}) {
  const domain = opts.domain ?? '일반';
  const result = await deepseekChat(
    [
      {
        role: 'system',
        content: `당신은 RAG 전처리 전문가입니다. 도메인: ${domain}.
주어진 문서에서 벡터 검색에 유용한 핵심 사실·결정·패턴을 추출하세요.
각 항목을 빈 줄로 구분해 출력하세요. 최대 20개 항목.`,
      },
      { role: 'user', content: document },
    ],
    { maxTokens: 2048, temperature: 0.2, ...opts }
  );

  const chunks = result.text
    .split(/\n\s*\n/)
    .map((c) => c.trim())
    .filter((c) => c.length > 10);

  return { chunks, cost_usd: result.cost_usd, usage: result.usage };
}

// ── CLI 직접 실행 지원 ────────────────────────────────────────────────────────
// node deepseek-client.mjs summarize "텍스트..."
// node deepseek-client.mjs classify  "텍스트..." "SyntaxError,ENOENT,NetworkError"
// node deepseek-client.mjs rag       "문서..."
if (process.argv[1] && process.argv[1].endsWith('deepseek-client.mjs')) {
  const [,, command, text, extra] = process.argv;

  if (!command || !text) {
    console.error('사용법: node deepseek-client.mjs <summarize|classify|rag> "<text>" [labels]');
    process.exit(1);
  }

  (async () => {
    try {
      let result;
      if (command === 'summarize') {
        result = await summarize(text);
        console.log('=== 요약 결과 ===');
        console.log(result.summary);
      } else if (command === 'classify') {
        const labels = (extra ?? 'Yes,No').split(',');
        result = await classify(text, labels);
        console.log('=== 분류 결과 ===');
        console.log(result.label);
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
