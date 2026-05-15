#!/usr/bin/env node
/**
 * qa-consistency-audit.mjs
 *
 * Q&A 정합성 감사 — answerGuide(코칭 가이드) ↔ approvedAnswer.content(실제 답변) 불일치 자동 감지.
 *
 * 배경: 2026-05-04 B044 사고 — answerGuide: Slack·CI/CD, answer: MySQL·Notion
 *       수작업 전수조사에 의존해 매번 새로운 불일치가 발견되는 구조.
 * 가드: 주간 cron + 수동 실행. 불일치 발견 시 Discord #jarvis-interview 알림.
 *
 * 사용:
 *   node qa-consistency-audit.mjs               # 불일치 목록 출력 (exit 0=정상, 1=불일치)
 *   node qa-consistency-audit.mjs --notify       # 불일치 시 Discord webhook 송출
 *   node qa-consistency-audit.mjs --scenario X   # 특정 시나리오 JSON (기본: samsung-cnt)
 */

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const SCENARIOS_DIR = join(homedir(), 'jarvis/runtime/state/scenarios');
const MONITORING_PATH = join(homedir(), 'jarvis/runtime/config/monitoring.json');

// CLI 파라미터 파싱
const NOTIFY = process.argv.includes('--notify');
const scenarioArg = (() => {
  const idx = process.argv.indexOf('--scenario');
  return idx !== -1 ? process.argv[idx + 1] : 'samsung-cnt';
})();

// P4: path traversal 방어 — '/' 포함 시 exit 2
if (scenarioArg.includes('/') || scenarioArg.includes('..')) {
  console.error(`❌ 유효하지 않은 시나리오 이름: ${scenarioArg}`);
  process.exit(2);
}

const SCENARIO_PATH = join(SCENARIOS_DIR, `${scenarioArg}.json`);

// ─── 도구/기업명 추출 패턴 ───────────────────────────────────────

// 한국어 동사/형용사/기능어 — 기술 목록 항목이 아닌 것들
const KOREAN_FUNCTIONAL = new Set([
  '적용','명시','구현','운영','관리','선택','설명','확인','포함','분리','낮게','높게',
  '이유','조건','기반으로','사용','추가','제거','변경','기준','방식','처리','설정',
  '분류','연산','감소','판별','검증','복구','저장','전송','수신','반환','요청','응답',
  '최소화','축소','가시화','서비스','인터페이스','그룹핑','첨부','내용','통합',
  '안정성','신뢰성','일관성','확장성','정합성',
  // P3 추가: 동사 누락분
  '수정','삭제','생성','조회','등록','실행','배포','호출','연결','정의','설계','허용',
  '금지','차단','재시도','초기화','갱신','교체','비교','정렬','필터','집계','파싱',
]);

// 가운뎃점·콤마 열거에서 기술적 명사 항목만 추출 (동사/기능어 제외)
// 예: "Jira·Confluence·Datadog" → ['Jira','Confluence','Datadog']
// 예: "도어락·에어컨·공기질·조명" → ['도어락','에어컨','공기질','조명']
function extractDotList(text) {
  const items = [];
  const groups = text.match(/[A-Za-z0-9가-힣/&]{2,}(?:[·,]\s*[A-Za-z0-9가-힣/&]{2,}){2,}/g) || [];
  for (const g of groups) {
    g.split(/[·,]\s*/).forEach(item => {
      const t = item.trim();
      // 기능어 제외, 2자 이상, 순수 숫자 제외
      if (t.length >= 2 && !KOREAN_FUNCTIONAL.has(t) && !/^\d+$/.test(t)) {
        items.push(t);
      }
    });
  }
  return [...new Set(items)];
}

// 괄호 형식 열거: "Jira(이슈트래킹), Confluence(문서)" → ['Jira','Confluence']
// 단, 항목이 영문 대문자 시작 또는 복합 한국어 명사(3자 이상)인 경우만
function extractParenList(text) {
  const matches = [...text.matchAll(/([A-Za-z가-힣]{2,})\s*\([^)]+\)/g)];
  return [...new Set(
    matches
      .map(m => m[1].trim())
      .filter(item =>
        !KOREAN_FUNCTIONAL.has(item) &&
        item.length >= 2 &&
        // 영문 대문자 시작이거나 한국어 3자 이상 명사
        (/^[A-Z]/.test(item) || /^[가-힣]{3,}$/.test(item) || /[A-Z0-9]/.test(item))
      )
  )];
}

// N가지/N개/N단계/N종 숫자 추출
function extractCounts(text) {
  return [...text.matchAll(/(\d+)\s*[가지개종단계]/g)].map(m => Number(m[1]));
}

// 첫째/둘째/셋째... 열거에서 첫 어절 추출 → 답변에 해당 문맥이 있는지 확인용
function extractOrdinalItems(text) {
  const pattern = /(?:첫째|둘째|셋째|넷째|다섯째)[,\s]+([A-Za-z가-힣]{2,})/g;
  return [...text.matchAll(pattern)].map(m => m[1].trim());
}

// ─── 핵심 정합성 체크 로직 ───────────────────────────────────────

function checkQuestion(q) {
  const issues = [];
  const guide = q.answerGuide || '';
  const answer = (q.approvedAnswer?.content || '');
  const qid = q.id;

  if (!guide.trim() || !answer.trim()) return issues;

  // 체크 1: 가운뎃점/쉼표 열거 항목이 answer에 없으면 경고
  const dotItems = extractDotList(guide);
  if (dotItems.length >= 3) {
    const missing = dotItems.filter(item => {
      // 공백 제거 매칭 + 부분 포함도 허용 (활동로그 → 활동 로그)
      const normalized = item.replace(/\s/g, '');
      const ansNorm = answer.replace(/\s/g, '');
      return !ansNorm.includes(normalized);
    });
    // 절반 이상 누락되면 실결함, 1~2개면 경고
    if (missing.length >= Math.ceil(dotItems.length / 2)) {
      issues.push({
        id: qid,
        severity: 'error',
        type: 'LIST_MISMATCH',
        msg: `guide 열거 ${dotItems.length}개 중 ${missing.length}개 answer 미등장: [${missing.join(', ')}]`,
        detail: `guide열거: [${dotItems.join(', ')}]`,
      });
    } else if (missing.length > 0) {
      issues.push({
        id: qid,
        severity: 'warn',
        type: 'LIST_PARTIAL',
        msg: `guide 열거 중 ${missing.length}개 answer 미등장: [${missing.join(', ')}]`,
        detail: `guide열거: [${dotItems.join(', ')}]`,
      });
    }
  }

  // 체크 2: 괄호형 열거 항목 (e.g. "Jira(이슈), Confluence(문서)") answer 대조
  const parenItems = extractParenList(guide);
  if (parenItems.length >= 3) {
    const missing = parenItems.filter(item => !answer.includes(item));
    if (missing.length >= Math.ceil(parenItems.length / 2)) {
      issues.push({
        id: qid,
        severity: 'error',
        type: 'PAREN_MISMATCH',
        msg: `guide 괄호열거 ${parenItems.length}개 중 ${missing.length}개 answer 미등장: [${missing.join(', ')}]`,
        detail: `guide괄호열거: [${parenItems.join(', ')}]`,
      });
    } else if (missing.length > 0) {
      issues.push({
        id: qid,
        severity: 'warn',
        type: 'PAREN_PARTIAL',
        msg: `guide 괄호열거 중 ${missing.length}개 answer 미등장: [${missing.join(', ')}]`,
        detail: `guide괄호열거: [${parenItems.join(', ')}]`,
      });
    }
  }

  // 체크 3 (P1): 역방향 exclusion 체크
  // guide에 "※ X는 해당 없음" 또는 "X·Y는 해당 없음" 패턴이 있는데
  // answer에 해당 항목이 등장하면 → EXCLUSION_VIOLATION
  // 예: B044 수정 후 answerGuide에 "※ Slack·CI/CD는 해당 없음" 명시
  const exclusionMatches = [
    ...guide.matchAll(/※\s*([A-Za-z가-힣·,\s/&]+?)(?:는|은)\s*해당\s*없음/g),
    ...guide.matchAll(/([A-Za-z가-힣·,\s/&]+?)(?:는|은)\s*해당\s*(?:없음|아님)/g),
  ];
  for (const m of exclusionMatches) {
    const excluded = m[1].split(/[·,\s]+/).map(s => s.trim()).filter(s => s.length >= 2);
    const violations = excluded.filter(item => answer.includes(item));
    if (violations.length > 0) {
      issues.push({
        id: qid,
        severity: 'error',
        type: 'EXCLUSION_VIOLATION',
        msg: `guide에서 "해당 없음"으로 명시된 항목이 answer에 등장: [${violations.join(', ')}]`,
        detail: `제외 명시: [${excluded.join(', ')}]`,
      });
    }
  }

  return issues;
}

// ─── Frankenstein 수치 의심 집계 ─────────────────────────────────

function countFabricationWarnings(questions) {
  let frankenstein = 0;
  let fabrication = 0;
  let aiTone = 0;
  const flagged = [];

  for (const q of questions) {
    const content = q.approvedAnswer?.content || '';
    const hasFrank = content.includes('Frankenstein(');
    const hasFabric = content.includes('창작수치의심(');
    const hasAI = content.includes('AI어투의심(');
    if (hasFrank) { frankenstein++; flagged.push({ id: q.id, type: 'Frankenstein' }); }
    if (hasFabric) { fabrication++; }
    if (hasAI) { aiTone++; }
  }
  return { frankenstein, fabrication, aiTone, total: flagged.length, flagged };
}

// ─── Discord 알림 ─────────────────────────────────────────────────

async function notifyWebhook(text) {
  try {
    if (!existsSync(MONITORING_PATH)) return;
    const cfg = JSON.parse(readFileSync(MONITORING_PATH, 'utf-8'));
    const url = cfg.webhooks?.['jarvis-interview'];
    if (!url) return;
    await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: text.slice(0, 1990) }),
    });
  } catch { /* ignore */ }
}

// ─── 메인 ─────────────────────────────────────────────────────────

if (!existsSync(SCENARIO_PATH)) {
  console.error(`❌ 시나리오 파일 없음: ${SCENARIO_PATH}`);
  process.exit(2);
}

// P2: JSON 파싱 예외 처리
let scenario;
try {
  scenario = JSON.parse(readFileSync(SCENARIO_PATH, 'utf-8'));
} catch (err) {
  console.error(`❌ JSON 파싱 실패 (${SCENARIO_PATH}): ${err.message}`);
  process.exit(2);
}
const questions = scenario.qnaQuestions || [];

console.log(`# QA Consistency Audit (${new Date().toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })} KST)`);
console.log(`시나리오: ${scenarioArg}  |  문항 수: ${questions.length}`);
console.log('');

// 정합성 체크
const allIssues = [];
for (const q of questions) {
  allIssues.push(...checkQuestion(q));
}

const errors = allIssues.filter(i => i.severity === 'error');
const warns = allIssues.filter(i => i.severity === 'warn');

// 창작수치 의심 집계
const fab = countFabricationWarnings(questions);

// 출력
if (allIssues.length === 0) {
  console.log('✅ 정합성 불일치 없음 — answerGuide ↔ approvedAnswer 일치');
} else {
  console.log(`🚨 정합성 불일치 ${allIssues.length}건 (error ${errors.length}, warn ${warns.length})`);
  console.log('');
  for (const issue of [...errors, ...warns]) {
    const prefix = issue.severity === 'error' ? '❌' : '⚠️ ';
    console.log(`${prefix} [${issue.id}] ${issue.type}: ${issue.msg}`);
    if (issue.detail) console.log(`   └─ ${issue.detail}`);
  }
}

console.log('');
console.log(`📊 창작수치 의심 현황 (시스템 메타데이터 경고)`);
console.log(`   Frankenstein 수치혼합: ${fab.frankenstein}건`);
console.log(`   창작수치의심:          ${fab.fabrication}건`);
console.log(`   AI어투의심:            ${fab.aiTone}건`);
console.log(`   ※ 이 경고는 answer content 내 footer — 면접 전 user-profile.md 수동 대조 필요`);

if (NOTIFY) {
  if (allIssues.length === 0) {
    await notifyWebhook(`✅ QA Consistency Audit (${scenarioArg}): 불일치 없음. Frankenstein ${fab.frankenstein}건 창작수치의심 ${fab.fabrication}건은 수동 대조 필요.`);
  } else {
    const lines = [...errors, ...warns].slice(0, 8).map(i => `• [${i.id}] ${i.type}: ${i.msg.slice(0, 120)}`).join('\n');
    const summary = `🚨 **QA Consistency Audit 불일치 ${allIssues.length}건** (error ${errors.length}, warn ${warns.length})\n${lines}\n\n📊 Frankenstein ${fab.frankenstein} · 창작수치의심 ${fab.fabrication} · AI어투 ${fab.aiTone}`;
    await notifyWebhook(summary);
  }
}

process.exit(errors.length > 0 ? 1 : 0);
