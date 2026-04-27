/**
 * anger-detector.mjs — 사용자 분노 키워드 즉시 학습 트리거 (Harness P2)
 *
 * 역할: 디스코드 turn에서 사용자 발화에 분노/지적 키워드가 감지되면
 * direct-fact 모드로 즉시 learned-mistakes.md에 등재하고, 다음 turn에서
 * "🚨 직전 정정" 섹션으로 강제 주입할 수 있도록 anger-signals.jsonl에 기록.
 *
 * 일반 mistake-extractor 흐름은 Haiku 호출 + 03:15 KST cron이라 즉시성 부족.
 * 분노 발화는 명시적 정정 신호이므로 LLM 추출 없이 휴리스틱으로 즉시 등재.
 *
 * 설계 의사결정:
 * - 키워드는 한국어 분노/지적 표현 위주. 일상 욕설 false positive 줄이기 위해
 *   "Jarvis/자비스" 또는 "왜/뭐가/이거" 컨텍스트가 함께 있을 때만 매치.
 * - direct-fact 모드는 cooldown·budget 가드 우회 (이미 mistake-extractor 내부 보장).
 * - anger-signals.jsonl은 24h retention. prompt-sections.js가 24h 이내 최신 1건만 주입.
 */

import { appendFileSync, mkdirSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { spawn } from 'node:child_process';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const SIGNALS_FILE = join(BOT_HOME, 'state', 'anger-signals.jsonl');
const EXTRACTOR_SCRIPT = join(homedir(), 'jarvis/infra/scripts/mistake-extractor.mjs');

// 분노/지적 키워드 — 한국어 위주
// false positive 회피: 단독 욕설은 매치하지 않고, 자비스 지칭 또는 "왜/뭐가/이거" 컨텍스트 필요
const ANGER_KEYWORDS = [
  '개병신', '병신같', '쓰레기', '쓰레기답변', '미친', '미친새끼', '미친새낀',
  '뭐가 잘못', '개판', '형편없', '멍청', '멍청한', '답답해',
  '왜이래', '왜 이래', '왜이렇', '왜 이렇',
  '틀렸어', '틀린', '엉터리', '이딴', '이따위',
  '제대로 해', '제대로해', '다시 해', '다시해',
  '짜증', '진짜 너', '너 진짜',
];

const CONTEXT_HINTS = [
  '자비스', 'Jarvis', 'jarvis', '답변', '응답', '말', '얘기', '소리',
  '왜', '뭐', '이거', '이게', '뭔', '뭘',
];

/**
 * 사용자 발화에서 분노 신호 감지.
 * @param {string} text - 사용자 원문
 * @returns {{matched: boolean, keyword: string|null}}
 */
export function detectAnger(text) {
  if (!text || typeof text !== 'string') return { matched: false, keyword: null };
  if (text.length < 4) return { matched: false, keyword: null };

  const hit = ANGER_KEYWORDS.find(k => text.includes(k));
  if (!hit) return { matched: false, keyword: null };

  // 컨텍스트 hint 함께 있어야 매치 — 일상 욕설 false positive 방지
  // (단, 명백한 자비스 지칭 키워드는 단독 매치 허용)
  const STRONG_KEYWORDS = ['쓰레기답변', '개병신', '병신같', '왜이래', '왜 이래', '제대로 해', '다시 해'];
  const isStrong = STRONG_KEYWORDS.some(k => text.includes(k));
  if (isStrong) return { matched: true, keyword: hit };

  const hasContext = CONTEXT_HINTS.some(h => text.includes(h));
  if (!hasContext) return { matched: false, keyword: null };

  return { matched: true, keyword: hit };
}

/**
 * 분노 신호 기록 + direct-fact 모드로 mistake-extractor 즉시 호출.
 * @param {object} sig
 * @param {string} sig.userId
 * @param {string} sig.channelId
 * @param {string} sig.keyword - 매치된 키워드
 * @param {string} sig.userText - 사용자 원문
 * @param {string} sig.assistantText - 직전 자비스 응답
 * @param {string} sig.sessionKey
 */
export async function recordAngerSignal(sig) {
  try {
    mkdirSync(join(BOT_HOME, 'state'), { recursive: true });

    // 1. anger-signals.jsonl append (prompt-sections.js가 다음 turn에 읽을 신호)
    // 동시에 48h 이상 entry는 prune (rotation 부재 R3 해소 — 메모리 폭발 방지)
    const ts = new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' });
    const tsISO = new Date(Date.now() + 9 * 3600_000).toISOString().replace('Z', '+09:00');
    const signal = {
      ts: tsISO,
      userId: sig.userId,
      channelId: sig.channelId,
      keyword: sig.keyword,
      userText: (sig.userText || '').slice(0, 400),
      assistantText: (sig.assistantText || '').slice(0, 600),
      sessionKey: sig.sessionKey,
    };
    pruneAndAppendSignal(signal);

    // 2. direct-fact 모드로 mistake-extractor 즉시 호출 (cooldown·budget 우회)
    if (!existsSync(EXTRACTOR_SCRIPT)) return;
    const fact = [{
      pattern: `사용자 분노 신호 감지 (${sig.keyword}) — 직전 응답 정정 필요`,
      actual: (sig.userText || '').slice(0, 100),
      evidence: `User(${ts}): ${(sig.userText || '').slice(0, 80)} | Jarvis 직전: ${(sig.assistantText || '').slice(0, 80)}`,
      correction: '다음 응답 작성 전 anger-signals.jsonl 24h 이내 최신 1건을 system prompt에 주입하여 같은 편향 재발 차단',
    }];

    const child = spawn(process.execPath, [EXTRACTOR_SCRIPT, '--direct-fact'], {
      detached: true,
      stdio: ['pipe', 'ignore', 'ignore'],
      env: { ...process.env, DISCORD_TURN_SOURCE: '1' },
    });
    if (child.stdin) {
      child.stdin.write(JSON.stringify(fact));
      child.stdin.end();
    }
    child.unref();
  } catch (err) {
    // best-effort — 분노 감지 실패가 메인 흐름 차단하지 않도록
    process.stderr.write(`[anger-detector] recordAngerSignal failed: ${err.message}\n`);
  }
}

/**
 * 48h 이상 entry는 제거하고 새 신호 append.
 * 1년 누적 ~50MB readFileSync 부하 방지 (R3 해소).
 */
function pruneAndAppendSignal(newSignal) {
  const RETENTION_H = 48;
  let kept = [];
  if (existsSync(SIGNALS_FILE)) {
    try {
      const lines = readFileSync(SIGNALS_FILE, 'utf-8').trim().split('\n').filter(Boolean);
      for (const line of lines) {
        try {
          const o = JSON.parse(line);
          if (!o.ts) continue;
          const ms = new Date(o.ts.replace('+09:00', 'Z')).getTime() - 9 * 3600_000;
          const ageH = (Date.now() - ms) / 3600_000;
          if (ageH <= RETENTION_H) kept.push(line);
        } catch { /* malformed line skip */ }
      }
    } catch { /* read failure → fresh start */ }
  }
  kept.push(JSON.stringify(newSignal));
  writeFileSync(SIGNALS_FILE, kept.join('\n') + '\n');
}

/**
 * 24h 이내 최신 분노 신호 1건 조회 (prompt-sections.js가 호출).
 * @returns {object|null}
 */
export function getLatestAngerSignal() {
  try {
    if (!existsSync(SIGNALS_FILE)) return null;
    const lines = readFileSync(SIGNALS_FILE, 'utf-8').trim().split('\n').filter(Boolean);
    if (lines.length === 0) return null;
    const last = JSON.parse(lines[lines.length - 1]);
    const lastMs = new Date(last.ts.replace('+09:00', 'Z')).getTime() - 9 * 3600_000;
    const ageH = (Date.now() - lastMs) / 3600_000;
    if (ageH > 24) return null;
    return last;
  } catch { return null; }
}
