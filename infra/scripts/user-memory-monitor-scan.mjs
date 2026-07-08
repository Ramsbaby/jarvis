#!/usr/bin/env node
/**
 * user-memory-monitor-scan.mjs — 전체 사용자 user-memory 오염 감지 스캐너
 *
 * 역할:
 *   - ~/jarvis/runtime/state/users/*.json 전수 순회
 *   - MONITOR_SOFT_LIMITS(SSoT: user-memory.mjs)와 실측 facts 개수 비교
 *   - 경보 페이로드 생성 (JSON 단일 라인으로 stdout 출력)
 *
 * 호출: user-memory-monitor.sh가 이 스크립트를 실행하고 JSON을 파싱해 Discord POST
 *
 * 교체 배경: 2026-04-23 /verify 감사관 B1·B6 지적 반영
 *            - monitor CAT_WARN과 user-memory.mjs CATEGORY_LIMITS 3곳 SSoT 부재
 *            - jarvis 감시 / travel·profile 사각지대 / shell injection 리스크
 *            → MONITOR_SOFT_LIMITS를 user-memory.mjs에 SSoT로 이관, 이 스크립트가 동적 참조
 */

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { MONITOR_SOFT_LIMITS, MONITOR_TOTAL_WARN } from '../lib/user-memory.mjs';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const USERS_DIR = join(BOT_HOME, 'state', 'users');

function scan() {
  const lines = [];       // stdout에 그대로 뿌릴 사용자별 요약 (기존 로그 포맷 유지)
  const alerts = [];      // 임계치 초과 블록 (Discord embed용)
  let allOk = true;

  let files;
  try {
    files = readdirSync(USERS_DIR)
      .filter(f => f.endsWith('.json'))
      .filter(f => !f.includes('.bak'))
      .sort();
  } catch (err) {
    return {
      allOk: false,
      fatal: `USERS_DIR 접근 실패: ${USERS_DIR} (${err.message})`,
      lines: [],
      alerts: [],
    };
  }

  for (const file of files) {
    const fullPath = join(USERS_DIR, file);
    let data;
    try {
      data = JSON.parse(readFileSync(fullPath, 'utf-8'));
    } catch (err) {
      // 파싱 실패는 조용히 삼키지 않음 (감사관 S1 지적: 2>/dev/null로 에러 은폐 금지)
      lines.push(`[memory-monitor] ERROR parse_fail ${file}: ${err.message}`);
      allOk = false;
      alerts.push({
        name: 'parse_error',
        userId: file.replace('.json', ''),
        total: 0,
        warnings: [`- 🔴 JSON 파싱 실패: ${err.message}`],
      });
      continue;
    }

    const name = (data.name && data.name.trim()) || 'unknown';
    const userId = data.userId || file.replace('.json', '');
    const facts = Array.isArray(data.facts) ? data.facts : [];
    const total = facts.length;

    // 카테고리별 집계
    const cats = {};
    for (const f of facts) {
      const c = (typeof f === 'string' ? 'legacy' : (f?.category ?? 'none'));
      cats[c] = (cats[c] ?? 0) + 1;
    }

    lines.push(`[memory-monitor] ${name} (${userId}): total=${total}`);

    const warnings = [];

    // 전체 임계치
    if (total > MONITOR_TOTAL_WARN) {
      warnings.push(`- 🔴 전체 facts ${total}개 (경보 임계치 ${MONITOR_TOTAL_WARN})`);
      allOk = false;
    }

    // 카테고리별 (SSoT = MONITOR_SOFT_LIMITS)
    for (const [cat, limit] of Object.entries(MONITOR_SOFT_LIMITS)) {
      const count = cats[cat] ?? 0;
      if (count > limit) {
        warnings.push(`- 🟡 카테고리 [${cat}] ${count}개 (경보 ${limit})`);
        allOk = false;
      }
    }

    // [2026-07-08] 파편 오염 감지 — session-summarizer류 파편(세션메타·컴팩션·마크다운 조각)이
    //   다시 쌓이는지 비율 감시. 오너 기억 92% 오염(코딩테스트 파편 도배) 사고 재발 방지.
    //   감지 전용 정규식(넓게) — user-memory.mjs FAMILY_JUNK_RE(저장 차단·앵커)와 목적이 다름.
    const JUNK_RE = /compacted at|사용자 의도|완료된 작업|미완 작업|핵심 참조|세션 요약|글자 수:|^\s*###|^\s*\|.*\||^-{3,}|^L\d{2,}:/im;
    const junkCount = facts.filter(f => JUNK_RE.test(typeof f === 'string' ? f : (f?.text ?? ''))).length;
    if (total >= 10 && junkCount / total > 0.3) {
      warnings.push(`- 🔴 파편 오염 ${junkCount}/${total}건 (${Math.round(junkCount / total * 100)}%) — session-summarizer류 재유입 의심 (addFact 필터·크론 점검)`);
      allOk = false;
    }

    if (warnings.length) {
      alerts.push({ name, userId, total, warnings });
    }
  }

  return { allOk, lines, alerts };
}

function main() {
  const result = scan();
  // stdout: JSON 한 줄 (bash에서 파싱)
  // 포맷 안정성 확보를 위해 compact + 마커 사용
  process.stdout.write('SCAN_RESULT_JSON=' + JSON.stringify(result) + '\n');
}

main();
