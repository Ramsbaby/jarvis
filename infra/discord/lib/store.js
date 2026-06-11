/**
 * SessionStore — thread-to-session mapping with TTL expiry and debounced persist.
 *
 * === 세션 파일 개념 정리 ===
 *
 * 세션(session)은 단순히 "파일"이 아닙니다. sessions.json은 메모리 맵입니다:
 *   threadId → { id: "session-uuid", updatedAt: timestamp, tokenCount: number }
 *
 * [A] 세션 파일 (Session File) 이란?
 *   - sessions.json 파일 자체
 *   - 메모리상 스레드별 세션 ID + 토큰 카운트 매핑 저장
 *   - Claude -p CLI가 자동 생성/관리하는 ~/.cache/claude-cli/ 내 실제 세션 파일과는 무관
 *   - 용도: 디스코드 채널별 또는 스레드별로 Claude CLI 세션을 "재사용"할지 결정
 *   - 크기: 매우 작음 (채널 수 × ~100 bytes)
 *
 * [B] 컨텍스트 토큰 (Context Tokens) 이란?
 *   - tokenCount: 누적된 LLM 호출 토큰 합계 (input_tokens + output_tokens)
 *   - 각 Claude 호출 후 ask-claude.sh → token-ledger.jsonl에 기록됨
 *   - 목적: 단일 세션에서 누적 토큰이 과도하면 "메모리 폭발" 감지
 *   - 임계값: SESSIONS_MAX_TOKEN_COUNT (기본 5000) 초과 시 세션 폐기
 *   - 비용 영향: 토큰 ∝ 비용, 세션별 독립 추적으로 영향 격리
 *
 * [C] 세션 크레딧/예산 (Budget) 이란?
 *   - sessionStore와는 무관, ask-claude.sh에서 관리
 *   - $MAX_BUDGET 인수로 전달, token-ledger.jsonl에 cost_usd 누적
 *   - 일일/월별 전체 예산과는 별개, 태스크별 독립 한도
 *   - 예: ask-claude.sh TASK_ID PROMPT ... "$10" → 이 태스크는 $10 한도
 *
 * === 사고 사례: 2026-05-08 세션 522d6b74 ===
 * - 문제: tokenCount 13,329까지 누적 (7일 TTL 게이트로는 못 잡음)
 * - 원인: 14일 동안 재사용되며 tokenCount는 계속 증가
 * - 결과: 호출 1회당 $1,685 발생 (컨텍스트 길이 때문)
 * - 해결: tokenCount 임계값(5000) + age 체크 병행, 부팅 시 자동 청소
 *
 * === 주의: 혼동하기 쉬운 부분 ===
 * ❌ "세션 파일이 커서 비용이 증가했다" → 잘못됨
 *    ✓ 옳은 것: "tokenCount가 누적되어 컨텍스트가 길어져 비용이 증가"
 *
 * ❌ "sessions.json 파일 크기가 크다" → 거의 불가능 (항상 매우 작음)
 *    ✓ 옳은 것: "세션 개수가 많거나, 토큰 카운트가 큼"
 */

import { readFileSync, writeFileSync, renameSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { log } from './claude-runner.js';

const SESSION_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7일
const PERSIST_DEBOUNCE_MS = 150;

// 부팅 시 자동 청소 임계 (좀비 세션 차단)
// 사고 사례 (2026-05-08): 522d6b74 세션이 14일간 매번 재사용되며 tokenCount 13,329 누적,
//   호출 1회당 $1,685 발생. updatedAt 갱신되어 7일 게이트로는 못 잡음 → tokenCount 게이트 필수.
const SESSIONS_MAX_AGE_DAYS = Number(process.env.SESSIONS_MAX_AGE_DAYS || 7);
const SESSIONS_MAX_TOKEN_COUNT = Number(process.env.SESSIONS_MAX_TOKEN_COUNT || 5000);

export class SessionStore {
  constructor(filePath) {
    this.filePath = filePath;
    this.data = {};
    this._flushTimer = null;
    this.load();

    // Synchronous flush on exit to avoid data loss
    process.on('exit', () => this._flushSync());
  }

  load() {
    if (!existsSync(this.filePath)) { this.data = {}; return; }
    let raw;
    try {
      raw = readFileSync(this.filePath, 'utf-8');
    } catch (readErr) {
      log('warn', 'SessionStore: could not read sessions file', { error: readErr.message });
      this.data = {};
      return;
    }
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (parseErr) {
      const corruptPath = `${this.filePath}.corrupt.${Date.now()}`;
      log('warn', 'SessionStore: corrupt JSON — renaming and starting fresh', {
        corrupt: corruptPath,
        error: parseErr.message,
      });
      try { renameSync(this.filePath, corruptPath); } catch { /* best effort */ }
      this.data = {};
      return;
    }
    // Migrate old format (string) → new format ({ id, updatedAt })
    for (const [k, v] of Object.entries(parsed)) {
      if (typeof v === 'string') {
        this.data[k] = { id: v, updatedAt: Date.now() };
      } else if (v && typeof v === 'object') {
        this.data[k] = v;
      }
    }

    // 부팅 시 좀비 세션 자동 청소 (2026-05-08 신설)
    // (1) tokenCount 임계 초과 → 컨텍스트 비대 회전 강제
    // (2) age 임계 초과 → stale 매핑 청소
    const now = Date.now();
    const ageThresholdMs = SESSIONS_MAX_AGE_DAYS * 24 * 60 * 60 * 1000;
    const pruned = [];
    for (const [k, v] of Object.entries(this.data)) {
      const tokenCount = v.tokenCount ?? 0;
      const ageMs = now - (v.updatedAt ?? 0);
      if (tokenCount > SESSIONS_MAX_TOKEN_COUNT) {
        pruned.push({ key: k, id: v.id, reason: 'tokenCount', value: tokenCount });
        delete this.data[k];
      } else if (ageMs > ageThresholdMs) {
        pruned.push({ key: k, id: v.id, reason: 'age', value: `${(ageMs / 86400000).toFixed(1)}d` });
        delete this.data[k];
      }
    }
    if (pruned.length > 0) {
      log('info', `SessionStore: ${pruned.length}개 좀비 매핑 청소 (boot prune)`, {
        threshold_token: SESSIONS_MAX_TOKEN_COUNT,
        threshold_age_days: SESSIONS_MAX_AGE_DAYS,
        pruned,
      });
      this._flushSync();  // 즉시 디스크 반영 — 다음 _flushSync(exit)로 부활 방지
    }
  }

  /** Schedule a debounced persist (150ms). Resets on each call. */
  save() {
    if (this._flushTimer) clearTimeout(this._flushTimer);
    this._flushTimer = setTimeout(() => {
      this._flushTimer = null;
      this._flushSync();
    }, PERSIST_DEBOUNCE_MS);
  }

  /** Immediate synchronous write to disk (atomic: tmp + rename). */
  _flushSync() {
    if (this._flushTimer) {
      clearTimeout(this._flushTimer);
      this._flushTimer = null;
    }
    const tmp = join(dirname(this.filePath), `.sessions-${process.pid}.tmp`);
    try {
      writeFileSync(tmp, JSON.stringify(this.data, null, 2));
      renameSync(tmp, this.filePath);
    } catch (err) {
      log('error', 'SessionStore flush failed', { error: err.message });
      try { writeFileSync(this.filePath, JSON.stringify(this.data, null, 2)); } catch { /* last resort */ }
    }
  }

  get(threadId) {
    const entry = this.data[threadId];
    if (!entry) return null;
    // Expire stale sessions
    if (Date.now() - entry.updatedAt > SESSION_TTL_MS) {
      delete this.data[threadId];
      this.save();
      return null;
    }
    return entry.id;
  }

  set(threadId, sessionId, tokenCount = null) {
    const existing = this.data[threadId]?.tokenCount ?? 0;
    this.data[threadId] = { id: sessionId, updatedAt: Date.now(), tokenCount: tokenCount !== null ? tokenCount : existing };
    this.save();
  }

  /**
   * 스레드별 누적 토큰 카운트 조회
   *
   * tokenCount는 이 스레드에서 Claude와 상호작용한 모든 호출의
   * input_tokens + output_tokens 합계입니다.
   *
   * 사용 예:
   *   - 토큰 카운트가 5000을 초과하면 메모리 폭발 위험 신호
   *   - Discord 사용자에게 경고: "이 스레드의 누적 토큰이 X개입니다"
   *   - 세션 폐기 결정 (부팅 시 자동 실행됨)
   */
  getTokenCount(threadId) {
    return this.data[threadId]?.tokenCount ?? 0;
  }

  /**
   * 스레드별 토큰 카운트에 증분 추가
   *
   * ask-claude.sh에서 LLM 호출 후 호출됨:
   *   sessions.addTokens(threadId, input_tokens + output_tokens)
   *
   * tokenCount가 SESSIONS_MAX_TOKEN_COUNT를 초과하면,
   * 다음 부팅 시 이 세션은 load() 함수에서 자동으로 폐기됩니다.
   *
   * 주의: 이 메서드는 sessionStore.addTokens()이지,
   *       token-ledger.jsonl과는 별개입니다.
   *       (레져는 ask-claude.sh에서 관리)
   */
  addTokens(threadId, delta) {
    if (!this.data[threadId]) return;
    this.data[threadId].tokenCount = (this.data[threadId].tokenCount ?? 0) + delta;
    this.save();
  }

  delete(threadId) {
    delete this.data[threadId];
    this.save();
  }
}
