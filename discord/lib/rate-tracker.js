/**
 * RateTracker — sliding window rate limiter in 5-hour blocks.
 */

import { readFileSync, writeFileSync } from 'node:fs';

const RATE_WINDOW_HOURS = 5;
const RATE_MAX_REQUESTS = 900;

export class RateTracker {
  constructor(filePath) {
    this.filePath = filePath;
    this.requests = [];
    this.load();
  }

  load() {
    try {
      const raw = readFileSync(this.filePath, 'utf-8');
      const parsed = JSON.parse(raw);
      this.requests = Array.isArray(parsed)
        ? parsed
        : (Array.isArray(parsed.requests) ? parsed.requests : []);
    } catch {
      this.requests = [];
    }
  }

  save() {
    writeFileSync(this.filePath, JSON.stringify(this.requests));
  }

  prune() {
    const cutoff = Date.now() - RATE_WINDOW_HOURS * 3600 * 1000;
    this.requests = this.requests.filter((t) => t > cutoff);
  }

  record() {
    this.prune();
    this.requests.push(Date.now());
    this.save();
  }

  /** Returns { count, pct, max, warn, reject } */
  check() {
    this.prune();
    const count = this.requests.length;
    const pct = count / RATE_MAX_REQUESTS;
    return {
      count,
      pct,
      max: RATE_MAX_REQUESTS,
      warn: pct >= 0.8 && pct < 0.9,
      reject: pct >= 0.9,
    };
  }
}
