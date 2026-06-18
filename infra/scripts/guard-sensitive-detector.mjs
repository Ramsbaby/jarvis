#!/usr/bin/env node

/**
 * guard-sensitive-detector.mjs
 *
 * 민감 개인정보(PII) 및 보건 정보 탐지 필터
 * 응답에 포함된 다음 정보를 자동 탐지:
 * - 주민번호, 카드번호, 계좌번호
 * - 휴대폰번호, 이메일
 * - 병력, 약물 알레르기, 특정 건강 상태
 *
 * 입력: JSON {text: string, context: {userId, channelId}}
 * 출력: JSON {detected: boolean, issues: [], severity: "critical"|"warning"|"none"}
 */

/**
 * Sensitive information patterns
 */
const SENSITIVE_PATTERNS = {
  // 주민번호 (YYMMDD-XXXXXXX)
  ssn: {
    pattern: /\b\d{2}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])-[1-4]\d{6}\b/g,
    name: '주민번호',
    severity: 'critical'
  },

  // 신용카드번호 (4자리씩, Luhn algorithm은 선택)
  creditCard: {
    pattern: /\b(?:\d[ -]*?){13,19}\b/g,
    name: '카드번호',
    severity: 'critical',
    validate: validateCreditCard
  },

  // 계좌번호 (은행명-계좌)
  accountNumber: {
    pattern: /(?:계좌|계정)[:\s]*(\d{10,20})|(?:신한|국민|우리|하나|농협|SC|중앙|대구|부산)[:\s]*(\d{10,20})/gi,
    name: '계좌번호',
    severity: 'critical'
  },

  // 휴대폰번호 (010/011/016/017/018/019-XXXX-XXXX)
  phoneNumber: {
    pattern: /01[0-9]-\d{3,4}-\d{4}|\b01[0-9]\d{7,8}\b/g,
    name: '휴대폰번호',
    severity: 'critical'
  },

  // 이메일 주소
  email: {
    pattern: /[\w\.-]+@[\w\.-]+\.\w+/g,
    name: '이메일',
    severity: 'warning'
  },

  // 병력 관련 민감 표현
  medicalHistory: {
    pattern: /(?:암|종양|에이즈|HIV|성병|매독|당뇨|고혈압|심장병|정신병|정신분열|조현병|우울증|불안장애|중독)[^.!?]*(?:진단|확진|판정|병력)/gi,
    name: '병력 정보',
    severity: 'critical'
  },

  // 알레르기 정보
  allergies: {
    pattern: /(?:알레르기|알러지)[:\s]*[^.!?\n]*(?:약물|항생제|페니실린|아스피린)/gi,
    name: '약물 알레르기',
    severity: 'critical'
  },

  // 약물 구체적 정보 (개인 처방약)
  prescription: {
    pattern: /(?:복용|투약|처방)[:\s]*(?:프로작|리튬|할로페리돌|클로자핀|리스페리돈|올란자핀)\b/gi,
    name: '처방약 정보',
    severity: 'critical'
  }
};

/**
 * Simplified Luhn algorithm validation
 */
function validateCreditCard(number) {
  const digits = number.replace(/\D/g, '');
  if (digits.length < 13 || digits.length > 19) return false;

  let sum = 0;
  let isEven = false;
  for (let i = digits.length - 1; i >= 0; i--) {
    let digit = parseInt(digits[i], 10);
    if (isEven) {
      digit *= 2;
      if (digit > 9) digit -= 9;
    }
    sum += digit;
    isEven = !isEven;
  }
  return sum % 10 === 0;
}

/**
 * Detect sensitive information in text
 */
function detectSensitiveInfo(text) {
  const issues = [];

  for (const [key, config] of Object.entries(SENSITIVE_PATTERNS)) {
    const matches = text.matchAll(config.pattern);

    for (const match of matches) {
      // Skip validation for patterns without validator
      if (config.validate && !config.validate(match[0])) {
        continue;
      }

      issues.push({
        type: key,
        name: config.name,
        severity: config.severity,
        sample: match[0].substring(0, 20) + '***' // Redact in output
      });
    }
  }

  return issues;
}

/**
 * Analyze sensitive data
 */
function analyzeSensitiveData(text, context = {}) {
  if (!text || typeof text !== 'string') {
    return {
      detected: false,
      issues: [],
      severity: 'none'
    };
  }

  const issues = detectSensitiveInfo(text);
  const hasIssue = issues.length > 0;
  const maxSeverity = issues.length > 0
    ? issues.reduce((max, issue) =>
        issue.severity === 'critical' ? 'critical' : max,
        'warning'
      )
    : 'none';

  return {
    detected: hasIssue,
    issues: issues,
    severity: maxSeverity,
    recommendation: getRecommendation(issues, context)
  };
}

/**
 * Generate remediation recommendation
 */
function getRecommendation(issues, context) {
  if (issues.length === 0) return null;

  const criticalIssues = issues.filter(i => i.severity === 'critical');

  if (criticalIssues.length > 0) {
    return {
      action: 'BLOCK_AND_REGENERATE',
      reason: `민감한 개인정보 ${criticalIssues.length}건 감지됨: ${criticalIssues.map(i => i.name).join(', ')}`,
      instruction: '응답을 재작성하되, 민감한 개인정보는 일반화하거나 마스킹(***) 처리하세요.'
    };
  }

  return {
    action: 'WARN',
    reason: `주의 대상 정보 ${issues.length}건 감지됨: ${issues.map(i => i.name).join(', ')}`,
    instruction: '응답 검토를 권고합니다.'
  };
}

/**
 * Main entry point
 */
const input = JSON.parse(process.argv[2] || '{}');
const result = analyzeSensitiveData(input.text, input.context);
console.log(JSON.stringify(result, null, 2));
