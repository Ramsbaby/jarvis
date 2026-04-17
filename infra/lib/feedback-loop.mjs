/**
 * feedback-loop.mjs — Phase 0.5 (표면 통합 학습 루프)
 *
 * Jarvis 의 여러 표면(Discord 봇 / Claude Code CLI / macOS 앱)이 동일한 피드백
 * 감지·저장 로직을 공유하기 위한 SSoT 모듈.
 *
 * 설계 원칙:
 *   1. 감지(detectFeedback) + 저장(processFeedback)은 표면과 무관
 *   2. 모든 write는 `source` 태그 필수 — 주간 감사로 불균형 감지
 *   3. RAG sync 같은 부수효과는 선택적 콜백(onCorrectionSaved)로 분리
 *   4. CLI/macOS 앱이 동일 owner로 동작할 때 같은 userMemory 파일에 수렴
 *
 * 호출처:
 *   - Discord: infra/discord/lib/claude-runner.js (re-export)
 *   - CLI:     infra/bin/feedback-loop-cli.mjs (stdin JSON 래퍼) ← sensor-prompt.sh
 *   - macOS:   (간접) `/remember` 스킬이 MCP wiki_add_fact 호출 → 위키 경로로 병합
 */

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { userMemory } from './user-memory.mjs';

const HOME = homedir();
const BOT_HOME = process.env.BOT_HOME || join(HOME, '.jarvis');

// Unicode lone surrogate 제거 — JSON 직렬화 시 invalid high/low surrogate 방지
export function sanitizeUnicode(str) {
  if (typeof str !== 'string') return str;
  return str.replace(/[\uD800-\uDFFF]/g, (match, offset, string) => {
    const code = match.charCodeAt(0);
    if (code >= 0xD800 && code <= 0xDBFF) {
      const next = string.charCodeAt(offset + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) return match;
      return '';
    }
    const prev = offset > 0 ? string.charCodeAt(offset - 1) : NaN;
    if (prev >= 0xD800 && prev <= 0xDBFF) return match;
    return '';
  });
}

/**
 * 오너 Discord ID 조회 — CLI/macOS 등 유저ID가 없는 표면에서 기본값으로 사용.
 * 모든 표면이 같은 ID로 수렴 → 같은 userMemory 파일 공유.
 */
export function getOwnerUserId() {
  try {
    const profiles = JSON.parse(readFileSync(join(BOT_HOME, 'config', 'user_profiles.json'), 'utf-8'));
    return profiles?.owner?.discordId ?? null;
  } catch { return null; }
}

/**
 * Detect user feedback signals from message text.
 * @returns {{type: 'remember'|'positive'|'negative'|'correction', fact?: string} | null}
 */
export function detectFeedback(text) {
  if (typeof text !== 'string' || !text.trim()) return null;
  const t = text.trim().toLowerCase();

  // 명시적 기억 명령
  const rememberPrefixMatch = text.match(/^(기억해:|\/remember\s+|기억해줘[,:]?\s*|메모해줘[,:]?\s*|저장해줘[,:]?\s*|알아둬[,:]?\s*)/i);
  if (rememberPrefixMatch) {
    const fact = text.slice(rememberPrefixMatch[0].length).trim();
    return fact ? { type: 'remember', fact } : null;
  }

  // 긍정 피드백 (15자 이하)
  if (t.length <= 15 && /좋아|잘했어|이게 맞아|완벽|ㄱㅌ|굿|정확해|완벽해|고마워|감사해|도움됐어|덕분에|최고|ㄳ|땡큐/.test(t)) {
    return { type: 'positive' };
  }

  // 부정 피드백 (15자 이하)
  if (t.length <= 15 && /별로야|틀렸어|다시 해|아니야|이건 아닌|잘못됐어|별로|틀림/.test(t)) {
    return { type: 'negative' };
  }

  // 교정 패턴
  const corrMatch = text.match(/^(앞으로는|다음부터는|이제부터는|다음엔|이다음엔)\s+(.+)/);
  if (corrMatch) {
    return { type: 'correction', fact: corrMatch[2] };
  }

  return null;
}

/**
 * 피드백 감지 + userMemory 반영.
 * @param {object} opts
 * @param {string} opts.userId
 * @param {string} opts.text
 * @param {string} opts.source — "discord-bot" | "claude-code-cli" | "claude-app" 등
 * @param {(userId: string) => Promise<void>} [opts.onFactSaved] — remember 저장 후 콜백 (RAG sync 등)
 * @param {(userId: string) => Promise<void>} [opts.onCorrectionSaved] — correction 저장 후 콜백
 * @returns {{fb: object|null, factChanged: boolean, correctionChanged: boolean}}
 */
export function processFeedback({ userId, text, source, onFactSaved, onCorrectionSaved }) {
  const fb = detectFeedback(text);
  if (!fb || !userId) return { fb: null, factChanged: false, correctionChanged: false };

  let factChanged = false;
  let correctionChanged = false;

  if (fb.type === 'remember' && fb.fact) {
    factChanged = userMemory.addFact(userId, fb.fact, source);
    if (factChanged && typeof onFactSaved === 'function') {
      Promise.resolve(onFactSaved(userId)).catch(() => { /* non-blocking */ });
    }
  } else if (fb.type === 'correction' && fb.fact) {
    correctionChanged = userMemory.addCorrection(userId, sanitizeUnicode(fb.fact), source);
    if (correctionChanged && typeof onCorrectionSaved === 'function') {
      Promise.resolve(onCorrectionSaved(userId)).catch(() => { /* non-blocking */ });
    }
  }
  // positive/negative는 userMemory 변경 없음 — 관측 전용 (센서 JSONL에서 집계)

  return { fb, factChanged, correctionChanged };
}

/**
 * 프롬프트 주입용 corrections 텍스트. CLI의 SessionStart 훅에서 쓰임.
 * Discord는 userMemory.getRelevantMemories()를 직접 호출하므로 이 함수는 CLI 전용.
 * @returns {string} 비어있으면 빈 문자열
 */
export function loadCorrectionsForContext(userId, maxItems = 10) {
  if (!userId) return '';
  try {
    const data = userMemory.get(userId);
    if (!Array.isArray(data.corrections) || data.corrections.length === 0) return '';
    const norm = (c) => (typeof c === 'string' ? c : c?.text ?? '');
    const recent = data.corrections.slice(-maxItems).map(norm).filter(Boolean);
    if (recent.length === 0) return '';
    return '🧠 오너 교정 (지키기): ' + recent.join(' | ');
  } catch { return ''; }
}
