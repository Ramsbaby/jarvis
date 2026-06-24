// fact-guard.mjs — 5층 실측 가드 (날짜·요일·신선도 검증)
//
// 배경: 2026-06-24 오답노트 "날짜의 요일을 date 실측 없이 추론 → 반복 오류".
// LLM이 요일·날짜를 머릿속으로 계산하면 틀린다. 그래서 모든 날짜 메타(요일·D-day)는
// 여기서 코드로 정확히 계산해 스냅샷에 부착한다. LLM은 이미 계산된 값을 인용만 한다.

import { statSync } from 'node:fs';

const WD = ['일', '월', '화', '수', '목', '금', '토'];

// 오늘(KST) — YYYY-MM-DD
export function todayKST() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Seoul' });
}

// 날짜 문자열(YYYY-MM-DD)의 KST 요일 — 추정 금지, 코드 실측
// 정오 기준으로 타임존 경계 문제 회피
export function weekdayKST(dateStr) {
  if (!dateStr) return null;
  const d = new Date(`${dateStr}T12:00:00+09:00`);
  if (isNaN(d)) return null;
  const wd = d.toLocaleDateString('en-US', { timeZone: 'Asia/Seoul', weekday: 'short' });
  const map = { Sun: '일', Mon: '월', Tue: '화', Wed: '수', Thu: '목', Fri: '금', Sat: '토' };
  return map[wd] || null;
}

// 오늘(KST) 기준 D-day (음수=지남, 0=오늘)
export function daysUntilKST(dateStr) {
  if (!dateStr) return null;
  const today = new Date(`${todayKST()}T00:00:00+09:00`);
  const target = new Date(`${dateStr}T00:00:00+09:00`);
  if (isNaN(target)) return null;
  return Math.round((target - today) / 86400000);
}

// 날짜에 n일 더하기 — YYYY-MM-DD
export function addDays(dateStr, n) {
  const d = new Date(`${dateStr}T00:00:00+09:00`);
  d.setDate(d.getDate() + n);
  return d.toLocaleDateString('en-CA', { timeZone: 'Asia/Seoul' });
}

// 파일 신선도 — maxAgeDays 초과 시 stale (오답노트: stale 파일을 최신 근거로 쓰지 말 것)
export function freshness(filePath, maxAgeDays) {
  try {
    const m = statSync(filePath).mtimeMs;
    const ageDays = (Date.now() - m) / 86400000;
    return { mtime: new Date(m).toISOString().slice(0, 10), ageDays: +ageDays.toFixed(1), stale: ageDays > maxAgeDays };
  } catch {
    return { mtime: null, ageDays: null, stale: true, missing: true };
  }
}
