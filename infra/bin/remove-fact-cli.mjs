#!/usr/bin/env node
/**
 * remove-fact-cli.mjs — userMemory.removeFact 안전 호출 래퍼.
 *
 * 봇 프롬프트에 `node -e "..."` 를 주는 방식은 shell injection 서피스가 있음
 * (LLM 이 fact 문자열에 따옴표·백틱 등을 그대로 주입하면 인자 경계 탈출 가능).
 * 이 래퍼는 쉘 인용과 무관한 argv 로 값을 받아 안전.
 *
 * 사용:
 *   node remove-fact-cli.mjs <userId> <query>
 *   → stdout: {"removed":N,"facts":A,"corrections":B}
 */

import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));

async function main() {
  const [userId, ...rest] = process.argv.slice(2);
  const query = rest.join(' ');
  if (!userId || !query) {
    process.stderr.write('Usage: remove-fact-cli.mjs <userId> <query>\n');
    process.exit(2);
  }

  const mod = await import(join(__dirname, '..', 'lib', 'user-memory.mjs'));
  const result = mod.userMemory.removeFact(userId, query);
  process.stdout.write(JSON.stringify(result) + '\n');
}

main().catch((err) => {
  process.stderr.write(`remove-fact-cli error: ${err.message}\n`);
  process.exit(1);
});
