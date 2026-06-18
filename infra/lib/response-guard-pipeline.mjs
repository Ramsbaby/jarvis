#!/usr/bin/env node

// 통합 후처리 필터 파이프라인
// 용도: 응답 생성 후 3개 가드를 체이닝하여 자동 검증 및 경고/재작성 트리거
// 입력: stdin으로 JSON { content, recipient_age?, recipient_gender?, recipient_health_status? }
// 반환: { original, guard_results, requires_rewrite: boolean, rewrite_prompt?: string }

import { readFileSync } from 'fs';
import { execSync, spawnSync } from 'child_process';

const input = JSON.parse(readFileSync(0, 'utf-8'));
const { content, recipient_age, recipient_gender, recipient_health_status } = input;

const guard_results = {
  sensitive_info: null,
  recipient_match: null,
  supplement_dose: null,
};

let requires_rewrite = false;
let rewrite_issues = [];

// Guard 1: 민감 정보 탐지
try {
  const sensitiveInfoScript = `${process.env.HOME}/.jarvis/lib/sensitive-info-detector.sh`;
  const sensitiveResult = execSync(`bash ${sensitiveInfoScript} "${content.replace(/"/g, '\\"')}"`, {
    encoding: 'utf-8',
  });
  const detected = JSON.parse(sensitiveResult);
  if (detected.length > 0) {
    guard_results.sensitive_info = {
      detected: detected,
      alert: `민감한 개인정보 탐지됨: ${detected.join(', ')}`,
    };
    requires_rewrite = true;
    rewrite_issues.push(`개인정보 제거: ${detected.join(', ')}`);
  } else {
    guard_results.sensitive_info = { detected: [], alert: null };
  }
} catch (e) {
  guard_results.sensitive_info = { error: e.message };
}

// Guard 2: 수신자-권장사항 매칭 검증
try {
  const matcherScript = `${process.env.HOME}/.jarvis/lib/recipient-matcher.mjs`;
  const matcherResult = spawnSync('node', [matcherScript], {
    input: JSON.stringify({ content, recipient_age, recipient_gender, recipient_health_status }),
    encoding: 'utf-8',
  });
  if (matcherResult.status === 0) {
    guard_results.recipient_match = JSON.parse(matcherResult.stdout);
    if (!guard_results.recipient_match.valid) {
      requires_rewrite = true;
      guard_results.recipient_match.issues.forEach((issue) => {
        rewrite_issues.push(`속성 검증 실패: ${issue}`);
      });
    }
  } else {
    guard_results.recipient_match = { error: matcherResult.stderr };
  }
} catch (e) {
  guard_results.recipient_match = { error: e.message };
}

// Guard 3: 영양제·의약품 절대값 패턴 탐지
try {
  const doseScript = `${process.env.HOME}/.jarvis/lib/supplement-dose-detector.mjs`;
  const doseResult = spawnSync('node', [doseScript], {
    input: content,
    encoding: 'utf-8',
  });
  if (doseResult.status === 0) {
    guard_results.supplement_dose = JSON.parse(doseResult.stdout);
    if (guard_results.supplement_dose.rewrite_suggested) {
      requires_rewrite = true;
      guard_results.supplement_dose.warnings.forEach((warning) => {
        rewrite_issues.push(`용량 표현 개선: ${warning}`);
      });
    }
  } else {
    guard_results.supplement_dose = { error: doseResult.stderr };
  }
} catch (e) {
  guard_results.supplement_dose = { error: e.message };
}

// 재작성 프롬프트 생성
let rewrite_prompt = null;
if (requires_rewrite && rewrite_issues.length > 0) {
  rewrite_prompt = `응답에서 아래 문제점을 수정해줘 (콘텐츠 다시 생성):\n\n${rewrite_issues.map((i) => `• ${i}`).join('\n')}\n\n수정 규칙:\n1. 개인정보는 모두 제거\n2. 용량 제시 시 단위 명시 필수 (mg, g, ml, 캡슐 등)\n3. 절대적 표현 대신 "의료 전문가와 상담 후", "개인차에 따라" 등 추가\n4. 건강 조언 시 면책 조항 포함`;
}

// 결과 출력
console.log(
  JSON.stringify(
    {
      original: content,
      guard_results,
      requires_rewrite,
      rewrite_issues: rewrite_issues,
      rewrite_prompt,
      summary: {
        passed: !requires_rewrite,
        severity: requires_rewrite
          ? guard_results.sensitive_info?.detected?.length > 0
            ? 'critical'
            : 'high'
          : 'pass',
      },
    },
    null,
    2
  )
);
