/**
 * Pending message queue — holds one message per session key when the
 * semaphore is busy, and drains it after the current request completes.
 *
 * Exports:
 *   pendingQueue      — Map of queued messages (shared mutable state)
 *   enqueue(sessionKey, message, userPrompt) — add a message to the queue
 *   processQueue(sessionKey, handleMessage, deps) — drain queue after semaphore release
 */

import { log } from './claude-runner.js';

const QUEUE_EXPIRY_MS = 120_000; // 2 minutes

/** @type {Map<string, { message: import('discord.js').Message, userPrompt: string, timestamp: number }>} */
export const pendingQueue = new Map();

/**
 * Enqueue a message for later processing (when semaphore is busy).
 * Only one message is kept per sessionKey — newer messages overwrite older ones.
 */
export function enqueue(sessionKey, message, userPrompt) {
  pendingQueue.set(sessionKey, { message, userPrompt, timestamp: Date.now() });
  log('info', 'Message queued (semaphore busy)', { sessionKey, content: userPrompt.slice(0, 50) });
}

/**
 * Process queued messages after semaphore release.
 * First checks current sessionKey, then scans all remaining entries.
 *
 * @param {string|null} sessionKey - The session key of the just-completed request
 * @param {Function} handleMessage - The handleMessage function for recursive invocation
 * @param {{ sessions, rateTracker, semaphore, activeProcesses, client }} deps - Handler dependencies
 */
export async function processQueue(sessionKey, handleMessage, deps) {
  let processed = false;

  // 1st pass: match current sessionKey (priority)
  if (sessionKey) {
    const queued = pendingQueue.get(sessionKey);
    if (queued && Date.now() - queued.timestamp < QUEUE_EXPIRY_MS) {
      pendingQueue.delete(sessionKey);
      processed = true;
      log('info', 'Processing queued message', { sessionKey, content: queued.userPrompt.slice(0, 50) });
      setImmediate(() => {
        handleMessage(queued.message, deps)
          .catch(err => log('error', 'Queued message processing failed', { error: err.message }));
      });
    } else if (queued) {
      pendingQueue.delete(sessionKey);
      log('info', 'Queued message expired, discarding', { sessionKey });
      try { await queued.message.reply('\u23f3 대기 시간이 초과되었습니다. 다시 말씀해 주세요.'); } catch { /* ignore */ }
    }
  }

  // 2nd pass: scan remaining entries — pick oldest non-expired
  if (!processed && pendingQueue.size > 0) {
    const now = Date.now();
    for (const [key, queued] of pendingQueue) {
      if (now - queued.timestamp >= QUEUE_EXPIRY_MS) {
        pendingQueue.delete(key);
        log('info', 'Queued message expired, discarding', { sessionKey: key });
        try { queued.message.reply('\u23f3 대기 시간이 초과되었습니다. 다시 말씀해 주세요.').catch(() => {}); } catch { /* ignore */ }
        continue;
      }
      pendingQueue.delete(key);
      log('info', 'Processing queued message (cross-key)', { sessionKey: key, content: queued.userPrompt.slice(0, 50) });
      setImmediate(() => {
        handleMessage(queued.message, deps)
          .catch(err => log('error', 'Queued message processing failed', { error: err.message }));
      });
      break; // process only one (one semaphore slot freed)
    }
  }
}
