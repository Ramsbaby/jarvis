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

// ── addedAt 누락 감지 + --fix 시 자동 삽입 ──────────────────────────────────
const TODAY = new Date().toISOString().slice(0, 10);
const FIX_MODE = process.argv.includes('--fix');
let fixedCount = 0;
const missingAddedAt = [];

for (const task of tasks) {
  if (!task.addedAt) {
    missingAddedAt.push(task.id);
    if (FIX_MODE) {
      task.addedAt = TODAY;
      fixedCount++;
    }
  }
}

if (missingAddedAt.length > 0) {
  if (FIX_MODE) {
    const { writeFileSync } = await import('fs');
    writeFileSync(TASKS_FILE, JSON.stringify(tasksData, null, 2), 'utf-8');
    log(`--fix: addedAt 자동 삽입 ${fixedCount}개 (${TODAY})`);
  } else {
    log(`⚠️  addedAt 누락 ${missingAddedAt.length}개 — gen-tasks-index 실행 시 자동 삽입됨`);
  }
}

// ── G3: SSoT cross-check (2026-05-07 v1, 2026-05-08 재구현) ───────────────────
// 외부 진입점(crontab / Library/LaunchAgents)에 tasks.json과 동일 ID 존재 시
// 양쪽 등록 = 중복 실행 위험. 기본 WARN-only, JARVIS_VALIDATE_STRICT=1로 reject 전환.
// 사고 사례: 2026-05-07 24건 crontab 중복 실행 → fail_24h 226건 본진. 5/7 적용 후
// 5/8 새벽 다른 세션 작업으로 코드 사라짐 → 재구현.
// 참조: ~/jarvis/infra/docs/CRON-ORCHESTRATION-SSOT.md 4-A·4-B
//
// 예외 카테고리(SSoT 등재 — verify B2 fix): meta-audit / system-monitor /
// retention/archive / bot-runner는 plist 직접 작성 OK이므로 위반에서 제외.

const STRICT = process.env.JARVIS_VALIDATE_STRICT === '1';
const violations = [];

// crontab -l 스캔 — wrapper 호출(bot-cron.sh / jarvis-cron.sh) 또는 스크립트 직접 호출이
// tasks.json ID와 매칭되면 양쪽 등록 위반.
try {
  const { execSync } = await import('child_process');
  const ctOut = execSync('crontab -l 2>/dev/null', { encoding: 'utf-8' });
  for (const line of ctOut.split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#') || t.startsWith('@reboot')) continue;
    if (/^\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(find|pgrep|kill|true)\b/.test(t)) continue;
    const w = t.match(/(?:bot-cron\.sh|jarvis-cron\.sh)\s+(\S+)/);
    if (w && ids.has(w[1])) {
      violations.push({ source: 'crontab', id: w[1], reason: 'wrapper-call' });
      continue;
    }
    const s = t.match(/\/([a-zA-Z0-9-_]+)\.(?:sh|mjs|py|js)\b/);
    if (s && ids.has(s[1])) {
      violations.push({ source: 'crontab', id: s[1], reason: 'script-id-match' });
    }
  }
} catch (e) {
  log(`SSoT cross-check (crontab) 스킵 — ${e.message}`);
}

// LaunchAgents 스캔 — plist 내부에 wrapper(bot-cron.sh / jarvis-cron.sh) 호출이 있으면
// SSoT 호환(정상). wrapper 없는 직접 실행 plist는 위반.
try {
  const { readdirSync, readFileSync: rfs } = await import('fs');
  const laDir = join(homedir(), 'Library/LaunchAgents');
  for (const f of readdirSync(laDir)) {
    const m = f.match(/^(?:ai|com)\.jarvis\.(.+)\.plist$/);
    if (!m) continue;
    if (!ids.has(m[1])) continue;
    const plistPath = join(laDir, f);
    let content = '';
    try { content = rfs(plistPath, 'utf-8'); } catch { continue; }
    if (/bot-cron\.sh|jarvis-cron\.sh/.test(content)) continue;
    violations.push({ source: 'plist', id: m[1], reason: 'direct-exec-bypass-ssot' });
  }
} catch (e) {
  log(`SSoT cross-check (plist) 스킵 — ${e.message}`);
}

if (violations.length > 0) {
  log(`⚠️  SSoT cross-check — 외부 진입점에 동일 ID ${violations.length}건 발견:`);
  const byId = {};
  for (const v of violations) {
    byId[v.id] = byId[v.id] || [];
    byId[v.id].push(`${v.source}:${v.reason}`);
  }
  for (const [id, sources] of Object.entries(byId)) {
    log(`  · ${id} → ${sources.join(', ')}`);
  }
  log(`  해결: 외부 진입점(crontab/plist)에서 제거 후 tasks.json만 유지.`);
  log(`  참조: ~/jarvis/infra/docs/CRON-ORCHESTRATION-SSOT.md`);
  if (STRICT) {
    log(`  STRICT 모드 — exit 1 (JARVIS_VALIDATE_STRICT=1)`);
    process.exit(1);
  }
  log(`  WARN-only 모드 — 안정화 후 JARVIS_VALIDATE_STRICT=1 전환 권고.`);
}

// ── 통과 ─────────────────────────────────────────────────────────────────────
log(`PASS — ${tasks.length}개 태스크 검증 완료${violations.length > 0 ? ` (cross-check 위반 ${violations.length}건 WARN)` : ''}`);
process.exit(0);