#!/usr/bin/env node

/**
 * Gemini 3.5 Flash API Client
 *
 * 비핵심 태스크(뉴스 요약, 시스템 헬스체크 등)를 처리하기 위한 저가 모델 API 클라이언트
 * - API: Google Generative AI (Gemini 3.5 Flash)
 * - 비용: $1.50/$9.00 per 1M tokens (Claude Haiku 대비 93% 절감)
 * - 컨텍스트: 1M 토큰 (대용량 문서 처리 가능)
 *
 * 사용법:
 *   node gemini-3-5-flash-client.mjs "프롬프트"
 *   node gemini-3-5-flash-client.mjs test "테스트 프롬프트"
 *
 * 환경변수:
 *   GEMINI_API_KEY: Google Generative AI API 키 (필수)
 *   GEMINI_MODEL: 모델명 (기본값: gemini-3.5-flash)
 *   GEMINI_TIMEOUT: 타임아웃(ms) (기본값: 60000)
 *
 * 산출물: JSON with {text, usage, cost_usd, model}
 */

import https from 'https';
import { URL } from 'url';

const API_KEY = process.env.GEMINI_API_KEY;
const MODEL = process.env.GEMINI_MODEL || 'gemini-3.5-flash';
const TIMEOUT_MS = parseInt(process.env.GEMINI_TIMEOUT || '60000', 10);

// 비용 계산 (per 1M tokens)
const COST_PER_1M_INPUT = 1.50;  // USD
const COST_PER_1M_OUTPUT = 9.00; // USD

/**
 * Gemini API 호출 (재시도 로직 포함)
 */
async function callGeminiAPI(prompt, maxRetries = 2) {
  if (!API_KEY) {
    throw new Error('GEMINI_API_KEY 환경변수가 설정되지 않았습니다');
  }

  const url = new URL(`https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`);
  url.searchParams.append('key', API_KEY);

  const requestBody = {
    contents: [
      {
        parts: [
          {
            text: prompt
          }
        ]
      }
    ],
    generationConfig: {
      maxOutputTokens: 4096,
      temperature: 0.7
    }
  };

  let lastError;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      const result = await makeRequest(url, requestBody, attempt);
      return result;
    } catch (error) {
      lastError = error;
      const delay = Math.pow(2, attempt - 1) * 1000; // exponential backoff: 1s, 2s, 4s...

      if (attempt < maxRetries) {
        console.error(`[Attempt ${attempt}] Gemini API 호출 실패 (${delay}ms 후 재시도): ${error.message}`);
        await sleep(delay);
      }
    }
  }

  throw lastError || new Error('Gemini API 호출 실패');
}

/**
 * HTTP 요청 수행
 */
function makeRequest(url, body, attemptNumber) {
  return new Promise((resolve, reject) => {
    const options = {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      timeout: TIMEOUT_MS
    };

    const req = https.request(url, options, (res) => {
      let data = '';

      res.on('data', (chunk) => {
        data += chunk;
      });

      res.on('end', () => {
        try {
          if (res.statusCode !== 200) {
            const errorData = JSON.parse(data);
            reject(new Error(`HTTP ${res.statusCode}: ${errorData.error?.message || data}`));
            return;
          }

          const response = JSON.parse(data);

          // API 응답 파싱
          const text = response.candidates?.[0]?.content?.parts?.[0]?.text || '';
          const usageData = response.usageMetadata || {};

          const inputTokens = usageData.promptTokenCount || 0;
          const outputTokens = usageData.candidatesTokenCount || 0;

          // 비용 계산
          const costUsd = (inputTokens * COST_PER_1M_INPUT + outputTokens * COST_PER_1M_OUTPUT) / 1_000_000;

          resolve({
            text: text.trim(),
            usage: {
              input_tokens: inputTokens,
              output_tokens: outputTokens,
              total_tokens: inputTokens + outputTokens
            },
            cost_usd: parseFloat(costUsd.toFixed(6)),
            model: MODEL,
            timestamp: new Date().toISOString(),
            success: true
          });
        } catch (error) {
          reject(new Error(`응답 파싱 실패: ${error.message}`));
        }
      });
    });

    req.on('error', (error) => {
      reject(error);
    });

    req.on('timeout', () => {
      req.destroy();
      reject(new Error(`API 타임아웃 (${TIMEOUT_MS}ms)`));
    });

    req.write(JSON.stringify(body));
    req.end();
  });
}

/**
 * 대기 함수
 */
function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * 메인 함수
 */
async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    console.error('사용법: node gemini-3-5-flash-client.mjs "프롬프트"');
    console.error('         node gemini-3-5-flash-client.mjs test "테스트 프롬프트"');
    process.exit(1);
  }

  let prompt = args[0];
  const isTest = prompt === 'test';

  if (isTest) {
    if (args.length < 2) {
      console.error('테스트 모드: node gemini-3-5-flash-client.mjs test "프롬프트"');
      process.exit(1);
    }
    prompt = args[1];
  }

  try {
    const result = await callGeminiAPI(prompt);

    if (isTest) {
      // 테스트 모드: 상세 출력
      console.log('✓ Gemini API 호출 성공');
      console.log('\n응답:');
      console.log(result.text);
      console.log('\n메타데이터:');
      console.log(`- 모델: ${result.model}`);
      console.log(`- 입력 토큰: ${result.usage.input_tokens}`);
      console.log(`- 출력 토큰: ${result.usage.output_tokens}`);
      console.log(`- 총 토큰: ${result.usage.total_tokens}`);
      console.log(`- 비용: $${result.cost_usd}`);
      console.log(`- 타임스탬프: ${result.timestamp}`);
    } else {
      // 정상 모드: JSON 출력
      console.log(JSON.stringify(result, null, 2));
    }
  } catch (error) {
    console.error('오류:', error.message);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}

/**
 * llm-gateway.sh 호환 인터페이스
 * node --input-type=module -e 에서 함수를 직접 호출
 */
export async function gemini35Chat(messages, options = {}) {
  const { apiKey, maxTokens = 4096 } = options;

  if (!apiKey) {
    throw new Error('API key is required');
  }

  // messages 배열을 프롬프트로 변환
  const prompt = messages
    .filter(m => m.role === 'user')
    .map(m => m.parts?.[0]?.text || '')
    .join('\n');

  const result = await callGeminiAPI(prompt, 2);
  return result;
}

export { callGeminiAPI, COST_PER_1M_INPUT, COST_PER_1M_OUTPUT, MODEL };
