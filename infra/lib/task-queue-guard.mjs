/**
 * task-queue-guard.mjs — 개발 큐(tasks.db) 생산 관문 (2026-10-03)
 *
 * 왜: 큐를 비우는 소비자 잡(jarvis-dev-task-runner)이 2026-09-10 부터 꺼져 있는데
 *     생산자(insight-extractor · mistake-promoter · jarvis-auditor)는 매일 태스크를 계속 넣었다.
 *     10-03 실측 pending 81 · queued 21 — 아무도 읽지 않는 일감이 쌓였고, 소비자를 다시 켜는 순간
 *     몇 주 묵은 일감이 코더에게 한꺼번에 넘어갈 상태였다.
 *     원칙: 소비자가 꺼져 있으면 생산하지 않는다. 소비자를 다시 켜면 생산도 저절로 돌아온다.
 *
 * 판정 순서:
 *   1) JARVIS_TASK_QUEUE_ENABLED = 1|true|on|yes → 켬, 0|false|off|no → 끔 (강제 지정·시험용)
 *   2) 오픈클로 게이트웨이 상태 DB(OPENCLAW_STATE_DB, 기본 ~/.openclaw/state/openclaw.sqlite)의
 *      cron_jobs 에서 소비자 잡(JARVIS_TASK_QUEUE_CONSUMER, 기본 jarvis-dev-task-runner)의 enabled
 *   3) 어느 쪽으로도 확인하지 못하면 끔 — 소비자가 있는지 모르면 쌓지 않는다.
 *
 * 생산자는 끔일 때 태스크만 넣지 않고 나머지 산출물(인사이트·원장·보고서)은 그대로 쓴다.
 *
 * CLI: node task-queue-guard.mjs  → stdout JSON {"enabled":bool,"reason":"..."}, 종료코드 0=켬 / 3=끔
 */

import { DatabaseSync } from 'node:sqlite';
import { existsSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

export const DEFAULT_CONSUMER = 'jarvis-dev-task-runner';

const ON = new Set(['1', 'true', 'on', 'yes']);
const OFF = new Set(['0', 'false', 'off', 'no']);

/**
 * 개발 큐 생산 허용 여부. 호출할 때마다 새로 판정한다(잡 실행 중 소비자 상태가 바뀌어도 다음 호출에 반영).
 * @param {Record<string,string|undefined>} [env]
 * @returns {{ enabled: boolean, reason: string }}
 */
export function taskQueueStatus(env = process.env) {
  const raw = String(env.JARVIS_TASK_QUEUE_ENABLED ?? '').trim().toLowerCase();
  if (ON.has(raw)) return { enabled: true, reason: `JARVIS_TASK_QUEUE_ENABLED=${raw}` };
  if (OFF.has(raw)) return { enabled: false, reason: `JARVIS_TASK_QUEUE_ENABLED=${raw}` };

  const consumer = env.JARVIS_TASK_QUEUE_CONSUMER || DEFAULT_CONSUMER;
  const dbPath = env.OPENCLAW_STATE_DB || join(homedir(), '.openclaw', 'state', 'openclaw.sqlite');
  if (!existsSync(dbPath)) {
    return { enabled: false, reason: `소비자 상태 확인 불가 — ${dbPath} 없음` };
  }
  let db;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true, timeout: 2000 });
    const row = db.prepare('SELECT COUNT(*) AS n, MAX(enabled) AS e FROM cron_jobs WHERE name=?').get(consumer);
    if (!row || Number(row.n) === 0) {
      return { enabled: false, reason: `소비자 잡 ${consumer} 미등록` };
    }
    const on = Number(row.e) === 1;
    return { enabled: on, reason: `소비자 잡 ${consumer} ${on ? '켜짐' : '꺼짐'}` };
  } catch (e) {
    return { enabled: false, reason: `소비자 상태 확인 불가 — ${e.message}` };
  } finally {
    try { db?.close(); } catch { /* 닫기 실패는 판정과 무관 */ }
  }
}

export function isTaskQueueEnabled(env = process.env) {
  return taskQueueStatus(env).enabled;
}

// ── CLI (bash 생산자용: jarvis-auditor.sh) ──
const isMain = (() => {
  try { return !!process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url); }
  catch { return false; }
})();
if (isMain) {
  const s = taskQueueStatus();
  process.stdout.write(JSON.stringify(s) + '\n');
  process.exit(s.enabled ? 0 : 3);
}
