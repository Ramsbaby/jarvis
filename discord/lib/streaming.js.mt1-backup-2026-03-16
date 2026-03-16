/**
 * StreamingMessage — debounced edit-in-place with code-fence awareness.
 */

// discord.js is CJS — use default import to avoid ESM named-export errors
import discordPkg from 'discord.js';
const { ActionRowBuilder, AttachmentBuilder, ButtonBuilder, ButtonStyle, MessageFlags } = discordPkg;
import { readFileSync, writeFileSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { log } from './claude-runner.js';
import { t } from './i18n.js';
import { formatForDiscord } from './format-pipeline.js';

/**
 * PID, 절대 파일경로 등 기술 내부 정보를 사용자 친화적 표현으로 마스킹.
 * 코드 펜스 내부는 건드리지 않음.
 */
function maskTechDetails(text) {
  if (!text) return text;
  const lines = text.split('\n');
  const result = [];
  let inFence = false;
  for (const line of lines) {
    if (line.trimStart().startsWith('```')) { inFence = !inFence; result.push(line); continue; }
    if (inFence) { result.push(line); continue; }
    let masked = line
      // PID 숫자 (예: "PID 1234", "pid=5678")
      .replace(/\b(PID|pid)[=\s]+\d{2,6}\b/g, '(내부 프로세스)')
      // 절대 홈 경로 (예: /Users/ramsbaby/.jarvis/..., ~/.jarvis/...)
      .replace(/\/Users\/[^/\s]+\/\.jarvis\/[^\s,)'"]+/g, '(Jarvis 내부 경로)')
      .replace(/~\/\.jarvis\/[^\s,)'"]+/g, '(Jarvis 내부 경로)')
      // 절대 홈 경로 일반 (예: /Users/ramsbaby/...)
      .replace(/\/Users\/[^/\s]+\/(?!\.jarvis)[^\s,)'"]{8,}/g, '(내부 경로)');
    result.push(masked);
  }
  return result.join('\n');
}

/**
 * Markdown 테이블을 Discord 모바일에서 읽기 좋은 불릿 리스트로 변환.
 * | 헤더1 | 헤더2 | 형식 → - **헤더1** · 값1 / **헤더2** · 값2
 */
function convertTablesToList(text) {
  if (!text.includes('|')) return text;

  const lines = text.split('\n');
  const result = [];
  let i = 0;
  let inFence = false;

  while (i < lines.length) {
    const line = lines[i];
    // 코드 펜스 추적 — 펜스 내부 파이프는 테이블로 처리하지 않음
    if (line.trimStart().startsWith('```')) {
      inFence = !inFence;
      result.push(line);
      i++;
      continue;
    }
    if (inFence) {
      result.push(line);
      i++;
      continue;
    }
    // 테이블 헤더 행 감지: 파이프로 시작하거나 파이프 2개 이상 포함
    if (/\|.+\|/.test(line)) {
      // 헤더 파싱
      const headers = line.split('|').map(h => h.trim()).filter(Boolean);
      const headerLineIdx = i;
      i++;
      // 구분선(---|---) 건너뛰기
      if (i < lines.length && /^\s*\|?[\s\-:|]+\|/.test(lines[i])) {
        i++;
      }
      // 데이터 행 처리
      let dataRowCount = 0;
      while (i < lines.length && /\|.+\|/.test(lines[i])) {
        const cells = lines[i].split('|').map(c => c.trim()).filter(Boolean);
        if (cells.length > 0) {
          if (headers.length >= 2 && cells.length >= 2) {
            // 헤더-값 쌍으로 출력
            const parts = headers.map((h, idx) => {
              const val = cells[idx] ?? '';
              return val ? `**${h}** · ${val}` : null;
            }).filter(Boolean);
            result.push(`- ${parts.join(' / ')}`);
          } else {
            // 단일 컬럼 or 헤더 없는 경우
            result.push(`- ${cells.join(' · ')}`);
          }
          dataRowCount++;
        }
        i++;
      }
      // 스트리밍 부분 수신: 헤더만 있고 데이터 행이 없으면 원본 헤더 행 보존
      if (dataRowCount === 0) {
        result.push(lines[headerLineIdx]);
      }
    } else {
      result.push(line);
      i++;
    }
  }

  return result.join('\n');
}

// Active placeholder tracking — persisted for orphan cleanup on restart
const PLACEHOLDER_STATE = join(process.env.BOT_HOME || join(homedir(), '.jarvis'), 'state', 'active-placeholders.json');

function _loadPlaceholders() {
  try { return JSON.parse(readFileSync(PLACEHOLDER_STATE, 'utf-8')); } catch { return []; }
}
function _savePlaceholders(list) {
  const tmp = PLACEHOLDER_STATE + '.tmp';
  try { writeFileSync(tmp, JSON.stringify(list)); renameSync(tmp, PLACEHOLDER_STATE); } catch { /* best effort */ }
}
function _registerPlaceholder(channelId, messageId) {
  const list = _loadPlaceholders();
  list.push({ channelId, messageId, ts: Date.now() });
  _savePlaceholders(list);
}
function _unregisterPlaceholder(messageId) {
  const list = _loadPlaceholders().filter(p => p.messageId !== messageId);
  _savePlaceholders(list);
}
export { _loadPlaceholders, _savePlaceholders };

/**
 * On bot startup: delete Discord messages that were left as orphan placeholders
 * (i.e. bot crashed mid-response). Removes entries older than 1 hour.
 * Call this once after the Discord client is ready.
 *
 * @param {import('discord.js').Client} client - The logged-in Discord client.
 */
export async function cleanupOrphanPlaceholders(client) {
  const list = _loadPlaceholders();
  if (!list.length) return;

  const ONE_HOUR_MS = 60 * 60 * 1000;
  const now = Date.now();
  const survivors = [];

  for (const entry of list) {
    const { channelId, messageId, ts: sentAt } = entry;
    // Keep entries younger than 1 hour — they may still be active
    if (now - sentAt < ONE_HOUR_MS) {
      survivors.push(entry);
      continue;
    }
    try {
      const channel = await client.channels.fetch(channelId);
      if (channel) {
        const message = await channel.messages.fetch(messageId);
        await message.delete();
        log('info', 'cleanupOrphanPlaceholders: deleted stale placeholder', { channelId, messageId });
      }
    } catch (err) {
      // Message already deleted or channel inaccessible — treat as cleaned up
      log('debug', 'cleanupOrphanPlaceholders: could not delete (already gone?)', {
        channelId, messageId, error: err.message,
      });
    }
    // Either deleted or already gone — do not keep in survivors
  }

  _savePlaceholders(survivors);
}

const STREAM_EDIT_INTERVAL_MS = 2000;
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
    this.hasRealContent = false;  // buffer에 텍스트가 있음 (finalize 판단용)
    this._textSent = false;       // Discord에 실제 텍스트 전송됨 (embed 업데이트 중단 기준)
    this._customPhase = false;    // updatePhase 호출됨 — progressTick 덮어쓰기 방지
    this._statusLines = [];
    this._statusTimer = null;
    this._thinkingMsg = t('stream.thinking');
    this._initialThinkingMsg = t('stream.thinking');
    this._placeholderSentAt = 0;
    this._progressTimer = null;
    this._toolCount = 0;
    this._isPlaceholder = false;
    this._flushing = false;
    this._flushDone = null;   // Promise | null — 진행 중인 flush 완료 신호
    // 보람 채널 등 quiet 채널: tool 상태 표시 생략
    const quietIds = (process.env.QUIET_CHANNEL_IDS || '').split(',').map(s => s.trim()).filter(Boolean);
    this._isQuiet = channelId ? quietIds.includes(channelId) : false;
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

  /** Send a plain-text placeholder with Stop button and start progress timer. */
  async sendPlaceholder() {
    if (this.currentMessage) return;
    this._placeholderSentAt = Date.now();
    const row = this._stopRow();
    const payload = {
      content: this._thinkingMsg,
      embeds: [],
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
      this._isPlaceholder = true;
      _registerPlaceholder(this.channel.id, this.currentMessage.id);
      this._progressTimer = setInterval(() => this._progressTick(), 5000);
    } catch (err) {
      log('error', 'Placeholder send failed', { error: err.message });
    }
  }

  /** Check elapsed time and update thinking message progressively. */
  _progressTick() {
    if (this._textSent || this.finalized) {
      clearInterval(this._progressTimer);
      this._progressTimer = null;
      return;
    }
    // updatePhase로 커스텀 메시지가 설정된 경우 덮어쓰지 않음
    if (this._customPhase) return;
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

  /** Update placeholder with a tool status line (before streaming starts). */
  updateStatus(line) {
    if (this._isQuiet || this._textSent || this.finalized || !this.currentMessage) return;
    this._toolCount++;
    // 마지막 줄과 동일하면 카운터로 합침 (예: "🔍 검색 중 ×3")
    if (this._statusLines.length > 0) {
      const last = this._statusLines[this._statusLines.length - 1];
      const baseMatch = last.match(/^(.*?)(?:\s×\d+)?$/);
      const base = baseMatch ? baseMatch[1] : last;
      if (base === line) {
        const prevCount = last.match(/×(\d+)$/);
        const count = prevCount ? parseInt(prevCount[1]) + 1 : 2;
        this._statusLines[this._statusLines.length - 1] = `${line} ×${count}`;
        // debounce flush만 하고 조기 리턴
        if (this._statusTimer) clearTimeout(this._statusTimer);
        this._statusTimer = setTimeout(() => { this._statusTimer = null; this._flushStatus(); }, 800);
        return;
      }
    }
    this._statusLines.push(line);
    // Keep only the 3 most recent tool lines to avoid clutter
    if (this._statusLines.length > 3) {
      this._statusLines = this._statusLines.slice(-3);
    }
    // 타이머를 리셋해서 마지막 상태 반영 (debounce reset 방식)
    if (this._statusTimer) clearTimeout(this._statusTimer);
    this._statusTimer = setTimeout(() => {
      this._statusTimer = null;
      this._flushStatus();
    }, 800);
  }

  // 단계별 progress 메시지 즉시 업데이트 (quiet 채널은 생략)
  async updatePhase(msg) {
    if (this._isQuiet || this._textSent || this.finalized) return;
    log('debug', 'updatePhase', { msg, hasMsg: !!this.currentMessage });
    this._thinkingMsg = msg;
    this._customPhase = true;  // progressTick 덮어쓰기 방지
    await this._flushStatus();
  }

  async _flushStatus() {
    if (this._textSent || !this.currentMessage) return;
    const parts = [this._thinkingMsg];
    if (this._statusLines.length > 0) {
      parts.push('', ...this._statusLines);
    }
    const row = this._stopRow();
    try {
      await this.currentMessage.edit({ content: parts.join('\n'), embeds: [], components: row ? [row] : [] });
    } catch (err) {
      log('warn', 'flushStatus edit failed', { error: err.message, code: err.code });
    }
  }

  /**
   * Replace Mode: tool 사용 후 새 텍스트 블록 시작 시 호출.
   * 이전 중간 텍스트를 버리고 새 텍스트로 교체 준비.
   * currentMessage는 유지 — 다음 append+flush 시 edit으로 교체됨.
   */
  clearForReplace() {
    this.buffer = '';
    this.sentLength = 0;
    this.fenceOpen = false;
  }

  append(text) {
    if (this.finalized) return;
    if (!text || text.length === 0) return;
    this.hasRealContent = true;
    this.buffer += text;
    // A형: 버퍼에만 쌓고 Discord edit 안 함. 버퍼가 Discord 한도 초과 시에만 분할 전송.
    if (this.buffer.length >= STREAM_MAX_CHARS) {
      this._flush();
    }
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
    if (this._flushing || this.buffer.length === 0) return;
    this._flushing = true;
    let resolve;
    this._flushDone = new Promise(r => { resolve = r; });
    try { await this._flushInner(); } finally {
      this._flushing = false;
      this._flushDone = null;
      resolve();
    }
  }

  async _flushInner() {

    while (this.buffer.length > STREAM_MAX_CHARS) {
      const splitAt = this._findSplitPoint(this.buffer, STREAM_MAX_CHARS);
      let chunk = this.buffer.slice(0, splitAt);
      this.buffer = this.buffer.slice(splitAt);

      // fenceOpen: 이전 청크에서 이미 열린 펜스가 있는지 포함해서 계산
      const fencesInChunk = (chunk.match(/```/g) || []).length;
      const openInChunk = ((this.fenceOpen ? 1 : 0) + fencesInChunk) % 2 === 1;
      if (openInChunk) {
        // 언어 태그 보존: 마지막 열린 펜스의 언어를 다음 청크에 이어붙임
        let lang = '';
        for (const m of chunk.matchAll(/```(\w*)/g)) lang = m[1] || '';
        chunk += '\n```';
        this.buffer = '```' + (lang ? lang + '\n' : '\n') + this.buffer;
        this.fenceOpen = true;  // 버퍼는 다시 펜스 안에서 시작
      } else {
        this.fenceOpen = false; // 이 청크 끝에서 펜스 닫힘
      }

      await this._sendOrEdit(chunk, true);
      this.currentMessage = null;
      this.sentLength = 0;
    }

    if (this.buffer.length > 0) {
      // fenceOpen 업데이트: 남은 버퍼의 펜스 상태 반영 (finalize용)
      const fencesInRemaining = (this.buffer.match(/```/g) || []).length;
      if (fencesInRemaining % 2 === 1) this.fenceOpen = !this.fenceOpen;
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
    this._textSent = true;  // Discord에 텍스트 전송 시작 — embed 업데이트 중단
    log('debug', '_sendOrEdit called', { contentLen: content.length, isFinal, isPlaceholder: this._isPlaceholder, finalized: this.finalized });
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
    const converted = convertTablesToList(content);
    if (converted !== content) {
      log('warn', 'Markdown table detected — converted to bullet list for Discord mobile', { channelId: this.channelId });
      content = converted;
    }
    // maskTechDetails: 비기술 채널에서만 선택 적용 (개발자 채널은 경로/PID 필요)
    // LLM 레벨 few-shot으로 이미 가이드 중 — 전체 파이프라인 강제 적용 금지
    const displayContent = (!this.finalized && !isFinal) ? content + ' ▌' : content;
    const row = this._stopRow();
    const components = (this.finalized || isFinal) ? [] : (row ? [row] : []);

    try {
      // Placeholder → edit in place (delete+resend causes message disappearing flash)
      if (this._isPlaceholder && this.currentMessage) {
        _unregisterPlaceholder(this.currentMessage.id);
        this._isPlaceholder = false;
        await this.currentMessage.edit({ content: displayContent, embeds: [], components, flags: MessageFlags.SuppressEmbeds });
        this.sentLength = content.length;
        return;
      }

      if (!this.currentMessage) {
        const payload = { content: displayContent, embeds: [], components, flags: MessageFlags.SuppressEmbeds };
        if (this.replyTo) {
          try {
            this.currentMessage = await this.replyTo.reply(payload);
          } catch {
            // 원본 메시지가 삭제된 경우 reply 실패 → channel.send로 폴백
            this.currentMessage = await this.channel.send(payload);
          }
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
    // Placeholder가 남아있는데 실제 내용이 없으면 → 조용히 삭제
    // (hasRealContent가 true면 buffer에 내용이 있으므로 아래 _flush()에서 처리)
    if (this._isPlaceholder && !this.hasRealContent) {
      if (this.currentMessage) {
        _unregisterPlaceholder(this.currentMessage.id);
        try { await this.currentMessage.delete(); } catch { /* ignore */ }
      }
      return;
    }
    // 진행 중인 flush가 있으면 완료될 때까지 대기.
    // (_flushing 플래그만 보고 루프하는 polling 방식 대신 Promise await로 정확하게 동기화)
    if (this._flushDone) {
      await this._flushDone;
    }
    // 대기 후 buffer에 아직 내용이 남아있으면(append가 flush 도중 들어온 경우 포함) 최종 전송
    if (this.buffer.length > 0) {
      await this._flush();  // _sendOrEdit 내부에서 placeholder→text 전환 처리
    } else if (this.currentMessage) {
      try {
        // 커서 ▌ 잔류 방지: content에서도 커서 제거
        const cleaned = (this.currentMessage.content || '').replace(/ ▌$/, '');
        await this.currentMessage.edit({ content: cleaned, components: [] });
      } catch { /* ignore */ }
    }
    if (this.currentMessage) {
      _unregisterPlaceholder(this.currentMessage.id);
    }
    await this._extractCodeBlockFiles();
    await this._extractAndSendMarkers();
    // GC 힌트: 대형 버퍼 참조 해제 (응답이 길수록 효과적)
    this.buffer = '';
    this._statusLines = [];
  }

  /** Post-finalize: extract long code blocks (30+ lines) as file attachments. */
  async _extractCodeBlockFiles() {
    if (!this.currentMessage) return;
    const content = this.currentMessage.content || '';
    const files = [];
    let idx = 0;

    const MAX_FILE_SIZE = 5 * 1024 * 1024; // 5MB
    const MAX_FILES = 5;

    const newContent = content.replace(/```(\w*)\n([\s\S]+?)```/g, (match, lang, code) => {
      const lines = code.split('\n');
      if (lines.length < CODE_FILE_MIN_LINES) return match;
      if (files.length >= MAX_FILES) return match;
      idx++;
      const ext = LANG_EXT[lang] || lang || 'txt';
      const filename = `code-${idx}.${ext}`;
      let buffer = Buffer.from(code, 'utf-8');
      // Check size and truncate if over limit
      if (buffer.length > MAX_FILE_SIZE) {
        const notice = '\n... [파일 크기 초과: 5MB 상한으로 잘림]';
        const truncated = buffer.slice(0, MAX_FILE_SIZE - notice.length);
        buffer = Buffer.concat([truncated, Buffer.from(notice)]);
      }
      files.push(new AttachmentBuilder(buffer, { name: filename }));
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

  /** Post-finalize: extract EMBED_DATA:/CHART_DATA: markers and send as Discord rich embeds. */
  async _extractAndSendMarkers() {
    if (!this.currentMessage) return;
    let content = this.currentMessage.content || '';

    let embedJson = null;
    let chartJson = null;

    const embedMatch = content.match(/^EMBED_DATA:(.+)$/m);
    if (embedMatch) {
      try { embedJson = JSON.parse(embedMatch[1]); } catch { /* malformed — skip */ }
      content = content.replace(/^EMBED_DATA:.+\n?/m, '');
    }

    const chartMatch = content.match(/^CHART_DATA:(.+)$/m);
    if (chartMatch) {
      try { chartJson = JSON.parse(chartMatch[1]); } catch { /* malformed — skip */ }
      content = content.replace(/^CHART_DATA:.+\n?/m, '');
    }

    if (!embedJson && !chartJson) return;

    // Collapse excess blank lines left after marker removal
    content = content.replace(/\n{3,}/g, '\n\n').trim();

    try {
      // Edit message: remove raw marker lines
      await this.currentMessage.edit({ content: content || '\u200b', components: [] });

      // Send EMBED_DATA as Discord rich embed card
      if (embedJson) {
        await this.channel.send({ embeds: [embedJson] });
      }

      // Send CHART_DATA as QuickChart image embed
      if (chartJson) {
        const chartUrl = 'https://quickchart.io/chart?w=700&h=350&bkg=white&c='
          + encodeURIComponent(JSON.stringify(chartJson));
        await this.channel.send({ embeds: [{ image: { url: chartUrl }, color: 3447003 }] });
      }
    } catch (err) {
      log('error', '_extractAndSendMarkers failed', { error: err.message });
    }
  }
}
