// interview-regex-verifier.mjs — Hybrid verifier (옵션 C)
// 2026-04-28 비서실장 3차 (옵션 A+C 동시 적용)
//
// 역할: LLM 메타분석(callClaudeMetaAnalyze) 호출 전, 규칙 기반(regex/script) 사전 검증.
//   - 명확한 forbid hit / styleGuide 위반 / 수치 디테일 부재 등 결정적 실패는 LLM 호출 없이 즉시 FAIL/REVISE 반환.
//   - 결정적 신호가 없으면 verdict='UNKNOWN' 반환 → ralph runner가 LLM verifier로 fallback.
//
// 입력:
//   - answer (string): SHORT + DETAIL 합본 답변 텍스트
//   - scenario (object): { forbiddenPhrases, styleGuide:{ rules, topPriority, examples }, ...}
//   - opts (object, optional): { strictDetailNumeric: false }
//
// 출력:
//   {
//     verdict: 'PASS' | 'REVISE' | 'FAIL' | 'UNKNOWN',
//     score: 0~10,
//     flagged: [ { type, severity, ... } ],
//     breakdown: { highCount, mediumCount, lowCount, numericHits, firstPersonHits, sentenceCount, longSentenceCount },
//     elapsedMs: number,
//     // hybrid 결정용 메타
//     deterministic: boolean,  // true면 LLM fallback 불필요
//     llmFallbackHint: string,  // UNKNOWN일 때 LLM에게 줄 요청 ('focus on detailGaps' 등)
//   }
//
// SSoT-aligned defaults: 시나리오 styleGuide.rules 기반 + 디테일 휴리스틱.
// 정확도 검증은 R1 fixture (ralph-insights.jsonl) 대비 일치율로 평가.

const ACRONYMS_NEED_GLOSS = ['p99', 'RF=3', 'ISR', 'saturate', 'throughput', 'idempotent', 'ALB', 'SLA', 'EDA', 'CDC'];
const NUMERIC_PATTERN = /\d+\s*(%|초|분|시간|일|배|건|호실|ms|s|MB|GB|TB|RPM|TPM|TPS|req\/s|req\/sec)/g;
const FIRST_PERSON_PATTERN = /(저는|제가|저희|제 경험|저희 팀)/g;
const SENTENCE_SPLIT = /(?<=[.!?。])\s+|(?<=다\.)\s+|\n+/;

// styleGuide rule 4: 한 문장 60자 이내
const SENTENCE_MAX_LEN = 60;
// 디테일 임계: 답변에 수치 0개면 detail-gap-no-numbers 발동
const MIN_NUMERIC_HITS = 1;
// 1인칭 임계: 답변에 1인칭 0회면 1인칭 부재 경고 (low)
const MIN_FIRST_PERSON = 1;

// ─────────────────────────────────────────────────────────────
// 개념 정확성 가드 (2026-06-23): 면접봇이 틀린 기술 개념을 답변으로 생성·승인하는 것 차단.
//   ground truth: 노션 면접 질답 23,000줄(/tmp/notion-interview.txt) 실측. 손으로 13개를
//   지어내면 정상 표현을 오인(오탐)할 위험 → 크롤에서 확인된 UNAMBIGUOUS 2개만 등재.
//   각 항목은 정답형/부정문을 면죄(negation guard)해 올바른 답변이 FAIL나지 않게 함.
//   concept-error 1건이라도 적중 시 deterministic FAIL — 사실 오류는 승인 절대 금지.
// ─────────────────────────────────────────────────────────────
const CONCEPT_ERRORS = [
  {
    name: 'redis-setnx-expire-atomic',
    hint: 'SETNX+EXPIRE는 별도 두 명령이라 원자적이지 않음. 원자형은 SET key val NX PX millis 단일 명령(또는 Lua). "SETNX+EXPIRE가 원자적"은 면접 즉사.',
    test: (t) => {
      if (!/SETNX/i.test(t)) return false;                                 // SETNX 명시 언급 없으면 무관
      const claimsAtomic = /SETNX[\s\S]{0,40}EXPIRE[\s\S]{0,30}원자/i.test(t);  // 두 명령 조합을 원자적이라 긍정 주장
      if (!claimsAtomic) return false;
      const negated = /원자[^.]{0,12}(않|못|아니|불가)/.test(t);            // "원자적이지 않/못" → 정답형 면죄
      return !negated;
    },
  },
  {
    name: 'grpc-5byte-header',
    hint: 'gRPC의 5바이트는 HTTP/2 프레임 "헤더"가 아니라 프레임 페이로드 내 길이 프리픽스(1B 압축플래그+4B 길이). HTTP/2 프레임 헤더는 9바이트.',
    test: (t) => {
      const claimsHeader = /gRPC[\s\S]{0,30}5\s*바이트[\s\S]{0,15}헤더|5\s*바이트[\s\S]{0,15}헤더[\s\S]{0,20}프레이밍/i.test(t);
      if (!claimsHeader) return false;
      const understood = /9\s*바이트|프리픽스|프리앰블|length-?prefix|페이로드/i.test(t);  // 정확히 이해한 표현 → 면죄
      return !understood;
    },
  },
];

/**
 * Hybrid regex/script verifier.
 * @param {string} answer  SHORT+DETAIL 합본
 * @param {object} scenario  scenario JSON (forbiddenPhrases, styleGuide)
 * @param {object} opts  { strictDetailNumeric, debug }
 * @returns {object} verdict bundle
 */
export function regexVerify(answer, scenario, opts = {}) {
  const t0 = Date.now();
  const flagged = [];
  const text = String(answer || '');
  const sc = scenario || {};
  const forbiddenPhrases = Array.isArray(sc.forbiddenPhrases) ? sc.forbiddenPhrases : [];
  const styleGuide = sc.styleGuide || {};
  const styleRules = Array.isArray(styleGuide.rules) ? styleGuide.rules : [];

  // ─────────────────────────────────────────────────────────────
  // 1. forbiddenPhrases 매칭 (severity=high — 즉시 FAIL 후보)
  // ─────────────────────────────────────────────────────────────
  for (const phrase of forbiddenPhrases) {
    if (!phrase) continue;
    if (text.includes(phrase)) {
      flagged.push({ type: 'forbid', phrase, severity: 'high' });
    }
  }

  // ─────────────────────────────────────────────────────────────
  // 2. styleGuide rule 4: 한 문장 60자 이내
  // ─────────────────────────────────────────────────────────────
  const sentences = text.split(SENTENCE_SPLIT).filter(s => s.trim().length > 0);
  const longSentences = sentences.filter(s => s.length > SENTENCE_MAX_LEN);
  for (const s of longSentences) {
    flagged.push({
      type: 'styleGuide-rule4-long-sentence',
      text: s.slice(0, 80),
      length: s.length,
      severity: 'medium',
    });
  }

  // ─────────────────────────────────────────────────────────────
  // 3. styleGuide rule 1+2: 영어 약어 첫 사용 시 풀이 부재
  //    검출: ACRONYMS_NEED_GLOSS 단어 등장 + 직후 괄호 풀이 없음
  // ─────────────────────────────────────────────────────────────
  for (const ac of ACRONYMS_NEED_GLOSS) {
    if (!text.includes(ac)) continue;
    // 풀이 패턴: "ac (한글풀이)" 또는 "ac은/는 한글풀이" 또는 "한글풀이(ac)"
    const escapedAc = ac.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const glossPatterns = [
      new RegExp(`${escapedAc}\\s*\\([^)]+\\)`),  // ac (풀이)
      new RegExp(`\\([^)]*${escapedAc}[^)]*\\)`),  // (...ac...)
      new RegExp(`${escapedAc}[^.]{1,15}(즉|=|는|은)\\s*[가-힣]`),  // ac 즉 풀이
    ];
    const glossed = glossPatterns.some(p => p.test(text));
    if (!glossed) {
      flagged.push({
        type: 'styleGuide-rule1-acronym-no-gloss',
        acronym: ac,
        severity: 'low',
      });
    }
  }

  // ─────────────────────────────────────────────────────────────
  // 4. 디테일 갭: 수치 패턴 카운트
  // ─────────────────────────────────────────────────────────────
  const numericMatches = text.match(NUMERIC_PATTERN) || [];
  const numericHits = numericMatches.length;
  if (numericHits < MIN_NUMERIC_HITS) {
    flagged.push({
      type: 'detail-gap-no-numbers',
      hint: '구체 수치(%, 초, 배, 건 등) 부재 → 면접관 즉사 trigger',
      severity: 'medium',
    });
  }

  // ─────────────────────────────────────────────────────────────
  // 5. 1인칭 비율 (사람다움 신호)
  // ─────────────────────────────────────────────────────────────
  const firstPersonMatches = text.match(FIRST_PERSON_PATTERN) || [];
  const firstPersonHits = firstPersonMatches.length;
  if (firstPersonHits < MIN_FIRST_PERSON) {
    flagged.push({
      type: 'first-person-absent',
      hint: '저는/제가/저희 팀 등 1인칭 부재 → AI 어투 의심',
      severity: 'low',
    });
  }

  // ─────────────────────────────────────────────────────────────
  // 6. AI bridge 어투 직접 매칭 (callClaudeMetaAnalyze prompt와 동일)
  // ─────────────────────────────────────────────────────────────
  const AI_BRIDGES = [
    '이로 인해', '이를 통해', '이를 바탕으로', '결과적으로',
    '이에 따라', '그 결과', '이 경험을 통해',
  ];
  for (const bridge of AI_BRIDGES) {
    if (text.includes(bridge)) {
      flagged.push({
        type: 'ai-bridge-phrase',
        phrase: bridge,
        severity: 'medium',
      });
    }
  }

  // ─────────────────────────────────────────────────────────────
  // 7. 격식체 마무리 / 환각 합성 패턴
  // ─────────────────────────────────────────────────────────────
  const FORMAL_TAILS = ['성과를 달성', '크게 향상', '확립했다', '제고했다', '함에 있어', '일환으로'];
  for (const tail of FORMAL_TAILS) {
    if (text.includes(tail)) {
      flagged.push({
        type: 'formal-tail-phrase',
        phrase: tail,
        severity: 'low',
      });
    }
  }

  // ─────────────────────────────────────────────────────────────
  // 8. 개념 정확성 가드 (틀린 기술 개념 — deterministic FAIL 후보)
  // ─────────────────────────────────────────────────────────────
  for (const ce of CONCEPT_ERRORS) {
    if (ce.test(text)) {
      flagged.push({
        type: 'concept-error',
        name: ce.name,
        hint: ce.hint,
        severity: 'high',
      });
    }
  }

  // ─────────────────────────────────────────────────────────────
  // breakdown + verdict
  // ─────────────────────────────────────────────────────────────
  const highCount = flagged.filter(f => f.severity === 'high').length;
  const mediumCount = flagged.filter(f => f.severity === 'medium').length;
  const lowCount = flagged.filter(f => f.severity === 'low').length;
  const conceptErrorCount = flagged.filter(f => f.type === 'concept-error').length;

  let verdict;
  let deterministic;
  let llmFallbackHint = '';

  // v4.52 비서실장 3차 임계 (보수적):
  //   - forbid hit이 2건 이상: 결정적 FAIL (1건만으로는 false positive 가능 — fast-path가 forbid 우회 시도 후 자연 등장 가능성)
  //   - 그 외는 모두 LLM fallback (회색지대 보전, 정확도 우선)
  // 초기 R1 fixture 정확도 17% precision 측정 결과로 임계 강화 (2026-04-28).
  // PASS criterion 미달 시 LLM-only fallback이 안전 기본값.
  if (conceptErrorCount >= 1) {
    // 개념 오류는 사실 오류 — 1건이라도 deterministic FAIL (정답형은 CONCEPT_ERRORS의 negation guard로 이미 제외됨)
    verdict = 'FAIL';
    deterministic = true;
    llmFallbackHint = `concept-error:${flagged.filter(f => f.type === 'concept-error').map(f => f.name).join(',')}`;
  } else if (highCount >= 2) {
    // forbid 2건 이상은 명백한 위반 — LLM 호출 불필요
    verdict = 'FAIL';
    deterministic = true;
  } else {
    // 그 외 (forbid 0~1건, medium 어떤 수, low 어떤 수): 모두 LLM verifier로 fallback
    // 이유: regex만으로는 ssot/디테일/사람다움의 미묘한 신호 판별 불가 (R1 fixture precision 17%)
    verdict = 'UNKNOWN';
    deterministic = false;
    const hints = [];
    if (highCount === 1) hints.push('forbid-1');
    if (mediumCount >= 1) hints.push(`mediums=${mediumCount}`);
    if (numericHits < 2) hints.push('low-numeric');
    if (firstPersonHits < 2) hints.push('low-first-person');
    llmFallbackHint = hints.join(',') || 'all-clean-llm-confirm';
  }

  // score 계산 (verdict 보조용)
  let score = 10 - highCount * 5 - mediumCount * 1.5 - lowCount * 0.3;
  // 디테일 보너스 — 수치 많고 1인칭 많으면 +
  if (numericHits >= 3) score += 0.5;
  if (firstPersonHits >= 3) score += 0.5;
  score = Math.max(0, Math.min(10, Number(score.toFixed(2))));

  return {
    verdict,
    score,
    flagged,
    breakdown: {
      highCount,
      mediumCount,
      lowCount,
      numericHits,
      firstPersonHits,
      sentenceCount: sentences.length,
      longSentenceCount: longSentences.length,
    },
    elapsedMs: Date.now() - t0,
    deterministic,
    llmFallbackHint,
  };
}

/**
 * LLM 메타분석 결과(JSON)를 regex 결과와 비교 → 일치율 측정.
 * R1 fixture(ralph-insights.jsonl) precision/recall 평가용.
 */
export function compareWithLlmResult(regexResult, llmMeta) {
  if (!llmMeta || typeof llmMeta !== 'object') {
    return { agreement: false, reason: 'no-llm-meta' };
  }
  // verdict 일치
  const verdictMatch =
    (regexResult.verdict === 'PASS' && llmMeta.verdict === 'PASS') ||
    (regexResult.verdict === 'FAIL' && llmMeta.verdict === 'FAIL') ||
    (regexResult.verdict === 'REVISE' && llmMeta.verdict === 'REVISE') ||
    (regexResult.verdict === 'UNKNOWN');  // UNKNOWN은 fallback이므로 자동 일치 처리

  // forbid 교집합 — LLM의 ssotIssues + styleViolations + aiTone과 regex flagged 비교
  const llmFlaggedTexts = [
    ...(llmMeta.ssotIssues || []),
    ...(llmMeta.styleViolations || []),
    ...(llmMeta.aiTone || []),
    ...(llmMeta.detailGaps || []),
  ].map(s => String(s).toLowerCase());

  const regexFlaggedTexts = regexResult.flagged.map(f =>
    String(f.phrase || f.text || f.acronym || f.hint || f.type).toLowerCase()
  );

  let intersectCount = 0;
  for (const rt of regexFlaggedTexts) {
    if (llmFlaggedTexts.some(lt => lt.includes(rt) || rt.includes(lt))) {
      intersectCount++;
    }
  }

  return {
    agreement: verdictMatch,
    verdictMatch,
    regexFlaggedCount: regexFlaggedTexts.length,
    llmFlaggedCount: llmFlaggedTexts.length,
    intersectCount,
    precision: regexFlaggedTexts.length ? intersectCount / regexFlaggedTexts.length : 0,
    recall: llmFlaggedTexts.length ? intersectCount / llmFlaggedTexts.length : 0,
  };
}

// CLI: node interview-regex-verifier.mjs --fixture <ralph-insights.jsonl> --scenario <name>
// → R1 fixture 110문 답변에 적용 → LLM 결과와 일치율 출력
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);

  // --self-test: 개념 정확성 가드 오탐 0 검증 (오답형 FAIL / 정답형 통과)
  if (args.includes('--self-test')) {
    const cases = [
      // [라벨, 답변텍스트, concept-error 적중 기대]
      ['SETNX 오류(원자 주장)', 'Redis는 싱글스레드라 SETNX + EXPIRE가 원자적으로 동작하여 분산락에 적합합니다.', true],
      ['SETNX 정답(부정문)', 'SETNX + EXPIRE는 키 설정과 TTL이 원자적으로 처리되지 않습니다. 그래서 SET key val NX PX 30000 단일 명령을 씁니다.', false],
      ['SETNX 정답(단일명령)', 'SET key value NX PX 30000으로 키 설정과 TTL을 원자적으로 처리합니다.', false],
      ['gRPC 오류(헤더)', 'gRPC도 내부적으로 5바이트 헤더로 프레이밍합니다.', true],
      ['gRPC 정답(프리픽스)', 'gRPC는 HTTP/2 프레임 페이로드에 5바이트 길이 프리픽스를 붙입니다. 프레임 헤더는 9바이트입니다.', false],
      ['무관 정상답변', 'gRPC와 R2DBC로 인증서버를 재설계해 인스턴스를 30대에서 5~8대로 줄였습니다.', false],
    ];
    let pass = 0, fail = 0;
    for (const [label, text, expect] of cases) {
      const r = regexVerify(text, {});
      const hits = r.flagged.filter(f => f.type === 'concept-error');
      const got = hits.length > 0;
      const ok = got === expect;
      ok ? pass++ : fail++;
      console.log(`${ok ? '✅' : '❌'} ${label}: concept=${got} (기대 ${expect}) verdict=${r.verdict}${got ? ' → ' + hits.map(h => h.name).join(',') : ''}`);
    }
    console.log(`\n개념 정확성 가드 자가테스트: ${pass} PASS / ${fail} FAIL`);
    process.exit(fail ? 1 : 0);
  }

  const opt = { fixture: '', scenario: '' };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--fixture') opt.fixture = args[++i];
    else if (args[i] === '--scenario') opt.scenario = args[++i];
  }
  if (!opt.fixture || !opt.scenario) {
    console.error('usage: node interview-regex-verifier.mjs --fixture <jsonl> --scenario <name>');
    process.exit(1);
  }

  // scenario 로드
  const scPath = join(homedir(), 'jarvis/runtime/state/scenarios', `${opt.scenario}.json`);
  if (!existsSync(scPath)) {
    console.error(`scenario not found: ${scPath}`);
    process.exit(1);
  }
  const scenario = JSON.parse(readFileSync(scPath, 'utf-8'));

  // fixture (insights.jsonl) — 답변 본문은 sidecar md에 있으므로 score만 비교
  if (!existsSync(opt.fixture)) {
    console.error(`fixture not found: ${opt.fixture}`);
    process.exit(1);
  }
  const lines = readFileSync(opt.fixture, 'utf-8').split('\n').filter(Boolean);
  const insights = lines.map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);

  console.log(`📊 Hybrid verifier accuracy test`);
  console.log(`   scenario: ${opt.scenario} (${scenario.qnaQuestions?.length || 0}문항, forbid ${scenario.forbiddenPhrases?.length || 0}, styleRules ${scenario.styleGuide?.rules?.length || 0})`);
  console.log(`   fixture: ${insights.length} insights\n`);

  // 단순 fixture에는 답변 본문이 없으므로, sidecar md에서 답변 추출 시도
  // sidecar 위치: ~/jarvis/runtime/wiki/05-career/interview-curated/<qid>.md
  const curatedDir = join(homedir(), 'jarvis/runtime/wiki/05-career/interview-curated');
  let totalAgreement = 0;
  let totalDeterministic = 0;
  let totalCompared = 0;
  let totalPrecision = 0;
  let totalRecall = 0;

  for (const ins of insights) {
    const sidecarPath = join(curatedDir, `${ins.qid}.md`);
    if (!existsSync(sidecarPath)) continue;
    const md = readFileSync(sidecarPath, 'utf-8');
    // SHORT/DETAIL 본문 추출 (간단 휴리스틱)
    const answerText = md.replace(/^#.*$/gm, '').trim();
    if (!answerText) continue;

    const r = regexVerify(answerText, scenario);
    const cmp = compareWithLlmResult(r, ins);
    totalCompared++;
    if (cmp.agreement) totalAgreement++;
    if (r.deterministic) totalDeterministic++;
    totalPrecision += cmp.precision;
    totalRecall += cmp.recall;
  }

  if (totalCompared === 0) {
    console.log(`⚠️ no fixture samples matched (sidecar md 부재)`);
    process.exit(0);
  }

  const agreementRate = (totalAgreement / totalCompared * 100).toFixed(1);
  const deterministicRate = (totalDeterministic / totalCompared * 100).toFixed(1);
  const avgPrecision = (totalPrecision / totalCompared * 100).toFixed(1);
  const avgRecall = (totalRecall / totalCompared * 100).toFixed(1);
  const f1 = (2 * (avgPrecision * avgRecall) / (parseFloat(avgPrecision) + parseFloat(avgRecall) || 1)).toFixed(1);

  console.log(`📊 결과 (n=${totalCompared}):`);
  console.log(`   ✅ verdict 일치율: ${agreementRate}%`);
  console.log(`   🎯 결정적 (LLM skip 가능): ${deterministicRate}%`);
  console.log(`   📐 precision: ${avgPrecision}%  recall: ${avgRecall}%  F1: ${f1}%`);
  console.log(`   💰 비용 절감 추정: ${deterministicRate}% 의 LLM 호출 skip → 대략 비용 ${deterministicRate}% 감소`);
  console.log(`\n   PASS criterion: agreement >= 90% & precision >= 80%`);
  if (parseFloat(agreementRate) >= 90 && parseFloat(avgPrecision) >= 80) {
    console.log(`   ✅ HYBRID GO`);
  } else {
    console.log(`   ⚠️ HYBRID NO-GO — LLM-only 유지 권장 또는 임계 재조정`);
  }
}
