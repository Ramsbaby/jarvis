// career-coding-mode.js — #jarvis-career 코딩테스트 모드 상태 (2026-06-11)
// env CAREER_CODING_MODE(재시작 필요)를 상태 파일 토글(즉시 적용)로 대체.
// 토글: bash ~/jarvis/infra/scripts/career-coding-mode.sh {coach|solve|off|status}
//   solve = 자바 직접 풀이 (2026-06-07 기존 모드)
//   coach = 생성형 AI 프롬프트 전략 코치 (AI 활용형 라이브코딩 대비, 2026-06-11)
//   off   = 평소 커리어 채널
import { readFileSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';

const STATE_FILE = join(
  process.env.BOT_HOME || join(homedir(), 'jarvis/runtime'),
  'state', 'career-coding-mode.json',
);

export const CAREER_CHANNEL_ID = '1471694919339868190';

export function getCareerCodingMode() {
  try {
    const m = JSON.parse(readFileSync(STATE_FILE, 'utf-8')).mode;
    if (m === 'solve' || m === 'coach' || m === 'off') return m;
  } catch { /* 상태 파일 없음/손상 → env 폴백 */ }
  return process.env.CAREER_CODING_MODE === '1' ? 'solve' : 'off';
}
