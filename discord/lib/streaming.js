/**
 * StreamingMessage — debounced edit-in-place with code-fence awareness.
 */

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

const STREAM_EDIT_INTERVAL_MS = 1500;
const STREAM_MAX_CHARS = 1900;
const CODE_FILE_MIN_LINES = 30;
const LANG_EXT = {
  javascript: 'js', typescript: 'ts', python: 'py', py: 'py',
  bash: 'sh', shell: 'sh', sh: 'sh', zsh: 'sh',
  json: 'json', yaml: 'yml', yml: 'yml',
  html: 'html', css: 'css', sql: 'sql',
  rust: 'rs', go: 'go', java: 'java',
  cpp: 'cpp', c: 'c', ruby: 'rb',
};

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
