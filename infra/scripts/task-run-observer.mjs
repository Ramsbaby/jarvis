#!/usr/bin/env node
/**
 * task-run-observer.mjs — 태스크 단위 절차적 자기 관찰 (Phase 2-A 메타인지)
 *
 * 역할: 크론 태스크 실행 직후 수행 과정을 구조화 기록하여
 * skill-loop-extract.mjs의 세션 선별 정확도를 높인다.
 *
 * 관찰 트리거 조건 (하나라도 해당 시 기록):
 *   - 실행시간이 예상 기준(120초)을 초과했을 때
 *   - EXIT_CODE != 0 (오류 발생)
 *   - 결과 스니펫에 도구 호출 패턴 5회 이상 (복잡 작업 완료)
 *   - 결과에 SKILL_JSON / EUREKA_JSON 마커 존재
 *
 * 호출 방식 (bot-cron.sh에서 환경변수로 전달):
 *   JARVIS_OBSERVE_TASK_ID="..." \
 *   JARVIS_OBSERVE_DURATION="120" \
 *   JARVIS_OBSERVE_EXIT="0" \
 *   JARVIS_OBSERVE_SNIPPET="..." \
 *     node task-run-observer.mjs
 *
 * 저장: runtime/ledger/task-observations.jsonl
 * 부산물: skill-loop-extract.mjs가 이 파일을 우선 선별 대상으로 사용
 *
 * 설계 의사결정:
 * - bot-cron.sh에 JARVIS_METACOG_OBSERVE=1 전역 설정 시 모든 태스크 관찰
 * - 첫 2주는 개별 tasks.json env 필드로 옵트인: env: {TASK_OBSERVE: "1"}
 * - LLM 미사용 — 휴리스틱만으로 100ms 이내 완료
 */

import { appendFileSync, mkdirSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis', 'runtime');
const TASK_OBSERVATIONS = join(BOT_HOME, 'ledger', 'task-observations.jsonl');
const SKILL_LOOP_LEDGER = join(BOT_HOME, 'ledger', 'skill-loop.jsonl');
const DRAFTS = join(BOT_HOME, 'state', 'skill-drafts');

// 환경변수에서 태스크 실행 정보 수신
const TASK_ID     = process.env.JARVIS_OBSERVE_TASK_ID || '';
const DURATION_S  = parseInt(process.env.JARVIS_OBSERVE_DURATION || '0', 10);
const EXIT_CODE   = parseInt(process.env.JARVIS_OBSERVE_EXIT || '0', 10);
const SNIPPET     = process.env.JARVIS_OBSERVE_SNIPPET || '';

// 관찰 임계값
const THRESHOLDS = {
  maxExpectedSec: 120,    // 기준 실행시간 초과 시 관찰
  minToolCalls: 5,         // 도구 호출 5회 이상
};

// 도구 호출 패턴 감지 (결과 스니펫에서 Bash/Read/Write/WebSearch 등 카운트)
function countToolCalls(text) {
  return (text.match(/\b(Bash|Read|Write|WebSearch|WebFetch|Grep|Glob)\b/g) || []).length;
}

// 스킬 후보 여부 판단
function isSkillCandidate(exitCode, duration, toolCalls, snippet) {
  const hasSynthesisMarker = /SKILL_JSON:|EUREKA_JSON:/.test(snippet);
  return exitCode === 0 && toolCalls >= THRESHOLDS.minToolCalls || hasSynthesisMarker;
}

function nowKST() {
  return new Date(Date.now() + 9 * 3600_000).toISOString().replace('Z', '+09:00');
}

function log(msg) {
  process.stderr.write(`[task-run-observer] ${msg}\n`);
}

function main() {
  if (!TASK_ID) {
    log('TASK_ID 미제공 — 종료');
    process.exit(0);
  }

  const toolCalls = countToolCalls(SNIPPET);
  const hasError  = EXIT_CODE !== 0;
  const isSlow    = DURATION_S > THRESHOLDS.maxExpectedSec;
  const hasSynthesisMarker = /SKILL_JSON:|EUREKA_JSON:/.test(SNIPPET);

  // 관찰 트리거 평가
  const shouldObserve = hasError || isSlow || toolCalls >= THRESHOLDS.minToolCalls || hasSynthesisMarker;

  if (!shouldObserve) {
    log(`SKIP ${TASK_ID} — 트리거 조건 미충족 (exit=${EXIT_CODE}, ${DURATION_S}s, tools=${toolCalls})`);
    process.exit(0);
  }

  const skillCandidate = isSkillCandidate(EXIT_CODE, DURATION_S, toolCalls, SNIPPET);
  const ts = nowKST();

  // task-observations.jsonl에 기록
  mkdirSync(join(BOT_HOME, 'ledger'), { recursive: true });
  const observation = {
    ts,
    taskId: TASK_ID,
    durationSec: DURATION_S,
    exitCode: EXIT_CODE,
    toolCalls,
    hasError,
    isSlow,
    hasSynthesisMarker,
    outcome: hasError ? 'failure' : 'success',
    skillCandidate,
    trigger: hasError ? 'error' : isSlow ? 'slow' : hasSynthesisMarker ? 'marker' : 'tool_calls',
  };

  appendFileSync(TASK_OBSERVATIONS, JSON.stringify(observation) + '\n');
  log(`OBSERVED ${TASK_ID} — outcome=${observation.outcome}, skillCandidate=${skillCandidate}`);

  // 스킬 후보이면 selected-날짜.jsonl에 즉시 등재
  // → skill-loop-extract.mjs가 이 파일을 우선 선별 대상으로 사용
  if (skillCandidate) {
    const today = ts.slice(0, 10);
    const selFile = join(DRAFTS, `selected-${today}.jsonl`);
    mkdirSync(DRAFTS, { recursive: true });
    appendFileSync(selFile, JSON.stringify({
      ts,
      taskId: TASK_ID,
      source: 'task-observer',
      trigger: observation.trigger,
      toolCalls,
      durationSec: DURATION_S,
    }) + '\n');
    log(`SKILL_CANDIDATE: ${TASK_ID} → selected-${today}.jsonl 등재`);

    // skill-loop.jsonl에도 이벤트 기록
    appendFileSync(SKILL_LOOP_LEDGER, JSON.stringify({
      ts,
      event: 'task_observed_skill_candidate',
      taskId: TASK_ID,
      trigger: observation.trigger,
    }) + '\n');
  }

  process.stdout.write(JSON.stringify(observation) + '\n');
}

main();
