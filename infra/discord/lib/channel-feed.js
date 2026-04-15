/**
 * channel-feed.js — 채널별 발신 메시지 피드
 *
 * 봇/크론/알람이 채널에 보낸 메시지를 ~/.jarvis/state/channel-feed/{name}.jsonl에 기록.
 * 사용자가 메시지를 보내면 claude-runner.js가 최근 N개를 시스템 프롬프트에 주입.
 * → "방금 크론이 보낸 알람이 뭐야?" 같은 질문에 재질문 없이 컨텍스트 보유.
 *
 * 발신자 구분 (from):
 *   'jarvis' — Claude 대화 응답
 *   'cron'   — nexus discord_send (크론/스케줄 메시지)
 *   'alert'  — AlertBatcher 배치 알람
 *   'system' — 봇 라이프사이클 (재시작 알림 등)
 */

import { appendFileSync, readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const FEED_DIR = join(homedir(), '.jarvis', 'state', 'channel-feed');
const MAX_ENTRIES = 30;  // 채널별 최대 보관 줄 수 (롤링)
const MAX_TEXT_LEN = 2000;

function feedPath(channelName) {
  return join(FEED_DIR, `${channelName}.jsonl`);
}

/**
 * 채널 피드에 메시지 추가.
 * @param {string} channelName  Discord 채널명 (e.g. 'jarvis-ceo', 'jarvis')
 * @param {string} from         발신자 구분
 * @param {string} text         메시지 내용
 */
export function appendFeed(channelName, from, text) {
  if (!channelName || !text?.trim()) return;
  try {
    mkdirSync(FEED_DIR, { recursive: true });
    const now = new Date();
    const kst = new Date(now.getTime() + 9 * 3600 * 1000);
    const ts = kst.toISOString().replace('T', ' ').slice(0, 16) + ' KST';
    const entry = JSON.stringify({ ts, from, text: text.slice(0, MAX_TEXT_LEN) }) + '\n';
    appendFileSync(feedPath(channelName), entry, 'utf-8');
    _trimFeed(channelName);
  } catch { /* 피드 실패가 메인 플로우를 막으면 안 됨 */ }
}

/**
 * 채널 피드 최근 N개 로드.
 * @param {string} channelName
 * @param {number} limit  최근 N개 (기본 15)
 * @returns {Array<{ts: string, from: string, text: string}>}
 */
export function loadFeed(channelName, limit = 15) {
  try {
    const fp = feedPath(channelName);
    if (!existsSync(fp)) return [];
    const lines = readFileSync(fp, 'utf-8').split('\n').filter(Boolean);
    return lines.slice(-limit).map(l => JSON.parse(l));
  } catch { return []; }
}

/**
 * 채널 피드를 시스템 프롬프트용 텍스트로 변환.
 * @param {string} channelName
 * @param {number} limit
 * @returns {string|null}
 */
export function buildChannelFeedSection(channelName, limit = 15) {
  const entries = loadFeed(channelName, limit);
  if (entries.length === 0) return null;

  const fromLabel = { jarvis: 'Jarvis 응답', cron: '크론 알림', alert: '시스템 알람', system: '봇 시스템' };
  const lines = entries.map(e => `[${e.ts}][${fromLabel[e.from] ?? e.from}] ${e.text}`);

  return [
    `--- 최근 채널 활동 (#${channelName}) ---`,
    '이 채널에 최근 전송된 메시지입니다. 사용자가 "크론이 보낸 거", "방금 온 알람", "아까 그 메시지", "이게 뭐야" 등을 물으면 이 내용을 참조하세요. 재질문 없이 답하세요.',
    ...lines,
    '--- 채널 활동 끝 ---',
  ].join('\n');
}

function _trimFeed(channelName) {
  try {
    const fp = feedPath(channelName);
    const lines = readFileSync(fp, 'utf-8').split('\n').filter(Boolean);
    if (lines.length > MAX_ENTRIES) {
      writeFileSync(fp, lines.slice(-MAX_ENTRIES).join('\n') + '\n', 'utf-8');
    }
  } catch { /* ignore */ }
}
