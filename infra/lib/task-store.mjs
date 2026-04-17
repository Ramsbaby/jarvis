/**
 * task-store.mjs — Jarvis 태스크 SQLite 저장소
 * node:sqlite 기반 (Node.js 22.5+ 내장, 별도 설치 불필요)
 *
 * 스키마:
 *   tasks            — 현재 상태 (dev-queue.json 대체)
 *   task_transitions — 전이 히스토리
 *
 * CLI:
 *   node task-store.mjs transition <id> <to> [triggeredBy] [extraJSON]
 *   node task-store.mjs pick
 *   node task-store.mjs field <id> <field>
 *   node task-store.mjs list
 *   node task-store.mjs export
 */

import { DatabaseSync } from 'node:sqlite';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { reportFormat, kstFooter } from '../discord/lib/formatters.js';

// SIGPIPE 핸들러: pick-and-lock 등 stdout 쓰기 중 파이프 끊김 시 crash 방지
process.on('SIGPIPE', () => process.exit(0));
process.stdout.on('error', (err) => { if (err.code === 'EPIPE') process.exit(0); });
import { mkdirSync, appendFileSync, readFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { canTransition } from './task-fsm.mjs';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const DB_PATH   = join(BOT_HOME, 'state', 'tasks.db');

let _db = null;

function getDb() {
  if (_db) return _db;
  mkdirSync(join(BOT_HOME, 'state'), { recursive: true });
  _db = new DatabaseSync(DB_PATH);
  _db.exec('PRAGMA journal_mode=WAL');
  _db.exec('PRAGMA busy_timeout=10000');
  _db.exec('PRAGMA wal_autocheckpoint=1000');
  _db.exec('PRAGMA optimize');
  _db.exec(`
    CREATE TABLE IF NOT EXISTS tasks (
      id         TEXT    PRIMARY KEY,
      status     TEXT    NOT NULL DEFAULT 'pending',
      priority   INTEGER NOT NULL DEFAULT 0,
      retries    INTEGER NOT NULL DEFAULT 0,
      depends    TEXT    NOT NULL DEFAULT '[]',
      parent_id  TEXT,
      meta       TEXT    NOT NULL DEFAULT '{}',
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS task_transitions (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      task_id      TEXT    NOT NULL,
      from_status  TEXT    NOT NULL,
      to_status    TEXT    NOT NULL,
      triggered_by TEXT,
      created_at   INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_tasks_status    ON tasks(status);
    CREATE INDEX IF NOT EXISTS idx_tasks_parent    ON tasks(parent_id);
    CREATE INDEX IF NOT EXISTS idx_trans_task      ON task_transitions(task_id);
  `);

  // 마이그레이션: parent_id 컬럼 추가 (이미 있으면 무시)
  try {
    _db.prepare('SELECT parent_id FROM tasks LIMIT 1').get();
  } catch {
    try {
      _db.exec('ALTER TABLE tasks ADD COLUMN parent_id TEXT');
      _db.exec('CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_id)');
    } catch (_) { /* parent_id already exists */ }
  }
  return _db;
}

// ── 직렬화/역직렬화 ────────────────────────────────────────────────────────

function deserialize(row) {
  const meta = JSON.parse(row.meta || '{}');
  return {
    id:              row.id,
    status:          row.status,
    priority:        row.priority,
    retries:         row.retries,
    depends:         JSON.parse(row.depends || '[]'),
    parent_id:       row.parent_id || null,
    // meta 편의 필드 flat-merge
    name:            meta.name,
    prompt:          meta.prompt,
    completionCheck: meta.completionCheck,
    maxBudget:       meta.maxBudget,
    timeout:         meta.timeout,
    allowedTools:    meta.allowedTools,
    patchOnly:       meta.patchOnly,
    maxRetries:      meta.maxRetries ?? 2,
    source:          meta.source,
    skipReason:      meta.skipReason,
    completedAt:     meta.completedAt,
    failedAt:        meta.failedAt,
    lastError:       meta.lastError,
    createdAt:       meta.createdAt,
    meta,
    updated_at:      row.updated_at,
  };
}

function flattenForExport(t) {
  return {
    id:       t.id,
    status:   t.status,
    priority: t.priority,
    retries:  t.retries,
    depends:  t.depends,
    ...t.meta,
  };
}

// ── 공개 API ───────────────────────────────────────────────────────────────

/** 태스크 단건 조회 */
export function getTask(id) {
  const row = getDb().prepare('SELECT * FROM tasks WHERE id=?').get(id);
  return row ? deserialize(row) : null;
}

/** 실행 가능 태스크 목록 (queued + depends done + retries < max) */
export function getReadyTasks() {
  const doneIds = new Set(
    getDb().prepare("SELECT id FROM tasks WHERE status='done'").all().map(r => r.id)
  );
  return getDb().prepare("SELECT * FROM tasks WHERE status='queued'")
    .all()
    .map(deserialize)
    .filter(t => t.source !== 'bot-cron')              // bot-cron 태스크는 dev-runner 제외
    .filter(t => !!(t.prompt?.trim() || t.name?.trim()))  // prompt 없으면 name fallback (즉시 실패 방지)
    .filter(t => (t.depends ?? []).every(d => doneIds.has(d)))
    .filter(t => t.retries < (t.maxRetries ?? 2))
    .sort((a, b) => b.priority - a.priority);
}

/** 같은 parent_id를 공유하는 queued 태스크 그룹을 반환. 그룹 전체가 queued일 때만 반환. */
export function getReadyGroup() {
  const db = getDb();
  const doneIds = new Set(
    db.prepare("SELECT id FROM tasks WHERE status='done'").all().map(r => r.id)
  );
  // parent_id가 있는 queued 태스크를 parent별로 그룹화
  const candidates = db.prepare(
    "SELECT DISTINCT parent_id FROM tasks WHERE status='queued' AND parent_id IS NOT NULL"
  ).all();

  for (const { parent_id: pid } of candidates) {
    const allSiblings = db.prepare(
      "SELECT * FROM tasks WHERE parent_id=?"
    ).all(pid).map(deserialize);

    // 모든 형제가 queued여야 함 (일부만 queued이면 불완전 그룹)
    if (!allSiblings.every(t => t.status === 'queued')) continue;

    // getReadyTasks()와 동일한 필터 적용
    const ready = allSiblings
      .filter(t => t.source !== 'bot-cron')
      .filter(t => !!(t.prompt?.trim() || t.name?.trim()))
      .filter(t => (t.depends ?? []).every(d => doneIds.has(d)))
      .filter(t => t.retries < (t.maxRetries ?? 2));

    if (ready.length === 0 || ready.length !== allSiblings.length) continue;

    return ready.sort((a, b) => b.priority - a.priority);
  }
  return [];
}

/** 상태 전이 (트랜잭션: tasks + task_transitions 원자적 업데이트) */
export function transition(id, toStatus, { triggeredBy = 'system', extra = {} } = {}) {
  const db  = getDb();
  const row = db.prepare('SELECT * FROM tasks WHERE id=?').get(id);
  if (!row) throw new Error(`task '${id}' not found`);

  const task = deserialize(row);
  if (!canTransition(task.status, toStatus)) {
    throw new Error(`유효하지 않은 전이: ${task.status} → ${toStatus} (${id})`);
  }

  const now     = Date.now();
  // extra에서 retries/priority는 별도 컬럼으로 관리 — meta에는 포함하지 않음
  const { retries: _r, priority: _p, ...metaExtra } = extra;
  const newMeta = { ...task.meta, ...metaExtra };
  if (toStatus === 'done')   newMeta.completedAt = new Date(now).toISOString();
  if (toStatus === 'failed') newMeta.failedAt    = new Date(now).toISOString();

  // running → queued = 재시도 카운터 자동 증가 (extra.retries 무시)
  // 그 외 = extra.retries 명시 시 사용, 없으면 현재값 유지
  const newRetries =
    (toStatus === 'queued' && task.status === 'running')
      ? task.retries + 1
      : (extra.retries ?? task.retries);

  // node:sqlite DatabaseSync은 .transaction() 헬퍼 없음 — BEGIN/COMMIT/ROLLBACK 직접 사용
  db.exec('BEGIN');
  try {
    db.prepare(
      'UPDATE tasks SET status=?, priority=?, retries=?, meta=?, updated_at=? WHERE id=?'
    ).run(toStatus, extra.priority ?? task.priority, newRetries, JSON.stringify(newMeta), now, id);

    db.prepare(
      'INSERT INTO task_transitions (task_id, from_status, to_status, triggered_by, created_at) VALUES (?,?,?,?,?)'
    ).run(id, task.status, toStatus, triggeredBy, now);

    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }

  // done 전이 시 RAG 피드백 루프 — rag/task-outcomes-YYYY-MM.md에 결과 적재
  if (toStatus === 'done') {
    try {
      const ragDir  = join(BOT_HOME, 'rag');
      mkdirSync(ragDir, { recursive: true });
      const month   = new Date(now).toISOString().slice(0, 7);             // YYYY-MM
      const ragFile = join(ragDir, `task-outcomes-${month}.md`);
      const header  = `## [done] ${task.name ?? id} \`${id}\`\n`;
      const body    = [
        `- **완료일시**: ${newMeta.completedAt}`,
        `- **시도 횟수**: ${newRetries + 1}`,
        `- **triggeredBy**: ${triggeredBy}`,
        newMeta.lastError ? `- **마지막 오류**: ${newMeta.lastError}` : null,
        newMeta.prompt    ? `- **프롬프트 요약**: ${String(newMeta.prompt).slice(0, 120)}...` : null,
      ].filter(Boolean).join('\n');
      appendFileSync(ragFile, `\n${header}${body}\n`);
    } catch (_) { /* RAG 적재 실패는 전이 자체를 막지 않음 */ }
  }

  return { ...task, status: toStatus, retries: newRetries, meta: newMeta };
}

/** 태스크 추가 (중복 시 무시) */
export function addTask(task) {
  const { id, status = 'pending', priority = 0, retries = 0, depends = [], parent_id = null, ...rest } = task;
  getDb().prepare(
    'INSERT OR IGNORE INTO tasks (id, status, priority, retries, depends, parent_id, meta, updated_at) VALUES (?,?,?,?,?,?,?,?)'
  ).run(id, status, priority, retries, JSON.stringify(depends), parent_id, JSON.stringify(rest), Date.now());
}

/**
 * cron 태스크 ensure: DB에 없으면 queued로 삽입, 있으면 현재 상태 반환.
 * failed/done 상태이면 queued로 리셋하여 재실행 가능하게 함.
 * @param {string} id
 * @param {Object} meta - name, source 등 부가 정보
 * @returns {{ id, status, isNew: boolean }}
 */
export function ensureCronTask(id, meta = {}) {
  const db  = getDb();
  const now = Date.now();
  const row = db.prepare('SELECT * FROM tasks WHERE id=?').get(id);

  if (!row) {
    // 신규 등록: queued로 바로 삽입 (cron은 항상 실행 대상이므로 pending 건너뜀)
    const metaJson = JSON.stringify({ source: 'bot-cron', ...meta, name: meta.name ?? id });
    const parentId = meta.parent_id ?? null;
    db.prepare(
      'INSERT INTO tasks (id, status, priority, retries, depends, parent_id, meta, updated_at) VALUES (?,?,?,?,?,?,?,?)'
    ).run(id, 'queued', meta.priority ?? 0, 0, '[]', parentId, metaJson, now);
    db.prepare(
      'INSERT INTO task_transitions (task_id, from_status, to_status, triggered_by, created_at) VALUES (?,?,?,?,?)'
    ).run(id, 'init', 'queued', 'bot-cron/ensure', now);
    return { id, status: 'queued', isNew: true };
  }

  const task = deserialize(row);
  // failed/done → queued 리셋 (cron은 매 실행 시 새로 시작해야 함)
  if (task.status === 'failed' || task.status === 'done') {
    db.exec('BEGIN');
    try {
      db.prepare('UPDATE tasks SET status=?, retries=?, updated_at=? WHERE id=?')
        .run('queued', 0, now, id);
      db.prepare(
        'INSERT INTO task_transitions (task_id, from_status, to_status, triggered_by, created_at) VALUES (?,?,?,?,?)'
      ).run(id, task.status, 'queued', 'bot-cron/ensure', now);
      db.exec('COMMIT');
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    }
    return { id, status: 'queued', isNew: false };
  }

  return { id, status: task.status, isNew: false };
}

/** Circuit Breaker 상태 조회 (FSM failed 횟수 기반) */
export function getCbStatus(id) {
  const db = getDb();
  const task = getTask(id);
  if (!task) return { id, consecutiveFails: 0, status: 'ok' };

  // 최근 전이 이력에서 연속 failed 횟수 계산
  // bot-cron/ensure가 생성하는 failed→queued 리셋 전이는 무시 (실제 성공이 아님)
  const recent = db.prepare(
    "SELECT to_status, triggered_by FROM task_transitions WHERE task_id=? ORDER BY created_at DESC LIMIT 20"
  ).all(id);

  let consecutiveFails = 0;
  for (const r of recent) {
    if (r.to_status === 'failed') {
      consecutiveFails++;
    } else if (r.to_status === 'done') {
      break; // 성공(done)이 나오면 연속 실패 체인 종료
    }
    // queued, running, skipped 는 카운트 유지하며 통과
    // (ensure 리셋 queued, 재시도 running 모두 연속 실패 체인 중에 발생하므로)
  }

  return {
    id,
    consecutiveFails,
    currentStatus: task.status,
    status: consecutiveFails >= 3 ? 'open' : 'ok',
  };
}

/**
 * 태스크의 depends 필드를 체크해서 모든 의존 태스크가 최근 N시간 내 done인지 확인.
 * tasks.json(또는 effective-tasks.json)의 depends 배열을 사용.
 * @param {string} taskId
 * @param {number} windowHours - done 유효 기간 (기본 25시간)
 * @returns {{ ok: boolean, missing: string[] }}
 */
export function checkDeps(taskId, windowHours = 25) {
  // effective-tasks.json 우선, 없으면 tasks.json 폴백
  const configCandidates = [
    join(BOT_HOME, 'config', 'effective-tasks.json'),
    join(BOT_HOME, 'config', 'tasks.json'),
  ];
  let tasksJson = null;
  for (const p of configCandidates) {
    try { tasksJson = JSON.parse(readFileSync(p, 'utf-8')); break; } catch { /* try next */ }
  }
  if (!tasksJson) return { ok: true, missing: [] };

  const taskDef = (tasksJson.tasks ?? []).find(t => t.id === taskId);
  if (!taskDef?.depends?.length) return { ok: true, missing: [] };

  const windowMs  = windowHours * 60 * 60 * 1000;
  const cutoff    = Date.now() - windowMs;
  const db        = getDb();

  const missing = [];
  for (const depId of taskDef.depends) {
    const row = db.prepare(
      "SELECT id FROM tasks WHERE id=? AND status='done' AND updated_at > ?"
    ).get(depId, cutoff);
    if (!row) missing.push(depId);
  }

  return { ok: missing.length === 0, missing };
}

/** 전체 태스크 목록 */
export function listTasks() {
  return getDb().prepare('SELECT * FROM tasks ORDER BY priority DESC, updated_at DESC')
    .all().map(deserialize);
}

/** dev-queue.json 호환 JSON export */
export function exportJson() {
  return { version: 1, tasks: listTasks().map(flattenForExport) };
}

// ── CLI 모드 (bash에서 직접 호출) ─────────────────────────────────────────
// node task-store.mjs <cmd> [args...]

if (process.argv[1]?.endsWith('task-store.mjs')) {
  const [,, cmd, ...args] = process.argv;
  try {
    switch (cmd) {
      case 'get': {
        const t = getTask(args[0]);
        if (!t) { process.stderr.write(`task not found: ${args[0]}\n`); process.exit(1); }
        process.stdout.write(JSON.stringify(t, null, 2) + '\n');
        break;
      }
      case 'transition': {
        const [id, to, by = 'bash'] = args;
        let extra = {};
        if (args[3]) {
          try {
            extra = JSON.parse(args[3]);
            if (typeof extra !== 'object' || extra === null || Array.isArray(extra)) {
              process.stderr.write(`transition: extraJSON must be a plain object, got: ${args[3].slice(0, 80)}\n`);
              extra = {};
            }
          } catch (parseErr) {
            process.stderr.write(`transition: extraJSON parse error (ignored): ${parseErr.message} — input: ${args[3].slice(0, 80)}\n`);
            extra = {};
          }
        }
        const result = transition(id, to, { triggeredBy: by, extra });
        process.stdout.write(JSON.stringify({ ok: true, status: result.status }) + '\n');
        break;
      }
      // force-done: FSM 규칙 무시하고 직접 done 상태로 설정 (completionCheck 이미 통과한 경우)
      // Usage: node task-store.mjs force-done <id>
      case 'force-done': {
        const [id] = args;
        if (!id) { process.stderr.write('Usage: force-done <id>\n'); process.exit(1); }
        const now = Date.now();
        const nowIso = new Date(now).toISOString();
        getDb().prepare(
          "UPDATE tasks SET status='done', updated_at=? WHERE id=?"
        ).run(now, id);
        getDb().prepare(
          "INSERT INTO task_transitions (task_id, from_status, to_status, triggered_by, created_at) VALUES (?, 'force', 'done', 'force-done', ?)"
        ).run(id, now);
        process.stdout.write(JSON.stringify({ ok: true, id, status: 'done', forced: true }) + '\n');
        break;
      }
      case 'pick-and-lock': {
        const candidates = getReadyTasks();
        const db = getDb();
        const now = Date.now();
        let picked = '';
        for (const task of candidates) {
          // BEGIN IMMEDIATE: WAL 모드에서도 즉시 write-lock 획득
          // busy_timeout(30s) 내에 retry → 다른 worker의 DB 접근과 충돌 방지
          let lockAcquired = false;
          for (let attempt = 0; attempt < 10; attempt++) {
            try { db.exec('BEGIN IMMEDIATE'); lockAcquired = true; break; } catch (_le) {
              if (attempt < 9) { const ms = 100 + attempt * 200; Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }
            }
          }
          if (!lockAcquired) continue;
          try {
            const cur = db.prepare("SELECT status FROM tasks WHERE id=?").get(task.id);
            if (!cur || cur.status !== 'queued') { db.exec('ROLLBACK'); continue; }
            db.prepare("UPDATE tasks SET status='running', updated_at=? WHERE id=?").run(now, task.id);
            db.prepare("INSERT INTO task_transitions (task_id, from_status, to_status, triggered_by, created_at) VALUES (?,?,?,?,?)").run(task.id, 'queued', 'running', 'pick-and-lock', now);
            db.exec('COMMIT');
            picked = task.id;
            break;
          } catch (_e) { try { db.exec('ROLLBACK'); } catch (_) {} }
        }
        process.stdout.write(picked + '\n');
        break;
      }
      case 'pick-group-and-lock': {
        const group = getReadyGroup();
        const db = getDb();
        const now = Date.now();
        const pickedIds = [];

        if (group.length === 0) {
          process.stdout.write('[]\n');
          break;
        }

        // BEGIN IMMEDIATE: 그룹 전체를 원자적으로 queued → running
        let lockAcquired = false;
        for (let attempt = 0; attempt < 10; attempt++) {
          try { db.exec('BEGIN IMMEDIATE'); lockAcquired = true; break; } catch (_le) {
            if (attempt < 9) { const ms = 100 + attempt * 200; Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }
          }
        }
        if (!lockAcquired) {
          process.stdout.write('[]\n');
          break;
        }
        try {
          for (const task of group) {
            const cur = db.prepare("SELECT status FROM tasks WHERE id=?").get(task.id);
            if (!cur || cur.status !== 'queued') {
              // 하나라도 queued가 아니면 전체 롤백 (일관성 보장)
              db.exec('ROLLBACK');
              pickedIds.length = 0;
              break;
            }
            db.prepare("UPDATE tasks SET status='running', updated_at=? WHERE id=?").run(now, task.id);
            db.prepare("INSERT INTO task_transitions (task_id, from_status, to_status, triggered_by, created_at) VALUES (?,?,?,?,?)")
              .run(task.id, 'queued', 'running', 'pick-group-and-lock', now);
            pickedIds.push(task.id);
          }
          if (pickedIds.length > 0) db.exec('COMMIT');
        } catch (_e) {
          try { db.exec('ROLLBACK'); } catch (_) {}
          pickedIds.length = 0;
        }
        process.stdout.write(JSON.stringify(pickedIds) + '\n');
        break;
      }
      case 'pick': {
        const ready = getReadyTasks();
        process.stdout.write((ready[0]?.id ?? '') + '\n');
        break;
      }
      case 'field': {
        const [id, field] = args;
        const t = getTask(id);
        if (!t) { process.stderr.write(`task not found: ${id}\n`); process.exit(1); }
        const val = t[field] ?? t.meta?.[field] ?? '';
        process.stdout.write(
          (typeof val === 'object' ? JSON.stringify(val) : String(val)) + '\n'
        );
        break;
      }
      case 'list':
        process.stdout.write(JSON.stringify(listTasks(), null, 2) + '\n');
        break;
      case 'export':
        process.stdout.write(JSON.stringify(exportJson(), null, 2) + '\n');
        break;
      case 'count-queued': {
        const n = getDb().prepare("SELECT COUNT(*) as c FROM tasks WHERE status='queued' AND COALESCE(JSON_EXTRACT(meta,'$.source'),'') != 'bot-cron'").get();
        process.stdout.write(String(n.c) + '\n');
        break;
      }
      // 임의 개선 태스크 큐 적재 (감사팀·인프라팀 → dev-runner 연결)
      // Usage: node task-store.mjs enqueue --id <id> --title <title> --prompt <prompt> [--priority high|medium|low] [--source <src>] [--type <type>] [--post-title <원본포스트제목>]
      // 동일 id가 queued/running이면 중복 적재 방지 (SKIP 반환)
      case 'enqueue': {
        const flagMap = {};
        for (let i = 0; i < args.length - 1; i++) {
          if (args[i].startsWith('--')) flagMap[args[i].slice(2)] = args[i + 1];
        }
        const { id: eId, title, prompt: ePrompt, priority: ePrio = 'medium', source: eSrc = 'agent', type: eType = 'improvement', 'post-title': ePostTitle, timeout: eTimeout, maxBudget: eMaxBudget, allowedTools: eAllowedTools } = flagMap;
        if (!eId || !title) { process.stderr.write('enqueue: --id and --title required\n'); process.exit(1); }
        const db = getDb();
        const existing = db.prepare("SELECT status FROM tasks WHERE id=?").get(eId);
        if (existing && (existing.status === 'queued' || existing.status === 'running')) {
          process.stdout.write(JSON.stringify({ ok: true, action: 'skip', reason: 'already-pending', id: eId }) + '\n');
          break;
        }
        // priority 문자열 → 정수 변환 (high=10, medium=5, low=1, 숫자 문자열은 parseInt)
        const PRIO_MAP = { high: 10, medium: 5, low: 1 };
        const ePrioInt = PRIO_MAP[ePrio] ?? (parseInt(ePrio, 10) || 5);
        const now = new Date().toISOString();
        const metaObj = { name: title, prompt: ePrompt ?? title, source: eSrc, type: eType, enqueuedAt: now };
        if (ePostTitle) metaObj.postTitle = ePostTitle;
        if (eTimeout) metaObj.timeout = parseInt(eTimeout, 10);
        if (eMaxBudget) metaObj.maxBudget = eMaxBudget;
        if (eAllowedTools) metaObj.allowedTools = eAllowedTools;
        const meta = JSON.stringify(metaObj);
        db.prepare('INSERT OR REPLACE INTO tasks (id, status, priority, retries, depends, meta, updated_at) VALUES (?,?,?,?,?,?,?)')
          .run(eId, 'queued', ePrioInt, 0, '[]', meta, Date.now());
        db.prepare('INSERT INTO task_transitions (task_id, from_status, to_status, triggered_by, created_at) VALUES (?,?,?,?,?)')
          .run(eId, existing?.status ?? 'init', 'queued', eSrc + '/enqueue', now);
        process.stdout.write(JSON.stringify({ ok: true, action: 'enqueued', id: eId, priority: ePrio }) + '\n');
        // enqueue 성공 → jarvis-coder 이벤트 트리거 (bot-cron 태스크 제외)
        if (eSrc !== 'bot-cron') {
          try {
            const emitScript = join(process.env.BOT_HOME || join(homedir(), 'jarvis/runtime'), 'scripts', 'emit-event.sh');
            execSync(`"${emitScript}" dev.task.queued '{"id":"${eId}"}'`, { timeout: 5000, stdio: 'ignore' });
          } catch { /* 이벤트 발행 실패해도 enqueue 자체는 성공 */ }
        }
        break;
      }
      // cron 태스크 ensure: DB에 없으면 queued로 삽입, failed/done이면 queued로 리셋
      // Usage: node task-store.mjs ensure <id> [name] [source]
      case 'ensure': {
        // Usage: node task-store.mjs ensure <id> <name> <source> <prompt> [allowedTools]
        // debug-cron-* 태스크는 코드 수정이 필요하므로 allowedTools 기본값 포함
        const [id, name, source, prompt, allowedTools] = args;
        const taskMeta = { name: name ?? id, source: source ?? 'bot-cron' };
        if (prompt) taskMeta.prompt = prompt;
        taskMeta.allowedTools = allowedTools ?? 'Bash,Read,Write,Edit';
        const result = ensureCronTask(id, taskMeta);
        process.stdout.write(JSON.stringify({ ok: true, ...result }) + '\n');
        break;
      }
      // Circuit Breaker 상태 조회 (FSM 이력 기반)
      // Usage: node task-store.mjs cb-status <id>
      case 'cb-status': {
        const result = getCbStatus(args[0]);
        process.stdout.write(JSON.stringify(result) + '\n');
        break;
      }
      // depends 체크: 의존 태스크가 최근 25시간 내 done인지 확인
      // Usage: node task-store.mjs check-deps <taskId> [windowHours]
      case 'check-deps': {
        const [id, windowStr] = args;
        if (!id) { process.stderr.write('Usage: check-deps <taskId> [windowHours]\n'); process.exit(1); }
        const windowHours = windowStr ? Number(windowStr) : 25;
        const result = checkDeps(id, windowHours);
        process.stdout.write(JSON.stringify(result) + '\n');
        break;
      }
      // FSM 상태 요약 (Discord daily-summary 등에서 호출)
      // Usage: node task-store.mjs fsm-summary
      case 'fsm-summary': {
        const tasks = listTasks();
        const byStatus = {};
        for (const t of tasks) {
          byStatus[t.status] = (byStatus[t.status] ?? 0) + 1;
        }
        const recentFailed = tasks
          .filter(t => t.status === 'failed')
          .slice(0, 5)
          .map(t => ({
            state: 'failed',
            label: t.id,
            note: t.meta?.failedAt?.slice(0, 16) ?? 'unknown',
          }));
        const recentDone = tasks
          .filter(t => t.status === 'done')
          .slice(0, 3)
          .map(t => ({ state: 'ok', label: t.id }));
        const contextLine = Object.entries(byStatus)
          .map(([s, n]) => `${s} ${n}개`)
          .join(' · ');
        const msg = reportFormat({
          title: `FSM 태스크 현황 — 총 ${tasks.length}개`,
          context: contextLine,
          sections: [
            recentFailed.length ? {
              heading: '최근 실패', state: 'failed', items: recentFailed,
            } : null,
            recentDone.length ? {
              heading: '최근 완료', state: 'ok', items: recentDone,
            } : null,
          ].filter(Boolean),
          footer: kstFooter('fsm-summary'),
        });
        process.stdout.write(msg + '\n');
        break;
      }
      // aggregation 포함 태스크 목록 (parent_id별 자식 집계)
      // Usage: node task-store.mjs list-with-aggregation
      case 'list-with-aggregation': {
        const db = getDb();
        // 모든 태스크와 함께 aggregation 필드 계산
        const allTasks = listTasks();

        // parent_id별로 자식 태스크 집계
        const childrenByParent = {};
        for (const t of allTasks) {
          if (t.parent_id) {
            if (!childrenByParent[t.parent_id]) {
              childrenByParent[t.parent_id] = { total: 0, completed: 0 };
            }
            childrenByParent[t.parent_id].total++;
            if (t.status === 'done') {
              childrenByParent[t.parent_id].completed++;
            }
          }
        }

        // 각 태스크에 aggregation 필드 추가
        const tasksWithAgg = allTasks.map(t => ({
          ...t,
          total_children: childrenByParent[t.id]?.total ?? 0,
          completed_children: childrenByParent[t.id]?.completed ?? 0,
        }));

        process.stdout.write(JSON.stringify(tasksWithAgg, null, 2) + '\n');
        break;
      }
      default:
        process.stderr.write(`Unknown command: ${cmd}\n`);
        process.exit(1);
    }
  } catch (e) {
    process.stderr.write(e.message + '\n');
    process.exit(1);
  }
}