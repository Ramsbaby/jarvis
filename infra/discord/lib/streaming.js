/**
 * StreamingMessage — debounced edit-in-place with code-fence awareness.
 */

// discord.js is CJS — use default import to avoid ESM named-export errors
import discordPkg from 'discord.js';
const { ActionRowBuilder, AttachmentBuilder, ButtonBuilder, ButtonStyle, MessageFlags,
  ContainerBuilder, TextDisplayBuilder, SeparatorBuilder,
  SectionBuilder, ThumbnailBuilder, MediaGalleryBuilder, MediaGalleryItemBuilder } = discordPkg;
import { readFileSync, writeFileSync, renameSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { log } from './claude-runner.js';
import { t } from './i18n.js';
import { formatForDiscord } from './format-pipeline.js';
import { pickVariant, recordOutcome } from './ab-experiment.js';

// ---------------------------------------------------------------------------
// 이미지 캐시 — SHA-256 해시 키, max 30건 (의존성 없는 간단한 Map LRU)
// TABLE_DATA / CHART_DATA 동일 데이터 반복 요청 시 렌더링 스킵
// Updated: 2026-03-21 13:52 - Force reload by adding timestamp
// ---------------------------------------------------------------------------
const _IMAGE_CACHE_MAX = 30;
const _imageCache = new Map();
function _imageCacheGet(key) { return _imageCache.get(key); }
function _imageCacheSet(key, val) {
  if (_imageCache.size >= _IMAGE_CACHE_MAX) {
    _imageCache.delete(_imageCache.keys().next().value); // oldest evict
  }
  _imageCache.set(key, val);
}
function _cacheKey(data) {
  return createHash('sha256').update(JSON.stringify(data)).digest('hex').slice(0, 16);
}

// ---------------------------------------------------------------------------
// lastQueryStore — sessionKey → 마지막 사용자 쿼리 (재생성/요약 버튼용)
// handlers.js에서 import해서 set, commands.js에서 regen 시 get
// ---------------------------------------------------------------------------
import { BoundedMap } from './bounded-map.js';
import { recordSilentError } from './error-ledger.js';
export const lastQueryStore = new BoundedMap(1000, 30 * 60_000); // 1000 items, 30min TTL

// ---------------------------------------------------------------------------
// chartjs-node-canvas 싱글톤 — CHART_DATA 렌더링 (Chrome 없이 순수 Node.js)
// ---------------------------------------------------------------------------
const _cjsRequire = createRequire(import.meta.url);
let _chartNodeCanvas = null;
function _getChartNodeCanvas() {
  if (!_chartNodeCanvas) {
    const { ChartJSNodeCanvas } = _cjsRequire('chartjs-node-canvas');
    _chartNodeCanvas = new ChartJSNodeCanvas({
      width: 780, height: 430,
      backgroundColour: '#313338',
    });
    log('info', 'ChartJSNodeCanvas renderer initialized (singleton)');
  }
  return _chartNodeCanvas;
}

// ---------------------------------------------------------------------------
// Chrome 싱글톤 — TABLE_DATA 렌더링용. 매 요청마다 launch/close 하지 않고 재사용.
// 페이지(page)는 요청마다 생성/닫기 (메모리 누수 방지)
// ---------------------------------------------------------------------------
const CHROME_PATH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
let _chromeBrowser = null;

// Chrome orphan 방지: 프로세스 종료 시 브라우저 정리
process.on('exit', () => {
  if (_chromeBrowser) { try { _chromeBrowser.process()?.kill(); } catch {} }
});
process.on('SIGTERM', () => {
  if (_chromeBrowser) { try { _chromeBrowser.process()?.kill(); } catch {} }
  process.exit(0);
});

async function _getChromeBrowser() {
  if (_chromeBrowser) {
    try {
      await _chromeBrowser.pages(); // 살아있는지 probe
      return _chromeBrowser;
    } catch {
      _chromeBrowser = null; // 죽어있으면 재시작
    }
  }
  const { default: puppeteer } = await import('puppeteer-core');
  _chromeBrowser = await puppeteer.launch({
    executablePath: CHROME_PATH,
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
  });
  log('info', 'Chrome browser instance started (singleton)');
  return _chromeBrowser;
}

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
      // 절대 홈 경로 (예: /Users/username/.jarvis/..., ~/jarvis/runtime/...) gitleaks:allow
      .replace(/\/Users\/[^/\s]+\/\.jarvis\/[^\s,)'"]+/g, '(Jarvis 내부 경로)') // gitleaks:allow
      .replace(/~\/\.jarvis\/[^\s,)'"]+/g, '(Jarvis 내부 경로)') // gitleaks:allow
      // 절대 홈 경로 일반 (예: /Users/username/...)  gitleaks:allow
      .replace(/\/Users\/[^/\s]+\/(?!\.jarvis)[^\s,)'"]{8,}/g, '(내부 경로)'); // gitleaks:allow
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
const PLACEHOLDER_STATE = join(process.env.BOT_HOME || join(homedir(), 'jarvis/runtime'), 'state', 'active-placeholders.json');

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
        // 버튼(components) + 커서(▌) 제거만 — 메시지 내용은 유지 (삭제 금지)
        const cleaned = (message.content || '').replace(/ ▌$/, '');
        await message.edit({ content: cleaned || '...', components: [], embeds: [] });
        log('info', 'cleanupOrphanPlaceholders: removed stale components from message', { channelId, messageId });
      }
    } catch (err) {
      // Message already deleted or channel inaccessible — treat as cleaned up
      log('debug', 'cleanupOrphanPlaceholders: could not clean (already gone?)', {
        channelId, messageId, error: err.message,
      });
    }
    // Either deleted or already gone — do not keep in survivors
  }

  _savePlaceholders(survivors);
}

// 700ms — Discord edit rate limit(~초당 1회) 내에서 체감 "타이핑" 수준.
// 2000ms 였을 때 블록 단위로 뚝뚝 떨어지는 느낌 → 대화형 경험 해침.
// 2026-04-19: 고정 700ms → adaptiveInterval() 가변 throttle 도입. 짧은 응답 체감 속도 2배.
const STREAM_EDIT_INTERVAL_MS = 700; // DEPRECATED: fallback 기본값. 실제는 adaptiveInterval() 사용.

/**
 * Discord edit 간격을 버퍼 특성에 맞춰 조정.
 *   - 짧은 응답(≤120자): 300ms  — 즉각적인 체감 응답
 *   - 일반 응답: 400ms             — 부드러운 타이핑
 *   - 긴 응답(>800자): 550ms       — rate-limit 부담 완화
 *   - 코드 블록 열림: 600ms         — fence 안전 마진
 *   - tool status 갱신 직후: 450ms  — 상태 라인 빠른 반영
 */
function adaptiveInterval({ bufferLen = 0, inFence = false, hasTool = false } = {}) {
  if (inFence) return 600;
  if (hasTool) return 450;
  if (bufferLen < 120) return 300;
  if (bufferLen > 800) return 550;
  return 400;
}

const STREAM_MAX_CHARS = 1700; // 포맷팅 확장(URL 래핑, 테이블→리스트) 여유 확보
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
// 텍스트 청크 분할 — Discord TextDisplay 4000자 메시지 합산 제한 대응.
// 단락(\n\n) → 줄(\n) → 단어 순으로 자연스러운 경계에서 분할.
// maxLen 기본 3800 (Discord 4000 제한의 95% — 안전 마진).
// ---------------------------------------------------------------------------
function _splitIntoChunks(text, maxLen = 3800) {
  if (text.length <= maxLen) return [text];
  const chunks = [];
  let remaining = text;
  while (remaining.length > maxLen) {
    let splitAt = maxLen;
    // 1차: 단락 경계 (\n\n) — 최소 절반 이상에서 발견된 경우만 사용
    const paraIdx = remaining.lastIndexOf('\n\n', maxLen);
    if (paraIdx > maxLen * 0.5) {
      splitAt = paraIdx + 2;
    } else {
      // 2차: 줄 경계 (\n)
      const lineIdx = remaining.lastIndexOf('\n', maxLen);
      if (lineIdx > maxLen * 0.5) {
        splitAt = lineIdx + 1;
      } else {
        // 3차: 단어 경계 (공백)
        const wordIdx = remaining.lastIndexOf(' ', maxLen);
        if (wordIdx > maxLen * 0.5) splitAt = wordIdx + 1;
        // else: 강제 분할 (maxLen 그대로)
      }
    }
    chunks.push(remaining.slice(0, splitAt).trimEnd());
    remaining = remaining.slice(splitAt).trimStart();
  }
  if (remaining.length > 0) chunks.push(remaining);
  return chunks;
}

// ---------------------------------------------------------------------------
// CV2 전송 전 마크다운 헤딩을 굵은 텍스트 시각 구조로 변환.
// Discord TextDisplay는 ## 헤딩을 렌더링하지 않으므로 볼드 텍스트로 대체.
// ---------------------------------------------------------------------------
function _preprocessMarkdown(text) {
  return text
    .replace(/^## (.+)$/mg, '\n**── $1 ──**\n')
    .replace(/^### (.+)$/mg, '**▸ $1**')
    .replace(/^#### (.+)$/mg, '**$1**')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

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
    this._markerCardSent = false; // CV2/CHART/TABLE 카드가 이미 전송됨 → _wrapInCV2 버튼 생략
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
    this._finalizeComplete = false; // 진정한 멱등성: 두 번째 finalize() 호출 방지
    // family 채널 등 quiet 채널: tool 상태 표시 생략
    const quietIds = (process.env.QUIET_CHANNEL_IDS || '').split(',').map(s => s.trim()).filter(Boolean);
    this._isQuiet = channelId ? quietIds.includes(channelId) : false;
    // ----- P0-1: tool status / thinking prefix (본문 스트리밍 중에도 표시) -----
    this._toolStatusLine = '';      // 현재 진행 중인 도구(한 줄)
    this._thinkingActive = false;   // thinking 블록 활성 상태
    this._lastToolAt = 0;           // 마지막 tool 이벤트 시각 (stale 제거용)
    this._channelName = null;       // artifact 업로드 시 태그로 사용
    // ----- P2-1: 상시 Status bar (모델·경과·턴·토큰) -----
    this._statusMeta = null;        // { model, startedAt, turn, tokens } 또는 null (비활성)
    // ----- P2-3: Stream resumption (edit 실패 연속 발생 시 새 메시지로 이어붙이기) -----
    this._editFailureStreak = 0;    // edit 연속 실패 카운터
    this._resumedCount = 0;         // 이어붙인 횟수 (메시지 분할)
    // ----- P3-1: 마커 조기 전송 (CHART_DATA_EARLY_SEND=1 opt-in) -----
    this._markerEarlySent = new Set(); // 조기 전송 완료된 마커 이름 (예: 'CHART_DATA')
    // ----- P3-3: A/B 실험 — throttle-v1 variant ('adaptive'|'fixed-700') -----
    this._userId = null;              // handlers.js가 setUserId()로 주입
    this._throttleVariant = null;     // pickVariant 결과 캐싱 (null = 미결정 → 기본 adaptive)
    this._startedAtMs = Date.now();   // recordOutcome용 elapsed 기산점
    this._editCount = 0;              // recordOutcome용 edit 횟수
    this._experimentRecorded = false; // finalize 중복 기록 방지
  }

  /**
   * P3-3: userId 설정 — A/B 실험 variant 결정에 사용.
   * 사용자 단위 deterministic 분산 (같은 userId는 항상 같은 variant).
   */
  setUserId(userId) {
    this._userId = userId || null;
    if (this._userId) {
      try {
        this._throttleVariant = pickVariant('throttle-v1', this._userId, {
          channelName: this._channelName,
        });
      } catch { this._throttleVariant = null; }
    }
  }

  /** 채널 이름 설정 — handlers.js에서 페르소나 로드 후 주입. artifact 태그에 사용. */
  setChannelName(name) { this._channelName = name || null; }

  /**
   * P0-1: 도구 실행 상태 표시.
   * placeholder 모드면 기존 updateStatus() 경로, 텍스트 스트리밍 중이면 prefix 라인으로 표시.
   */
  setToolStatus(line) {
    if (this._isQuiet) return;
    this._toolStatusLine = line || '';
    this._lastToolAt = Date.now();
    if (this._textSent) {
      // 본문 스트리밍 중 — 다음 flush에 prefix 반영
      this._scheduleFlush();
    } else {
      // placeholder 모드 — 기존 경로 (line ×N 카운팅 포함)
      this.updateStatus(line);
    }
  }

  /** tool 블록 종료 시 호출 — prefix 제거. 300ms debounce로 잔상 방지. */
  clearToolStatus() {
    if (!this._toolStatusLine) return;
    this._toolStatusLine = '';
    if (this._textSent) this._scheduleFlush();
  }

  /** P0-1: thinking 블록 감지. 본문 스트리밍 중 "🧠 생각 정리 중" prefix. */
  setThinking(on) {
    if (this._isQuiet) return;
    const next = !!on;
    if (this._thinkingActive === next) return;
    this._thinkingActive = next;
    if (this._textSent) this._scheduleFlush();
  }

  /**
   * P2-1: 상시 Status bar 메타 갱신.
   * 처음 호출 시 활성화 (startedAt 기록), 이후 patch 방식으로 누적.
   * 호출 예:
   *   setStatusMeta({ model: 'Opus 4.7', startedAt: Date.now() })
   *   setStatusMeta({ turn: prev+1 })
   *   setStatusMeta({ tokens: 8234 })
   */
  setStatusMeta(patch) {
    if (this._isQuiet) return;
    if (!patch || typeof patch !== 'object') return;
    if (!this._statusMeta) this._statusMeta = {};
    Object.assign(this._statusMeta, patch);
    if (this._textSent) this._scheduleFlush();
  }

  /** 턴 카운터 편의 메서드 — setStatusMeta({ turn: ++ }) 대용 */
  incTurn() {
    if (this._isQuiet) return;
    if (!this._statusMeta) this._statusMeta = { turn: 0 };
    this._statusMeta.turn = (this._statusMeta.turn || 0) + 1;
    if (this._textSent) this._scheduleFlush();
  }

  /** 상태 바 문자열 렌더 (없으면 빈 문자열)
   *
   * isFinal=true 시에는 빈 문자열 반환 — 최종 메시지에는 handlers.js 가
   * `streamer.append('\n' + statsLine)` 으로 붙이는 completion stats line
   * (`🤖 Opus · ⏱️ Ns · 💭 K↑ K↓ · 🛠️ N · 📊 N%`) 만 남도록.
   * (과거엔 여기서도 `✅ 🤖 ... · 📊 N턴 · 🎫 N` 을 붙였으나 정보 중복 + 아래 푸터
   * 2개가 겹치는 버그가 있어 최종 시점에는 숨김.)
   */
  _renderStatusBar(isFinal) {
    if (isFinal) return '';
    const m = this._statusMeta;
    if (!m) return '';
    const parts = [];
    if (m.model) parts.push(`🤖 ${m.model}`);
    if (m.startedAt) {
      const elapsed = Math.max(0, Math.round((Date.now() - m.startedAt) / 1000));
      parts.push(`⏱️ ${elapsed}s`);
    }
    if (m.turn) parts.push(`📊 ${m.turn}턴`);
    if (m.tokens) {
      const t = m.tokens >= 1000
        ? `${(m.tokens / 1000).toFixed(1)}k`
        : String(m.tokens);
      parts.push(`🎫 ${t}`);
    }
    if (parts.length === 0) return '';
    return `-# ⏳ ${parts.join(' · ')}`;
  }

  /**
   * P0-1: 본문 + status prefix 합성.
   * - 🧠 thinking 활성 → 상단 1줄
   * - 🔧 tool 상태(15초 이내) → 상단 소형 라인 (-# prefix)
   * - isFinal=false면 커서(▌) 부착
   */
  _composeDisplay(content, isFinal) {
    const prefixes = [];
    if (this._thinkingActive && !this.finalized && !isFinal) {
      prefixes.push('🧠 *생각 정리 중…*');
    }
    if (this._toolStatusLine && (Date.now() - this._lastToolAt) < 15000 && !this.finalized && !isFinal) {
      // -# prefix는 Discord small text — 본문을 방해하지 않음
      prefixes.push(`-# ${this._toolStatusLine}`);
    }
    const cursor = (!this.finalized && !isFinal) ? ' ▌' : '';
    // P2-1: 상시 Status bar (모델·경과·턴·토큰) — 본문 하단 메타 라인
    const statusBar = this._renderStatusBar(isFinal);
    const head = prefixes.length > 0
      ? `${prefixes.join('\n')}\n\n${content}${cursor}`
      : `${content}${cursor}`;
    return statusBar ? `${head}\n\n${statusBar}` : head;
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

  /**
   * P1-2: 종료 시 표시되는 최종 액션 행 — 재생성 / 요약 / 다운로드
   * 3개 섹션(마커 이미지, CV2, 일반 텍스트) 모두 동일 행 사용 (DRY).
   * sessionKey 없으면 null.
   */
  _finalActionRow() {
    if (!this.sessionKey) return null;
    return new ActionRowBuilder().addComponents(
      new ButtonBuilder()
        .setCustomId(`regen_${this.sessionKey}`)
        .setLabel('🔄 재생성')
        .setStyle(ButtonStyle.Secondary),
      new ButtonBuilder()
        .setCustomId(`summarize_${this.sessionKey}`)
        .setLabel('📝 요약')
        .setStyle(ButtonStyle.Secondary),
      new ButtonBuilder()
        .setCustomId(`download_${this.sessionKey}`)
        .setLabel('💾 다운로드')
        .setStyle(ButtonStyle.Secondary),
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
    // 2초마다 Discord edit 발동 (타이핑 효과 스트리밍)
    this._scheduleFlush();
    // 버퍼가 Discord 한도 초과 시 즉시 분할 전송
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
    // P3-3: throttle-v1 A/B — 'fixed-700' variant일 때는 고정 700ms, 아니면 adaptive
    const interval = this._throttleVariant === 'fixed-700'
      ? 700
      : adaptiveInterval({
          bufferLen: this.buffer.length,
          inFence: this.fenceOpen,
          hasTool: !!this._toolStatusLine,
        });
    this.timer = setTimeout(() => {
      this.timer = null;
      this._editCount++; // P3-3: flush = 1 edit 시도 (대략적 지표)
      this._flush();
    }, interval);
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
    // 스트리밍 버퍼 전체에 narration filter 적용 (라인 단위 regex가 전체 텍스트에서 매칭)
    // _sendOrEdit의 formatForDiscord는 청크 단위라 분할된 내러티브를 못 잡음
    this.buffer = formatForDiscord(this.buffer, { channelId: this.channelId });

    // P3-1: 마커 조기 전송 (opt-in) — 마커가 완성되자마자 이미지 전송 착수
    await this._tryEarlyMarkerSend();

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
    // P3-1: CHART_DATA / TABLE_DATA 마커가 완성되면 백그라운드 렌더링 사전 실행
    // finalize 시점에 이미 캐시에 적중하도록 → 전송 지연 단축
    this._maybePrefetchMarkers();
  }

  /**
   * P3-1: 스트리밍 중 CHART_DATA JSON이 balanced 완료되면 백그라운드로 PNG 렌더링.
   * finalize 시점에 `_imageCache`에서 바로 적중 → 차트 표시 체감 지연 최소화.
   * 실패/미완성은 silent — finalize의 정식 경로가 재시도.
   */
  _maybePrefetchMarkers() {
    if (this._chartPrefetchScheduled) return;
    const buf = this.buffer;
    const idx = buf.indexOf('CHART_DATA:{');
    if (idx < 0) return;
    // balanced JSON 찾기
    const after = buf.slice(idx + 'CHART_DATA:'.length);
    let depth = 0, inStr = false, escape = false, end = -1;
    for (let i = 0; i < after.length; i++) {
      const ch = after[i];
      if (escape) { escape = false; continue; }
      if (ch === '\\') { escape = true; continue; }
      if (ch === '"') { inStr = !inStr; continue; }
      if (inStr) continue;
      if (ch === '{' || ch === '[') depth++;
      if (ch === '}' || ch === ']') { depth--; if (depth === 0) { end = i; break; } }
    }
    if (end === -1) return; // 아직 JSON 미완성 — 다음 flush 시 재시도
    const rawJson = after.slice(0, end + 1);
    let chartJson;
    try { chartJson = JSON.parse(rawJson); } catch { return; }
    this._chartPrefetchScheduled = true;
    const key = _cacheKey(chartJson);
    if (_imageCacheGet(key)) return; // 이미 캐시됨
    // 백그라운드 렌더링 — 메인 flush 루프 차단 금지
    setImmediate(async () => {
      try {
        const { type = 'line', title, labels = [], datasets = [] } = chartJson;
        const palette = ['#5865f2', '#57f287', '#fee75c', '#ed4245', '#eb459e', '#faa61a'];
        const normalizedDatasets = datasets.map((d, i) => ({
          borderColor: d.borderColor || d.color || palette[i % palette.length],
          backgroundColor: d.backgroundColor ?? (type === 'line' ? 'transparent' : (d.color || palette[i % palette.length]) + '99'),
          borderWidth: d.borderWidth ?? 2,
          pointRadius: d.pointRadius ?? 3,
          tension: d.tension ?? 0.3,
          fill: d.fill ?? false,
          ...d,
        }));
        const config = {
          type,
          data: { labels, datasets: normalizedDatasets },
          options: {
            responsive: false, animation: false, devicePixelRatio: 2,
            plugins: {
              title: { display: !!title, text: title ?? '', color: '#fff', font: { size: 15, weight: 'bold' }, padding: { bottom: 12 } },
              legend: { labels: { color: '#dbdee1', font: { size: 12 }, padding: 16, usePointStyle: true } },
            },
            scales: (type !== 'pie' && type !== 'doughnut') ? {
              x: { ticks: { color: '#9b9fa8', font: { size: 11 } }, grid: { color: '#3b3d43' }, border: { color: '#3b3d43' } },
              y: { ticks: { color: '#9b9fa8', font: { size: 11 } }, grid: { color: '#3b3d43' }, border: { color: '#3b3d43' } },
            } : undefined,
          },
        };
        const renderer = _getChartNodeCanvas();
        const buf = await renderer.renderToBuffer(config);
        _imageCacheSet(key, buf);
        log('info', 'CHART_DATA prefetch rendered', { key, size: buf.length });
      } catch (err) {
        log('debug', 'CHART_DATA prefetch failed (non-blocking)', { error: err.message });
      }
    });
  }

  _findSplitPoint(text, maxLen) {
    // 우선순위 1: ### 헤딩 경계 (섹션 단위 분할)
    const headingRe = /\n(?=###? )/g;
    let bestHeading = -1;
    let m;
    while ((m = headingRe.exec(text)) !== null) {
      if (m.index > 0 && m.index <= maxLen) bestHeading = m.index;
    }
    if (bestHeading > maxLen * 0.4) return bestHeading + 1;

    // 우선순위 2: --- 구분선
    const hrIdx = text.lastIndexOf('\n---', maxLen);
    if (hrIdx > maxLen * 0.4) return hrIdx + 1;

    // 우선순위 3: 빈 줄 (단락 경계)
    const blankIdx = text.lastIndexOf('\n\n', maxLen);
    if (blankIdx > maxLen * 0.5) return blankIdx + 1;

    // 우선순위 4: 일반 줄바꿈
    const candidate = text.lastIndexOf('\n', maxLen);
    if (candidate > maxLen * 0.6) return candidate + 1;

    // 우선순위 5: 공백
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
    // Safety: formatForDiscord/convertTablesToList may expand content beyond Discord 2000 limit.
    // 트런케이션 대신 분할 전송 — 내용 유실 없음.
    const DISCORD_LIMIT = 1990;
    if (content.length > DISCORD_LIMIT) {
      log('warn', '_sendOrEdit: content exceeded Discord limit after formatting — splitting', { originalLen: content.length });
      const parts = _splitIntoChunks(content, DISCORD_LIMIT);
      // 첫 번째 파트: 현재 _sendOrEdit 흐름으로 처리 (재귀)
      // 나머지 파트: 순차 channel.send
      for (let pi = 0; pi < parts.length; pi++) {
        const part = parts[pi];
        const isLast = pi === parts.length - 1;
        const partDisplay = (!isLast || (!this.finalized && !isFinal)) ? part : part;
        const payload = { content: partDisplay, embeds: [], components: [], flags: MessageFlags.SuppressEmbeds };
        if (pi === 0 && this._isPlaceholder && this.currentMessage) {
          // _unregisterPlaceholder는 finalize() 완료 시점에만 호출 (orphan cleanup이 버튼 제거할 수 있도록)
          this._isPlaceholder = false;
          await this.currentMessage.edit({ content: partDisplay, embeds: [], components: [], flags: MessageFlags.SuppressEmbeds });
          this.sentLength = part.length;
        } else if (pi === 0 && !this.currentMessage && this.replyTo) {
          try { this.currentMessage = await this.replyTo.reply(payload); }
          catch { this.currentMessage = await this.channel.send(payload); }
          this.replyTo = null;
          this.sentLength = part.length;
        } else {
          this.currentMessage = await this.channel.send(payload);
          this.sentLength = part.length;
        }
        if (!isLast) await new Promise(r => setTimeout(r, 300)); // rate limit 방지
      }
      return;
    }
    // maskTechDetails: 비기술 채널에서만 선택 적용 (개발자 채널은 경로/PID 필요)
    // LLM 레벨 few-shot으로 이미 가이드 중 — 전체 파이프라인 강제 적용 금지
    // P0-1: tool status / thinking prefix + 커서 합성 통합
    const displayContent = this._composeDisplay(content, isFinal);
    const row = this._stopRow();
    const components = (this.finalized || isFinal) ? [] : (row ? [row] : []);

    try {
      // Placeholder → edit in place (delete+resend causes message disappearing flash)
      // _unregisterPlaceholder는 finalize() 완료 시점에만 호출 (orphan cleanup이 버튼 제거할 수 있도록)
      if (this._isPlaceholder && this.currentMessage) {
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
      log('error', 'StreamingMessage send/edit failed', { error: err.message, code: err.code });
      // Rate limit (429) 또는 일시적 오류 시 1회 retry
      if (err.status === 429 || err.code === 'RateLimited' || err.message?.includes('rate')) {
        const retryAfter = (err.retryAfter ?? 1) * 1000 + 200;
        log('warn', '_sendOrEdit rate limited — retrying', { retryAfter });
        await new Promise(r => setTimeout(r, retryAfter));
        try {
          const retryDisplay = this._composeDisplay(content, isFinal);
          if (this.currentMessage) {
            await this.currentMessage.edit({ content: retryDisplay, embeds: [], components: [], flags: MessageFlags.SuppressEmbeds });
          } else {
            this.currentMessage = await this.channel.send({ content: retryDisplay, embeds: [], components: [], flags: MessageFlags.SuppressEmbeds });
          }
          this.sentLength = content.length;
          log('info', '_sendOrEdit retry succeeded');
          return;
        } catch (retryErr) {
          log('error', '_sendOrEdit retry also failed', { error: retryErr.message });
          // P2-3: stream resumption — retry도 실패하면 차이분을 새 메시지로 분할 전송
          await this._resumeAsNewMessage(content, isFinal, retryErr);
        }
      } else {
        // 429 외 다른 영구성 오류(권한/메시지 삭제 등) — 즉시 resumption 시도
        await this._resumeAsNewMessage(content, isFinal, err);
      }
    }
  }

  /**
   * P2-3: edit 실패 후 차이분(delta)을 새 메시지로 이어 전송.
   *
   * 기존 currentMessage는 이미 전송된 sentLength 까지 보존되어 있다고 가정.
   * content[sentLength:] 만 new message로 send → currentMessage 교체 → 이후 append는 새 메시지에 대해 edit.
   *
   * 삭제/권한 오류로 새 send 조차 실패하면 silent (로그만).
   */
  async _resumeAsNewMessage(content, isFinal, originalErr) {
    const delta = this.sentLength > 0 ? content.slice(this.sentLength) : content;
    if (!delta || !delta.trim()) {
      log('debug', '_resumeAsNewMessage: no delta, skipping');
      return;
    }
    try {
      const resumeMarker = '\n\n-# ↪️ 이어서…';
      const resumeDisplay = this._composeDisplay(delta, isFinal);
      const newMsg = await this.channel.send({
        content: resumeMarker + '\n' + resumeDisplay,
        embeds: [],
        components: [],
        flags: MessageFlags.SuppressEmbeds,
      });
      // 새 메시지를 currentMessage 로 교체 → 이후 append/edit 타겟 이동
      this.currentMessage = newMsg;
      this.sentLength = content.length;
      log('warn', '_resumeAsNewMessage: split successful (edit failed, new msg created)', {
        newMsgId: newMsg.id, deltaLen: delta.length, originalErr: originalErr?.message?.slice(0, 120),
      });
    } catch (splitErr) {
      log('error', '_resumeAsNewMessage failed — content may be lost', {
        error: splitErr.message,
        deltaLen: delta.length,
      });
    }
  }

  async finalize() {
    // 멱등성 보장: 비활성 타임아웃 등 이중 호출 시 두 번째는 no-op
    // (this.finalized는 _sendOrEdit 커서 표시에 여전히 사용되므로 별도 플래그 사용)
    if (this._finalizeComplete) return;
    this._finalizeComplete = true;
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
        try { await this.currentMessage.delete(); } catch (err) { recordSilentError('streaming.finalize.deletePlaceholder', err); }
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
      } catch (err) { recordSilentError('streaming.finalize.editClean', err); }
    }
    // 안전망: rate limit 등으로 마지막 edit가 실패했을 경우 커서 잔류 방지
    // _flush()/_sendOrEdit에서 retry 했어도 실패했다면 여기서 여러 번 재시도 (말짤림 방지)
    if (this.currentMessage) {
      // buffer가 남아 있으면 전체 내용으로 복원, 없으면 Discord 캐시에서 커서만 제거
      const finalContent = this.buffer.length > 0
        ? formatForDiscord(this.buffer, { channelId: this.channelId })
        : (this.currentMessage.content || '').replace(/ ▌$/, '');
      if ((this.currentMessage.content || '').endsWith(' ▌')) {
        log('warn', 'finalize: cursor still present after flush — force removing with retry');
        // Exponential backoff retry: rate limit 심각해도 최종적으로 반영
        const delays = [500, 1500, 3000];
        let success = false;
        for (const delay of delays) {
          try {
            await new Promise(r => setTimeout(r, delay));
            await this.currentMessage.edit({ content: finalContent, components: [] });
            success = true;
            break;
          } catch (err) {
            recordSilentError('streaming.finalize.cursorRemovalRetry', err);
          }
        }
        if (!success) {
          log('error', 'finalize: all cursor removal retries failed — 응답 말짤림 가능성', {
            messageId: this.currentMessage.id, contentLen: finalContent.length,
          });
        }
      }
    }
    if (this.currentMessage) {
      _unregisterPlaceholder(this.currentMessage.id);
    }
    await this._extractCodeBlockFiles();
    await this._extractAndSendMarkers();
    // P1-1: 인용 각주 자동 포맷 (2개 이상 감지 시 [^N] 치환 + 출처 블록)
    await this._maybeFormatCitations();
    await this._wrapInCV2();
    // P0-3: 아티팩트 분리 — 코드 첨부 후에도 남은 본문이 여전히 길면 board 업로드
    await this._maybeUploadArtifact();
    // P1-2: 종료 액션 버튼 행(재생성/요약/다운로드) — 응답 길이 임계 충족 시 편집으로 부착
    await this._appendActionButtons();
    // P1-3: 긴 응답 자동 Thread — 채널 직접 응답 & 3000자+ 시 follow-up 스레드 생성
    await this._maybeCreateThread();
    // P3-3: A/B 실험 outcome 기록 — ledger에 elapsed/edits/variant 누적
    this._recordExperimentOutcome();
    // GC 힌트: 대형 버퍼 참조 해제 (응답이 길수록 효과적)
    this.buffer = '';
    this._statusLines = [];
  }

  /**
   * P3-3: throttle-v1 outcome ledger 기록 (응답 1회당 1 entry).
   * silent — 실패해도 응답 흐름에 영향 없음.
   */
  _recordExperimentOutcome() {
    if (this._experimentRecorded) return;
    this._experimentRecorded = true;
    if (!this._userId || !this._throttleVariant) return;
    try {
      recordOutcome('throttle-v1', this._userId, {
        variant: this._throttleVariant,
        elapsedMs: Date.now() - this._startedAtMs,
        editCount: this._editCount,
        bufferLen: this._textSent ? (this.currentMessage?.content?.length ?? 0) : 0,
        channelName: this._channelName,
      });
    } catch { /* 응답 차단 금지 */ }
  }

  /**
   * P1-2: 최종 응답에 액션 버튼 행(재생성/요약/다운로드) 부착.
   *
   * 조건:
   *   - currentMessage 존재
   *   - sessionKey 존재 (핸들러가 customId 파싱)
   *   - 응답 본문 ≥ 600자 (짧은 응답에는 버튼 노이즈 회피)
   *   - 이미 components 붙은 메시지(CV2/마커 카드)면 스킵 — 중복 방지
   *
   * 구현:
   *   현재 메시지를 edit({ components: [ActionRow] })로 업데이트.
   *   Discord.js에서 평문 메시지도 components 추가 가능(IsComponentsV2 플래그 없을 때).
   *   실패 시 silent — 채팅 흐름 차단 금지.
   */
  async _appendActionButtons() {
    if (!this.currentMessage || !this.sessionKey) return;
    if (this._markerCardSent) return; // CV2 마커 카드가 이미 전송됨
    const content = this.currentMessage.content || '';
    if (content.length < 600) return; // 짧은 응답 스킵
    // 이미 components가 붙어있으면(예: _wrapInCV2 경로) 중복 방지
    try {
      const existing = this.currentMessage.components;
      if (Array.isArray(existing) && existing.length > 0) return;
    } catch { /* ignore */ }

    try {
      const row = new ActionRowBuilder().addComponents(
        new ButtonBuilder()
          .setCustomId(`regen_${this.sessionKey}`)
          .setLabel('🔄 재생성')
          .setStyle(ButtonStyle.Secondary),
        new ButtonBuilder()
          .setCustomId(`summarize_${this.sessionKey}`)
          .setLabel('📝 요약')
          .setStyle(ButtonStyle.Secondary),
        new ButtonBuilder()
          .setCustomId(`download_${this.sessionKey}`)
          .setLabel('📄 다운로드')
          .setStyle(ButtonStyle.Secondary),
      );
      await this.currentMessage.edit({ content, components: [row] });
      log('debug', 'action buttons attached', {
        sessionKey: this.sessionKey,
        contentLen: content.length,
      });
    } catch (err) {
      log('warn', '_appendActionButtons failed (non-critical)', { error: err.message });
    }
  }

  /**
   * P3-1: CHART_DATA / TABLE_DATA 마커 조기 전송.
   *
   * opt-in: CHART_DATA_EARLY_SEND=1 env.
   * buffer에서 마커 완성분만 제거 + 이미지 렌더 + 채널 전송 (비차단).
   * 조기 전송된 마커 타입은 finalize의 _extractAndSendMarkers에서 skip.
   *
   * 실패 / 비활성 시 silent.
   */
  async _tryEarlyMarkerSend() {
    try {
      const { isEarlySendEnabled, peekCompleteMarker } = await import('./early-marker.js');
      if (!isEarlySendEnabled()) return;
      const hit = peekCompleteMarker(this.buffer, this._markerEarlySent);
      if (!hit) return;
      // 버퍼에서 해당 마커 라인 제거 (이후 finalize가 중복 전송 안 하도록 Set에도 등록)
      this.buffer = this.buffer.replace(hit.raw, '').replace(/^\n/m, '');
      this._markerEarlySent.add(hit.name);
      // 실제 이미지 렌더·전송은 비동기로 띄워 다음 flush 흐름을 막지 않음
      setImmediate(() => this._renderAndSendEarlyMarker(hit).catch(err => {
        log('warn', 'early marker render failed (non-critical)', { name: hit.name, error: err.message });
      }));
    } catch (err) {
      log('debug', '_tryEarlyMarkerSend skipped', { error: err.message });
    }
  }

  /** 조기 마커 렌더링·전송 (CHART_DATA 만 처리 — TABLE은 Chrome 비용 높음). */
  async _renderAndSendEarlyMarker({ name, json }) {
    if (name !== 'CHART_DATA') return;
    const { type = 'line', title, labels = [], datasets = [] } = json;
    const colorPalette = ['#5865f2', '#57f287', '#fee75c', '#ed4245', '#eb459e', '#faa61a'];
    const normalizedDatasets = datasets.map((d, i) => ({
      ...d,
      borderColor: d.borderColor || d.color || colorPalette[i % colorPalette.length],
      backgroundColor: d.backgroundColor || ((d.borderColor || d.color || colorPalette[i % colorPalette.length]) + '33'),
    }));
    const cfg = {
      type, data: { labels, datasets: normalizedDatasets },
      options: {
        plugins: {
          title: title ? { display: true, text: title, color: '#fff' } : undefined,
          legend: { labels: { color: '#fff' } },
        },
        scales: type === 'pie' || type === 'doughnut'
          ? {}
          : { x: { ticks: { color: '#ddd' } }, y: { ticks: { color: '#ddd' } } },
      },
    };
    const canvas = _getChartNodeCanvas();
    const buf = await canvas.renderToBuffer(cfg, 'image/png');
    await this.channel.send({
      content: '-# ⏳ 차트 먼저 보내드립니다 (본문은 계속 작성 중)',
      files: [new AttachmentBuilder(buf, { name: 'chart-early.png' })],
    });
    log('info', 'CHART_DATA early-sent', { channel: this.channel.id });
  }

  /**
   * P1-3: 긴 응답 자동 Thread 생성.
   *
   * 채널 직접 응답 & 본문 ≥ AUTO_THREAD_MIN(기본 3000자)일 때,
   * currentMessage에 딸린 follow-up 스레드를 만들고 후속 대화를 유도.
   * 원본 메시지는 그대로 유지 (스트리밍 결과 훼손 방지).
   *
   * 비활성 조건:
   *   - AUTO_THREAD_ENABLED=0 환경변수
   *   - 이미 Thread 채널(this.channel.isThread())
   *   - 봇 권한 부족 / channel.type != GuildText
   *   - ARTIFACT 경로 대형 본문(8000자+) — board로 이관했으므로 스레드 불필요
   *
   * 실패 시 silent.
   */
  async _maybeCreateThread() {
    if (process.env.AUTO_THREAD_ENABLED === '0') return;
    if (!this.currentMessage || !this.channel) return;
    // 이미 Thread 안이면 중첩 스레드 불가
    try {
      if (typeof this.channel.isThread === 'function' && this.channel.isThread()) return;
    } catch { /* ignore */ }

    const content = this.currentMessage.content || '';
    const MIN = Number(process.env.AUTO_THREAD_MIN || 3000);
    const MAX = Number(process.env.AUTO_THREAD_MAX || 8000);
    // 길이 게이트: MIN 이상 & MAX 미만 (MAX 이상은 artifact로 이관되는 편이 나음)
    if (content.length < MIN || content.length >= MAX) return;

    try {
      // Discord.js: GuildText 채널에서 message.startThread 가능
      if (typeof this.currentMessage.startThread !== 'function') return;
      const rawTitle = (content.split('\n').map(l => l.trim()).find(l => l.length > 10) || '응답').replace(/^[-*#>`]+\s*/, '');
      const threadName = rawTitle.length > 90 ? rawTitle.slice(0, 89) + '…' : rawTitle;
      const thread = await this.currentMessage.startThread({
        name: `💬 ${threadName}`,
        autoArchiveDuration: 60, // 1시간 후 자동 아카이브
        reason: 'Jarvis auto-thread for long response',
      });
      if (!thread) return;
      // 스레드에 후속 대화 유도 메시지
      await thread.send({
        content: [
          '💡 **후속 질문/피드백은 이 스레드에서 이어갈 수 있습니다.**',
          '-# 채널 메인 스크롤을 방해하지 않기 위해 자동 생성된 스레드입니다.',
        ].join('\n'),
      }).catch(() => {});
      log('info', 'auto-thread created', {
        messageId: this.currentMessage.id,
        threadId: thread.id,
        contentLen: content.length,
      });
    } catch (err) {
      log('warn', '_maybeCreateThread failed (non-critical)', { error: err.message });
    }
  }

  /**
   * P0-3: 아티팩트 자동 분리.
   * _extractCodeBlockFiles()이 30줄+ 코드를 파일 첨부로 빼낸 '후' 실행됨.
   * 남은 본문이 여전히 길면(TOTAL_CHARS_THRESHOLD+) board로 업로드하고
   * 카드 링크를 채널에 추가 전송.
   *
   * 비활성 조건:
   *   - ARTIFACT_ENABLED=0 환경변수
   *   - AGENT_API_KEY 미설정
   *   - 실패 시 silent (채팅 흐름 차단하지 않음)
   */
  /**
   * P1-1: 본문에 흩어진 bare citation을 [^N] 각주로 통합 포맷.
   *
   * 대상: `[filename.md]`, `(출처: ...)`, `[[wiki]]` — 2개 이상일 때만 적용.
   * 적용 후: 본문 번호 치환 + 하단 `-# 📚 출처` 블록.
   *
   * 실패 시 silent (citation 미형성도 응답 흐름 차단 금지).
   */
  async _maybeFormatCitations() {
    if (!this.currentMessage) return;
    const content = this.currentMessage.content || '';
    if (!content || content.length < 200) return; // 짧은 응답은 패스
    try {
      const { formatCitations } = await import('./citation-formatter.js');
      const result = formatCitations(content, { minCitations: 2 });
      if (!result.changed) return;
      await this._sendOrEdit(result.content, true);
      log('info', 'citations formatted', {
        count: result.citations.length,
        channel: this.channel.id,
      });
    } catch (err) {
      log('warn', '_maybeFormatCitations failed (non-critical)', { error: err.message });
    }
  }

  async _maybeUploadArtifact() {
    if (!this.currentMessage) return;
    const content = this.currentMessage.content || '';
    if (!content || content.length < 2500) return; // threshold 빠른 게이트 (uploader도 재검증)
    try {
      const { uploadArtifact, renderArtifactCard } = await import('./artifact-uploader.js');
      const artifact = await uploadArtifact({
        content,
        sessionKey: this.sessionKey,
        channelName: this._channelName,
      });
      if (!artifact) return;
      // 카드 전송 — 원본 메시지는 그대로 두고 후속 카드로 링크 안내
      const card = renderArtifactCard(artifact);
      await this.channel.send({
        content: card,
        flags: MessageFlags.SuppressEmbeds,
      });
      log('info', 'artifact card sent', { id: artifact.id, channel: this.channel.id });
    } catch (err) {
      log('warn', '_maybeUploadArtifact failed (non-critical)', { error: err.message });
    }
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

  /** Post-finalize: extract EMBED_DATA:/CHART_DATA:/CV2_DATA:/TABLE_DATA: markers and send as Discord rich embeds or Components V2. */
  async _extractAndSendMarkers() {
    if (!this.currentMessage) return;
    let content = this.currentMessage.content || '';

    let embedJson = null;
    let chartJson = null;
    let cv2Json = null;
    let tableJson = null;

    // 마커 추출 헬퍼: 한 줄 매칭 실패 시 멀티라인 JSON까지 시도
    function _extractMarker(text, prefix) {
      // 1차: 한 줄 매칭 (정상 케이스)
      const singleLine = text.match(new RegExp(`^${prefix}:(.+)$`, 'm'));
      if (singleLine) {
        try {
          const parsed = JSON.parse(singleLine[1]);
          const cleaned = text.replace(new RegExp(`^${prefix}:.+\\n?`, 'm'), '');
          return { json: parsed, content: cleaned };
        } catch { /* 한 줄이지만 파싱 실패 — 멀티라인 시도 */ }
      }
      // 2차: 멀티라인 매칭 (Claude가 JSON을 줄바꿈해서 출력한 경우)
      const multiIdx = text.indexOf(`${prefix}:`);
      if (multiIdx === -1) return null;
      const afterMarker = text.slice(multiIdx + prefix.length + 1);
      // JSON 끝 찾기: 중괄호 균형 맞추기
      let depth = 0; let inStr = false; let escape = false; let end = -1;
      for (let i = 0; i < afterMarker.length; i++) {
        const ch = afterMarker[i];
        if (escape) { escape = false; continue; }
        if (ch === '\\') { escape = true; continue; }
        if (ch === '"') { inStr = !inStr; continue; }
        if (inStr) continue;
        if (ch === '{' || ch === '[') depth++;
        if (ch === '}' || ch === ']') { depth--; if (depth === 0) { end = i; break; } }
      }
      if (end === -1) return null;
      const rawJson = afterMarker.slice(0, end + 1).trim();
      try {
        const parsed = JSON.parse(rawJson);
        const markerFull = text.slice(multiIdx, multiIdx + prefix.length + 1 + end + 1);
        const cleaned = text.replace(markerFull, '').replace(/^\n/m, '');
        return { json: parsed, content: cleaned };
      } catch { return null; }
    }

    const embedResult = _extractMarker(content, 'EMBED_DATA');
    if (embedResult) { embedJson = embedResult.json; content = embedResult.content; }

    // P3-1: 다중 CHART_DATA 지원 — 여러 마커를 순차 추출해서 배열에 적재.
    // 조기 전송(CHART_DATA_EARLY_SEND=1)으로 이미 처리된 경우 finalize는 스킵.
    const chartJsons = [];
    if (!this._markerEarlySent?.has('CHART_DATA')) {
      while (true) {
        const r = _extractMarker(content, 'CHART_DATA');
        if (!r) break;
        chartJsons.push(r.json);
        content = r.content;
        if (chartJsons.length >= 6) break; // MediaGallery + rate limit 한계
      }
      if (chartJsons.length > 0) chartJson = chartJsons[0];
    } else {
      // 남아있는 CHART_DATA 라인이 본문에 혹시 있으면 제거만 수행 (재전송 안 함)
      content = content.replace(/^CHART_DATA:\{[^\n]+\}\s*$/gm, '').replace(/\n{3,}/g, '\n\n');
    }

    const cv2Result = _extractMarker(content, 'CV2_DATA');
    if (cv2Result) { cv2Json = cv2Result.json; content = cv2Result.content; }

    const tableResult = _extractMarker(content, 'TABLE_DATA');
    if (tableResult) { tableJson = tableResult.json; content = tableResult.content; }

    // Mermaid 코드 블록 감지 (```mermaid ... ```)
    let mermaidCode = null;
    const mermaidMatch = content.match(/```mermaid\n([\s\S]+?)```/);
    if (mermaidMatch) {
      mermaidCode = mermaidMatch[1].trim();
      content = content.replace(/```mermaid\n[\s\S]+?```\n?/, '');
    }

    if (!embedJson && !chartJson && !cv2Json && !tableJson && !mermaidCode) return;

    // Collapse excess blank lines left after marker removal
    content = content.replace(/\n{3,}/g, '\n\n').trim();

    try {
      // Edit message: remove raw marker lines (return value 저장 — content 최신화 보장)
      this.currentMessage = await this.currentMessage.edit({ content: content || '\u200b', components: [] });

      // Send EMBED_DATA as Discord rich embed card
      if (embedJson) {
        await this.channel.send({ embeds: [embedJson] });
      }

      // CHART/TABLE/Mermaid 렌더링 결과 버퍼 — MediaGallery로 번들
      let chartImgBuf = null;
      let tableImgBuf = null;
      let mermaidImgBuf = null;
      // P3-1: 추가 차트 버퍼 (2번째부터 N번째)
      const extraChartBufs = [];

      // Send CHART_DATA as Chart.js PNG via chartjs-node-canvas (Chrome 불필요, 순수 Node.js)
      if (chartJson) {
        const chartCacheKey = _cacheKey(chartJson);
        const chartCached = _imageCacheGet(chartCacheKey);
        if (chartCached) {
          log('info', 'CHART_DATA cache hit', { key: chartCacheKey });
          chartImgBuf = chartCached;
        } else {
          try {
            const { type = 'line', title, labels = [], datasets = [] } = chartJson;
            const colorPalette = ['#5865f2', '#57f287', '#fee75c', '#ed4245', '#eb459e', '#faa61a'];
            const normalizedDatasets = datasets.map((d, i) => {
              const color = d.borderColor || d.color || colorPalette[i % colorPalette.length];
              return {
                borderColor: color,
                backgroundColor: d.backgroundColor ?? (type === 'line' ? 'transparent' : color + '99'),
                borderWidth: d.borderWidth ?? 2,
                pointRadius: d.pointRadius ?? 3,
                tension: d.tension ?? 0.3,
                fill: d.fill ?? false,
                ...d,
              };
            });
            const chartConfig = {
              type,
              data: { labels, datasets: normalizedDatasets },
              options: {
                responsive: false,
                animation: false,
                devicePixelRatio: 2,
                plugins: {
                  title: {
                    display: !!title,
                    text: title ?? '',
                    color: '#fff',
                    font: { size: 15, weight: 'bold' },
                    padding: { bottom: 12 },
                  },
                  legend: {
                    labels: { color: '#dbdee1', font: { size: 12 }, padding: 16, usePointStyle: true },
                  },
                },
                scales: (type !== 'pie' && type !== 'doughnut') ? {
                  x: { ticks: { color: '#9b9fa8', font: { size: 11 } }, grid: { color: '#3b3d43' }, border: { color: '#3b3d43' } },
                  y: { ticks: { color: '#9b9fa8', font: { size: 11 } }, grid: { color: '#3b3d43' }, border: { color: '#3b3d43' } },
                } : undefined,
              },
            };
            const renderer = _getChartNodeCanvas();
            const imgBuf = await renderer.renderToBuffer(chartConfig);
            _imageCacheSet(chartCacheKey, imgBuf);
            chartImgBuf = imgBuf;
          } catch (cErr) {
            log('error', 'CHART_DATA render failed', { error: cErr.message });
          }
        }
      }

      // P3-1: 추가 차트(2번째부터) 렌더링 — 같은 파이프라인 사용 (캐시 포함)
      if (chartJsons.length > 1) {
        for (let ci = 1; ci < chartJsons.length; ci++) {
          const extraJson = chartJsons[ci];
          const key = _cacheKey(extraJson);
          const cached = _imageCacheGet(key);
          if (cached) { extraChartBufs.push(cached); continue; }
          try {
            const { type = 'line', title, labels = [], datasets = [] } = extraJson;
            const colorPalette = ['#5865f2', '#57f287', '#fee75c', '#ed4245', '#eb459e', '#faa61a'];
            const normalizedDatasets = datasets.map((d, i) => {
              const color = d.borderColor || d.color || colorPalette[i % colorPalette.length];
              return {
                borderColor: color,
                backgroundColor: d.backgroundColor ?? (type === 'line' ? 'transparent' : color + '99'),
                borderWidth: d.borderWidth ?? 2,
                pointRadius: d.pointRadius ?? 3,
                tension: d.tension ?? 0.3,
                fill: d.fill ?? false,
                ...d,
              };
            });
            const cfg = {
              type,
              data: { labels, datasets: normalizedDatasets },
              options: {
                responsive: false, animation: false, devicePixelRatio: 2,
                plugins: {
                  title: { display: !!title, text: title ?? '', color: '#fff', font: { size: 15, weight: 'bold' }, padding: { bottom: 12 } },
                  legend: { labels: { color: '#dbdee1', font: { size: 12 }, padding: 16, usePointStyle: true } },
                },
                scales: (type !== 'pie' && type !== 'doughnut') ? {
                  x: { ticks: { color: '#9b9fa8', font: { size: 11 } }, grid: { color: '#3b3d43' }, border: { color: '#3b3d43' } },
                  y: { ticks: { color: '#9b9fa8', font: { size: 11 } }, grid: { color: '#3b3d43' }, border: { color: '#3b3d43' } },
                } : undefined,
              },
            };
            const buf = await _getChartNodeCanvas().renderToBuffer(cfg);
            _imageCacheSet(key, buf);
            extraChartBufs.push(buf);
          } catch (eErr) {
            log('error', 'CHART_DATA extra render failed', { idx: ci, error: eErr.message });
          }
        }
      }

      // TABLE_DATA → Discord mobile-friendly 텍스트 (Chrome PNG 제거 — 2026-04-15)
      // Chrome 렌더링 PNG 대신 bullet list 형식으로 전송
      if (tableJson) {
        const { title, columns = [], dataSource = [] } = tableJson;
        if (columns.length > 0 && dataSource.length > 0) {
          try {
            const lines = [];
            if (title) lines.push(`**${title}**`);
            // 헤더: 첫 컬럼 외 나머지 컬럼명 표시
            const restHeaders = columns.slice(1).map(c => c.title ?? c.dataIndex ?? '').join(' · ');
            if (restHeaders) lines.push(`*${restHeaders}*`);
            lines.push('─'.repeat(24));
            for (const row of dataSource) {
              const firstCol = columns[0];
              const firstVal = firstCol ? String(row[firstCol.dataIndex] ?? '') : '';
              const restVals = columns.slice(1).map(c => String(row[c.dataIndex] ?? '')).join(' · ');
              lines.push(restVals ? `- **${firstVal}** · ${restVals}` : `- ${firstVal}`);
            }
            const tableText = lines.join('\n').slice(0, 2000); // Discord 2000자 제한
            await this.channel.send({ content: tableText });
            this._markerCardSent = true;
            log('info', 'TABLE_DATA sent as text', { rows: dataSource.length });
          } catch (tErr) {
            log('error', 'TABLE_DATA text render failed', { error: tErr.message });
          }
        }
      }

      // Mermaid diagram rendering via Chrome singleton (same as TABLE_DATA)
      if (mermaidCode) {
        const mermaidCacheKey = _cacheKey({ mermaid: mermaidCode });
        const mermaidCached = _imageCache.get(mermaidCacheKey);
        if (mermaidCached) {
          log('info', 'Mermaid cache hit', { key: mermaidCacheKey });
          mermaidImgBuf = mermaidCached;
        } else {
          let page = null;
          try {
            const browser = await _getChromeBrowser();
            page = await browser.newPage();
            await page.setViewport({ width: 1280, height: 900, deviceScaleFactor: 2 });
            const escaped = mermaidCode.replace(/</g, '&lt;').replace(/>/g, '&gt;');
            const html = `<!DOCTYPE html><html><head><meta charset="utf-8">
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"><\/script>
</head><body style="background:#313338;margin:0;padding:24px;display:inline-block;min-width:200px;">
<pre class="mermaid">${escaped}</pre>
<script>
mermaid.initialize({
  startOnLoad:true, theme:'dark',
  themeVariables:{
    darkMode:true, background:'#313338',
    primaryColor:'#5865f2', primaryTextColor:'#dbdee1',
    primaryBorderColor:'#4752c4', lineColor:'#9b9fa8',
    secondaryColor:'#2b2d31', tertiaryColor:'#1e1f22',
    noteBkgColor:'#2b2d31', noteTextColor:'#dbdee1'
  }
});
<\/script></body></html>`;
            await page.setContent(html, { waitUntil: 'networkidle0' });
            await page.waitForSelector('.mermaid svg', { timeout: 15000 });
            const el = await page.$('.mermaid');
            const imgBuf = await el.screenshot({ type: 'png' });
            _imageCache.set(mermaidCacheKey, imgBuf);
            mermaidImgBuf = imgBuf;
          } catch (mErr) {
            log('error', 'Mermaid render failed', { error: mErr.message });
            _chromeBrowser = null;
          } finally {
            if (page) await page.close().catch(() => {});
          }
        }
      }

      // CHART/TABLE/Mermaid 이미지 → MediaGallery + 버튼으로 단일 메시지 전송
      if (chartImgBuf || tableImgBuf || mermaidImgBuf || extraChartBufs.length > 0) {
        try {
          const imgContainer = new ContainerBuilder();
          const gallery = new MediaGalleryBuilder();
          const imgFiles = [];
          if (chartImgBuf) {
            gallery.addItems(new MediaGalleryItemBuilder().setURL('attachment://chart.png'));
            imgFiles.push(new AttachmentBuilder(chartImgBuf, { name: 'chart.png' }));
          }
          // P3-1: 추가 차트 MediaGallery 아이템 추가 (chart-2.png, chart-3.png, ...)
          for (let i = 0; i < extraChartBufs.length; i++) {
            const name = `chart-${i + 2}.png`;
            gallery.addItems(new MediaGalleryItemBuilder().setURL(`attachment://${name}`));
            imgFiles.push(new AttachmentBuilder(extraChartBufs[i], { name }));
          }
          if (tableImgBuf) {
            gallery.addItems(new MediaGalleryItemBuilder().setURL('attachment://table.png'));
            imgFiles.push(new AttachmentBuilder(tableImgBuf, { name: 'table.png' }));
          }
          if (mermaidImgBuf) {
            gallery.addItems(new MediaGalleryItemBuilder().setURL('attachment://diagram.png'));
            imgFiles.push(new AttachmentBuilder(mermaidImgBuf, { name: 'diagram.png' }));
          }
          imgContainer.addMediaGalleryComponents(gallery);
          const imgRow = this._finalActionRow();
          if (imgRow) {
            imgContainer.addSeparatorComponents(new SeparatorBuilder());
            imgContainer.addActionRowComponents(imgRow);
          }
          await this.channel.send({
            files: imgFiles,
            components: [imgContainer],
            flags: MessageFlags.IsComponentsV2,
          });
          this._markerCardSent = true;
        } catch (imgErr) {
          log('error', 'MediaGallery send failed, falling back to raw files', { error: imgErr.message });
          // 폴백: 개별 파일 전송
          if (chartImgBuf) await this.channel.send({ files: [new AttachmentBuilder(chartImgBuf, { name: 'chart.png' })] });
          // P3-1 폴백: 추가 차트도 개별 전송
          for (let i = 0; i < extraChartBufs.length; i++) {
            const name = `chart-${i + 2}.png`;
            await this.channel.send({ files: [new AttachmentBuilder(extraChartBufs[i], { name })] });
          }
          if (tableImgBuf) await this.channel.send({ files: [new AttachmentBuilder(tableImgBuf, { name: 'table.png' })] });
          if (mermaidImgBuf) await this.channel.send({ files: [new AttachmentBuilder(mermaidImgBuf, { name: 'diagram.png' })] });
        }
      }

      // Send CV2_DATA as Discord Components V2
      // 옵션: thumbnail URL 있으면 첫 블록을 SectionBuilder로 렌더링
      if (cv2Json) {
        const { color = 5763719, blocks = [], thumbnail } = cv2Json;
        if (blocks.length > 0) {
          const container = new ContainerBuilder().setAccentColor(color);
          blocks.forEach((block, i) => {
            // block이 {type, content} 객체 형식이면 content 추출, 아니면 문자열 그대로 사용
            const blockText = (block && typeof block === 'object' && typeof block.content === 'string')
              ? block.content
              : String(block);
            // 첫 번째 블록 + thumbnail 있으면 SectionBuilder 사용
            if (i === 0 && thumbnail) {
              try {
                const section = new SectionBuilder()
                  .addTextDisplayComponents(new TextDisplayBuilder().setContent(blockText))
                  .setThumbnailAccessory(
                    new ThumbnailBuilder().setURL(thumbnail).setDescription('thumbnail')
                  );
                container.addSectionComponents(section);
              } catch {
                // SectionBuilder 실패 시 일반 TextDisplay로 폴백
                container.addTextDisplayComponents(new TextDisplayBuilder().setContent(blockText));
              }
            } else {
              container.addTextDisplayComponents(new TextDisplayBuilder().setContent(blockText));
            }
            if (i < blocks.length - 1) {
              container.addSeparatorComponents(new SeparatorBuilder());
            }
          });
          const cv2Row = this._finalActionRow();
          if (cv2Row) {
            container.addSeparatorComponents(new SeparatorBuilder());
            container.addActionRowComponents(cv2Row);
          }
          await this.channel.send({
            components: [container],
            flags: MessageFlags.IsComponentsV2,
          });
          this._markerCardSent = true;
        }
      }
    } catch (err) {
      log('error', '_extractAndSendMarkers failed', { error: err.message });
      // Stop 버튼 잔류 방지: 에러 시에도 components 제거
      try {
        if (this.currentMessage) {
          await this.currentMessage.edit({ components: [] });
        }
      } catch { /* best effort */ }
    }
  }

  /**
   * Post-finalize: plain text 응답을 Discord Components V2 ContainerBuilder 카드로 래핑.
   * 스트리밍 중에는 text로 유지, finalize 후 delete+resend 방식.
   * _extractAndSendMarkers() 이후 호출되므로 currentMessage.content는 마커 제거된 순수 텍스트.
   *
   * 래핑 조건 (flash UX 최소화):
   *   - 500자 미만 + ## 제목 없음 → 스킵 (텍스트 그대로, flash 없음)
   *   - 마커 카드 전송됐고 남은 텍스트 300자 미만 → 스킵 (마커 카드가 메인 콘텐츠)
   *
   * 버튼 조건 (button bloat 방지):
   *   - 마커 카드 없고 1000자 이상일 때만 부착
   *
   * 4000자 제한 대응: 단락(\n\n) → 줄(\n) → 단어 순으로 스마트 분할.
   * 청크마다 별도 channel.send() (동일 컨테이너 내 다중 TextDisplay는 합산 제한에 걸림).
   * 버튼은 마지막 청크에만 부착.
   */
  async _wrapInCV2() {
    // 자동 래핑 비활성화 — Discord 응답 평문 markdown 전환 정책 (2026-04-15)
    // 명시적 CV2_DATA 마커가 있을 때만 CV2 사용. streaming 레이어 자동 래핑 금지.
    return;
    if (!this.currentMessage) return;
    const rawContent = (this.currentMessage.content || '').replace(/ ▌$/, '').trim();
    if (!rawContent || rawContent === '\u200b' || rawContent.length < 10) return;

    // 래핑 스킵 조건 — flash 유발 최소화
    const hasHeadings = /^#{1,4} /m.test(rawContent);
    const isLongContent = rawContent.length >= 500;
    if (!hasHeadings || !isLongContent) return; // 500자 미만 OR ## 제목 없음 → 텍스트 유지

    // 마커 카드가 이미 있고 남은 텍스트가 짧으면 → 래핑 스킵 (마커 카드가 메인)
    if (this._markerCardSent && rawContent.length < 300) return;

    // 버튼: 마커 카드 없고 충분히 긴 응답에만 (button bloat 방지)
    const addButtons = !!(this.sessionKey && !this._markerCardSent && rawContent.length >= 1000);

    try {
      const chunks = _splitIntoChunks(_preprocessMarkdown(rawContent));
      const originalMessage = this.currentMessage; // 전송 성공 후 삭제를 위해 참조 보존
      // CV2 카드 전송 먼저 → 모두 성공하면 원본 삭제 (순서 역전으로 유실 방지)
      for (let i = 0; i < chunks.length; i++) {
        const isLast = i === chunks.length - 1;
        const container = new ContainerBuilder().setAccentColor(0x5865f2); // Discord blurple
        container.addTextDisplayComponents(new TextDisplayBuilder().setContent(chunks[i]));
        if (isLast && addButtons) {
          const plainRow = this._finalActionRow();
          if (plainRow) {
            container.addSeparatorComponents(new SeparatorBuilder());
            container.addActionRowComponents(plainRow);
          }
        }
        const sent = await this.channel.send({
          components: [container],
          flags: MessageFlags.IsComponentsV2,
        });
        if (isLast) this.currentMessage = sent;
      }
      // 모든 CV2 전송 성공 후 원본 삭제 (실패 시 원본 유지됨)
      try { await originalMessage.delete(); } catch { /* 이미 삭제됐거나 권한 없음 */ }
    } catch (err) {
      log('error', '_wrapInCV2 failed', { error: err.message });
    }
  }
}