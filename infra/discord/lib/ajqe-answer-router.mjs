/**
 * ajqe-answer-router.mjs — Active Jarvis Question Engine 답변 라우터
 *
 * 역할: AJQE webhook 메시지에 대한 사용자 reply를 감지하여
 *       원본 질문(sent.jsonl)과 매칭하고 wiki/<domain>/_facts.md에 자동 적재.
 *
 * 호출 측: discord/lib/handlers.js handleMessage()
 *   - extractAjqeId(refMessage.content) → ajqeId or null
 *   - handleAjqeAnswer({ ajqeId, answerText, userId, messageId }) → boolean (handled)
 *
 * 설계 원칙:
 *   - 봇 핸들러 수정 최소화 (10줄 hook만, 비즈니스 로직은 본 모듈)
 *   - sent.jsonl은 SSoT — 모르는 id는 false 반환 (silent skip)
 *   - addFactToWiki source='ajqe-answer' 태그로 감사 가능
 *   - PII 마스킹은 addFactToWiki가 자동 처리
 */
import { readFileSync, existsSync, appendFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { spawn } from 'node:child_process';

const HOME = homedir();
const SENT_PATH = join(HOME, 'jarvis/runtime/state/ajqe-sent.jsonl');
const ANSWERED_PATH = join(HOME, 'jarvis/runtime/state/ajqe-answered.jsonl');
const ACTION_EXECUTOR = join(HOME, 'jarvis/infra/scripts/ajqe-action-executor.mjs');

// 답변 키워드 → 액션 매핑 (대소문자 무시, 정규식)
// 매칭 실패 = 액션 없음 (기존처럼 wiki 적재만)
const ACTION_KEYWORDS = [
  { action: 'undo',        re: /^(되돌|복원|롤백|undo|취소|되돌려)/i }, // v5.5
  { action: 'investigate', re: /^(조사|분석|investigate|살펴|확인)/i },
  { action: 'restart',     re: /^(재시작|리스타트|restart|재가동|재실행)/i },
  { action: 'disable',     re: /^(끄기|꺼|disable|비활성|영구\s*disable)/i },
  { action: 'ignore',      re: /^(무시|ignore|skip|다음에|패스)/i },
];

function classifyAction(answerText) {
  const text = String(answerText || '').trim();
  for (const { action, re } of ACTION_KEYWORDS) {
    if (re.test(text)) return action;
  }
  return null;
}

// AJQE 메시지 본문에서 id 추출 (dispatch가 출력하는 `id: \`xxx\`` 패턴)
export function extractAjqeId(messageContent) {
  if (!messageContent) return null;
  const m = messageContent.match(/id:\s*`([a-zA-Z0-9_\-]+)`/);
  return m ? m[1] : null;
}

function findSentRecord(ajqeId) {
  if (!existsSync(SENT_PATH)) return null;
  const lines = readFileSync(SENT_PATH, 'utf-8').split('\n').filter(l => l.trim());
  // 가장 최근 매칭 (역순) — 동일 id 재발송 시 최신 이력 우선
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const r = JSON.parse(lines[i]);
      if (r.id === ajqeId) return r;
    } catch { /* skip malformed */ }
  }
  return null;
}

/**
 * AJQE 답변 처리. wiki에 적재 + (v5.2) 액션 키워드 감지 시 executor spawn.
 * @returns {Promise<{handled:boolean, domain?:string, ssot?:string, action?:string}>}
 */
export async function handleAjqeAnswer({ ajqeId, answerText, userId, messageId }) {
  if (!ajqeId) return { handled: false };
  const text = String(answerText || '').trim();
  if (!text) return { handled: false };

  const sent = findSentRecord(ajqeId);
  if (!sent) return { handled: false };

  // wiki 적재 — addFactToWiki가 PII 마스킹·중복 체크 자동 처리
  const { addFactToWiki } = await import('./wiki-engine.mjs');
  const fact = `[AJQE 답변] ${sent.ssot} 갭 (id ${ajqeId}): ${text}`;
  const storedDomain = addFactToWiki(userId, fact, {
    domainOverride: sent.domain,
    source: 'ajqe-answer',
  });

  // v5.2: 액션 키워드 감지 → executor spawn (봇 blocking 방지)
  const action = classifyAction(text);
  if (action && existsSync(ACTION_EXECUTOR)) {
    const channel = sent.channel || 'jarvis';
    const child = spawn('/opt/homebrew/bin/node', [ACTION_EXECUTOR, ajqeId, action, channel], {
      detached: true,
      stdio: 'ignore',
    });
    child.unref();
  }

  // 답변 이력 기록
  mkdirSync(dirname(ANSWERED_PATH), { recursive: true });
  appendFileSync(ANSWERED_PATH, JSON.stringify({
    ajqeId,
    domain: sent.domain,
    ssot: sent.ssot,
    answerText: text.slice(0, 500),
    answeredBy: userId,
    answerMessageId: messageId,
    answeredAt: new Date().toISOString(),
    storedToDomain: storedDomain,
    action: action || null,
  }) + '\n');

  return { handled: true, domain: storedDomain, ssot: sent.ssot, action };
}
