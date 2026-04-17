#!/usr/bin/env node
/**
 * migrate-queue.mjs — dev-queue.json → tasks.db 일회성 마이그레이션
 * Usage: node migrate-queue.mjs [--dry-run]
 *
 * 주의: 실행 전 dev-runner cron(22:50)이 돌지 않는 시간대에 실행할 것.
 */

import { readFileSync } from 'node:fs';
import { join }         from 'node:path';
import { homedir }      from 'node:os';
import { addTask, listTasks } from '../lib/task-store.mjs';

const BOT_HOME   = process.env.BOT_HOME || join(homedir(), 'jarvis/runtime');
const QUEUE_FILE = join(BOT_HOME, 'state', 'dev-queue.json');
const DRY_RUN    = process.argv.includes('--dry-run');

console.log(DRY_RUN ? '[migrate] DRY-RUN 모드' : '[migrate] dev-queue.json → tasks.db');

let data;
try {
  data = JSON.parse(readFileSync(QUEUE_FILE, 'utf-8'));
} catch (e) {
  console.error(`[migrate] dev-queue.json 읽기 실패: ${e.message}`);
  process.exit(1);
}

const tasks = data.tasks ?? [];
console.log(`[migrate] ${tasks.length}개 태스크 발견`);

let inserted = 0, skipped = 0;

for (const task of tasks) {
  const { id, status = 'pending', priority = 0, retries = 0, depends = [], ...meta } = task;

  if (DRY_RUN) {
    console.log(`  [dry] ${id} (${status}, priority=${priority})`);
    continue;
  }

  try {
    addTask({ id, status, priority, retries, depends, ...meta });
    console.log(`  [+] ${id} (${status})`);
    inserted++;
  } catch (e) {
    console.log(`  [skip] ${id}: ${e.message}`);
    skipped++;
  }
}

if (!DRY_RUN) {
  const total = listTasks().length;
  console.log(`\n완료: ${inserted}개 삽입, ${skipped}개 스킵, DB 총 ${total}개`);
  console.log(`DB 위치: ${join(BOT_HOME, 'state', 'tasks.db')}`);
}