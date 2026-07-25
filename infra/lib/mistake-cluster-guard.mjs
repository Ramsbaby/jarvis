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

import { readFileSync, writeFileSync, appendFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
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
  'cl-081997ea83d6da01': {
    name: 'Idempotency Violation - Duplicate Side Effects on Re-execution',
    seedPattern: '검증 목적의 재실행이 중복 버그 유발 — 멱등성 부재',
    memberPatterns: [
      '검증 목적의 재실행이 중복 버그 유발',
      '자체 검증 기능(중복 방지 가드) 추가했다고 선언 후 실제로는 작동 안 됨',
      '검증 로직 동작 미확인 후 재실행 의도 → 부작용 생성',
      '자가 판단 오류 → 추정 기반 재실행 → 중복 부작용 유발',
      '단일 사이클 검증만 실행 — 전체 패턴 교차검증 누락',
    ],
    guards: [
      // Guard 1: send/create/insert 함수에 이미 완료 여부 체크 강제
      {
        id: 'idempotency-key-validation',
        type: 'pre-execution-hook',
        action: 'check_idempotency_key',
        params: { timeout_secs: 10 },
        description: '모든 부작용 함수(send, create, insert) 실행 전 이미 완료 상태 확인',
      },
      // Guard 2: 실행 로그 대조를 통한 중복 실행 방지
      {
        id: 'execution-log-dedup',
        type: 'execution-tracker',
        action: 'check_execution_log',
        params: {
          log_file: '~/jarvis/runtime/state/execution-log.jsonl',
          hash_by_input: true,
        },
        description: '입력값 기반 해시로 동일 입력 재실행 감지 및 skip 처리',
      },
      // Guard 3: 상태 DB에 unique key 체크
      {
        id: 'unique-key-db-check',
        type: 'state-db-validator',
        action: 'validate_unique_constraint',
        params: {
          db_path: '~/jarvis/runtime/state/execution-state.db',
          fields: ['operation_type', 'target_id', 'input_hash'],
        },
        description: 'SQLite 상태 DB에 unique constraint를 통한 중복 실행 방지',
      },
      // Guard 4: 재실행 시뮬레이션 검증 (동일 입력 2회 실행 → 2번째는 skip)
      {
        id: 'reexecution-simulation-test',
        type: 'test-runner',
        action: 'run_idempotency_test',
        params: {
          timeout_secs: 30,
          repeat_count: 2,
        },
        description: '동일한 입력으로 함수를 2회 연속 실행하여 멱등성 검증',
      },
      // Guard 5: 기존 테스트 무결성 검증
      {
        id: 'legacy-test-compatibility',
        type: 'regression-test',
        action: 'run_existing_tests',
        params: { timeout_secs: 60 },
        description: '멱등성 가드 추가 전 통과하던 모든 기존 테스트 재검증',
      },
      // Guard 6: 멱등성 가드 작동 상태 메트릭 추적
      {
        id: 'idempotency-metrics-collector',
        type: 'metric-collector',
        action: 'collect_idempotency_metrics',
        params: {
          metrics_file: '~/jarvis/runtime/state/idempotency-metrics.jsonl',
          window_hours: 24,
        },
        description: '재실행 방지 여부, 중복 감지 횟수, skip 비율 등을 메트릭으로 추적',
      },
    ],
    escalationPath: 'idempotency-design-review',
    ttl_days: 30,
    priority: 'high',
  },
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
  'cl-f6921eb1d5ea4c87': {
    name: 'Partial Completion False Declaration (전체 합계 명시 후 부분만 처리)',
    seedPattern: '전체 합계 명시 후 부분 데이터만 계산 — 누락 미감지',
    memberPatterns: [
      '전체 합계 명시 후 부분 데이터만 계산 (누락 미감지)',
      '부분 조치 후 완료 선언 (skill-synthesis-verify 수정만)',
      '부분 중단 후 안전 상태 단언 — 나머지 인덱싱 프로세스 미발견',
      '검증 없이 추정을 사실처럼 보고 — 고아 DB 용량 합산',
    ],
    guards: [
      // Guard 1: 작업 완료 선언 전 자동 검증 (전체 vs 완료)
      {
        id: 'enforce-completion-evidence',
        type: 'pre-completion-hook',
        action: 'validate_completion_count',
        params: {
          timeout_secs: 60,
          require_full_evidence: true,
          min_completion_ratio: 1.0,
        },
        description: '작업 완료 선언 시 "전체 N건 중 N건 처리 완료" 형식 강제 및 부분 완료 차단',
      },
      // Guard 2: completion-validator와의 통합 (부분 처리 미감지 방지)
      {
        id: 'completion-validator-integration',
        type: 'validator-hook',
        action: 'invoke_completion_validator',
        params: { timeout_secs: 30 },
        description: 'completion-validator.sh를 호출하여 대상 전체 목록과 실제 완료 항목 자동 대조',
      },
      // Guard 3: 누락 항목 탐지 (차집합 계산)
      {
        id: 'missing-items-detector',
        type: 'diff-checker',
        action: 'detect_missing_items',
        params: { auto_report: true },
        description: '대상 목록과 완료 목록의 차집합을 계산하여 누락 항목 자동 리포팅',
      },
      // Guard 4: 부분 처리 후 완료 선언 차단
      {
        id: 'partial-completion-blocker',
        type: 'declaration-blocker',
        action: 'block_partial_declaration',
        params: { allow_partial: false },
        description: 'completed/total < 1.0 시 완료 선언 스크립트 실행 자체를 차단 (exit 1)',
      },
      // Guard 5: 클러스터 재발 추적 (최근 7일)
      {
        id: 'cluster-recurrence-tracker',
        type: 'metric-collector',
        action: 'track_recurrence_events',
        params: { window_days: 7 },
        description: '부분 처리 오선언 재발 사건 기록 및 7일 내 재발 횟수 추적',
      },
    ],
    escalationPath: 'completion-evidence-review',
    ttl_days: 30,
    priority: 'high',
  },
  'cl-fd25ae4c34818568': {
    name: 'Sensitive Info & Health Advice Misclassification',
    seedPattern: '용도 명시 후에도 민감 정보 포함 & 수신자 속성 오분류 & 절대값 표현',
    memberPatterns: [
      '용도 명시 후에도 민감 정보 포함',
      '민감 정보 포함 버전 재작성 요청',
      '여러 상품 분석 시 소유자 대상 오분류',
      '임신 준비 관계자 권장사항 오적용',
      '제품명 명시 없이 영양제 복용량을 절대적으로 표현 후 편차 인정',
    ],
    guards: [
      // Guard 1: 응답 생성 후 통합 필터 파이프라인 자동 실행
      {
        id: 'response-guard-pipeline-auto',
        type: 'post-generation-hook',
        action: 'invoke_response_guard_pipeline',
        params: { timeout_secs: 30 },
        description: '모든 응답에 대해 3개 가드(민감정보, 수신자매칭, 절대값) 자동 체이닝',
      },
      // Guard 2: 민감 정보 탐지 및 자동 재작성
      {
        id: 'pii-detection-rewrite',
        type: 'sensitive-info-filter',
        action: 'detect_and_rewrite_pii',
        params: { auto_rewrite: true },
        description: '개인정보 탐지 시 민감정보 제거하고 재작성 자동 트리거',
      },
      // Guard 3: 수신자-권장사항 속성 매칭 검증
      {
        id: 'recipient-attribute-matcher',
        type: 'recipient-validator',
        action: 'validate_recipient_health_advice',
        params: { timeout_secs: 20 },
        description: '응답의 대상자 속성(연령, 성별, 건강상태)과 권장사항 일치 여부 검증',
      },
      // Guard 4: 영양제·의약품 절대값 패턴 탐지
      {
        id: 'supplement-dose-validator',
        type: 'medical-advice-filter',
        action: 'detect_absolute_dose_patterns',
        params: { auto_rewrite: true },
        description: '단위 없는 절대값 용량 표현 탐지 및 개인차 고려 표현 강제',
      },
      // Guard 5: 클러스터 재발 추적
      {
        id: 'cluster-recurrence-tracker',
        type: 'metric-collector',
        action: 'track_recurrence_events',
        params: { window_days: 7 },
        description: '클러스터 재발 사건 기록 및 7일 내 재발 횟수 추적',
      },
    ],
    escalationPath: 'health-advice-quality-review',
    ttl_days: 60,
    priority: 'critical',
  },
  'cl-5f04f13d1c3d759d': {
    name: 'Rule Recognition Without Execution + False State Reporting',
    seedPattern: '기존 규칙 인식했으나 실행 누락 + 상태 허위 보고',
    memberPatterns: [
      '기존 규칙 인식했으나 실행 누락 + 상태 허위 보고',
      '지시 범위를 부분만 적용 (동기화 누락)',
      '한영병기 규칙 적용 누락 — 문법 표 영어 해석 미제시',
      '기존 SSoT 규칙 무시',
      '도구 실행 상태 모호 보고',
    ],
    guards: [
      // Guard 1: 한영병기·HTML 업로드 규칙 자동 검증
      {
        id: 'post-edit-lint-validation',
        type: 'pre-submission-hook',
        action: 'invoke_post_edit_lint',
        params: {
          script_path: '~/.jarvis/lib/post-edit-lint.sh',
          strict_mode: true,
          timeout_secs: 30,
        },
        description: '편집 후 한영병기·HTML 업로드·동기화 규칙의 실제 적용 여부를 자동 검증',
      },
      // Guard 2: 규칙 실행 추적 및 로깅
      {
        id: 'rule-execution-audit',
        type: 'execution-tracker',
        action: 'invoke_rule_audit',
        params: {
          script_path: '~/.jarvis/lib/rule-execution-audit.mjs',
          rules: ['bilingual-grammar-tables', 'html-upload-path', 'synchronization-complete'],
          timeout_secs: 20,
        },
        description: '선언된 규칙(한영병기, HTML 업로드, 동기화)의 실행 여부를 기록하는 감시 로거',
      },
      // Guard 3: 상태 보고 전 검증 가드
      {
        id: 'verify-before-report',
        type: 'pre-report-gate',
        action: 'invoke_verify_before_report',
        params: {
          script_path: '~/.jarvis/lib/verify-before-report.sh',
          check_rule_execution: true,
          check_violations: true,
          timeout_secs: 45,
        },
        description: '상태 보고 전 실제 파일·출력 검증 및 규칙 위반 사건 확인으로 거짓 상태 보고 방지',
      },
      // Guard 4: 재발 추적 (7일 내)
      {
        id: 'cluster-recurrence-tracker',
        type: 'metric-collector',
        action: 'track_recurrence_events',
        params: { window_days: 7 },
        description: '규칙 위반 재발 사건 기록 및 7일 내 재발 횟수 추적',
      },
      // Guard 5: 부분 적용 차단
      {
        id: 'partial-execution-blocker',
        type: 'completion-gate',
        action: 'block_partial_execution',
        params: { allow_partial: false, min_rule_pass_rate: 0.66 },
        description: '규칙 적용률 < 66% 시 상태 보고 차단',
      },
    ],
    escalationPath: 'rule-execution-review',
    ttl_days: 30,
    priority: 'high',
  },
  'cl-0cece7e70f08a98f': {
    name: 'Verbal Recurrence Prevention Without Structural Validation',
    seedPattern: '재발 방지 선언만 하고 구조적 검증 루틴 미구현',
    memberPatterns: [
      '재발 방지 선언만 하고 구조적 검증 루틴 미구현',
      '재발 방지 선언만 하고 구체적 절차 미이행',
      '재발 방지를 말로만 선언하고 검증 루틴 구조화 미실행',
      '말로만 재발 방지 약속 후 구체적 절차 없이 같은 실수 반복 위험',
      '이전 세션 문제는 재검증 불가능함을 사전 공지 없이 검증 완료인 척 보고',
    ],
    guards: [
      {
        id: 'structural-guard-file-exists',
        type: 'pre-declaration-hook',
        action: 'verify_guard_script_exists',
        params: {
          script_path: '~/.jarvis/infra/lib/cluster-guard-cl-0cece7e70f08a98f.sh',
          timeout_secs: 10,
        },
        description: '재발 방지 선언 전 대응 가드 스크립트 파일 실존 여부 확인',
      },
      {
        id: 'checklist-auto-run',
        type: 'checklist-executor',
        action: 'run_checklist_and_record',
        params: {
          script_path: '~/.jarvis/infra/lib/cluster-guard-cl-0cece7e70f08a98f.sh',
          arg: 'run',
          require_pass_count: 1,
          timeout_secs: 30,
        },
        description: '선언 후 자동으로 체크리스트 실행하고 PASS/FAIL 판정 기록',
      },
      {
        id: 'declaration-verbal-detector',
        type: 'text-analyzer',
        action: 'detect_verbal_only_declaration',
        params: {
          script_path: '~/.jarvis/infra/lib/cluster-guard-cl-0cece7e70f08a98f.sh',
          arg: 'check-declaration',
          block_on_verbal: true,
        },
        description: '재발 방지 선언 텍스트에서 구조적 검증 없는 말뿐인 선언 패턴 감지 및 차단',
      },
      {
        id: 'result-file-evidence-check',
        type: 'evidence-validator',
        action: 'validate_result_file_exists',
        params: {
          result_dir: '~/jarvis/runtime/reports/cluster-guard-cl-0cece7e70f08a98f',
          require_pass_fail_string: true,
        },
        description: '결과 파일에 PASS/FAIL 판정 문자열이 실제로 기록되었는지 확인',
      },
      {
        id: 'cluster-recurrence-tracker',
        type: 'metric-collector',
        action: 'track_recurrence_events',
        params: { window_days: 7 },
        description: '말뿐인 재발 방지 선언 재발 사건 기록 및 7일 내 재발 횟수 추적',
      },
    ],
    escalationPath: 'structural-validation-review',
    ttl_days: 30,
    priority: 'high',
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
    const files = readdirSync(CLUSTER_GUARDS_DIR)
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
