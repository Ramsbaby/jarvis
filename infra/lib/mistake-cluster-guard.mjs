#!/usr/bin/env node
/**
 * mistake-cluster-guard.mjs — 반복 실수 클러스터 구조적 가드
 *
 * 역할: cl-1b6f71eed569a8b7 같은 반복 실수 클러스터에 대해:
 *   1. 구조적 패턴 인식 (e.g., "감사관 오류 미검증" → 단방향 신뢰 문제)
 *   2. 자동 가드 룰 생성 및 적용 (cross-validator 호출, /verify 강제 등)
 *   3. 클러스터 재발률 추적 (7일 내 재발 횟수)
 *   4. 발견 및 수정 시 메타인지 루프 강화
 *
 * 시스템 통합:
 *   - auditor fix 후: post-fix-verification.sh 자동 호출
 *   - anger-detector 신호 시: triggerSkillPatch 작동
 *   - task-run-observer 통합: 스킬 패치 기록
 *   - 최종: project-context 주입으로 프롬프트 강화
 */

import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const STATE_DIR = join(BOT_HOME, 'state');
const CLUSTER_GUARDS_DIR = join(STATE_DIR, 'cluster-guards');
const METRICS_FILE = join(STATE_DIR, 'cluster-recurrence-metrics.jsonl');

/**
 * 클러스터별 가드 정의
 * 나중에 외부 파일로 옮길 수 있음
 */
const CLUSTER_DEFINITIONS = {
  'cl-1b6f71eed569a8b7': {
    name: 'Auditor Trust Without Cross-Validation',
    seedPattern: '감사관 오류 미검증 — 단방향 신뢰로 재검증 없음',
    memberPatterns: [
      '감사관 오류 미검증',
      '초기 감시 기준 설정 오류',
      '1차 수정 후 /verify 미실시',
      '첫 수정안의 설계 구멍',
      '원인 파악 후 검증 미실시',
    ],
    guards: [
      // Guard 1: 수정 후 항상 /verify 재검증 강제
      {
        id: 'enforce-post-fix-verify',
        type: 'post-fix-hook',
        action: 'invoke_post_fix_verification',
        params: { timeout_secs: 120 },
        description: '모든 수정 후 post-fix-verification.sh 자동 호출',
      },
      // Guard 2: 감사관 결과 교차 검증 (단방향 신뢰 방지)
      {
        id: 'cross-validate-auditor',
        type: 'auditor-hook',
        action: 'invoke_cross_validator',
        params: { timeout_secs: 60 },
        description: '감사관 결과를 cross-validator로 재검증',
      },
      // Guard 3: 고위험 패턴 감시 (초기 감시 기준 오류 방지)
      {
        id: 'high-risk-pattern-watch',
        type: 'anti-pattern-enhanced',
        patterns: [
          {
            pattern: 'single-direction-trust',
            description: '단방향 신뢰 패턴 (X 검증 없이 Y 결과만 신뢰)',
            examples: ['감사관 출력만 믿음', '초기 조건만으로 성공 판정'],
          },
          {
            pattern: 'unverified-cooldown',
            description: '검증 없이 cooldown 기준만 사용',
            examples: ['재시도 횟수만 보고 실제 고침 확인 안 함'],
          },
        ],
      },
      // Guard 4: anger-detector 신호 시 skill patch 자동 트리거
      {
        id: 'anger-to-skill-patch',
        type: 'anger-detector-hook',
        action: 'trigger_skill_patch',
        description: '사용자 분노 신호 감지 시 skill patch 자동 생성',
      },
    ],
    escalationPath: 'ceo-approval-for-design-fix',
    ttl_days: 30,
  },
};

class MistakeClusterGuard {
  constructor() {
    this.clusters = new Map(Object.entries(CLUSTER_DEFINITIONS));
    this.metrics = [];
    mkdirSync(CLUSTER_GUARDS_DIR, { recursive: true });
  }

  /**
   * 클러스터ID로 정의 조회
   */
  getClusterDef(clusterId) {
    return this.clusters.get(clusterId) || null;
  }

  /**
   * 클러스터 가드 상태 파일 초기화/업데이트
   */
  initializeClusterGuard(clusterId, metadata = {}) {
    const clusterDef = this.getClusterDef(clusterId);
    if (!clusterDef) {
      throw new Error(`Cluster definition not found: ${clusterId}`);
    }

    const guardFile = join(CLUSTER_GUARDS_DIR, `${clusterId}.json`);
    const guardState = {
      cluster_id: clusterId,
      cluster_name: clusterDef.name,
      guard_status: 'active',
      created_at: new Date().toISOString(),
      last_updated: new Date().toISOString(),
      guards_applied: clusterDef.guards.map(g => ({
        id: g.id,
        type: g.type,
        action: g.action,
        status: 'pending',
        executions: 0,
        last_exec: null,
      })),
      recurrence_count: 0,
      recurrence_days: [],
      escalation_path: clusterDef.escalationPath,
      metadata,
    };

    writeFileSync(guardFile, JSON.stringify(guardState, null, 2));
    return guardState;
  }

  /**
   * 가드 실행 기록 (Guard가 작동했을 때 호출)
   */
  recordGuardExecution(clusterId, guardId, result) {
    const guardFile = join(CLUSTER_GUARDS_DIR, `${clusterId}.json`);

    if (!existsSync(guardFile)) {
      this.initializeClusterGuard(clusterId);
    }

    const guardState = JSON.parse(readFileSync(guardFile, 'utf-8'));
    const guard = guardState.guards_applied.find(g => g.id === guardId);

    if (guard) {
      guard.executions += 1;
      guard.last_exec = new Date().toISOString();
      guard.last_result = result;
      if (result !== 'success') {
        guard.status = 'issue-detected';
      }
    }

    guardState.last_updated = new Date().toISOString();
    writeFileSync(guardFile, JSON.stringify(guardState, null, 2));

    // JSONL 메트릭 기록
    this.recordMetric({
      cluster_id: clusterId,
      guard_id: guardId,
      result,
      timestamp: new Date().toISOString(),
    });
  }

  /**
   * 재발 기록
   */
  recordRecurrence(clusterId, incidentDescription) {
    const guardFile = join(CLUSTER_GUARDS_DIR, `${clusterId}.json`);

    if (!existsSync(guardFile)) {
      this.initializeClusterGuard(clusterId);
    }

    const guardState = JSON.parse(readFileSync(guardFile, 'utf-8'));
    const today = new Date().toISOString().split('T')[0];

    if (!guardState.recurrence_days.includes(today)) {
      guardState.recurrence_days.push(today);
      guardState.recurrence_count += 1;
    }

    guardState.last_recurrence = {
      date: new Date().toISOString(),
      description: incidentDescription,
    };

    guardState.last_updated = new Date().toISOString();
    writeFileSync(guardFile, JSON.stringify(guardState, null, 2));

    // JSONL 메트릭 기록
    this.recordMetric({
      cluster_id: clusterId,
      type: 'recurrence',
      description: incidentDescription,
      timestamp: new Date().toISOString(),
    });
  }

  /**
   * 메트릭 기록 (JSONL append)
   */
  recordMetric(metric) {
    mkdirSync(STATE_DIR, { recursive: true });
    appendFileSync(METRICS_FILE, JSON.stringify(metric) + '\n');
  }

  /**
   * 클러스터 재발률 계산 (최근 7일)
   */
  getRecurrenceRate(clusterId) {
    const guardFile = join(CLUSTER_GUARDS_DIR, `${clusterId}.json`);

    if (!existsSync(guardFile)) {
      return { count: 0, days: [] };
    }

    const guardState = JSON.parse(readFileSync(guardFile, 'utf-8'));
    const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 3600_000)
      .toISOString()
      .split('T')[0];

    const recent = guardState.recurrence_days.filter(d => d >= sevenDaysAgo);
    return {
      count: recent.length,
      days: recent,
      last_recurrence: guardState.last_recurrence,
    };
  }

  /**
   * 가드 상태 조회
   */
  getGuardStatus(clusterId) {
    const guardFile = join(CLUSTER_GUARDS_DIR, `${clusterId}.json`);

    if (!existsSync(guardFile)) {
      return null;
    }

    return JSON.parse(readFileSync(guardFile, 'utf-8'));
  }

  /**
   * 모든 활성 클러스터 나열
   */
  getActiveClusters() {
    const files = require('node:fs')
      .readdirSync(CLUSTER_GUARDS_DIR)
      .filter(f => f.endsWith('.json'));

    return files.map(f => {
      const state = JSON.parse(readFileSync(join(CLUSTER_GUARDS_DIR, f), 'utf-8'));
      return {
        cluster_id: state.cluster_id,
        cluster_name: state.cluster_name,
        guard_status: state.guard_status,
        recurrence_count: state.recurrence_count,
        last_updated: state.last_updated,
      };
    });
  }
}

/**
 * CLI 엔트리포인트
 */
async function main() {
  const args = process.argv.slice(2);
  const guard = new MistakeClusterGuard();

  if (args.length === 0) {
    console.log('Usage:');
    console.log('  mistake-cluster-guard.mjs init <cluster-id>');
    console.log('  mistake-cluster-guard.mjs record-exec <cluster-id> <guard-id> <result>');
    console.log('  mistake-cluster-guard.mjs record-recurrence <cluster-id> <description>');
    console.log('  mistake-cluster-guard.mjs status <cluster-id>');
    console.log('  mistake-cluster-guard.mjs list');
    return;
  }

  const cmd = args[0];

  try {
    switch (cmd) {
      case 'init': {
        const clusterId = args[1];
        const state = guard.initializeClusterGuard(clusterId);
        console.log(`✅ Guard initialized for ${clusterId}`);
        console.log(JSON.stringify(state, null, 2));
        break;
      }

      case 'record-exec': {
        const clusterId = args[1];
        const guardId = args[2];
        const result = args[3] || 'unknown';
        guard.recordGuardExecution(clusterId, guardId, result);
        console.log(`✅ Guard execution recorded: ${guardId} = ${result}`);
        break;
      }

      case 'record-recurrence': {
        const clusterId = args[1];
        const desc = args.slice(2).join(' ');
        guard.recordRecurrence(clusterId, desc);
        console.log(`✅ Recurrence recorded for ${clusterId}`);
        break;
      }

      case 'status': {
        const clusterId = args[1];
        const status = guard.getGuardStatus(clusterId);
        if (!status) {
          console.log(`⚠️  No guard found for ${clusterId}`);
        } else {
          const rate = guard.getRecurrenceRate(clusterId);
          console.log(JSON.stringify({ status, recurrence_rate: rate }, null, 2));
        }
        break;
      }

      case 'list': {
        const clusters = guard.getActiveClusters();
        console.log(JSON.stringify(clusters, null, 2));
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

export { MistakeClusterGuard };

if (import.meta.url.startsWith('file://') && process.argv[1] === import.meta.url.replace('file://', '')) {
  main().catch(err => {
    console.error(err);
    process.exit(1);
  });
}
