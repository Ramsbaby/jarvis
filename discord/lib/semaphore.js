/**
 * Semaphore — concurrency control with cross-process global counter.
 */

import { readFileSync, writeFileSync, mkdirSync, rmdirSync, unlinkSync, renameSync, statSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const MAX_GLOBAL_CONCURRENT = 4;
const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const GLOBAL_COUNT_FILE = join(BOT_HOME, 'state', 'claude-global.count');
const GLOBAL_LOCK_FILE = join(BOT_HOME, 'state', 'claude-global.lock');

/** Read the global count file atomically. Returns 0 if missing/unreadable. */
function _readGlobalCount() {
  try {
    const raw = readFileSync(GLOBAL_COUNT_FILE, 'utf-8').trim();
    const n = parseInt(raw, 10);
    return Number.isFinite(n) && n >= 0 ? n : 0;
  } catch {
    return 0;
  }
}

/** Write global count atomically using tmp + rename. */
function _writeGlobalCount(n) {
  const tmp = GLOBAL_COUNT_FILE + '.tmp.' + process.pid;
  try {
    writeFileSync(tmp, String(Math.max(0, n)));
    renameSync(tmp, GLOBAL_COUNT_FILE);
  } catch {
    try { unlinkSync(tmp); } catch { /* ignore */ }
  }
}

/**
 * Acquire exclusive lock via mkdir (atomic on all POSIX, compatible with bash side).
 * Stale locks older than 30s are cleaned automatically.
 */
function _acquireFileLock(maxWaitMs = 3000) {
  const start = Date.now();
  while (Date.now() - start < maxWaitMs) {
    try {
      mkdirSync(GLOBAL_LOCK_FILE);
      return true;
    } catch (err) {
      if (err.code === 'EEXIST') {
        // Check for stale lock (> 30s old)
        try {
          const st = statSync(GLOBAL_LOCK_FILE);
          if (Date.now() - st.mtimeMs > 30000) {
            try { rmdirSync(GLOBAL_LOCK_FILE); } catch { /* race ok */ }
          }
        } catch { /* stat failed, lock may have been released */ }
        // Busy-wait briefly
        const wait = 5 + Math.floor(Math.random() * 10);
        const deadline = Date.now() + wait;
        while (Date.now() < deadline) { /* spin */ }
        continue;
      }
      return false;
    }
  }
  return false;
}

function _releaseFileLock() {
  try { rmdirSync(GLOBAL_LOCK_FILE); } catch { /* ignore */ }
}

export class Semaphore {
  constructor(max) {
    this.max = max;
    this.current = 0;
    this._waitQueue = [];

    // Ensure state directory exists
    try {
      mkdirSync(join(BOT_HOME, 'state'), { recursive: true });
    } catch { /* already exists */ }

    // Reconcile counter file with actual lock slots on startup
    // Prevents stale counts from accumulating across restarts
    this._reconcileCounter();
  }

  /** Reset counter file to match actual lock slot directories (ground truth). */
  _reconcileCounter() {
    if (_acquireFileLock()) {
      try {
        let actualSlots = 0;
        const lockDir = '/tmp/claude-discord-locks';
        try {
          const entries = readdirSync(lockDir);
          actualSlots = entries.filter(e => e.startsWith('slot-')).length;
        } catch { /* dir missing = 0 slots */ }
        const fileCount = _readGlobalCount();
        if (fileCount !== actualSlots) {
          _writeGlobalCount(actualSlots);
        }
      } finally {
        _releaseFileLock();
      }
    }
  }

  acquire() {
    // Check local limit
    if (this.current >= this.max) return false;

    // Check global cross-process limit
    if (_acquireFileLock()) {
      try {
        const globalCount = _readGlobalCount();
        if (globalCount >= MAX_GLOBAL_CONCURRENT) {
          return false;
        }
        _writeGlobalCount(globalCount + 1);
        this.current++;
        return true;
      } finally {
        _releaseFileLock();
      }
    }

    // Could not acquire file lock — deny rather than bypass global ceiling
    return false;
  }

  release() {
    if (this.current <= 0) return;
    this.current = Math.max(0, this.current - 1);

    // Decrement global counter — retry up to 3 times to prevent counter leak
    let released = false;
    for (let i = 0; i < 3 && !released; i++) {
      if (_acquireFileLock()) {
        try {
          const globalCount = _readGlobalCount();
          _writeGlobalCount(Math.max(0, globalCount - 1));
          released = true;
        } finally {
          _releaseFileLock();
        }
      }
    }
  }
}
