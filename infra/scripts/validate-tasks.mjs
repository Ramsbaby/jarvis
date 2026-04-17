#!/usr/bin/env node
/**
 * validate-tasks.mjs — tasks.json JSON Schema 검증
 *
 * Usage:
 *   node ~/jarvis/infra/scripts/validate-tasks.mjs
 *   node ~/jarvis/infra/scripts/validate-tasks.mjs --fix   # (향후: auto-fix 가능한 오류 수정)
 *
 * 종료 코드:
 *   0 — 검증 통과
 *   1 — 검증 실패 (오류 목록 출력)
 *
 * 크론에서 사용:
 *   tasks.json 수정 후 gen-tasks-index.mjs 전에 자동 실행됨.
 *   실패 시 gen-tasks-index 중단 → 잘못된 태스크 정보가 인덱스에 반영되지 않음.
 */

import { readFileSync } from 'fs';
import { join } from 'path';
import { homedir } from 'os';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const Ajv = (() => {
  try { return require('ajv'); } catch { return null; }
})();

const INFRA = join(homedir(), 'jarvis', 'infra');
const SCHEMA_FILE = join(INFRA, 'config', 'tasks.schema.json');
const TASKS_FILE = join(homedir(), 'jarvis/runtime', 'config', 'tasks.json');

function log(msg) { process.stderr.write(`[validate-tasks] ${msg}\n`); }

// ── JSON 파싱 ─────────────────────────────────────────────────────────────────
let schema, tasksData;
try {
  schema = JSON.parse(readFileSync(SCHEMA_FILE, 'utf-8'));
} catch (e) {
  log(`Schema 파일 읽기 실패: ${e.message}`);
  process.exit(1);
}

try {
  tasksData = JSON.parse(readFileSync(TASKS_FILE, 'utf-8'));
} catch (e) {
  log(`tasks.json 읽기/파싱 실패: ${e.message}`);
  log('  → JSON 문법 오류가 있습니다. 편집 내용을 확인하세요.');
  process.exit(1);
}

// ── 기본 구조 확인 ────────────────────────────────────────────────────────────
if (!Array.isArray(tasksData?.tasks)) {
  log('tasks.json 최상위에 "tasks" 배열이 없습니다.');
  process.exit(1);
}

// ── Ajv 검증 (설치된 경우) ───────────────────────────────────────────────────
if (Ajv) {
  const ajv = new Ajv({ allErrors: true });
  const validate = ajv.compile(schema);
  const valid = validate(tasksData);

  if (!valid) {
    log(`검증 실패 — ${validate.errors.length}개 오류:`);
    for (const err of validate.errors) {
      const path = err.instancePath || '/';
      log(`  ${path}: ${err.message}`);
      if (err.params?.additionalProperty) {
        log(`    → 허용되지 않는 필드: "${err.params.additionalProperty}"`);
      }
    }
    process.exit(1);
  }
} else {
  log('ajv 미설치 — JSON 문법만 확인 (npm install ajv 로 Schema 검증 활성화)');
}

// ── 추가 비즈니스 규칙 검증 ──────────────────────────────────────────────────
const tasks = tasksData.tasks;
const ids = new Set();
const errors = [];

for (const [i, task] of tasks.entries()) {
  // 중복 ID
  if (ids.has(task.id)) {
    errors.push(`task[${i}] '${task.id}': ID 중복`);
  }
  ids.add(task.id);

  // prompt 없이 script 도 없는 태스크 (실행 방법 없음)
  if (!task.prompt && !task.prompt_file && !task.script && !task.event_trigger) {
    errors.push(`task[${i}] '${task.id}': prompt/prompt_file/script/event_trigger 중 하나 필요`);
  }

  // enabled=false 인데 disabled 필드도 없는 경우 → 의도 불명
  // (경고 아닌 참고 — exit 1 아님)

  // depends 참조 ID 존재 여부 (pre-pass 후 검증)
}

// depends 참조 검증 (전체 ID 수집 후)
for (const [i, task] of tasks.entries()) {
  for (const dep of task.depends ?? []) {
    if (!ids.has(dep)) {
      errors.push(`task[${i}] '${task.id}': depends '${dep}' — 존재하지 않는 ID`);
    }
  }
}

if (errors.length > 0) {
  log(`비즈니스 규칙 위반 ${errors.length}개:`);
  for (const e of errors) log(`  ✗ ${e}`);
  process.exit(1);
}

// ── 통과 ─────────────────────────────────────────────────────────────────────
log(`PASS — ${tasks.length}개 태스크 검증 완료`);
process.exit(0);