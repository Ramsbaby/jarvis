#!/usr/bin/env node
/**
 * promoter-auto-close.mjs — promoter 루프 자동 닫기 (Phase 1-A 메타인지)
 *
 * 역할: proposed_dev_queue / proposed_retro 상태로 멈춰있는 promoter 항목을
 * 야간에 자동 처리하여 폐쇄형 학습 루프를 완성한다.
 *
 * 처리 전략:
 *   - tier_a/b + proposed_dev_queue → 자비스 보드 DEV 태스크 자동 등록
 *   - tier_c + proposed_retro      → wiki/meta/_facts.md 모니터링 사실 추가
 *
 * 실행 시점: 매일 04:30 KST (skill-loop-nightly 완료 40분 후)
 * 의존: skill-loop-nightly (03:50 완료)
 * 모델: 없음 (LLM 미사용 — 순수 JS 처리)
 *
 * 설계 의사결정:
 * - Phase 1에서는 tasks.json 직접 패치 제외 (오판 리스크). wiki fact + 보드 등록만.
 * - 자동 닫기 완료 항목은 type=close_event로 ledger에 기록 (멱등성 보장).
 * - Discord #jarvis-system으로 처리 결과 보고.
 */

import { readFileSync, appendFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { execFileSync } from 'node:child_process';

const HOME = homedir();
const BOT_HOME = process.env.BOT_HOME || join(HOME, 'jarvis', 'runtime');
const INFRA = join(HOME, 'jarvis', 'infra');
const JARVIS_ROOT = join(HOME, 'jarvis');

const LEDGER_FILE = join(BOT_HOME, 'ledger', 'promoter-ledger.jsonl');
const SKILL_LOOP_LEDGER = join(BOT_HOME, 'ledger', 'skill-loop.jsonl');
const WIKI_META_FACTS = join(JARVIS_ROOT, 'runtime', 'wiki', 'meta', '_facts.md');
const DISCORD_ROUTE_SH = join(INFRA, 'lib', 'discord-route.sh');

// 자비스 보드 API
const BOARD_URL = 'https://board.ramsbaby.com';
const BOARD_KEY = 'jarvis-board-internal-2026';

const DRY_RUN = process.argv.includes('--dry-run');

function nowKST() {
  return new Date(Date.now() + 9 * 3600_000).toISOString().replace('Z', '+09:00');
}

function log(msg) {
  const ts = nowKST().slice(0, 19).replace('T', ' ');
  console.log(`[${ts}] [promoter-auto-close] ${msg}`);
}

// promoter-ledger.jsonl에서 cluster 항목 전체 로드
function loadQueue() {
  if (!existsSync(LEDGER_FILE)) return [];
  return readFileSync(LEDGER_FILE, 'utf-8')
    .split('\n')
    .filter(Boolean)
    .map(l => { try { return JSON.parse(l); } catch { return null; } })
    .filter(e => e && e.type === 'cluster');
}

// 이미 자동 닫힌 cluster_id Set 구성
function loadClosedIds() {
  if (!existsSync(LEDGER_FILE)) return new Set();
  return new Set(
    readFileSync(LEDGER_FILE, 'utf-8')
      .split('\n')
      .filter(Boolean)
      .map(l => { try { return JSON.parse(l); } catch { return null; } })
      .filter(e => e && e.type === 'close_event')
      .map(e => e.cluster_id)
  );
}

// ledger에 close_event 기록 (멱등성 보장용)
function appendClose(cluster_id, method, note) {
  const entry = { ts: nowKST(), type: 'close_event', cluster_id, method, note };
  appendFileSync(LEDGER_FILE, JSON.stringify(entry) + '\n');
}

// skill-loop.jsonl에 이벤트 기록
function appendSkillLoop(cluster_id, method) {
  const entry = { ts: nowKST(), event: 'promoter_auto_closed', cluster_id, method };
  appendFileSync(SKILL_LOOP_LEDGER, JSON.stringify(entry) + '\n');
}

// 자비스 보드 DEV 태스크 등록
async function registerBoardTask(item) {
  if (DRY_RUN) {
    log(`[DRY] 보드 등록 → ${item.cluster_id} (${item.tier}): ${item.seed}`);
    return 'dry-run-id';
  }

  const body = {
    title: `[자동] ${item.seed.slice(0, 80)}`,
    description: [
      `**티어:** ${item.tier}`,
      `**반복 횟수:** ${item.size}회`,
      `**이유:** ${item.reason}`,
      `**promoter_cluster_id:** \`${item.cluster_id}\``,
      ``,
      `> 자동 등록 — promoter-auto-close (${nowKST().slice(0, 10)})`,
    ].join('\n'),
    priority: item.tier === 'tier_a' ? 'high' : 'medium',
    status: 'pending',
    tags: ['metacog', 'auto-queue', item.tier],
  };

  try {
    const res = await fetch(`${BOARD_URL}/api/dev-tasks`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-agent-key': BOARD_KEY,
      },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
    const data = await res.json();
    return String(data.id || data._id || '등록됨');
  } catch (err) {
    log(`⚠️ 보드 등록 실패 (${item.cluster_id}): ${err.message}`);
    return null;
  }
}

// wiki/meta/_facts.md에 모니터링 사실 추가
function addWikiFact(item) {
  if (DRY_RUN) {
    log(`[DRY] wiki 추가 → ${item.cluster_id}: ${item.seed}`);
    return true;
  }
  try {
    mkdirSync(join(JARVIS_ROOT, 'runtime', 'wiki', 'meta'), { recursive: true });
    const fact = `- [${nowKST().slice(0, 10)}][source:promoter-auto] ${item.seed} (tier_c, ${item.size}회 반복) — 주간 재발 모니터링 대상\n`;
    appendFileSync(WIKI_META_FACTS, fact);
    return true;
  } catch (err) {
    log(`⚠️ wiki 추가 실패 (${item.cluster_id}): ${err.message}`);
    return false;
  }
}

// Discord #jarvis-system 알림 (mistake-promoter.mjs 패턴 재사용)
function notify(severity, title, kvObj) {
  if (DRY_RUN || !existsSync(DISCORD_ROUTE_SH)) {
    log(`[NOTIFY] ${severity} / ${title} / ${JSON.stringify(kvObj)}`);
    return;
  }
  const kv = Object.entries(kvObj)
    .map(([k, v]) => `${String(k).replace(/[,=]/g, '_')}=${String(v).replace(/[,=]/g, '_')}`)
    .join(',');
  const snippet = `export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; source "${DISCORD_ROUTE_SH}"; discord_route "$1" "$2" "$3"`;
  try {
    execFileSync('/bin/bash', ['-c', snippet, 'bash', severity, title, kv], {
      stdio: ['ignore', 'inherit', 'inherit'], timeout: 30_000,
    });
  } catch (e) {
    log(`WARN: Discord 통보 실패: ${e.message}`);
  }
}

async function main() {
  log('시작');

  const queue = loadQueue();
  const closedIds = loadClosedIds();

  // 아직 닫히지 않은 항목만 추출
  const pending = queue.filter(e => !closedIds.has(e.cluster_id));
  const devQueue = pending.filter(e => e.status === 'proposed_dev_queue');
  const retroQueue = pending.filter(e => e.status === 'proposed_retro' && e.tier === 'tier_c');

  log(`대기 항목 — dev_queue: ${devQueue.length}건, retro(tier_c): ${retroQueue.length}건`);

  const results = {
    board_registered: [],
    wiki_added: [],
    skipped: [],
    total_pending: pending.length,
  };

  // ─── tier_a/b + proposed_dev_queue → 보드 DEV 태스크 ───────────────
  for (const item of devQueue) {
    const taskId = await registerBoardTask(item);
    if (taskId) {
      appendClose(item.cluster_id, 'board_task', `보드 DEV 태스크: ${taskId}`);
      appendSkillLoop(item.cluster_id, 'board_task');
      results.board_registered.push({ cluster_id: item.cluster_id, seed: item.seed.slice(0, 50), taskId });
      log(`✅ 보드 등록: ${item.cluster_id} → ${taskId}`);
    } else {
      results.skipped.push(item.cluster_id);
    }
  }

  // ─── tier_c + proposed_retro → wiki/meta fact 추가 ─────────────────
  for (const item of retroQueue) {
    const ok = addWikiFact(item);
    if (ok) {
      appendClose(item.cluster_id, 'wiki_fact', 'wiki/meta/_facts.md 추가');
      appendSkillLoop(item.cluster_id, 'wiki_fact');
      results.wiki_added.push({ cluster_id: item.cluster_id, seed: item.seed.slice(0, 50) });
      log(`✅ wiki 추가: ${item.cluster_id}`);
    } else {
      results.skipped.push(item.cluster_id);
    }
  }

  // ─── Discord 보고 ────────────────────────────────────────────────────
  const total = results.board_registered.length + results.wiki_added.length;
  if (total > 0 || results.skipped.length > 0) {
    notify('info', 'promoter 루프 자동 닫기', {
      보드등록: results.board_registered.length,
      wiki추가: results.wiki_added.length,
      스킵: results.skipped.length,
      전체대기: results.total_pending,
    });
  } else {
    log('처리 대상 없음 — 모든 항목이 이미 처리됨');
  }

  log(`완료 — 보드: ${results.board_registered.length}, wiki: ${results.wiki_added.length}, 스킵: ${results.skipped.length}`);
  process.stdout.write(JSON.stringify(results) + '\n');
}

main().catch(err => {
  console.error('[promoter-auto-close] fatal:', err.message);
  process.exit(1);
});
