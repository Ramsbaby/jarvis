/**
 * SessionStore — thread-to-session mapping with TTL expiry and debounced persist.
 */

import { readFileSync, writeFileSync, renameSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
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
    if (!existsSync(this.filePath)) { this.data = {}; return; }
    let raw;
    try {
      raw = readFileSync(this.filePath, 'utf-8');
    } catch (readErr) {
      log('warn', 'SessionStore: could not read sessions file', { error: readErr.message });
      this.data = {};
      return;
    }
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (parseErr) {
      const corruptPath = `${this.filePath}.corrupt.${Date.now()}`;
      log('warn', 'SessionStore: corrupt JSON — renaming and starting fresh', {
        corrupt: corruptPath,
        error: parseErr.message,
      });
      try { renameSync(this.filePath, corruptPath); } catch { /* best effort */ }
      this.data = {};
      return;
    }
    // Migrate old format (string) → new format ({ id, updatedAt })
    for (const [k, v] of Object.entries(parsed)) {
      if (typeof v === 'string') {
        this.data[k] = { id: v, updatedAt: Date.now() };
      } else if (v && typeof v === 'object') {
        this.data[k] = v;
      }
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

  /** Immediate synchronous write to disk (atomic: tmp + rename). */
  _flushSync() {
    if (this._flushTimer) {
      clearTimeout(this._flushTimer);
      this._flushTimer = null;
    }
    const tmp = join(dirname(this.filePath), `.sessions-${process.pid}.tmp`);
    try {
      writeFileSync(tmp, JSON.stringify(this.data, null, 2));
      renameSync(tmp, this.filePath);
    } catch (err) {
      log('error', 'SessionStore flush failed', { error: err.message });
      try { writeFileSync(this.filePath, JSON.stringify(this.data, null, 2)); } catch { /* last resort */ }
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

  set(threadId, sessionId, tokenCount = null) {
    const existing = this.data[threadId]?.tokenCount ?? 0;
    this.data[threadId] = { id: sessionId, updatedAt: Date.now(), tokenCount: tokenCount !== null ? tokenCount : existing };
    this.save();
  }

  getTokenCount(threadId) {
    return this.data[threadId]?.tokenCount ?? 0;
  }

  addTokens(threadId, delta) {
    if (!this.data[threadId]) return;
    this.data[threadId].tokenCount = (this.data[threadId].tokenCount ?? 0) + delta;
    this.save();
  }

  delete(threadId) {
    delete this.data[threadId];
    this.save();
  }
}
