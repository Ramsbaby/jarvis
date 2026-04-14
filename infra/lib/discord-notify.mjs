/**
 * discord-notify.mjs — Discord 메시지 전송 SSoT
 *
 * 왜 이 파일이 존재하는가:
 *   sendDiscord / discordSend / sendDiscordMsg 3개 함수명이 5개 파일에 각자
 *   구현되어 있었다. 구현도 다 달랐다:
 *   - job-apply.mjs: monitoring.json `jarvis` 키만 참조, 청킹 없음
 *   - oss-manager.mjs: spawnSync curl, channelKey 있음, 청킹 없음
 *   - job-crawl.mjs: .env fallback + bot token 이중 구조
 *   - job-match.mjs: 2000자 줄경계 청킹 (가장 완성도 높음)
 *   이 파일이 하나의 정답이다.
 *
 * 사용법:
 *   import { discordSend } from '../lib/discord-notify.mjs';
 *   await discordSend('메시지 내용', 'jarvis-system');
 *   await discordSend(longText, 'jarvis-career', { username: 'Bot' });
 */

import { readFileSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const DISCORD_CHAR_LIMIT = 1990; // 2000 - 여유 10자

/**
 * monitoring.json 에서 webhook URL 을 읽는다.
 * channelKey → webhooks[channelKey] 순으로 조회.
 * 없으면 null.
 */
function resolveWebhook(channelKey = 'jarvis-system') {
  try {
    const monitoring = JSON.parse(
      readFileSync(join(BOT_HOME, 'config', 'monitoring.json'), 'utf-8'),
    );
    return monitoring.webhooks?.[channelKey]
      ?? monitoring.webhook?.url
      ?? null;
  } catch {
    return null;
  }
}

/**
 * 2000자 초과 텍스트를 줄 경계에서 청킹한다.
 * Discord 2000자 제한 준수.
 */
function chunkContent(content) {
  const chunks = [];
  let pos = 0;
  while (pos < content.length) {
    let end = pos + DISCORD_CHAR_LIMIT;
    if (end < content.length) {
      // 줄 경계에서 자르기
      const cut = content.lastIndexOf('\n', end);
      if (cut > pos) end = cut + 1;
    }
    chunks.push(content.slice(pos, end));
    pos = end;
  }
  return chunks;
}

/**
 * Discord 채널에 메시지를 전송한다.
 *
 * @param {string}  content     - 전송할 메시지 (2000자 초과 시 자동 청킹)
 * @param {string}  channelKey  - monitoring.json webhooks 키 (기본: 'jarvis-system')
 * @param {object}  opts
 * @param {string}  [opts.username] - 표시될 봇 이름 (기본: 'Jarvis')
 * @param {number}  [opts.chunkDelayMs] - 청크 간 지연(ms) (기본: 500)
 */
export async function discordSend(
  content,
  channelKey = 'jarvis-system',
  { username = 'Jarvis', chunkDelayMs = 500 } = {},
) {
  const webhook = resolveWebhook(channelKey);
  if (!webhook) {
    console.warn(`[discord-notify] webhook 미설정 (${channelKey}) — monitoring.json 확인`);
    return;
  }

  const chunks = chunkContent(String(content));
  for (let i = 0; i < chunks.length; i++) {
    try {
      const res = await fetch(webhook, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ content: chunks[i], username }),
      });
      if (!res.ok) {
        console.warn(`[discord-notify] 전송 실패 (${channelKey}): HTTP ${res.status}`);
      }
    } catch (e) {
      console.error(`[discord-notify] 전송 오류:`, e.message);
    }
    if (i < chunks.length - 1) {
      await new Promise(r => setTimeout(r, chunkDelayMs));
    }
  }
}
