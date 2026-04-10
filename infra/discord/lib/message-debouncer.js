/**
 * MessageDebouncer — 빠른 연속 메시지를 배치로 묶어 단일 Claude 호출로 처리
 *
 * Best practice (production AI bot standard):
 *   - 1.5초 debounce: 마지막 메시지 후 1.5초 침묵 → flush
 *   - 4초 max cap: 메시지가 계속 와도 첫 메시지 후 4초 강제 flush
 *   - per-sessionKey 독립 타이머 (사용자·채널별)
 */

const DEBOUNCE_MS = 1500;   // 마지막 메시지 후 대기 시간
const MAX_WAIT_MS = 4000;   // 첫 메시지 후 최대 대기 시간 (cap)

export class MessageDebouncer {
  constructor() {
    /** @type {Map<string, ReturnType<typeof setTimeout>>} */
    this._timers = new Map();
    /** @type {Map<string, import('discord.js').Message[]>} */
    this._buffers = new Map();
    /** @type {Map<string, number>} */
    this._startTimes = new Map();
  }

  /**
   * 메시지를 버퍼에 추가하고 debounce 타이머를 (재)시작.
   * @param {string} sessionKey
   * @param {import('discord.js').Message} message
   * @param {(messages: import('discord.js').Message[]) => void} onFlush
   */
  add(sessionKey, message, onFlush) {
    // 버퍼 초기화 (첫 메시지)
    if (!this._buffers.has(sessionKey)) {
      this._buffers.set(sessionKey, []);
      this._startTimes.set(sessionKey, Date.now());
    }
    this._buffers.get(sessionKey).push(message);

    // 기존 debounce 타이머 취소
    const existing = this._timers.get(sessionKey);
    if (existing) clearTimeout(existing);

    // max cap 확인 — 초과하면 즉시 flush
    const elapsed = Date.now() - (this._startTimes.get(sessionKey) ?? Date.now());
    const remaining = MAX_WAIT_MS - elapsed;
    if (remaining <= 0) {
      this._flush(sessionKey, onFlush);
      return;
    }

    // debounce 타이머 설정 (남은 max cap과 DEBOUNCE_MS 중 짧은 쪽)
    const delay = Math.min(DEBOUNCE_MS, remaining);
    this._timers.set(sessionKey, setTimeout(() => {
      this._flush(sessionKey, onFlush);
    }, delay));
  }

  /** 특정 sessionKey 버퍼를 즉시 flush (외부 강제 호출용) */
  flush(sessionKey, onFlush) {
    const existing = this._timers.get(sessionKey);
    if (existing) clearTimeout(existing);
    this._flush(sessionKey, onFlush);
  }

  /** 해당 sessionKey가 대기 중인 메시지 있는지 확인 */
  hasPending(sessionKey) {
    return this._buffers.has(sessionKey) && (this._buffers.get(sessionKey)?.length ?? 0) > 0;
  }

  _flush(sessionKey, onFlush) {
    const messages = this._buffers.get(sessionKey) ?? [];
    this._buffers.delete(sessionKey);
    this._timers.delete(sessionKey);
    this._startTimes.delete(sessionKey);
    if (messages.length > 0) {
      onFlush(messages);
    }
  }
}
