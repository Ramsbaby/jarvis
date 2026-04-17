/**
 * error-ledger.js — Silent error tracking (append-only JSONL)
 *
 * 빈 catch 블록에서 삼켜지던 에러를 원장에 기록.
 * 파일 크기 100KB 초과 시 자동 rotate (최근 500줄 유지).
 *
 * Usage:
 *   import { recordSilentError } from './error-ledger.js';
 *   try { ... } catch (err) { recordSilentError('streaming._sendOrEdit', err); }
 */

import { appendFileSync, readFileSync, writeFileSync, mkdirSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const LEDGER_PATH = join(BOT_HOME, 'state', 'error-ledger.jsonl');
const MAX_SIZE_BYTES = 100 * 1024; // 100KB
const KEEP_LINES = 500;

/**
 * Record a silently-caught error to the ledger.
 * @param {string} source — e.g. 'streaming._sendOrEdit', 'handlers.cleanup'
 * @param {Error|any} error
 */
export function recordSilentError(source, error) {
  try {
    mkdirSync(dirname(LEDGER_PATH), { recursive: true });
    const entry = {
      ts: new Date().toISOString(),
      src: source,
      msg: error?.message || String(error),
      stk: (error?.stack || '').split('\n')[1]?.trim() || '',
    };
    appendFileSync(LEDGER_PATH, JSON.stringify(entry) + '\n');

    // Auto-rotate if oversized
    try {
      const size = statSync(LEDGER_PATH).size;
      if (size > MAX_SIZE_BYTES) {
        const lines = readFileSync(LEDGER_PATH, 'utf-8').split('\n').filter(Boolean);
        writeFileSync(LEDGER_PATH, lines.slice(-KEEP_LINES).join('\n') + '\n');
      }
    } catch { /* rotate failure is non-fatal */ }
  } catch { /* ledger write failure must never crash the caller */ }
}