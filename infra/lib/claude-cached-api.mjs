#!/usr/bin/env node
/**
 * claude-cached-api.mjs
 * Anthropic Messages API 직접 호출 래퍼 — cache_control 브레이크포인트 적용
 *
 * 용도: llm-gateway.sh의 _llm_claude_cli() 대체 경로
 *       ANTHROPIC_API_KEY가 설정된 환경에서 STABLE/SEMI/DYNAMIC 섹션을 분리 전송하여
 *       프롬프트 캐시 히트율을 최대화한다.
 *
 * 사용:
 *   node claude-cached-api.mjs \
 *     --prompt "분석 요청 내용" \
 *     --stable "불변 시스템 프롬프트 (_capabilities.md)" \
 *     --semi   "준안정 섹션 (insight-report + task-context)" \
 *     --dynamic "동적 섹션 (RAG, context-bus, history)" \
 *     --model claude-haiku-4-5-20251001 \
 *     --max-tokens 4096
 *
 * 출력: claude -p --output-format json 호환 JSON (stdout)
 *   { "result": "...", "cost_usd": 0.0012, "usage": { "input_tokens": 900,
 *     "output_tokens": 400, "cache_creation_input_tokens": 340,
 *     "cache_read_input_tokens": 560 } }
 *
 * 캐시 브레이크포인트 전략:
 *   ┌─ STABLE ─────────────────────── cache_control: ephemeral ┐
 *   │  _capabilities.md (~340 tok)                              │
 *   └───────────────────────────────────────────────────────────┘
 *   ┌─ SEMI ───────────────────────── cache_control: ephemeral ┐
 *   │  insight-report.md + {task-id}.md (~600-1500 tok)        │
 *   └───────────────────────────────────────────────────────────┘
 *   ┌─ DYNAMIC ─────────────────────── (no cache) ─────────────┐
 *   │  RAG + context-bus + agent-note + history (~500-3000 tok) │
 *   └───────────────────────────────────────────────────────────┘
 *
 * 가격 참고 (Claude Haiku 4.5 기준, 2026-07):
 *   - 캐시 미스: $0.25/MTok input
 *   - 캐시 쓰기: $0.30/MTok (미스보다 20% 비쌈 — 첫 호출 시만)
 *   - 캐시 읽기: $0.025/MTok (90% 할인!)
 *   - 출력:      $1.25/MTok
 */

import { readFileSync } from 'fs';
import Anthropic from '@anthropic-ai/sdk';

// --- CLI 파서 ---
function parseArgs(argv) {
  const args = { prompt: '', stable: '', semi: '', dynamic: '', model: '', maxTokens: 4096, timeout: 180 };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--prompt':      args.prompt     = argv[++i] ?? ''; break;
      case '--stable':      args.stable     = argv[++i] ?? ''; break;
      case '--semi':        args.semi       = argv[++i] ?? ''; break;
      case '--dynamic':     args.dynamic    = argv[++i] ?? ''; break;
      case '--model':       args.model      = argv[++i] ?? ''; break;
      case '--max-tokens':  args.maxTokens  = parseInt(argv[++i], 10) || 4096; break;
      case '--timeout':     args.timeout    = parseInt(argv[++i], 10) || 180; break;
      // 파일에서 로드하는 단축키
      case '--stable-file':   args.stable   = readFileSync(argv[++i], 'utf8'); break;
      case '--semi-file':     args.semi     = readFileSync(argv[++i], 'utf8'); break;
      case '--dynamic-file':  args.dynamic  = readFileSync(argv[++i], 'utf8'); break;
    }
  }
  return args;
}

// --- 모델 선택 기본값 ---
const DEFAULT_MODEL = 'claude-haiku-4-5-20251001';

// --- 가격표 (per 1M tokens, USD) ---
// 2026-07-25 요율 전면 교정: 기존 표는 Claude 3 시대 요율(Haiku 3 $0.25/$1.25, Opus 3 $15/$75)이
//   모델 ID만 4.5/4.8로 바뀐 채 남아 비용이 최대 3배 과대 계상되고 있었음. 공식 요율로 재작성.
//   규칙: cache_write = input × 1.25, cache_read = input × 0.1
const PRICING = {
  'claude-haiku-4-5-20251001': { input: 1.00, cache_write: 1.25, cache_read: 0.10, output: 5.00 },
  'claude-sonnet-4-6':         { input: 3.00, cache_write: 3.75, cache_read: 0.30, output: 15.0 },  // ALLOW-DEPRECATED-MODEL
  // ⚠️ sonnet-5 의 $2/$10 은 인트로 가격으로 2026-08-31 까지만 유효하다. 이후 $3/$15 로 복귀 —
  //    그때 이 줄을 되돌려야 한다. 가격 정본은 infra/config/models.json.
  'claude-sonnet-5':           { input: 2.00, cache_write: 2.50, cache_read: 0.20, output: 10.0 },
  'claude-opus-5':             { input: 5.00, cache_write: 6.25, cache_read: 0.50, output: 25.0 },
  'claude-opus-4-8':           { input: 5.00, cache_write: 6.25, cache_read: 0.50, output: 25.0 },  // ALLOW-DEPRECATED-MODEL
  'claude-opus-4-7':           { input: 5.00, cache_write: 6.25, cache_read: 0.50, output: 25.0 },  // ALLOW-DEPRECATED-MODEL
  'default':                   { input: 3.00, cache_write: 3.75, cache_read: 0.30, output: 15.0 },
};

function calcCost(model, usage) {
  const p = PRICING[model] ?? PRICING['default'];
  const perM = 1_000_000;
  return (
    ((usage.input_tokens ?? 0) * p.input / perM) +
    ((usage.cache_creation_input_tokens ?? 0) * p.cache_write / perM) +
    ((usage.cache_read_input_tokens ?? 0) * p.cache_read / perM) +
    ((usage.output_tokens ?? 0) * p.output / perM)
  );
}

// --- 메인 ---
async function main() {
  const args = parseArgs(process.argv.slice(2));

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    const err = { result: '', cost_usd: 0, usage: { input_tokens: 0, output_tokens: 0 }, is_error: true, subtype: 'no_api_key' };
    console.log(JSON.stringify(err));
    process.exit(1);
  }

  if (!args.prompt) {
    const err = { result: '', cost_usd: 0, usage: { input_tokens: 0, output_tokens: 0 }, is_error: true, subtype: 'missing_prompt' };
    console.log(JSON.stringify(err));
    process.exit(1);
  }

  const model = args.model || DEFAULT_MODEL;
  const client = new Anthropic({ apiKey, timeout: args.timeout * 1000 });

  // --- system[] 배열 구성 (섹션별 cache_control 삽입) ---
  //
  // 캐시 히트 조건: 이전 호출과 동일 내용의 블록 (hash 기반 비교)
  //   STABLE 블록: _capabilities.md — 모든 태스크·모든 호출에서 동일 → 최고 히트율
  //   SEMI 블록:   insight-report + task-context — 같은 태스크 당일 재실행 시 히트
  //   DYNAMIC 블록: cache_control 없음 → 캐시 안 함 (매 호출 변경되므로)
  //
  // 주의: Anthropic 캐시 TTL = ephemeral 기준 5분 (beta: 1시간)
  //   고빈도 태스크(*/15): TTL 내 히트 → 절감 효과 최대
  //   저빈도 태스크(daily): TTL 초과 → STABLE 캐시는 hit (불변), SEMI는 miss

  const systemBlocks = [];

  if (args.stable) {
    systemBlocks.push({
      type: 'text',
      text: args.stable,
      cache_control: { type: 'ephemeral' },  // 브레이크포인트 #1
    });
  }

  if (args.semi) {
    systemBlocks.push({
      type: 'text',
      text: args.semi,
      cache_control: { type: 'ephemeral' },  // 브레이크포인트 #2
    });
  }

  if (args.dynamic) {
    systemBlocks.push({
      type: 'text',
      text: args.dynamic,
      // cache_control 없음 — DYNAMIC은 매 호출 변경
    });
  }

  // 섹션이 하나도 없으면 단일 텍스트 시스템 프롬프트로 폴백
  const requestParams = {
    model,
    max_tokens: args.maxTokens,
    messages: [{ role: 'user', content: args.prompt }],
  };

  if (systemBlocks.length > 0) {
    requestParams.system = systemBlocks;
  }

  let message;
  try {
    message = await client.messages.create(requestParams);
  } catch (err) {
    const out = {
      result: err.message ?? 'API call failed',
      cost_usd: 0,
      usage: { input_tokens: 0, output_tokens: 0 },
      is_error: true,
      subtype: `api_error_${err.status ?? 'unknown'}`,
    };
    console.log(JSON.stringify(out));
    process.exit(1);
  }

  const resultText = message.content
    .filter(b => b.type === 'text')
    .map(b => b.text)
    .join('');

  const usage = message.usage ?? {};
  const cost = calcCost(model, usage);

  // claude -p --output-format json 호환 출력
  const out = {
    result: resultText,
    cost_usd: Math.round(cost * 1e8) / 1e8,
    usage: {
      input_tokens:                  usage.input_tokens                  ?? 0,
      output_tokens:                 usage.output_tokens                 ?? 0,
      cache_creation_input_tokens:   usage.cache_creation_input_tokens   ?? 0,
      cache_read_input_tokens:       usage.cache_read_input_tokens        ?? 0,
    },
    model,
    stop_reason: message.stop_reason,
    is_error: false,
    subtype: 'anthropic_cached_api',
  };

  console.log(JSON.stringify(out));
}

main().catch(err => {
  const out = {
    result: String(err),
    cost_usd: 0,
    usage: { input_tokens: 0, output_tokens: 0 },
    is_error: true,
    subtype: 'unhandled_error',
  };
  console.log(JSON.stringify(out));
  process.exit(1);
});
