// career-coding-mode.js — #jarvis-career 코딩테스트 모드 상태 (2026-06-11)
// env CAREER_CODING_MODE(재시작 필요)를 상태 파일 토글(즉시 적용)로 대체.
// 토글: bash ~/jarvis/infra/scripts/career-coding-mode.sh {coach|solve|off|status}
//   solve = 자바 직접 풀이 (2026-06-07 기존 모드)
//   coach = 생성형 AI 프롬프트 전략 코치 (AI 활용형 라이브코딩 대비, 2026-06-11)
//   off   = 평소 커리어 채널
import { readFileSync, writeFileSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

const BOT_HOME_DIR = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const STATE_FILE = join(BOT_HOME_DIR, 'state', 'career-coding-mode.json');

// owner Discord ID — 공개 리포에 하드코딩 금지(privacy guard high) → 런타임 설정에서 로드
let _ownerIdCache;
export function getOwnerDiscordId() {
  if (_ownerIdCache !== undefined) return _ownerIdCache;
  try {
    const profiles = JSON.parse(readFileSync(join(BOT_HOME_DIR, 'config', 'user_profiles.json'), 'utf-8'));
    _ownerIdCache = profiles.owner?.discordId || null;
  } catch { _ownerIdCache = null; }
  return _ownerIdCache;
}

export const CAREER_CHANNEL_ID = '1471694919339868190';

export function getCareerCodingMode() {
  try {
    const m = JSON.parse(readFileSync(STATE_FILE, 'utf-8')).mode;
    if (m === 'solve' || m === 'coach' || m === 'off') return m;
  } catch { /* 상태 파일 없음/손상 → env 폴백 */ }
  return process.env.CAREER_CODING_MODE === '1' ? 'solve' : 'off';
}

export function setCareerCodingMode(mode, via = 'unknown') {
  if (mode !== 'coach' && mode !== 'solve' && mode !== 'off') {
    throw new Error(`invalid coding mode: ${mode}`);
  }
  writeFileSync(STATE_FILE, JSON.stringify({ mode, changedAt: new Date().toISOString(), via }) + '\n');
  return mode;
}

// 자연어 토글 파서 (2026-06-11): "코딩모드 켜줘/꺼줘/풀이로/상태" 류 짧은 발화만 명령으로 인식.
// 매치 없으면 null → 일반 메시지(문제 본문)로 처리. 40자 초과 발화는 문제로 간주해 오발동 차단.
export function parseCodingModeCommand(text) {
  const t = String(text || '').trim();
  if (!t || t.length > 40) return null;
  if (!/(코딩|코테|코치)\s*(테스트)?\s*모드/.test(t)) return null;
  if (/상태|확인|뭐|status/i.test(t)) return 'status';
  if (/꺼|끄|중지|해제|종료|off/i.test(t)) return 'off';   // "코치 모드 꺼줘" 오인 방지 — off를 coach보다 먼저
  if (/풀이|솔브|solve/i.test(t)) return 'solve';
  if (/켜|시작|온|on|코치|coach/i.test(t)) return 'coach';
  return null;
}
