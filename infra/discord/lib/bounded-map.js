/**
 * bounded-map.js — Size + TTL bounded Map wrapper
 *
 * Drop-in replacement for Map with:
 *   - maxSize: FIFO eviction when exceeded
 *   - ttlMs:  Lazy expiry on get() (optional, 0 = no TTL)
 *
 * Usage:
 *   import { BoundedMap } from './bounded-map.js';
 *   const cache = new BoundedMap(1000, 30 * 60_000); // 1000 items, 30min TTL
 *   cache.set('key', value);
 *   cache.get('key'); // null if expired
 */

export class BoundedMap {
  /** @param {number} maxSize  @param {number} [ttlMs=0] 0 = no TTL */
  constructor(maxSize = 1000, ttlMs = 0) {
    this._map = new Map();    // key → { value, ts }
    this._maxSize = maxSize;
    this._ttlMs = ttlMs;
  }

  get size() { return this._map.size; }

  has(key) {
    if (!this._map.has(key)) return false;
    if (this._isExpired(key)) { this._map.delete(key); return false; }
    return true;
  }

  get(key) {
    const entry = this._map.get(key);
    if (!entry) return undefined;
    if (this._isExpired(key)) { this._map.delete(key); return undefined; }
    return entry.value;
  }

  set(key, value) {
    // Update existing — no eviction needed
    if (this._map.has(key)) {
      this._map.delete(key); // re-insert for iteration order
    } else if (this._map.size >= this._maxSize) {
      // FIFO evict oldest
      const oldest = this._map.keys().next().value;
      this._map.delete(oldest);
    }
    this._map.set(key, { value, ts: Date.now() });
    return this;
  }

  delete(key) { return this._map.delete(key); }

  clear() { this._map.clear(); }

  keys() { return this._map.keys(); }

  values() {
    return Array.from(this._map.values())
      .filter((_, i) => !this._isExpiredByIndex(i))
      .map(e => e.value);
  }

  entries() {
    const result = [];
    for (const [k, entry] of this._map) {
      if (!this._isExpired(k)) result.push([k, entry.value]);
    }
    return result;
  }

  forEach(fn) {
    for (const [k, entry] of this._map) {
      if (!this._isExpired(k)) fn(entry.value, k, this);
    }
  }

  /** Iterate like Map (for...of support) */
  [Symbol.iterator]() {
    return this.entries()[Symbol.iterator]();
  }

  // --- internal ---

  _isExpired(key) {
    if (!this._ttlMs) return false;
    const entry = this._map.get(key);
    return entry && (Date.now() - entry.ts > this._ttlMs);
  }

  _isExpiredByIndex(idx) {
    if (!this._ttlMs) return false;
    const entries = Array.from(this._map.values());
    const entry = entries[idx];
    return entry && (Date.now() - entry.ts > this._ttlMs);
  }
}
