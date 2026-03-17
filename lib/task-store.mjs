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
import { mkdirSync } from 'node:fs';
import { canTransition } from './task-fsm.mjs';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const DB_PATH   = join(BOT_HOME, 'state', 'tasks.db');

let _db = null;

function getDb() {
  if (_db) return _db;
  mkdirSync(join(BOT_HOME, 'state'), { recursive: true });
  _db = new DatabaseSync(DB_PATH);
  _db.exec('PRAGMA journal_mode=WAL');
  _db.exec('PRAGMA busy_timeout=5000');
  _db.exec(`
    CREATE TABLE IF NOT EXISTS tasks (
      id         TEXT    PRIMARY KEY,
      status     TEXT    NOT NULL DEFAULT 'pending',
      priority   INTEGER NOT NULL DEFAULT 0,
      retries    INTEGER NOT NULL DEFAULT 0,
      depends    TEXT    NOT NULL DEFAULT '[]',
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
    CREATE INDEX IF NOT EXISTS idx_trans_task      ON task_transitions(task_id);
  `);
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
    .filter(t => (t.depends ?? []).every(d => doneIds.has(d)))
    .filter(t => t.retries < (t.maxRetries ?? 2))
    .sort((a, b) => b.priority - a.priority);
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

  db.transaction(() => {
    db.prepare(
      'UPDATE tasks SET status=?, priority=?, retries=?, meta=?, updated_at=? WHERE id=?'
    ).run(toStatus, extra.priority ?? task.priority, newRetries, JSON.stringify(newMeta), now, id);

    db.prepare(
      'INSERT INTO task_transitions (task_id, from_status, to_status, triggered_by, created_at) VALUES (?,?,?,?,?)'
    ).run(id, task.status, toStatus, triggeredBy, now);
  })();

  return { ...task, status: toStatus, retries: newRetries, meta: newMeta };
}

/** 태스크 추가 (중복 시 무시) */
export function addTask(task) {
  const { id, status = 'pending', priority = 0, retries = 0, depends = [], ...rest } = task;
  getDb().prepare(
    'INSERT OR IGNORE INTO tasks (id, status, priority, retries, depends, meta, updated_at) VALUES (?,?,?,?,?,?,?)'
  ).run(id, status, priority, retries, JSON.stringify(depends), JSON.stringify(rest), Date.now());
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
        const extra = args[3] ? JSON.parse(args[3]) : {};
        const result = transition(id, to, { triggeredBy: by, extra });
        process.stdout.write(JSON.stringify({ ok: true, status: result.status }) + '\n');
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
        const n = getDb().prepare("SELECT COUNT(*) as c FROM tasks WHERE status='queued'").get();
        process.stdout.write(String(n.c) + '\n');
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
