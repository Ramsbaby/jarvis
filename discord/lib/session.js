/**
 * Session management, rate tracking, concurrency control, and streaming.
 *
 * Exports: SessionStore, RateTracker, Semaphore, StreamingMessage
 */

import { readFileSync, writeFileSync, mkdirSync, rmdirSync, unlinkSync, renameSync, statSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import {
  ActionRowBuilder,
  AttachmentBuilder,
  ButtonBuilder,
  ButtonStyle,
  EmbedBuilder,
  MessageFlags,
} from 'discord.js';
import { log } from './claude-runner.js';
import { t } from './i18n.js';
import { formatForDiscord } from './format-pipeline.js';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SESSION_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7일
const STREAM_EDIT_INTERVAL_MS = 1500;
const STREAM_MAX_CHARS = 1900;
const RATE_WINDOW_HOURS = 5;
const RATE_MAX_REQUESTS = 900;
const PERSIST_DEBOUNCE_MS = 150;
const MAX_GLOBAL_CONCURRENT = 4;
const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const GLOBAL_COUNT_FILE = join(BOT_HOME, 'state', 'claude-global.count');
const GLOBAL_LOCK_FILE = join(BOT_HOME, 'state', 'claude-global.lock');
const CODE_FILE_MIN_LINES = 30;
const LANG_EXT = {
  javascript: 'js', typescript: 'ts', python: 'py', py: 'py',
  bash: 'sh', shell: 'sh', sh: 'sh', zsh: 'sh',
  json: 'json', yaml: 'yml', yml: 'yml',
  html: 'html', css: 'css', sql: 'sql',
  rust: 'rs', go: 'go', java: 'java',
  cpp: 'cpp', c: 'c', ruby: 'rb',
};

// ---------------------------------------------------------------------------
// SessionStore
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// RateTracker — sliding window in 5-hour blocks
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Semaphore — concurrency control with cross-process global counter
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// StreamingMessage — debounced edit-in-place with code-fence awareness
// ---------------------------------------------------------------------------

export class StreamingMessage {
  constructor(channel, replyTo = null, sessionKey = null, channelId = null) {
    this.channel = channel;
    this.replyTo = replyTo;
    this.sessionKey = sessionKey;
    this.channelId = channelId;
    this.buffer = '';
    this.currentMessage = null;
    this.sentLength = 0;
    this.timer = null;
    this.fenceOpen = false;
    this.finalized = false;
    this.hasRealContent = false;
    this._statusLines = [];
    this._statusTimer = null;
    this._thinkingMsg = t('stream.thinking');
    this._initialThinkingMsg = t('stream.thinking');
    this._placeholderSentAt = 0;
    this._progressTimer = null;
    this._toolCount = 0;
  }

  /** Build the Stop button row (null if no sessionKey) */
  _stopRow() {
    if (!this.sessionKey) return null;
    return new ActionRowBuilder().addComponents(
      new ButtonBuilder()
        .setCustomId(`cancel_${this.sessionKey}`)
        .setLabel(t('stream.stop'))
        .setStyle(ButtonStyle.Danger)
    );
  }

  /** Set context-aware initial thinking message (call before sendPlaceholder). */
  setContext(msg) {
    this._thinkingMsg = msg;
    this._initialThinkingMsg = msg;
  }

  /** Send an embed placeholder with Stop button and start progress timer. */
  async sendPlaceholder() {
    if (this.currentMessage) return;
    this._placeholderSentAt = Date.now();
    const row = this._stopRow();
    const embed = new EmbedBuilder()
      .setColor(0x5865f2)
      .setDescription(this._thinkingMsg);
    const payload = {
      embeds: [embed],
      components: row ? [row] : [],
      flags: MessageFlags.SuppressEmbeds,
    };
    try {
      if (this.replyTo) {
        this.currentMessage = await this.replyTo.reply(payload);
        this.replyTo = null;
      } else {
        this.currentMessage = await this.channel.send(payload);
      }
      // Progressive messages: start only after successful send
      this._progressTimer = setInterval(() => this._progressTick(), 5000);
    } catch (err) {
      log('error', 'Placeholder send failed', { error: err.message });
    }
  }

  /** Check elapsed time and update thinking message progressively. */
  _progressTick() {
    if (this.hasRealContent || this.finalized) {
      clearInterval(this._progressTimer);
      this._progressTimer = null;
      return;
    }
    const elapsed = Date.now() - this._placeholderSentAt;
    const newMsg = this._getProgressMessage(elapsed);
    if (newMsg !== this._thinkingMsg) {
      this._thinkingMsg = newMsg;
      this._flushStatus();
    }
  }

  _getProgressMessage(elapsedMs) {
    const s = elapsedMs / 1000;
    if (s >= 60) return t('stream.thinking.almostDone');
    if (s >= 30) return t('stream.thinking.deep');
    if (s >= 15) return t('stream.thinking.complex');
    if (s >= 8) return t('stream.thinking.careful');
    return this._initialThinkingMsg;
  }

  /** Update placeholder embed with a tool status line (before streaming starts). */
  updateStatus(line) {
    if (this.hasRealContent || this.finalized || !this.currentMessage) return;
    this._toolCount++;
    this._statusLines.push(line);
    // Keep only the 3 most recent tool lines to avoid clutter
    if (this._statusLines.length > 3) {
      this._statusLines = this._statusLines.slice(-3);
    }
    if (this._statusTimer) return;
    this._statusTimer = setTimeout(() => {
      this._statusTimer = null;
      this._flushStatus();
    }, 800);
  }

  async _flushStatus() {
    if (this.hasRealContent || !this.currentMessage) return;
    const parts = [this._thinkingMsg, ''];
    if (this._toolCount > 3) {
      parts.push(t('stream.toolCount', { count: this._toolCount }));
    }
    parts.push(...this._statusLines);
    const embed = new EmbedBuilder()
      .setColor(0x5865f2)
      .setDescription(parts.join('\n'));
    const row = this._stopRow();
    try {
      await this.currentMessage.edit({ embeds: [embed], components: row ? [row] : [] });
    } catch { /* ignore */ }
  }

  append(text) {
    if (this.finalized) return;
    this.hasRealContent = true;
    this.buffer += text;
    this._trackFences(text);
    this._scheduleFlush();
  }

  _trackFences(text) {
    const matches = text.match(/```/g);
    if (matches) {
      for (const _ of matches) {
        this.fenceOpen = !this.fenceOpen;
      }
    }
  }

  _scheduleFlush() {
    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this._flush();
    }, STREAM_EDIT_INTERVAL_MS);
  }

  async _flush() {
    if (this.buffer.length === 0) return;

    while (this.buffer.length > STREAM_MAX_CHARS) {
      const splitAt = this._findSplitPoint(this.buffer, STREAM_MAX_CHARS);
      let chunk = this.buffer.slice(0, splitAt);
      this.buffer = this.buffer.slice(splitAt);

      // fenceOpen: 이전 청크에서 이미 열린 펜스가 있는지 포함해서 계산
      const fencesInChunk = (chunk.match(/```/g) || []).length;
      const openInChunk = ((this.fenceOpen ? 1 : 0) + fencesInChunk) % 2 === 1;
      if (openInChunk) {
        chunk += '\n```';
        this.buffer = '```\n' + this.buffer;
        this.fenceOpen = true;  // 버퍼는 다시 펜스 안에서 시작
      } else {
        this.fenceOpen = false; // 이 청크 끝에서 펜스 닫힘
      }

      await this._sendOrEdit(chunk, true);
      this.currentMessage = null;
      this.sentLength = 0;
    }

    if (this.buffer.length > 0) {
      await this._sendOrEdit(this.buffer, false);
    }
  }

  _findSplitPoint(text, maxLen) {
    const candidate = text.lastIndexOf('\n', maxLen);
    if (candidate > maxLen * 0.6) return candidate + 1;
    const lastSpace = text.lastIndexOf(' ', maxLen);
    if (lastSpace > maxLen * 0.6) return lastSpace + 1;
    return maxLen;
  }

  async _sendOrEdit(content, isFinal) {
    // Clear timers on transition from placeholder to streaming
    if (this._statusTimer) {
      clearTimeout(this._statusTimer);
      this._statusTimer = null;
    }
    if (this._progressTimer) {
      clearInterval(this._progressTimer);
      this._progressTimer = null;
    }
    content = formatForDiscord(content, { channelId: this.channelId });
    const displayContent = (!this.finalized && !isFinal) ? content + ' ▌' : content;
    const row = this._stopRow();
    const components = (this.finalized || isFinal) ? [] : (row ? [row] : []);

    try {
      if (!this.currentMessage) {
        const payload = { content: displayContent, embeds: [], components, flags: MessageFlags.SuppressEmbeds };
        if (this.replyTo) {
          this.currentMessage = await this.replyTo.reply(payload);
          this.replyTo = null;
        } else {
          this.currentMessage = await this.channel.send(payload);
        }
        this.sentLength = content.length;
      } else {
        await this.currentMessage.edit({ content: displayContent, embeds: [], components, flags: MessageFlags.SuppressEmbeds });
        this.sentLength = content.length;
      }
      // buffer 관리는 _flush()에서 처리 — 여기서 지우면 분할 시 나머지 유실
    } catch (err) {
      log('error', 'StreamingMessage send/edit failed', { error: err.message });
    }
  }

  async finalize() {
    this.finalized = true;
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    if (this._statusTimer) {
      clearTimeout(this._statusTimer);
      this._statusTimer = null;
    }
    if (this._progressTimer) {
      clearInterval(this._progressTimer);
      this._progressTimer = null;
    }
    if (this.fenceOpen) {
      this.buffer += '\n```';
      this.fenceOpen = false;
    }
    if (this.buffer.length > 0) {
      await this._flush();
    } else if (this.currentMessage) {
      try {
        await this.currentMessage.edit({ components: [] });
      } catch { /* ignore */ }
    }
    await this._extractCodeBlockFiles();
  }

  /** Post-finalize: extract long code blocks (30+ lines) as file attachments. */
  async _extractCodeBlockFiles() {
    if (!this.currentMessage) return;
    const content = this.currentMessage.content || '';
    const files = [];
    let idx = 0;

    const newContent = content.replace(/```(\w*)\n([\s\S]+?)```/g, (match, lang, code) => {
      const lines = code.split('\n');
      if (lines.length < CODE_FILE_MIN_LINES) return match;
      idx++;
      const ext = LANG_EXT[lang] || lang || 'txt';
      const filename = `code-${idx}.${ext}`;
      files.push(new AttachmentBuilder(Buffer.from(code, 'utf-8'), { name: filename }));
      return `\u{1F4CE} \`${filename}\` (${lines.length} lines)`;
    });

    if (files.length === 0) return;

    try {
      await this.currentMessage.edit({ content: newContent, components: [] });
      await this.channel.send({ files, flags: MessageFlags.SuppressEmbeds });
    } catch (err) {
      log('error', 'Code block file extraction failed', { error: err.message });
    }
  }
}
