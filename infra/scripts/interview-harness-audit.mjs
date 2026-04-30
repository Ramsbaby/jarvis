#!/usr/bin/env node
/**
 * interview-harness-audit.mjs — 면접봇 하네스 독립 감사관
 *
 * 목적: 실행 경로 내부 가드(schema guard 등)가 잡지 못하는
 *       데이터 무결성 문제를 외부에서 독립적으로 검증한다.
 *
 * Karpathy 원칙: "The eval must be independent of the thing being evaluated."
 * 내부 가드(fast-path 안)는 fast-path가 망가지면 같이 망가진다.
 * 이 스크립트는 면접봇과 완전히 분리된 독립 감사 루프다.
 *
 * 검사 항목:
 *   C1. instantRiskQuestions ↔ qnaQuestions.id 교차 참조 무결성
 *   C2. insights.jsonl EVAL_ERROR 오염률
 *   C3. 동적 질문 vs 베이스 질문 점수 역전 여부
 *   C4. forbid list 패턴 품질 (너무 짧음 / 비면접 오염)
 *   C5. rounds.jsonl 구조 무결성
 *
 * 사용:
 *   node interview-harness-audit.mjs           # 조용한 모드 (이상 시만 출력)
 *   node interview-harness-audit.mjs --verbose  # 전체 출력
 *   node interview-harness-audit.mjs --notify   # Discord 전송
 *   node interview-harness-audit.mjs --fix      # 자동 수정 가능한 항목 수정
 *
 * 마이그레이션 후 자동 실행 권장:
 *   npm run migration && node interview-harness-audit.mjs --notify
 *
 * 2026-04-30 신설 — 2026-04-28 v9.2 마이그레이션 이후 instantRiskQuestions
 *   ID 불일치 2일간 미감지 사고의 재발 방지 구조.
 */

import { readFileSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const VERBOSE  = process.argv.includes('--verbose');
const NOTIFY   = process.argv.includes('--notify');
const FIX_MODE = process.argv.includes('--fix');

const HOME     = homedir();
const SCN_PATH = join(HOME, 'jarvis/runtime/state/scenarios/samsung-cnt.json');
const INSIGHTS = join(HOME, 'jarvis/runtime/state/ralph-insights.jsonl');
const FORBID   = join(HOME, 'jarvis/runtime/state/ralph-forbid-list.json');
const ROUNDS   = join(HOME, 'jarvis/runtime/state/ralph-rounds.jsonl');
const WEBHOOK  = process.env.DISCORD_INTERVIEW_WEBHOOK ||
                 (() => { try { return JSON.parse(readFileSync(join(HOME, 'jarvis/runtime/.env'), 'utf-8').split('\n').find(l => l.startsWith('DISCORD_WEBHOOK_INTERVIEW='))?.split('=').slice(1).join('=')); } catch { return null; } })();

// ─── 유틸 ────────────────────────────────────────────────────────────────────
let passCount = 0;
let failCount = 0;
const failures = [];

function pass(code, msg) {
  passCount++;
  if (VERBOSE) console.log(`  ✅ [${code}] ${msg}`);
}
function fail(code, msg, detail = '') {
  failCount++;
  failures.push({ code, msg, detail });
  console.log(`  ❌ [${code}] ${msg}`);
  if (detail && VERBOSE) console.log(`       ${detail}`);
}
function warn(code, msg) {
  console.log(`  ⚠️  [${code}] ${msg}`);
}

async function postWebhook(text) {
  if (!WEBHOOK || !NOTIFY) return;
  try {
    await fetch(WEBHOOK, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: text.slice(0, 1900) }),
    });
  } catch { /* Discord 실패해도 감사 계속 */ }
}

// ─── C1: instantRiskQuestions ↔ qnaQuestions.id 교차 참조 무결성 ────────────
function checkC1(scn) {
  console.log('\n[C1] instantRiskQuestions ↔ qnaQuestions.id 교차 참조');
  const irq = scn.instantRiskQuestions || [];
  const qnaIds = new Set((scn.qnaQuestions || []).map(q => q.id));

  if (irq.length === 0) {
    warn('C1', 'instantRiskQuestions 배열 비어 있음 — 즉답 위험 우선순위 비활성');
    return;
  }

  const matched   = irq.filter(id => qnaIds.has(id));
  const unmatched = irq.filter(id => !qnaIds.has(id));

  if (unmatched.length === 0) {
    pass('C1', `instantRiskQuestions ${irq.length}개 전원 qnaQuestions ID 일치`);
  } else {
    fail(
      'C1',
      `instantRiskQuestions ${unmatched.length}/${irq.length}개 ID 불일치 — 즉답 위험 우선순위 무효`,
      `불일치: ${unmatched.slice(0, 5).join(', ')}... | 예시 qnaId: ${[...qnaIds].slice(0, 3).join(', ')}`,
    );

    // --fix 모드: isInstantRisk=true 항목에서 올바른 ID 추출하여 배열 갱신
    if (FIX_MODE) {
      const correctIds = (scn.qnaQuestions || [])
        .filter(q => q.isInstantRisk === true)
        .map(q => q.id);
      if (correctIds.length > 0) {
        scn.instantRiskQuestions = correctIds;
        console.log(`     🔧 --fix: instantRiskQuestions → ${correctIds.length}개 (isInstantRisk=true 기반)`);
        console.log(`        ${correctIds.slice(0, 5).join(', ')}...`);
        return { fixed: true, scn };
      }
    }
  }

  // isInstantRisk=true 항목 수와 배열 수 불일치 경고
  const boolTrue = (scn.qnaQuestions || []).filter(q => q.isInstantRisk === true).length;
  if (boolTrue !== irq.length) {
    warn('C1', `isInstantRisk=true ${boolTrue}개 vs instantRiskQuestions 배열 ${irq.length}개 불일치 — 코드가 boolean 기준으로 동작 중`);
  }
}

// ─── C2: insights.jsonl EVAL_ERROR 오염률 ────────────────────────────────────
function checkC2() {
  console.log('\n[C2] insights.jsonl EVAL_ERROR 오염률');
  if (!existsSync(INSIGHTS)) {
    warn('C2', 'insights.jsonl 없음 — 첫 라운드 전');
    return;
  }

  const lines = readFileSync(INSIGHTS, 'utf-8').split('\n').filter(Boolean);
  const entries = lines.map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);

  const total    = entries.length;
  const errCount = entries.filter(e => e.evalError === true || e.verdict === 'EVAL_ERROR').length;
  const zeroScoreNoFlag = entries.filter(e =>
    e.overallScore === 0 && e.verdict === 'FAIL' &&
    e.evalError !== true && e.verdict !== 'EVAL_ERROR',
  ).length;

  const rate = total > 0 ? (errCount / total * 100).toFixed(1) : '0.0';

  if (errCount === 0 && zeroScoreNoFlag === 0) {
    pass('C2', `insights.jsonl ${total}건 — EVAL_ERROR 없음`);
  } else {
    if (errCount > 0) {
      pass('C2-a', `EVAL_ERROR ${errCount}건 (${rate}%) 플래그 격리 정상 — 집계에서 제외됨`);
    }
    if (zeroScoreNoFlag > 0) {
      fail(
        'C2-b',
        `score=0 + verdict=FAIL (플래그 없음) ${zeroScoreNoFlag}건 — 구버전 오염 데이터 의심`,
        `이 항목들은 v4.57 이전에 생성된 parse 실패 잔재일 수 있음. --fix로 플래그 부여 가능.`,
      );
    }
  }

  if (VERBOSE) {
    console.log(`     총 ${total}건: EVAL_ERROR=${errCount} | 레거시 0점=${zeroScoreNoFlag} | 정상=${total - errCount - zeroScoreNoFlag}`);
  }
  return { total, errCount, zeroScoreNoFlag };
}

// ─── C3: 동적 질문 vs 베이스 질문 점수 역전 ─────────────────────────────────
function checkC3() {
  console.log('\n[C3] 동적 질문 vs 베이스 질문 점수 역전 (약점 노출 효과)');
  if (!existsSync(INSIGHTS)) {
    warn('C3', 'insights.jsonl 없음');
    return;
  }

  const lines = readFileSync(INSIGHTS, 'utf-8').split('\n').filter(Boolean);
  const entries = lines.map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  const valid = entries.filter(e => e.evalError !== true && e.verdict !== 'EVAL_ERROR');

  const dynScores  = valid.filter(e => e.qid?.startsWith('q-dyn-') && typeof e.overallScore === 'number' && e.overallScore > 0);
  const baseScores = valid.filter(e => e.qid?.startsWith('q-star') && typeof e.overallScore === 'number' && e.overallScore > 0);

  if (dynScores.length < 5 || baseScores.length < 5) {
    warn('C3', `데이터 부족 — DYN ${dynScores.length}건, BASE ${baseScores.length}건 (최소 5건 필요)`);
    return;
  }

  const dynAvg  = dynScores.reduce((s, e) => s + e.overallScore, 0) / dynScores.length;
  const baseAvg = baseScores.reduce((s, e) => s + e.overallScore, 0) / baseScores.length;
  const diff    = dynAvg - baseAvg;

  if (VERBOSE) {
    console.log(`     DYN  평균: ${dynAvg.toFixed(2)} (${dynScores.length}건)`);
    console.log(`     BASE 평균: ${baseAvg.toFixed(2)} (${baseScores.length}건)`);
    console.log(`     차이: ${diff >= 0 ? '+' : ''}${diff.toFixed(2)}점`);
  }

  if (Math.abs(diff) < 0.3) {
    pass('C3', `동적/베이스 난이도 유사 (차이 ${diff >= 0 ? '+' : ''}${diff.toFixed(2)}점)`);
  } else if (diff < 0) {
    pass('C3', `동적 질문이 더 어려움 (차이 ${diff.toFixed(2)}점) — 약점 노출 성공`);
  } else {
    fail(
      'C3',
      `동적 질문 역전 — DYN ${dynAvg.toFixed(2)} > BASE ${baseAvg.toFixed(2)} (차이 +${diff.toFixed(2)}점)`,
      '동적 질문 캐시 삭제 후 LLM 재생성 권장. ralph 재가동 시 자동 처리됨.',
    );
  }

  return { dynAvg, baseAvg, diff };
}

// ─── C4: forbid list 패턴 품질 ───────────────────────────────────────────────
function checkC4() {
  console.log('\n[C4] forbid list 패턴 품질');
  if (!existsSync(FORBID)) {
    warn('C4', 'ralph-forbid-list.json 없음');
    return;
  }

  const { forbidPatterns = [] } = JSON.parse(readFileSync(FORBID, 'utf-8'));

  // 중복 검사
  const seen = new Set();
  const dupes = [];
  for (const p of forbidPatterns) {
    if (seen.has(p)) dupes.push(p);
    seen.add(p);
  }

  // 비면접 오염 키워드 (k8s/IaC)
  const CONTAM_KW = ['helm', 'k8s', 'kubernetes', 'kubectl', 'terraform', 'argocd', 'dockerfile', 'ansible'];
  const contaminated = forbidPatterns.filter(p =>
    CONTAM_KW.some(kw => p.toLowerCase().includes(kw)),
  );

  if (dupes.length === 0) {
    pass('C4-dup', `forbid list 중복 없음 (${forbidPatterns.length}개)`);
  } else {
    fail('C4-dup', `forbid list 중복 ${dupes.length}개`, dupes.join(', '));
  }

  if (contaminated.length === 0) {
    pass('C4-contam', 'forbid list 비면접(k8s/IaC) 오염 없음');
  } else {
    fail('C4-contam', `forbid list 비면접 오염 ${contaminated.length}개`, contaminated.join(', '));
  }
}

// ─── C5: rounds.jsonl 구조 무결성 ────────────────────────────────────────────
function checkC5() {
  console.log('\n[C5] rounds.jsonl 구조 무결성');
  if (!existsSync(ROUNDS)) {
    warn('C5', 'ralph-rounds.jsonl 없음');
    return;
  }

  const lines = readFileSync(ROUNDS, 'utf-8').split('\n').filter(Boolean);
  let parseErrs = 0;
  let missingTs  = 0;
  let allSkip    = 0;

  for (const line of lines) {
    try {
      const obj = JSON.parse(line);
      if (!obj.ts) missingTs++;
      const results = obj.results || [];
      if (results.length > 0 && results.every(r => r.skipped === true)) {
        allSkip++;
      }
    } catch {
      parseErrs++;
    }
  }

  if (parseErrs === 0) {
    pass('C5-json', `rounds.jsonl ${lines.length}개 라운드 JSON 파싱 성공`);
  } else {
    fail('C5-json', `rounds.jsonl ${parseErrs}개 parse 오류`);
  }

  if (missingTs === 0) {
    pass('C5-ts', 'rounds.jsonl 타임스탬프 전원 존재');
  } else {
    fail('C5-ts', `rounds.jsonl ts 필드 누락 ${missingTs}건`);
  }

  if (allSkip > 0) {
    warn('C5-skip', `전량 SKIP 라운드 ${allSkip}건 — daily cap 또는 circuit breaker 흔적`);
  }
}

// ─── 메인 ─────────────────────────────────────────────────────────────────────
async function main() {
  console.log('🔍 interview-harness-audit — 면접봇 하네스 독립 감사');
  console.log(`   모드: ${VERBOSE ? 'VERBOSE' : 'QUIET'} | notify=${NOTIFY} | fix=${FIX_MODE}`);
  console.log(`   시각: ${new Date().toISOString()}`);

  // 시나리오 로드
  if (!existsSync(SCN_PATH)) {
    console.error(`❌ 시나리오 파일 없음: ${SCN_PATH}`);
    process.exit(1);
  }
  let scn = JSON.parse(readFileSync(SCN_PATH, 'utf-8'));

  // 검사 실행
  const c1Result = checkC1(scn);
  checkC2();
  const c3Result = checkC3();
  checkC4();
  checkC5();

  // --fix: C1 수정 후 파일 저장
  if (FIX_MODE && c1Result?.fixed) {
    writeFileSync(SCN_PATH, JSON.stringify(c1Result.scn, null, 2));
    console.log('\n💾 --fix: samsung-cnt.json instantRiskQuestions 갱신 저장 완료');
  }

  // 결과 요약
  console.log('\n' + '━'.repeat(60));
  console.log(`📊 감사 결과: PASS=${passCount}  FAIL=${failCount}`);

  if (failCount > 0) {
    console.log('\n❌ 실패 항목:');
    for (const f of failures) {
      console.log(`  [${f.code}] ${f.msg}`);
    }
  } else {
    console.log('✅ 전체 통과');
  }

  // Discord 알림
  if (NOTIFY) {
    let card = failCount === 0
      ? `✅ **면접봇 하네스 감사 PASS** — ${passCount}개 검사 통과`
      : `⚠️ **면접봇 하네스 감사 FAIL** — ${failCount}개 실패\n` +
        failures.map(f => `• [${f.code}] ${f.msg}`).join('\n');

    if (c3Result && c3Result.diff >= 0.3) {
      card += `\n\n🔴 **동적 질문 역전**: DYN ${c3Result.dynAvg.toFixed(2)} > BASE ${c3Result.baseAvg.toFixed(2)} (+${c3Result.diff.toFixed(2)}점) — 캐시 삭제 예정`;
    }

    await postWebhook(card);
  }

  process.exit(failCount > 0 ? 1 : 0);
}

main().catch(err => {
  console.error('harness-audit 실행 오류:', err.message);
  process.exit(2);
});
