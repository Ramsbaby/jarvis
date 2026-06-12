#!/usr/bin/env node
// task-dedup-check.mjs — 자가 개발 큐 의미 중복 판별기
//
// Why 1줄: news-briefing이 같은 주제(예: 모델 라우팅)를 슬러그만 바꿔 반복 제안하는
// 큐 증식을 차단한다 (2026-06-12 감사에서 라우팅류 10건 중복 적발, 주인님 승인).
//
// 판정: 후보 ID의 핵심 단어와 기존 태스크 ID의 핵심 단어가 2개 이상 겹치면 중복.
// exit 0 = 고유 / exit 3 = 중복(stdout에 충돌 태스크 ID) / 그 외 = 판별기 자체 오류(fail-open 권장)

import { DatabaseSync } from 'node:sqlite';
import { homedir } from 'node:os';
import { join } from 'node:path';

const STOPWORDS = new Set(['tech', 'claude', 'anthropic', 'ai', 'api', 'beta', 'mode', 'new', 'the', 'a']);
const tokens = (id) => new Set(
  id.toLowerCase().split(/[^a-z0-9]+/).filter(w => w && !STOPWORDS.has(w))
);

const candidate = process.argv[2];
if (!candidate) { console.error('usage: task-dedup-check.mjs <task-id>'); process.exit(2); }

const dbPath = join(process.env.BOT_HOME || join(homedir(), 'jarvis/runtime'), 'state', 'tasks.db');
const db = new DatabaseSync(dbPath, { readOnly: true });
const rows = db.prepare('SELECT id FROM tasks').all();

const cand = tokens(candidate);
for (const { id } of rows) {
  if (id === candidate) { console.log(id); process.exit(3); } // 동일 ID는 당연히 중복
  let shared = 0;
  for (const t of tokens(id)) if (cand.has(t)) shared++;
  if (shared >= 2) { console.log(id); process.exit(3); }
}
process.exit(0);
