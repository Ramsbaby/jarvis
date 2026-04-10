/**
 * pairing.js — 미등록 사용자 페어링 코드 관리
 *
 * 동작 흐름:
 *   1. 미등록 사용자 메시지 → generateCode(discordId, username) → 6자리 코드 발급
 *   2. Owner가 !pair <코드> 실행 → verifyCode(code) → discordId + username 반환
 *   3. handlers.js가 user_profiles.json 업데이트 → claude-runner.js reloadUserProfiles()
 *
 * 코드: 6자리 대문자 알파숫자, 10분 TTL
 * 저장: 메모리(재시작 시 초기화, 의도적)
 */

import { randomBytes } from 'node:crypto';

// pending: code → { discordId, username, expiresAt }
const _pending = new Map();

const TTL_MS = 10 * 60 * 1000; // 10분
const CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // 혼동 문자(I,O,1,0) 제외

/**
 * 미등록 사용자의 페어링 코드를 생성한다.
 * 같은 discordId로 기존 코드가 있으면 재사용 (중복 발급 방지).
 * @param {string} discordId
 * @param {string} username  Discord displayName 또는 tag
 * @returns {string} 6자리 코드
 */
export function generateCode(discordId, username) {
  // 기존 미만료 코드 재사용
  for (const [code, entry] of _pending) {
    if (entry.discordId === discordId && entry.expiresAt > Date.now()) return code;
  }

  // 새 코드 생성 (중복 회피)
  let code;
  do {
    code = Array.from(randomBytes(6), (b) => CHARS[b % CHARS.length]).join('');
  } while (_pending.has(code));

  _pending.set(code, { discordId, username, expiresAt: Date.now() + TTL_MS });

  // 만료 자동 정리 (10분 후)
  setTimeout(() => _pending.delete(code), TTL_MS);

  return code;
}

/**
 * Owner가 입력한 코드를 검증한다.
 * @param {string} code
 * @returns {{ discordId: string, username: string } | null}  만료/없으면 null
 */
export function verifyCode(code) {
  const entry = _pending.get(code?.toUpperCase());
  if (!entry) return null;
  if (entry.expiresAt < Date.now()) {
    _pending.delete(code);
    return null;
  }
  _pending.delete(code); // 1회 사용 후 삭제
  return { discordId: entry.discordId, username: entry.username };
}

/**
 * 현재 pending 코드 수 (진단용)
 */
export function pendingCount() {
  return _pending.size;
}
