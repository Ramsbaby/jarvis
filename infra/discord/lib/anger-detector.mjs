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

    // Phase 1-B 메타인지 자기 조정: 스킬 패치 초안 자동 생성 (비블로킹)
    setImmediate(() => triggerSkillPatch(sig).catch(() => {}));
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

// ────────────────────────────────────────────────────────────
// 가드 #1 통합 — 자비스 응답 자체에서 단정 표현 검출 후 anger-signals 기록
// (사용자가 분노하지 않아도, LLM이 단정 표현을 쓰면 자동 신호화)
// ────────────────────────────────────────────────────────────

/**
 * 응답 검증 후 단정 표현 발견 시 anger-signals.jsonl에 자체 신호 기록.
 * 다음 turn에서 prompt-sections.js의 buildAngerCorrectionSection이
 * 이 신호를 읽어 "🚨 직전 정정" 헤더로 강제 주입 → 같은 단정 즉시 차단.
 *
 * 사고 사례 (2026-04-28):
 *   사용자가 분노 안 해도 자비스가 "100% 자동 차단" 단정 후, 사용자 지적 후에야
 *   사후 정정. 자기검열만으로 차단 불가능하므로, 단정 검출 시 signals에 자동 기록.
 *
 * @param {object} args
 * @param {string} args.userId
 * @param {string} args.channelId
 * @param {string} args.sessionKey
 * @param {string} args.userText - 사용자 원문 (맥락)
 * @param {string} args.assistantText - 검증 대상 자비스 응답
 */
export async function recordSelfAssertiveSignal(args) {
  try {
    const { validateResponse } = await import('./response-validator.mjs');
    const validation = validateResponse(args.assistantText || '');

    // info 이하면 신호 안 박음 (노이즈 방지)
    if (validation.severity === 'pass' || validation.severity === 'info') {
      return { recorded: false, reason: 'below-threshold', validation };
    }

    const ts = new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' });
    const tsISO = new Date(Date.now() + 9 * 3600_000).toISOString().replace('Z', '+09:00');
    const topMatches = validation.matches.slice(0, 3).map(m => `[${m.level}] ${m.label}`).join(', ');

    const signal = {
      ts: tsISO,
      userId: args.userId,
      channelId: args.channelId,
      keyword: `self-assertive-${validation.severity}`,
      userText: (args.userText || '').slice(0, 200),
      assistantText: (args.assistantText || '').slice(0, 600),
      sessionKey: args.sessionKey,
      _self: true,
      _matches: topMatches,
    };
    pruneAndAppendSignal(signal);
    return { recorded: true, validation };
  } catch (err) {
    process.stderr.write(`[anger-detector] recordSelfAssertiveSignal failed: ${err.message}\n`);
    return { recorded: false, reason: 'error', error: err.message };
  }
}

/**
 * triggerSkillPatch — 분노 감지 직후 스킬 패치 초안을 자동 생성하여 pending 폴더에 저장.
 *
 * Phase 1-B 메타인지 자기 조정: anger-detector가 감지→등재에서 멈추던 루프를
 * 감지→등재→스킬 패치 초안 생성까지 연결한다. setImmediate로 비동기 실행되므로
 * 메인 응답 흐름을 차단하지 않는다.
 *
 * 처리 흐름:
 *   1. 동일 userId 60초 디바운스 (연속 분노 신호 누적 방지)
 *   2. SKILL_DIRS에서 관련 스킬 파일 간이 탐색
 *   3. 패치 초안을 skill-drafts/pending/ 에 JSON으로 저장
 *   4. skill-loop.jsonl에 anger_patch_triggered 이벤트 기록
 *      → 다음 skill-loop-nightly가 이 파일을 우선 선별 대상으로 사용
 */
async function triggerSkillPatch(sig) {
  // 동일 userId 60초 디바운스
  const debounceKey = `patch-${sig.userId}`;
  const now = Date.now();
  triggerSkillPatch._debounce = triggerSkillPatch._debounce || {};
  if (triggerSkillPatch._debounce[debounceKey] && now - triggerSkillPatch._debounce[debounceKey] < 60_000) return;
  triggerSkillPatch._debounce[debounceKey] = now;

  const { mkdirSync: mkdir, writeFileSync: write, appendFileSync: append, readdirSync: readdir, existsSync: exists } = await import('node:fs');
  const { join: pjoin } = await import('node:path');
  const { homedir: home } = await import('node:os');

  const HOME_DIR = home();
  const DRAFTS_PENDING = pjoin(BOT_HOME, 'state', 'skill-drafts', 'pending');
  const SKILL_LOOP_LEDGER = pjoin(BOT_HOME, 'ledger', 'skill-loop.jsonl');

  mkdir(DRAFTS_PENDING, { recursive: true });

  // 관련 스킬 파일 간이 탐색 (mistake/anger/correction 관련 파일)
  const SKILL_DIRS_LOCAL = [
    pjoin(HOME_DIR, '.claude', 'commands'),
    pjoin(HOME_DIR, '.claude', 'skills'),
  ];

  const relatedSkills = [];
  for (const dir of SKILL_DIRS_LOCAL) {
    if (!exists(dir)) continue;
    try {
      for (const f of readdir(dir)) {
        if (/mistake|anger|correction|정정|오류/.test(f)) {
          relatedSkills.push(pjoin(dir, f));
        }
      }
    } catch { /* 스킵 */ }
  }

  const draftId = `anger-${now}`;
  const tsKST = new Date(now + 9 * 3600_000).toISOString().replace('Z', '+09:00');

  const patchDraft = {
    id: draftId,
    trigger: sig.keyword,
    userText: (sig.userText || '').slice(0, 200),
    assistantText: (sig.assistantText || '').slice(0, 200),
    relatedSkills: relatedSkills.slice(0, 3),
    suggestedNote: `## 주의 (${tsKST.slice(0, 10)} 사용자 정정)\n키워드: ${sig.keyword}\n사용자: ${(sig.userText || '').slice(0, 100)}`,
    status: 'pending_review',
    createdAt: tsKST,
    source: 'anger-detector',
    userId: sig.userId,
    channelId: sig.channelId,
  };

  // pending 폴더에 패치 초안 저장
  write(pjoin(DRAFTS_PENDING, `${draftId}.json`), JSON.stringify(patchDraft, null, 2));

  // skill-loop.jsonl에 이벤트 기록
  append(SKILL_LOOP_LEDGER, JSON.stringify({
    ts: tsKST,
    event: 'anger_patch_triggered',
    draft_id: draftId,
    trigger: sig.keyword,
    userId: sig.userId,
  }) + '\n');
}
