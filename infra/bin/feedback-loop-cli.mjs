#!/usr/bin/env node
/**
 * feedback-loop-cli.mjs — CLI 훅(sensor-prompt.sh)용 shell-friendly 래퍼.
 *
 * 두 가지 모드:
 *   1. process (기본): stdin JSON {text, userId?, source?} → shared processFeedback 호출 + stdout에 결과 JSON
 *   2. --dump-corrections: userMemory.corrections 문자열을 stdout에 출력 (SessionStart 컨텍스트 주입용)
 *
 * userId 생략 시 getOwnerUserId() 사용 → CLI/macOS 앱은 기본적으로 오너 계정에 기록.
 *
 * 호출 예:
 *   echo '{"text":"앞으로는 KST로만 답해줘","source":"claude-code-cli"}' | \
 *     node infra/bin/feedback-loop-cli.mjs
 *   node infra/bin/feedback-loop-cli.mjs --dump-corrections
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SHARED = join(__dirname, '..', 'lib', 'feedback-loop.mjs');

async function main() {
  const mod = await import(SHARED);

  const mode = process.argv[2];
  if (mode === '--dump-corrections') {
    const userId = process.argv[3] || mod.getOwnerUserId();
    const text = mod.loadCorrectionsForContext(userId);
    if (text) process.stdout.write(text);
    process.exit(0);
  }

  // 기본: stdin JSON 읽기
  let raw = '';
  try {
    raw = readFileSync(0, 'utf-8');
  } catch {
    process.stderr.write('feedback-loop-cli: stdin empty\n');
    process.exit(2);
  }

  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (e) {
    process.stderr.write(`feedback-loop-cli: invalid JSON — ${e.message}\n`);
    process.exit(2);
  }

  const text = typeof payload.text === 'string' ? payload.text : '';
  const userId = payload.userId || mod.getOwnerUserId();
  const source = payload.source || 'claude-code-cli';

  if (!text) {
    process.stdout.write(JSON.stringify({ ok: true, skipped: 'empty text' }) + '\n');
    return;
  }
  if (!userId) {
    process.stdout.write(JSON.stringify({ ok: true, skipped: 'no userId (owner unconfigured)' }) + '\n');
    return;
  }

  const result = mod.processFeedback({
    userId,
    text,
    source,
    // CLI에서는 Discord용 RAG sync 콜백 없음 — userMemory write만 수행
  });

  process.stdout.write(JSON.stringify({
    ok: true,
    userId,
    source,
    fb: result.fb,
    factChanged: result.factChanged,
    correctionChanged: result.correctionChanged,
  }) + '\n');
}

main().catch((err) => {
  process.stderr.write(`feedback-loop-cli: ${err.message}\n`);
  process.exit(1);
});
