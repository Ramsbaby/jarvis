/**
 * session-handoff.js — Structured Session State Transfer
 *
 * Anthropic 하네스 Sensors 패턴: 세션 간 구조화된 상태 핸드오프.
 * compaction summary(자유 형식 마크다운)와 달리, 구조화된 JSON으로
 * 토픽/결정사항/미완료 태스크를 정확히 전달.
 *
 * 저장소: ~/.jarvis/state/session-handoffs/{sessionKey}.json
 *
 * 사용:
 *   saveHandoff(sessionKey, data)  — 세션 종료 시
 *   loadHandoff(sessionKey)        — 세션 시작 시
 *   formatHandoffForPrompt(data)   — 시스템 프롬프트 주입용 마크다운
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync, renameSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const HANDOFF_DIR = join(BOT_HOME, 'state', 'session-handoffs');
const MAX_HANDOFF_AGE_MS = 24 * 60 * 60_000; // 24시간 초과 핸드오프는 stale

/**
 * 세션 핸드오프 저장.
 * @param {string} sessionKey — 채널-사용자 키
 * @param {object} data
 * @param {string} data.lastTopic — 마지막 대화 주제
 * @param {string[]} [data.keyDecisions] — 이번 세션에서 내린 결정사항
 * @param {string[]} [data.pendingTasks] — 미완료 작업
 * @param {string[]} [data.toolsUsed] — 사용한 주요 도구
 * @param {object} [data.context] — 추가 맥락 (자유 형식)
 */
export function saveHandoff(sessionKey, data) {
  try {
    mkdirSync(HANDOFF_DIR, { recursive: true });
    const filePath = join(HANDOFF_DIR, `${_sanitize(sessionKey)}.json`);
    const entry = {
      sessionKey,
      savedAt: new Date().toISOString(),
      lastTopic: data.lastTopic || '',
      keyDecisions: data.keyDecisions || [],
      pendingTasks: data.pendingTasks || [],
      toolsUsed: data.toolsUsed || [],
      context: data.context || null,
    };
    // Atomic write
    const tmp = filePath + '.tmp';
    writeFileSync(tmp, JSON.stringify(entry, null, 2), 'utf-8');
    renameSync(tmp, filePath);
  } catch { /* handoff 실패는 세션을 차단하지 않음 */ }
}

/**
 * 세션 핸드오프 로드.
 * @param {string} sessionKey
 * @returns {object|null} — 핸드오프 데이터 또는 null (없거나 stale)
 */
export function loadHandoff(sessionKey) {
  try {
    const filePath = join(HANDOFF_DIR, `${_sanitize(sessionKey)}.json`);
    if (!existsSync(filePath)) return null;
    const raw = readFileSync(filePath, 'utf-8');
    const data = JSON.parse(raw);
    // Stale 체크: 24시간 초과 핸드오프는 무시
    const age = Date.now() - new Date(data.savedAt).getTime();
    if (age > MAX_HANDOFF_AGE_MS) return null;
    return data;
  } catch {
    return null;
  }
}

/**
 * 핸드오프 데이터를 시스템 프롬프트에 주입할 마크다운으로 포맷.
 * @param {object} data — loadHandoff() 반환값
 * @returns {string} — 프롬프트 주입용 텍스트 (빈 문자열이면 주입 불필요)
 */
export function formatHandoffForPrompt(data) {
  if (!data) return '';
  const lines = ['--- 이전 세션 핸드오프 ---'];

  if (data.lastTopic) {
    lines.push(`주제: ${data.lastTopic}`);
  }
  if (data.keyDecisions?.length) {
    lines.push(`결정사항: ${data.keyDecisions.join('; ')}`);
  }
  if (data.pendingTasks?.length) {
    lines.push(`미완료: ${data.pendingTasks.join('; ')}`);
  }

  // 최대 500자 (프롬프트 예산 보호, 서로게이트 페어 안전 처리)
  let result = lines.join('\n');
  if (result.length > 500) {
    result = result.slice(0, 497);
    // lone surrogate 제거 (UTF-16 안전)
    result = result.replace(/[\uD800-\uDBFF]$/g, '');
    result += '...';
  }
  return result;
}

// --- internal ---

function _sanitize(key) {
  return key.replace(/[^a-zA-Z0-9_-]/g, '_');
}
