#!/usr/bin/env node
/**
 * rule-execution-audit.mjs — 규칙 실행 추적 및 감시 시스템
 *
 * 역할:
 *   1. 선언된 규칙(한영병기, HTML 업로드, 동기화)의 실행 여부를 기록
 *   2. 규칙 위반 사건을 감시하고 로깅
 *   3. 클러스터 cl-5f04f13d1c3d759d의 재발 패턴 추적
 *   4. verify-before-report 가드와 통합하여 거짓 상태 보고 방지
 *
 * 사용:
 *   rule-execution-audit.mjs --record <rule-id> <status> [metadata]
 *   rule-execution-audit.mjs --query <rule-id> [--window 7d]
 *   rule-execution-audit.mjs --list-violations
 *   rule-execution-audit.mjs --summary
 */

import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const STATE_DIR = join(BOT_HOME, 'runtime/state');
const AUDIT_LOG = join(STATE_DIR, 'rule-execution-audit.jsonl');
const RULE_VIOLATIONS = join(STATE_DIR, 'rule-violations.jsonl');

// 규칙 정의 (cl-5f04f13d1c3d759d 클러스터)
const RULES = {
  'bilingual-grammar-tables': {
    name: '한영병기 규칙',
    description: '문법 표가 있으면 반드시 영어 해석 포함',
    cluster: 'cl-5f04f13d1c3d759d',
    severity: 'high',
  },
  'html-upload-path': {
    name: 'HTML 업로드 경로 명시',
    description: 'HTML 파일 업로드 시 대상 경로 반드시 명시',
    cluster: 'cl-5f04f13d1c3d759d',
    severity: 'high',
  },
  'synchronization-complete': {
    name: '동기화 완료 명시',
    description: '다중 소스 변경 시 동기화 완료 상태 명시',
    cluster: 'cl-5f04f13d1c3d759d',
    severity: 'medium',
  },
};

class RuleExecutionAudit {
  constructor() {
    mkdirSync(STATE_DIR, { recursive: true });
  }

  /**
   * 규칙 실행 기록 (성공/실패/스킵)
   */
  recordRuleExecution(ruleId, status, metadata = {}) {
    const rule = RULES[ruleId];
    if (!rule) {
      throw new Error(`Unknown rule: ${ruleId}`);
    }

    const record = {
      timestamp: new Date().toISOString(),
      rule_id: ruleId,
      rule_name: rule.name,
      status, // 'pass', 'fail', 'skip'
      severity: rule.severity,
      cluster: rule.cluster,
      metadata,
    };

    appendFileSync(AUDIT_LOG, JSON.stringify(record) + '\n');

    // 실패 시 위반 기록
    if (status === 'fail') {
      this.recordViolation(ruleId, rule, metadata);
    }

    return record;
  }

  /**
   * 규칙 위반 사건 기록
   */
  recordViolation(ruleId, rule, metadata) {
    const violation = {
      timestamp: new Date().toISOString(),
      rule_id: ruleId,
      rule_name: rule.name,
      description: rule.description,
      severity: rule.severity,
      cluster: rule.cluster,
      details: metadata,
    };

    appendFileSync(RULE_VIOLATIONS, JSON.stringify(violation) + '\n');
  }

  /**
   * 특정 규칙의 최근 실행 이력 조회
   */
  queryRule(ruleId, windowDays = 7) {
    if (!existsSync(AUDIT_LOG)) {
      return { rule_id: ruleId, executions: [], total: 0 };
    }

    const lines = readFileSync(AUDIT_LOG, 'utf-8').split('\n').filter(l => l.trim());
    const cutoffDate = new Date(Date.now() - windowDays * 24 * 60 * 60 * 1000).toISOString();

    const executions = lines
      .map(l => JSON.parse(l))
      .filter(r => r.rule_id === ruleId && r.timestamp >= cutoffDate)
      .sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));

    const summary = {
      pass: executions.filter(e => e.status === 'pass').length,
      fail: executions.filter(e => e.status === 'fail').length,
      skip: executions.filter(e => e.status === 'skip').length,
    };

    return {
      rule_id: ruleId,
      rule_name: RULES[ruleId]?.name,
      window_days: windowDays,
      total: executions.length,
      summary,
      executions,
    };
  }

  /**
   * 모든 위반 사건 나열
   */
  listViolations(windowDays = 7) {
    if (!existsSync(RULE_VIOLATIONS)) {
      return { violations: [] };
    }

    const lines = readFileSync(RULE_VIOLATIONS, 'utf-8').split('\n').filter(l => l.trim());
    const cutoffDate = new Date(Date.now() - windowDays * 24 * 60 * 60 * 1000).toISOString();

    const violations = lines
      .map(l => JSON.parse(l))
      .filter(v => v.timestamp >= cutoffDate)
      .sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));

    const bySeverity = {
      critical: violations.filter(v => v.severity === 'critical').length,
      high: violations.filter(v => v.severity === 'high').length,
      medium: violations.filter(v => v.severity === 'medium').length,
      low: violations.filter(v => v.severity === 'low').length,
    };

    return { violations, total: violations.length, by_severity: bySeverity, window_days: windowDays };
  }

  /**
   * 클러스터별 감시 요약
   */
  getSummary(clusterId = 'cl-5f04f13d1c3d759d', windowDays = 7) {
    const auditResult = this.getClusterAudit(clusterId, windowDays);
    const violationResult = this.listViolations(windowDays);

    const clusterViolations = violationResult.violations.filter(v => v.cluster === clusterId);

    return {
      cluster_id: clusterId,
      window_days: windowDays,
      rules_defined: Object.keys(RULES).filter(k => RULES[k].cluster === clusterId).length,
      total_executions: auditResult.total_executions,
      total_violations: clusterViolations.length,
      execution_summary: auditResult.summary,
      violation_summary: {
        by_rule: clusterViolations.reduce((acc, v) => {
          if (!acc[v.rule_id]) acc[v.rule_id] = [];
          acc[v.rule_id].push(v);
          return acc;
        }, {}),
      },
    };
  }

  /**
   * 클러스터별 감사 상태
   */
  getClusterAudit(clusterId, windowDays = 7) {
    if (!existsSync(AUDIT_LOG)) {
      return { cluster_id: clusterId, total_executions: 0, summary: {} };
    }

    const lines = readFileSync(AUDIT_LOG, 'utf-8').split('\n').filter(l => l.trim());
    const cutoffDate = new Date(Date.now() - windowDays * 24 * 60 * 60 * 1000).toISOString();

    const executions = lines
      .map(l => JSON.parse(l))
      .filter(r => r.cluster === clusterId && r.timestamp >= cutoffDate);

    const summary = {
      pass: executions.filter(e => e.status === 'pass').length,
      fail: executions.filter(e => e.status === 'fail').length,
      skip: executions.filter(e => e.status === 'skip').length,
    };

    return {
      cluster_id: clusterId,
      window_days: windowDays,
      total_executions: executions.length,
      summary,
    };
  }
}

/**
 * CLI 엔트리포인트
 */
async function main() {
  const args = process.argv.slice(2);
  const audit = new RuleExecutionAudit();

  if (args.length === 0) {
    console.log('Usage:');
    console.log('  rule-execution-audit.mjs --record <rule-id> <status> [metadata-json]');
    console.log('  rule-execution-audit.mjs --query <rule-id> [--window 7]');
    console.log('  rule-execution-audit.mjs --list-violations [--window 7]');
    console.log('  rule-execution-audit.mjs --summary [cluster-id] [--window 7]');
    console.log('');
    console.log('Available rules:');
    Object.entries(RULES).forEach(([id, rule]) => {
      console.log(`  ${id}: ${rule.name} (${rule.severity})`);
    });
    return;
  }

  const cmd = args[0];

  try {
    switch (cmd) {
      case '--record': {
        const ruleId = args[1];
        const status = args[2];
        let metadata = {};
        if (args[3]) {
          try {
            metadata = JSON.parse(args[3]);
          } catch (e) {
            console.error('Invalid JSON metadata:', args[3]);
            process.exit(1);
          }
        }

        const record = audit.recordRuleExecution(ruleId, status, metadata);
        console.log(`✅ Rule execution recorded: ${ruleId} = ${status}`);
        console.log(JSON.stringify(record, null, 2));
        break;
      }

      case '--query': {
        const ruleId = args[1];
        const windowIdx = args.indexOf('--window');
        const windowDays = windowIdx !== -1 ? parseInt(args[windowIdx + 1], 10) : 7;

        const result = audit.queryRule(ruleId, windowDays);
        console.log(JSON.stringify(result, null, 2));
        break;
      }

      case '--list-violations': {
        const windowIdx = args.indexOf('--window');
        const windowDays = windowIdx !== -1 ? parseInt(args[windowIdx + 1], 10) : 7;

        const result = audit.listViolations(windowDays);
        console.log(JSON.stringify(result, null, 2));
        break;
      }

      case '--summary': {
        const clusterId = args[1] || 'cl-5f04f13d1c3d759d';
        const windowIdx = args.indexOf('--window');
        const windowDays = windowIdx !== -1 ? parseInt(args[windowIdx + 1], 10) : 7;

        const result = audit.getSummary(clusterId, windowDays);
        console.log(JSON.stringify(result, null, 2));
        break;
      }

      default:
        console.error(`Unknown command: ${cmd}`);
        process.exit(1);
    }
  } catch (err) {
    console.error(`ERROR: ${err.message}`);
    process.exit(1);
  }
}

export { RuleExecutionAudit };

// 메인 스크립트로 실행되는 경우
if (import.meta.url === `file://${process.argv[1]}` ||
    import.meta.url === `file:///${process.argv[1].replace(/^\//, '')}` ||
    process.argv[1].endsWith('rule-execution-audit.mjs')) {
  main().catch(err => {
    console.error(err);
    process.exit(1);
  });
}
