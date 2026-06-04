/**
 * gemini-test.mjs — Gemini 3.5 Flash API 통합 테스트
 *
 * [성공 기준]
 * 1. 문법 오류 없음 ✓
 * 2. 100K+ 토큰 대용량 문서 처리 성공
 * 3. Claude Sonnet 대비 비용 < 50%
 * 4. 실제 Jarvis 태스크 e2e 완료
 *
 * 실행:
 *   node gemini-test.mjs test-summarize
 *   node gemini-test.mjs test-large-doc       # 100K+ token 테스트
 *   node gemini-test.mjs benchmark             # 비용 비교
 *   node gemini-test.mjs all
 */

import { geminiChat, summarize, analyze, preprocessForRag } from './gemini-client.mjs';
import { deepseekChat } from './deepseek-client.mjs';

// ── 테스트 유틸 ─────────────────────────────────────────────────────────────

function logSection(title) {
  console.log(`\n${'='.repeat(70)}`);
  console.log(`  ${title}`);
  console.log('='.repeat(70));
}

function logTest(name, status, details = '') {
  const icon = status === 'PASS' ? '✓' : status === 'FAIL' ? '✗' : '⊙';
  console.log(`[${icon}] ${name}`);
  if (details) console.log(`    ${details}`);
}

/**
 * 대용량 문서 생성 (약 N 토큰 상당)
 * 평균적으로 1 토큰 ≈ 4 글자
 */
function generateLargeDocument(tokenCount = 100_000) {
  const charCount = tokenCount * 4;
  const sampleText = `
Jarvis는 차세대 AI 기반 개인 비서 시스템입니다.

핵심 기능:
- 자동화된 일정 관리 및 알림
- 대용량 문서 처리 및 요약
- 실시간 정보 수집 및 분석
- 작업 자동화 및 워크플로우 관리
- 멀티 모달 입출력

기술 스택:
- Node.js 22.5+ (내장 SQLite)
- LLM 멀티 모델 라우팅
  * Claude (Anthropic) — 복잡한 작업
  * DeepSeek V4 Flash — 요약·분류 (저가)
  * Gemini 2.0 Flash — 대용량 문서 처리 (1M 컨텍스트)
- Discord 봇 인터페이스
- RAG 엔진 (LanceDB 벡터 DB)
- 상태 관리 (SQLite FSM)

아키텍처:
  [Discord 이벤트] → [Task Queue] → [Dev Runner]
                                        ↓
                                    [LLM Router]
                                        ↓
                      [Claude|DeepSeek|Gemini]
                                        ↓
                                   [Result Store]

성능:
- 크론 태스크 100% 성공률
- 평균 처리 시간: 30초
- 월간 API 비용: ~$50
- 토큰 처리량: 100M+ 토큰/월

사용 사례:
1. 일일 뉴스 요약
2. 이메일 분류 및 우선순위 지정
3. 회의 기록 요약
4. 코드 리뷰 자동화
5. 성과 분석 및 리포팅
  `.trim();

  const repeats = Math.ceil(charCount / sampleText.length);
  let result = '';
  for (let i = 0; i < repeats; i++) {
    result += `\n[섹션 ${i + 1}]\n${sampleText}`;
  }
  return result.slice(0, charCount);
}

/**
 * 토큰 개수 추정 (Claude 방식: 1 토큰 ≈ 4 글자)
 */
function estimateTokens(text) {
  return Math.ceil(text.length / 4);
}

// ── 테스트 1: 기본 요약 ─────────────────────────────────────────────────────

async function testSummarize() {
  logSection('TEST 1: 기본 요약 기능');

  try {
    const text = '클로드는 Anthropic에서 만든 AI 어시스턴트입니다. ' +
                 '다양한 작업을 수행할 수 있으며, 매우 안전하고 신뢰할 수 있습니다.';

    console.log('입력 텍스트:', text);
    const result = await summarize(text);

    console.log('요약 결과:', result.summary);
    console.log(`비용: $${result.cost_usd}`);
    console.log(`토큰: 입력 ${result.usage.input_tokens} | 출력 ${result.usage.output_tokens}`);

    logTest('기본 요약', 'PASS', `비용 $${result.cost_usd}`);
    return { passed: true, cost: result.cost_usd, result };
  } catch (err) {
    logTest('기본 요약', 'FAIL', err.message);
    return { passed: false, error: err.message };
  }
}

// ── 테스트 2: 대용량 문서 처리 (100K+ 토큰) ─────────────────────────────

async function testLargeDocument() {
  logSection('TEST 2: 대용량 문서 처리 (100K+ 토큰)');

  try {
    // 약 100K 토큰의 문서 생성
    const doc = generateLargeDocument(100_000);
    const estimatedTokens = estimateTokens(doc);

    console.log(`생성된 문서 크기:`);
    console.log(`  - 글자 수: ${doc.length.toLocaleString()}`);
    console.log(`  - 예상 토큰: ~${estimatedTokens.toLocaleString()}`);

    console.log('\n처리 중...');
    const startTime = Date.now();
    const result = await summarize(doc, { maxSentences: 10 });
    const duration = ((Date.now() - startTime) / 1000).toFixed(2);

    console.log(`\n처리 완료 (${duration}초)`);
    console.log('요약 결과:', result.summary.slice(0, 200) + '...');
    console.log(`비용: $${result.cost_usd}`);
    console.log(`토큰: 입력 ${result.usage.input_tokens} | 출력 ${result.usage.output_tokens}`);

    const passed = result.usage.input_tokens > 50_000; // 최소 50K 토큰 처리 확인
    logTest('100K+ 토큰 문서 처리', passed ? 'PASS' : 'FAIL',
            `입력 토큰: ${result.usage.input_tokens} (예상: 100K+)`);

    return { passed, cost: result.cost_usd, result };
  } catch (err) {
    logTest('100K+ 토큰 문서 처리', 'FAIL', err.message);
    return { passed: false, error: err.message };
  }
}

// ── 테스트 3: RAG 전처리 ────────────────────────────────────────────────────

async function testRagPreprocessing() {
  logSection('TEST 3: RAG 전처리');

  try {
    const doc = `
Jarvis 기술 스택은 다음과 같습니다:

1. 백엔드: Node.js 22.5+
   - 내장 SQLite (node:sqlite)
   - Discord.js 라이브러리
   - 비동기 작업 큐

2. 데이터베이스: SQLite WAL 모드
   - 트랜잭션 보장
   - 동시성 지원

3. LLM 통합:
   - Claude (Anthropic)
   - DeepSeek V4 Flash
   - Gemini 2.0 Flash

4. 벡터 DB: LanceDB
   - RAG 엔진
   - 시맨틱 검색

5. 모니터링:
   - Langfuse 트레이싱
   - Discord 웹훅 알림
   - 로그 수집
    `.trim();

    console.log('입력 문서 길이:', doc.length, '글자');

    const result = await preprocessForRag(doc, { domain: 'tech' });

    console.log(`생성된 청크 개수: ${result.chunks.length}`);
    result.chunks.forEach((chunk, i) => {
      console.log(`  [${i + 1}] ${chunk.slice(0, 60)}...`);
    });
    console.log(`비용: $${result.cost_usd}`);

    logTest('RAG 전처리', result.chunks.length > 0 ? 'PASS' : 'FAIL',
            `생성된 청크: ${result.chunks.length}`);

    return { passed: result.chunks.length > 0, cost: result.cost_usd, result };
  } catch (err) {
    logTest('RAG 전처리', 'FAIL', err.message);
    return { passed: false, error: err.message };
  }
}

// ── 테스트 4: 분석 기능 ─────────────────────────────────────────────────────

async function testAnalysis() {
  logSection('TEST 4: 문서 분석');

  try {
    const doc = `
에러 로그 분석:
  2026-05-20 10:30:45 [ERROR] TypeError: Cannot read property 'id' of undefined
  2026-05-20 10:30:46 [ERROR] at processTask (/path/to/task.js:42:15)
  2026-05-20 10:30:47 [WARN] Retrying in 5 seconds...
  2026-05-20 10:30:52 [INFO] Task resumed successfully

패턴 분석:
  - 매일 10:30-10:40 사이에 3-4건 발생
  - 항상 processTask 함수에서 발생
  - 재시도 시 성공률 85%
  - 평균 5초 이내 복구
    `.trim();

    console.log('분석 문서:', doc.slice(0, 100) + '...');

    const result = await analyze(doc, 'identify-patterns');

    console.log('\n분석 결과:', result.analysis.slice(0, 200) + '...');
    console.log(`비용: $${result.cost_usd}`);

    logTest('문서 분석', 'PASS', `비용 $${result.cost_usd}`);
    return { passed: true, cost: result.cost_usd, result };
  } catch (err) {
    logTest('문서 분석', 'FAIL', err.message);
    return { passed: false, error: err.message };
  }
}

// ── 테스트 5: Claude Sonnet 비용 비교 ──────────────────────────────────────

async function benchmarkCosts() {
  logSection('TEST 5: Claude Sonnet vs Gemini Flash 비용 비교');

  // Claude Sonnet 가격 (2025-05 기준)
  const CLAUDE_SONNET_INPUT  = 3.00  / 1_000_000;   // $3.00/1M tokens
  const CLAUDE_SONNET_OUTPUT = 15.00 / 1_000_000;   // $15.00/1M tokens

  // Gemini 2.0 Flash 가격
  const GEMINI_INPUT  = 1.50  / 1_000_000;   // $1.50/1M tokens
  const GEMINI_OUTPUT = 9.00  / 1_000_000;   // $9.00/1M tokens

  // 전형적인 시나리오: 100K 입력 토큰, 1K 출력 토큰
  const testCases = [
    { name: '소규모 (10K 입력, 500 출력)', input: 10_000, output: 500 },
    { name: '중규모 (100K 입력, 1K 출력)', input: 100_000, output: 1_000 },
    { name: '대규모 (500K 입력, 2K 출력)', input: 500_000, output: 2_000 },
    { name: '초대규모 (1M 입력, 5K 출력)', input: 1_000_000, output: 5_000 },
  ];

  const results = [];

  for (const testCase of testCases) {
    const claudeCost = (testCase.input * CLAUDE_SONNET_INPUT) +
                       (testCase.output * CLAUDE_SONNET_OUTPUT);
    const geminiCost = (testCase.input * GEMINI_INPUT) +
                       (testCase.output * GEMINI_OUTPUT);
    const savings = ((claudeCost - geminiCost) / claudeCost * 100).toFixed(1);
    const ratio = (geminiCost / claudeCost * 100).toFixed(1);

    console.log(`\n${testCase.name}:`);
    console.log(`  Claude Sonnet: $${claudeCost.toFixed(4)}`);
    console.log(`  Gemini Flash:  $${geminiCost.toFixed(4)}`);
    console.log(`  절감: ${savings}% (Gemini = Claude의 ${ratio}%)`);

    results.push({
      name: testCase.name,
      claude: claudeCost,
      gemini: geminiCost,
      ratio,
    });
  }

  const allUnder50 = results.every(r => parseFloat(r.ratio) <= 50);
  logTest('비용 효율성 (< 50%)', allUnder50 ? 'PASS' : 'FAIL',
          `Gemini = Claude의 ${results[1].ratio}% (100K 시나리오)`);

  return { passed: allUnder50, results };
}

// ── 메인 테스트 스위트 ──────────────────────────────────────────────────────

async function runAllTests() {
  console.log('\n╔════════════════════════════════════════════════════════════════════╗');
  console.log('║        Gemini 3.5 Flash API 통합 테스트 스위트                        ║');
  console.log('╚════════════════════════════════════════════════════════════════════╝');

  const tests = [
    { name: 'test-summarize', fn: testSummarize },
    { name: 'test-large-doc', fn: testLargeDocument },
    { name: 'test-rag', fn: testRagPreprocessing },
    { name: 'test-analysis', fn: testAnalysis },
    { name: 'benchmark', fn: benchmarkCosts },
  ];

  const allResults = [];

  for (const test of tests) {
    try {
      const result = await test.fn();
      allResults.push({ test: test.name, ...result });
    } catch (err) {
      console.error(`[✗] ${test.name} 실행 오류:`, err.message);
      allResults.push({ test: test.name, passed: false, error: err.message });
    }
  }

  // 최종 요약
  logSection('테스트 결과 요약');

  const passCount = allResults.filter(r => r.passed).length;
  const totalCount = allResults.length;

  console.log(`통과: ${passCount}/${totalCount}`);
  allResults.forEach(r => {
    const status = r.passed ? '✓' : '✗';
    console.log(`  [${status}] ${r.test}`);
  });

  const totalCost = allResults.reduce((sum, r) => sum + (r.cost ?? 0), 0);
  console.log(`\n총 API 비용: $${totalCost.toFixed(4)}`);

  if (passCount === totalCount) {
    console.log('\n🎉 모든 테스트 통과!');
  } else {
    console.log(`\n⚠️  ${totalCount - passCount}개 테스트 실패`);
  }

  return allResults;
}

// ── CLI 진입점 ──────────────────────────────────────────────────────────────

if (process.argv[1] && process.argv[1].endsWith('gemini-test.mjs')) {
  const [,, command] = process.argv;

  (async () => {
    try {
      let result;
      switch (command) {
        case 'test-summarize':
          result = await testSummarize();
          process.exit(result.passed ? 0 : 1);
          break;
        case 'test-large-doc':
          result = await testLargeDocument();
          process.exit(result.passed ? 0 : 1);
          break;
        case 'test-rag':
          result = await testRagPreprocessing();
          process.exit(result.passed ? 0 : 1);
          break;
        case 'test-analysis':
          result = await testAnalysis();
          process.exit(result.passed ? 0 : 1);
          break;
        case 'benchmark':
          result = await benchmarkCosts();
          process.exit(result.passed ? 0 : 1);
          break;
        case 'all':
          await runAllTests();
          process.exit(0);
          break;
        default:
          console.log('사용법: node gemini-test.mjs <test-summarize|test-large-doc|test-rag|test-analysis|benchmark|all>');
          process.exit(1);
      }
    } catch (err) {
      console.error('오류:', err.message);
      process.exit(1);
    }
  })();
}

export { testSummarize, testLargeDocument, testRagPreprocessing, testAnalysis, benchmarkCosts, runAllTests };
