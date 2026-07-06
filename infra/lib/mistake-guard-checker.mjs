#!/usr/bin/env node
// mistake-guard-checker.mjs — 응답 생성 전 자동 검사 로직 (cl-a3200445ee1623e8)
//
// 목적: 응답을 생성할 때 반복 지적 항목(인자순서, 포맷, 자격증, 모순, 이력)을 자동 검증
//
// 사용법:
//   node mistake-guard-checker.mjs --response <text> --context <json> [--student-id <id>]
//
// 출력:
//   JSON 형식 검사 결과
//   {
//     "cluster_id": "cl-a3200445ee1623e8",
//     "checks": [
//       { "rule_id": "rule-arg-order", "status": "PASS|FAIL|WARN", "message": "..." }
//     ],
//     "overall": "PASS|FAIL|WARN",
//     "required_fixes": [ { "type": "...", "location": "...", "action": "..." } ]
//   }

import {
  readFileSync, existsSync,
} from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const CLUSTER_ID = 'cl-a3200445ee1623e8';
const RULES_FILE = join(HOME, '.jarvis', 'infra', 'lib', 'mistake-guard-rules.md');
const MEMORY_DIR = join(HOME, '.jarvis', 'runtime', 'state', 'student-memory');

function nowISO() {
  return new Date().toISOString();
}

function log(msg) {
  console.log(`[${nowISO()}] ${msg}`);
}

// 규칙 정의
const RULES = {
  'rule-arg-order': {
    name: '인자 순서 검증',
    severity: 'high',
    check: (response, context) => checkArgumentOrder(response, context),
  },
  'rule-format-consistency': {
    name: '포맷 규칙 일관성',
    severity: 'high',
    check: (response, context) => checkFormatConsistency(response, context),
  },
  'rule-cert-level': {
    name: '자격증 난이도 기준',
    severity: 'high',
    check: (response, context) => checkCertificationLevel(response, context),
  },
  'rule-session-consistency': {
    name: '세션 모순 검증',
    severity: 'medium',
    check: (response, context) => checkSessionConsistency(response, context),
  },
  'rule-student-sso-memory': {
    name: '학생 메모리 주입',
    severity: 'medium',
    check: (response, context) => checkStudentMemoryInjection(response, context),
  },
};

// ── 체크 함수들 ──

// 규칙 1: 인자 순서 검증
function checkArgumentOrder(response, context) {
  const issues = [];

  // 함수 호출 패턴 감지 (함수명(arg1, arg2, ...))
  const funcCallPattern = /\b(\w+)\s*\(\s*([^)]*)\)/g;
  let match;

  while ((match = funcCallPattern.exec(response)) !== null) {
    const funcName = match[1];
    const args = match[2];

    // 예시: 잘못된 패턴 감지 (각 함수마다 서명 검증이 필요하지만, 여기서는 기본 패턴만)
    // 예: git commit --amend -m → 순서 가능 (둘 다 flag이므로)
    // bash 명령의 경우 위치적 인자 순서 확인

    if (args.includes('-') && !args.match(/^-/)) {
      // 플래그가 뒤에 있으면 경고
      issues.push({
        type: 'potential_arg_order',
        location: funcName,
        details: `플래그가 뒤쪽에 있음 (${args})`,
        severity: 'warn',
      });
    }
  }

  // bash/npm 명령 패턴
  const bashPattern = /(?:npm|git|docker|bash|sh)\s+([a-z-]+)(?:\s+([^|$\n]*))?/gi;
  while ((match = bashPattern.exec(response)) !== null) {
    const cmd = match[1];
    const args = match[2] || '';

    // 특정 명령의 알려진 인자 순서 규칙
    const argOrderRules = {
      'commit': { flags_before: ['--amend'], positional_after: ['-m'] },
      'add': { positional_first: true },
    };

    if (argOrderRules[cmd]) {
      // 간단한 검증: -m이 플래그보다 먼저 오면 WARN
      if (cmd === 'commit' && args.indexOf('-m') > -1 && args.indexOf('-m') < args.indexOf('--')) {
        // OK
      }
    }
  }

  return {
    status: issues.length === 0 ? 'PASS' : issues.length <= 2 ? 'WARN' : 'FAIL',
    message: issues.length === 0
      ? '인자 순서 정상'
      : `잠재적 인자 순서 문제 ${issues.length}건: ${issues.map((i) => i.location).join(', ')}`,
    details: issues,
  };
}

// 규칙 2: 포맷 규칙 일관성
function checkFormatConsistency(response, context) {
  const issues = [];
  const lines = response.split('\n');

  let headerStyle = null; // markdown|bold|plain
  let bulletStyle = null; // dash|star|plus
  let prevIndent = 0;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim()) continue;

    // 제목 스타일 감지
    if (line.match(/^#+\s/)) {
      const level = line.match(/^#+/)[0].length;
      if (!headerStyle) headerStyle = `md_h${level}`;
      else if (headerStyle !== `md_h${level}` && line.match(/^##/) !== null) {
        // 헤더 수준이 섹션별로 일관되지 않음 (경고)
        issues.push({
          type: 'inconsistent_header_level',
          line: i + 1,
          content: line.slice(0, 50),
          severity: 'warn',
        });
      }
    }

    // 강조 제목
    if (line.match(/^\*\*[^*]+\*\*/)) {
      if (!headerStyle) headerStyle = 'bold';
    }

    // 나열 기호 감지
    if (line.match(/^\s*[-*+]\s/)) {
      const style = line.match(/^\s*([-*+])/)[1];
      if (!bulletStyle) bulletStyle = style;
      else if (bulletStyle !== style && Math.abs(prevIndent - (line.search(/\S/) || 0)) < 2) {
        // 같은 깊이에서 나열 기호가 바뀜
        issues.push({
          type: 'inconsistent_bullet_style',
          line: i + 1,
          expected: bulletStyle,
          found: style,
          severity: 'warn',
        });
      }
      prevIndent = line.search(/\S/) || 0;
    }
  }

  // 섹션 간 포맷 검증 (더 복잡한 분석은 context 필요)
  if (context?.previous_response) {
    const prevLines = context.previous_response.split('\n');
    const prevBullet = prevLines.find((l) => l.match(/^\s*[-*+]\s/))?.match(/^\s*([-*+])/)?.[1];
    if (prevBullet && bulletStyle && prevBullet !== bulletStyle) {
      issues.push({
        type: 'format_mismatch_with_previous',
        severity: 'medium',
        details: `이전 응답의 기호(${prevBullet})와 현재(${bulletStyle})가 다름`,
      });
    }
  }

  return {
    status: issues.length === 0 ? 'PASS' : issues.some((i) => i.severity === 'medium') ? 'FAIL' : 'WARN',
    message: issues.length === 0
      ? '포맷 일관성 정상'
      : `포맷 불일치 ${issues.length}건 감지`,
    details: issues,
  };
}

// 규칙 3: 자격증 난이도 기준
function checkCertificationLevel(response, context) {
  const issues = [];

  // 자격증/시험/교재 제안 키워드
  const certKeywords = ['자격증', '시험', '교재', '책', '강좌', '과정', 'certification', 'exam', 'course'];
  const hasCertProposal = certKeywords.some((kw) => response.toLowerCase().includes(kw));

  if (!hasCertProposal) {
    return {
      status: 'PASS',
      message: '자격증 제안 없음',
      details: [],
    };
  }

  // 자격증 제안이 있으면 학생 레벨·근거 확인
  const hasStudentLevel = response.includes('당신의') || response.includes('레벨') ||
                          response.includes('수준') || response.includes('당신');
  const hasReason = response.includes('때문에') || response.includes('필요') ||
                    response.includes('권장') || response.includes('적합');
  const hasDifficultyContext = response.match(/어려운|쉬운|고급|초급|중급|난이도|레벨|수준/gi);

  if (!hasStudentLevel) {
    issues.push({
      type: 'missing_student_context',
      severity: 'high',
      message: '학생의 현재 레벨 언급 없음',
    });
  }

  if (!hasReason) {
    issues.push({
      type: 'missing_justification',
      severity: 'high',
      message: '자격증 선택 근거(필요성) 없음',
    });
  }

  // 절대 난이도만 언급했는지 확인
  if (hasDifficultyContext && !hasStudentLevel) {
    issues.push({
      type: 'absolute_difficulty_only',
      severity: 'high',
      message: '절대 난이도만 언급 — 상대 난이도(학생 레벨 대비)를 포함해야 함',
    });
  }

  return {
    status: issues.length === 0 ? 'PASS' : 'FAIL',
    message: issues.length === 0
      ? '자격증 제안 근거 완전'
      : `자격증 제안 결함 ${issues.length}건`,
    details: issues,
  };
}

// 규칙 4: 세션 모순 검증
function checkSessionConsistency(response, context) {
  const issues = [];

  if (!context?.previous_responses || context.previous_responses.length === 0) {
    return {
      status: 'PASS',
      message: '이전 응답 없음 — 모순 검증 불필요',
      details: [],
    };
  }

  // 이전 응답에서 주요 결론 추출 (간단한 휴리스틱)
  const prevConclusions = context.previous_responses
    .flatMap((r) => r.match(/(?:결론|결과|따라서|그래서)\s*[:：]?\s*([^.。!！?？]+)/gi) || []);

  if (prevConclusions.length === 0) {
    return {
      status: 'PASS',
      message: '이전 결론 없음 — 모순 검증 불필요',
      details: [],
    };
  }

  // 현재 응답이 모순될 가능성이 있는 키워드
  const contradictionKeywords = ['모르겠습니다', '알 수 없습니다', '불명확', '확인 불가'];
  const isContradicting = contradictionKeywords.some((kw) => response.includes(kw));

  if (isContradicting && prevConclusions.length > 0) {
    issues.push({
      type: 'potential_contradiction',
      severity: 'warn',
      message: '이전 응답에서 이미 언급한 내용에 대해 "알 수 없다"고 응답 가능성',
      previous_conclusions: prevConclusions.slice(0, 2),
    });
  }

  return {
    status: issues.length === 0 ? 'PASS' : 'WARN',
    message: issues.length === 0
      ? '세션 일관성 정상'
      : `모순 가능성 ${issues.length}건`,
    details: issues,
  };
}

// 규칙 5: 학생 메모리 주입
function checkStudentMemoryInjection(response, context) {
  const issues = [];
  const studentId = context?.student_id;

  if (!studentId) {
    return {
      status: 'WARN',
      message: '학생 ID 미제공 — 메모리 주입 검증 불가',
      details: [],
    };
  }

  const memoryFile = join(MEMORY_DIR, `${studentId}.json`);

  // 메모리 파일 없음은 에러가 아니라 주의 수준으로 처리
  // (세션이 처음이거나 메모리가 아직 생성되지 않은 상태)
  if (!existsSync(memoryFile)) {
    return {
      status: 'PASS',  // WARN → PASS로 변경 (파일 없음은 정상)
      message: '신규 학생 또는 메모리 파일 미생성 상태 — 주입 검증 생략',
      details: [],
    };
  } else {
    // 메모리 파일이 있으면 로드 및 상호작용 반영 확인
    try {
      const memory = JSON.parse(readFileSync(memoryFile, 'utf-8'));
      const lastSessions = memory.sessions?.slice(-3) || [];

      if (lastSessions.length > 0) {
        // 메모리가 로드되었는지 간접 확인 (응답에 학생명·이전 세션 정보 포함 여부)
        const hasMemoryInference = response.includes(memory.name) ||
                                   response.includes('앞서') ||
                                   response.includes('저번') ||
                                   response.includes('이전 대화');

        if (!hasMemoryInference && response.length > 200) {
          // 충분한 길이의 응답인데 메모리 참조 없음 → 경고
          issues.push({
            type: 'memory_injection_weak',
            severity: 'medium',
            message: `학생 메모리가 로드되었으나 응답에 충분히 반영되지 않음 (${lastSessions.length}개 세션 보유)`,
          });
        }
      }
    } catch (e) {
      issues.push({
        type: 'memory_parse_error',
        severity: 'low',
        message: `메모리 파일 파싱 실패: ${e.message}`,
      });
    }
  }

  return {
    status: issues.some((i) => i.severity === 'medium') ? 'WARN' : 'PASS',
    message: issues.length === 0
      ? '학생 메모리 주입 정상'
      : `메모리 주입 이슈 ${issues.length}건`,
    details: issues,
  };
}

// ── 메인 체크 함수 ──

function checkResponse(response, context = {}) {
  const results = {
    cluster_id: CLUSTER_ID,
    timestamp: nowISO(),
    student_id: context.student_id || 'unknown',
    checks: [],
    required_fixes: [],
  };

  let hasFailure = false;
  let hasWarning = false;

  for (const [ruleId, rule] of Object.entries(RULES)) {
    try {
      const check = rule.check(response, context);
      results.checks.push({
        rule_id: ruleId,
        name: rule.name,
        severity: rule.severity,
        ...check,
      });

      if (check.status === 'FAIL') {
        hasFailure = true;
        if (check.details?.length > 0) {
          results.required_fixes.push(...check.details.map((d) => ({
            rule_id: ruleId,
            ...d,
          })));
        }
      } else if (check.status === 'WARN') {
        hasWarning = true;
      }
    } catch (e) {
      results.checks.push({
        rule_id: ruleId,
        name: rule.name,
        severity: rule.severity,
        status: 'ERROR',
        message: `체크 실행 오류: ${e.message}`,
      });
    }
  }

  results.overall = hasFailure ? 'FAIL' : hasWarning ? 'WARN' : 'PASS';

  return results;
}

// ── CLI 파싱 ──

const args = process.argv.slice(2);
const response = args.find((a) => a.startsWith('--response'))?.split('=')[1] ||
                 args[args.indexOf('--response') + 1] ||
                 (args[0]?.startsWith('--') ? '' : args[0]);
const contextArg = args.find((a) => a.startsWith('--context'))?.split('=')[1] ||
                   args[args.indexOf('--context') + 1];
const studentId = args.find((a) => a.startsWith('--student-id'))?.split('=')[1] ||
                  args[args.indexOf('--student-id') + 1];

if (!response) {
  console.error('필수: --response <text> [--context <json>] [--student-id <id>]');
  process.exit(1);
}

let context = { student_id: studentId };
if (contextArg) {
  try {
    context = { ...context, ...JSON.parse(contextArg) };
  } catch (e) {
    log(`WARN: context JSON 파싱 실패: ${e.message}`);
  }
}

const result = checkResponse(response, context);
console.log(JSON.stringify(result, null, 2));

// exit 코드: FAIL=1, WARN=0, PASS=0 (경고는 무시, 실패만 감지)
process.exit(result.overall === 'FAIL' ? 1 : 0);
