/**
 * Semaphore — concurrency control with cross-process global counter.
 */

import { readFileSync, writeFileSync, mkdirSync, rmdirSync, unlinkSync, renameSync, statSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { execSync } from 'node:child_process';

const MAX_GLOBAL_CONCURRENT = 4;
const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const GLOBAL_COUNT_FILE = join(BOT_HOME, 'state', 'claude-global.count');
const GLOBAL_LOCK_FILE = join(BOT_HOME, 'state', 'claude-global.lock');
const SLOT_LOCK_DIR = '/tmp/claude-discord-locks';

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
async function _acquireFileLock(maxWaitMs = 3000) {
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
        // Async sleep instead of spin-wait
        const wait = 5 + Math.floor(Math.random() * 10);
        await new Promise(resolve => setTimeout(resolve, wait));
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
    /** @type {number[]} slot numbers held by this instance */
    this._heldSlots = [];

    try {
      mkdirSync(join(BOT_HOME, 'state'), { recursive: true });
    } catch { /* already exists */ }
    try {
      mkdirSync(SLOT_LOCK_DIR, { recursive: true });
    } catch { /* already exists */ }

    this._reconcileCounter();

    // 주기적 자가 복구: 에이전트 크래시로 슬롯 미해제 시 대비 (5분마다)
    this._reconcileInterval = setInterval(() => {
      this._reconcileCounter().catch(() => {});
    }, 5 * 60 * 1000);
    process.once('exit', () => clearInterval(this._reconcileInterval));
  }

  /** Reset counter file to match actual LIVE lock slot directories (ground truth).
   *  Cleans up stale slots whose PID is no longer running. */
  async _reconcileCounter() {
    if (await _acquireFileLock()) {
      try {
        let liveSlots = 0;
        try {
          const entries = readdirSync(SLOT_LOCK_DIR).filter(e => e.startsWith('slot-'));
          for (const entry of entries) {
            const slotDir = join(SLOT_LOCK_DIR, entry);
            let alive = false;
            try {
              const raw = readFileSync(join(slotDir, 'pid'), 'utf-8').trim();
              const colonIdx = raw.indexOf(':');
              const pid = colonIdx > -1 ? raw.slice(0, colonIdx) : raw;
              const savedStart = colonIdx > -1 ? raw.slice(colonIdx + 1) : '';
              if (pid && /^\d+$/.test(pid)) {
                // 1) PID가 살아있는지 확인 (죽었으면 alive=false 유지)
                let pidAlive = false;
                try { execSync(`kill -0 ${pid} 2>/dev/null`); pidAlive = true; } catch { /* dead */ }
                if (pidAlive) {
                  // 2) 살아있어도 시작 시각이 다르면 PID 재사용 → stale
                  if (savedStart) {
                    let currentStart = '';
                    try { currentStart = execSync(`ps -o lstart= -p ${pid} 2>/dev/null`).toString().trim(); } catch { /* ignore */ }
                    alive = currentStart === savedStart;
                  } else {
                    // 구형 pid 파일 (시작 시각 없음) — PID만으로 판단
                    alive = true;
                  }
                }
              }
            } catch { /* no pid file = stale */ }
            if (alive) {
              liveSlots++;
            } else {
              // Clean up stale slot
              try { unlinkSync(join(slotDir, 'pid')); } catch { /* ignore */ }
              try { rmdirSync(slotDir); } catch { /* ignore */ }
            }
          }
        } catch { /* dir missing = 0 slots */ }
        _writeGlobalCount(liveSlots);
      } finally {
        _releaseFileLock();
      }
    }
  }

  /**
   * Try to claim a slot directory (compatible with bash semaphore.sh).
   * Scans slot-1..slot-{MAX_GLOBAL_CONCURRENT} and mkdir the first free one.
   * @returns {number} slot number (1-based) or 0 if none available
   */
  _acquireSlotDir() {
    try {
      mkdirSync(SLOT_LOCK_DIR, { recursive: true });
    } catch { /* already exists */ }
    for (let i = 1; i <= MAX_GLOBAL_CONCURRENT; i++) {
      const slotDir = join(SLOT_LOCK_DIR, `slot-${i}`);
      try {
        mkdirSync(slotDir);
        // Write PID file for stale-lock detection (matches bash convention)
        try {
          // PID:시작시각 형식 저장 — PID 재사용 오탐 방지
          let startTime = '';
          try { startTime = execSync(`ps -o lstart= -p ${process.pid} 2>/dev/null`).toString().trim(); } catch { /* ignore */ }
          writeFileSync(join(slotDir, 'pid'), `${process.pid}:${startTime}`);
        } catch { /* non-fatal */ }
        return i;
      } catch (err) {
        if (err.code === 'EEXIST') continue;
        // Other error — skip this slot
        continue;
      }
    }
    return 0;
  }

  /**
   * Release a slot directory.
   * @param {number} slotNum 1-based slot number
   */
  _releaseSlotDir(slotNum) {
    const slotDir = join(SLOT_LOCK_DIR, `slot-${slotNum}`);
    try {
      // Remove pid file then directory
      try { unlinkSync(join(slotDir, 'pid')); } catch { /* ignore */ }
      rmdirSync(slotDir);
    } catch { /* already removed */ }
  }

  async acquire() {
    // Check local limit
    if (this.current >= this.max) return false;

    // Check global cross-process limit and claim a slot atomically
    if (await _acquireFileLock()) {
      try {
        const globalCount = _readGlobalCount();
        if (globalCount >= MAX_GLOBAL_CONCURRENT) {
          return false;
        }
        // Try to claim a physical slot directory
        const slotNum = this._acquireSlotDir();
        if (slotNum === 0) {
          return false;
        }
        _writeGlobalCount(globalCount + 1);
        this.current++;
        this._heldSlots.push(slotNum);
        return true;
      } finally {
        _releaseFileLock();
      }
    }

    // Could not acquire file lock — deny rather than bypass global ceiling
    return false;
  }

  async release() {
    if (this.current <= 0) return;
    this.current = Math.max(0, this.current - 1);

    // Release the most recently acquired slot directory
    const slotNum = this._heldSlots.pop();

    // Decrement global counter — retry up to 3 times to prevent counter leak
    let released = false;
    for (let i = 0; i < 3 && !released; i++) {
      if (await _acquireFileLock()) {
        try {
          if (slotNum) {
            this._releaseSlotDir(slotNum);
          }
          const globalCount = _readGlobalCount();
          _writeGlobalCount(Math.max(0, globalCount - 1));
          released = true;
        } finally {
          _releaseFileLock();
        }
      }
    }

    // If we couldn't get the file lock but have a slot dir, still try to clean it up
    if (!released && slotNum) {
      this._releaseSlotDir(slotNum);
    }
  }
}
