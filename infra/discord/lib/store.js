/**
 * SessionStore — thread-to-session mapping with TTL expiry and debounced persist.
 */

import { readFileSync, writeFileSync, renameSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { log } from './claude-runner.js';

const SESSION_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7일
const PERSIST_DEBOUNCE_MS = 150;

// 부팅 시 자동 청소 임계 (좀비 세션 차단)
// 사고 사례 (2026-05-08): 522d6b74 세션이 14일간 매번 재사용되며 tokenCount 13,329 누적,
//   호출 1회당 $1,685 발생. updatedAt 갱신되어 7일 게이트로는 못 잡음 → tokenCount 게이트 필수.
const SESSIONS_MAX_AGE_DAYS = Number(process.env.SESSIONS_MAX_AGE_DAYS || 7);
const SESSIONS_MAX_TOKEN_COUNT = Number(process.env.SESSIONS_MAX_TOKEN_COUNT || 5000);

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

    // 부팅 시 좀비 세션 자동 청소 (2026-05-08 신설)
    // (1) tokenCount 임계 초과 → 컨텍스트 비대 회전 강제
    // (2) age 임계 초과 → stale 매핑 청소
    const now = Date.now();
    const ageThresholdMs = SESSIONS_MAX_AGE_DAYS * 24 * 60 * 60 * 1000;
    const pruned = [];
    for (const [k, v] of Object.entries(this.data)) {
      const tokenCount = v.tokenCount ?? 0;
      const ageMs = now - (v.updatedAt ?? 0);
      if (tokenCount > SESSIONS_MAX_TOKEN_COUNT) {
        pruned.push({ key: k, id: v.id, reason: 'tokenCount', value: tokenCount });
        delete this.data[k];
      } else if (ageMs > ageThresholdMs) {
        pruned.push({ key: k, id: v.id, reason: 'age', value: `${(ageMs / 86400000).toFixed(1)}d` });
        delete this.data[k];
      }
    }
    if (pruned.length > 0) {
      log('info', `SessionStore: ${pruned.length}개 좀비 매핑 청소 (boot prune)`, {
        threshold_token: SESSIONS_MAX_TOKEN_COUNT,
        threshold_age_days: SESSIONS_MAX_AGE_DAYS,
        pruned,
      });
      this._flushSync();  // 즉시 디스크 반영 — 다음 _flushSync(exit)로 부활 방지
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
