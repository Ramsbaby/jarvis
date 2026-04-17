#!/usr/bin/env node
// tasks-prompt-path-audit.mjs
//
// Why: 2026-04-17 사건 — OSS 공개 재구성(f0d6b33) 때 개인 스크립트는 repo에서 뺐는데
//      tasks.json 프롬프트의 경로 참조는 안 고쳐서, 크론이 LLM에게 유령 경로를 건네주고
//      LLM이 "스크립트 없어요" 자연어 응답으로 끝내서(exit 0) Discord에 허깨비 알림만 발생.
//      script-not-found auto-disable(faecde7)도 이 패턴을 못 잡았음.
//
// What: 활성 태스크 각 프롬프트 + script 필드에서 실행 경로를 추출해 실제 존재 여부 감사.
//       유령 경로 발견 시 ledger append + Discord jarvis-system 알림 + exit 2.
//       exit 2는 cron-safe-wrapper가 "SUCCESS"로 집어삼키지 않는 실패 상태로 기록하도록.
//
// Schedule: tasks.json에 `23 3 * * *` (매일 03:23 KST) 로 등록 — 24h 내 감지 보장.
// Ledger: ~/jarvis/runtime/ledger/tasks-prompt-path-audit.jsonl

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const HOME = os.homedir();
const TASKS_FILE = `${HOME}/.jarvis/config/tasks.json`;
const LEDGER_DIR = `${HOME}/jarvis/runtime/ledger`;
const LEDGER_FILE = `${LEDGER_DIR}/tasks-prompt-path-audit.jsonl`;
const MONITORING_CANDIDATES = [
  `${HOME}/jarvis/runtime/config/monitoring.json`,
  `${HOME}/.jarvis/config/monitoring.json`,
];
const BOT_HOME_CANDIDATES = [`${HOME}/jarvis/runtime`, `${HOME}/.jarvis`];

// 확장자 바운더리 있는 정규식 — `.json`이 `.js`로 오탐되는 문제 방지
const EXEC_RE =
  /(?:bash|sh|zsh|node|python3?)\s+["']?([~$][^\s`)'";|]+?\.(?:sh|mjs|js|py))(?=[\s`)'";|]|$)/gi;

function expandHome(p) {
  return p.startsWith('~') ? HOME + p.slice(1) : p;
}

function resolveCandidates(ref) {
  const expanded = expandHome(ref);
  if (!/\$\{?BOT_HOME\}?/.test(expanded)) return [expanded];
  return BOT_HOME_CANDIDATES.map((bh) =>
    expanded.replace(/\$\{?BOT_HOME\}?/g, bh),
  );
}

function auditTask(t) {
  if (t.disabled || t.enabled === false) return [];
  const prompt = String(t.prompt || '');
  const refs = new Set();
  const re = new RegExp(EXEC_RE.source, EXEC_RE.flags);
  let m;
  while ((m = re.exec(prompt)) !== null) refs.add(m[1]);
  if (t.script) refs.add(t.script);

  const missing = [];
  for (const ref of refs) {
    const candidates = resolveCandidates(ref);
    const exists = candidates.some((p) => {
      try {
        return fs.existsSync(p);
      } catch {
        return false;
      }
    });
    if (!exists) missing.push({ ref, tried: candidates });
  }
  return missing;
}

function loadMonitoringWebhook() {
  for (const f of MONITORING_CANDIDATES) {
    try {
      const j = JSON.parse(fs.readFileSync(f, 'utf8'));
      const w = j?.webhooks?.['jarvis-system'];
      if (w) return w;
    } catch {}
  }
  return null;
}

async function notifyDiscord(issues) {
  const webhook = loadMonitoringWebhook();
  if (!webhook) {
    console.error('[audit] monitoring webhook not found — skip discord notify');
    return false;
  }
  const lines = issues.map((i) => {
    const refs = i.missing.map((m) => `\`${m.ref}\``).join(', ');
    const trig = i.schedule !== 'none' ? i.schedule : i.trigger || 'manual';
    return `• **${i.id}** (${trig}): ${refs}`;
  });
  const content = [
    `🛂 **tasks-prompt-path-audit** — 유령 스크립트 경로 ${issues.length}건 발견`,
    ...lines,
    '',
    '대응: 스크립트 복원하거나 `tasks.json`에서 경로 갱신/태스크 disable.',
    'ledger: `~/jarvis/runtime/ledger/tasks-prompt-path-audit.jsonl`',
  ].join('\n');
  try {
    const res = await fetch(webhook, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        content,
        allowed_mentions: { parse: [] },
      }),
    });
    return res.ok;
  } catch (e) {
    console.error('[audit] discord notify failed:', e.message);
    return false;
  }
}

async function main() {
  fs.mkdirSync(LEDGER_DIR, { recursive: true });

  const data = JSON.parse(fs.readFileSync(TASKS_FILE, 'utf8'));
  const tasks = Array.isArray(data) ? data : data.tasks || [];

  const issues = [];
  let totalActive = 0;
  for (const t of tasks) {
    if (t.disabled || t.enabled === false) continue;
    totalActive++;
    const missing = auditTask(t);
    if (missing.length > 0) {
      issues.push({
        id: t.id || t.name || '?',
        schedule: t.schedule || 'none',
        trigger: t.event_trigger || null,
        missing,
      });
    }
  }

  const record = {
    ts: new Date().toISOString(),
    total_active_tasks: totalActive,
    issues_count: issues.length,
    total_missing_refs: issues.reduce((s, i) => s + i.missing.length, 0),
    issues,
  };
  fs.appendFileSync(LEDGER_FILE, JSON.stringify(record) + '\n');

  console.log(
    `[tasks-prompt-path-audit] active=${totalActive} issues=${issues.length}`,
  );

  if (issues.length === 0) {
    console.log('OK — no phantom script paths');
    process.exit(0);
  }

  for (const i of issues) {
    console.log(`  [${i.id}] (${i.schedule}) ${i.missing.length} missing:`);
    for (const m of i.missing) console.log(`    ${m.ref}`);
  }

  await notifyDiscord(issues);
  process.exit(2);
}

main().catch((e) => {
  console.error('[audit] fatal:', e);
  process.exit(1);
});
