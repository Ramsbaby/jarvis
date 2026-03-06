/**
 * SessionStore — thread-to-session mapping with TTL expiry and debounced persist.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { log } from './claude-runner.js';

const SESSION_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7일
const PERSIST_DEBOUNCE_MS = 150;

export class SessionStore {
  constructor(filePath) {
    this.filePath = filePath;
    this.data = {};
    this._flushTimer = null;
    this.load();

    // Synchronous flush on exit to avoid data loss
    process.on('exit', () => this._flushSync());
  }

  load() {
    try {
      const raw = readFileSync(this.filePath, 'utf-8');
      const parsed = JSON.parse(raw);
      // Migrate old format (string) → new format ({ id, updatedAt })
      for (const [k, v] of Object.entries(parsed)) {
        if (typeof v === 'string') {
          this.data[k] = { id: v, updatedAt: Date.now() };
        } else if (v && typeof v === 'object') {
          this.data[k] = v;
        }
      }
    } catch {
      this.data = {};
    }
  }

  /** Schedule a debounced persist (150ms). Resets on each call. */
  save() {
    if (this._flushTimer) clearTimeout(this._flushTimer);
    this._flushTimer = setTimeout(() => {
      this._flushTimer = null;
      this._flushSync();
    }, PERSIST_DEBOUNCE_MS);
  }

  /** Immediate synchronous write to disk. */
  _flushSync() {
    if (this._flushTimer) {
      clearTimeout(this._flushTimer);
      this._flushTimer = null;
    }
    try {
      writeFileSync(this.filePath, JSON.stringify(this.data, null, 2));
    } catch (err) {
      log('error', 'SessionStore flush failed', { error: err.message });
    }
  }

  get(threadId) {
    const entry = this.data[threadId];
    if (!entry) return null;
    // Expire stale sessions
    if (Date.now() - entry.updatedAt > SESSION_TTL_MS) {
      delete this.data[threadId];
      this.save();
      return null;
    }
    return entry.id;
  }

  set(threadId, sessionId) {
    this.data[threadId] = { id: sessionId, updatedAt: Date.now() };
    this.save();
  }

  delete(threadId) {
    delete this.data[threadId];
    this.save();
  }
}
