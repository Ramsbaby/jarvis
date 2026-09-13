#!/usr/bin/env node
// 오픈클로 에이전트 SQLite의 턴별 사용량 → 자비스 토큰 원장(JSONL) 내보내기.
//
// 왜 훅이 아니라 이 방식인가 (2026-09-09 실측):
//   `llm_output`·`model_call_ended` 는 **내장(embedded) 모델 호출 경로에서만** 발생한다
//   (docs/plugins/hooks.md:941). 우리는 `claude-cli` 외부 하네스라 그 훅이 오지 않는다.
//   반면 사용량은 이미 `transcript_events` 의 `message.usage` 에 전부 적혀 있다.
//   훅 가용성에 기대지 않는 이 경로가 런타임을 바꿔도 계속 동작한다.
//
// 주의: 구독(claude-cli) 재사용이라 `cost` 는 정상적으로 0이다. 돈이 아니라 **토큰**을 센다.
// 달러 금액을 원장에 넣고 싶으면 API 키 과금으로 바꿔야 하고, 그건 별개의 결정이다.

import { execFileSync } from 'node:child_process';
import { appendFileSync, readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const LEDGER = process.env.OC_LEDGER ?? join(HOME, '.openclaw-data/runtime/state/token-ledger.jsonl');
const STATE = process.env.OC_LEDGER_STATE ?? join(HOME, '.openclaw-data/runtime/state/openclaw-ledger-watermark.json');
const AGENTS = (process.env.OC_AGENTS ?? 'main,home').split(',').map((s) => s.trim()).filter(Boolean);

function dbPath(agent) {
  return join(HOME, `.openclaw/agents/${agent}/agent/openclaw-agent.sqlite`);
}

function query(db, sql) {
  // 읽기 전용으로 연다. 게이트웨이가 쓰는 중인 DB를 잠그지 않기 위해서다.
  const out = execFileSync('sqlite3', ['-readonly', '-json', db, sql], {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  });
  return out.trim() ? JSON.parse(out) : [];
}

function loadWatermark() {
  try { return JSON.parse(readFileSync(STATE, 'utf8')); } catch { return {}; }
}

function main() {
  const wm = loadWatermark();
  mkdirSync(dirname(LEDGER), { recursive: true });
  let written = 0;
  let scanned = 0;

  for (const agent of AGENTS) {
    const db = dbPath(agent);
    if (!existsSync(db)) continue;
    const since = Number(wm[agent] ?? 0);
    let rows;
    try {
      rows = query(
        db,
        `select session_id, seq, created_at, event_json from transcript_events
         where created_at > ${since} and event_json like '%"usage"%'
         order by created_at asc limit 5000;`,
      );
    } catch (err) {
      console.error(`[${agent}] 조회 실패: ${String(err).slice(0, 200)}`);
      continue;
    }

    let maxTs = since;
    for (const r of rows) {
      scanned++;
      maxTs = Math.max(maxTs, Number(r.created_at));
      let ev;
      try { ev = JSON.parse(r.event_json); } catch { continue; }
      const msg = ev?.message ?? ev;
      const u = msg?.usage;
      if (!u) continue;
      // 어시스턴트 턴만 센다. 사용자 메시지에는 사용량이 붙지 않는다.
      if (msg?.role && msg.role !== 'assistant') continue;

      appendFileSync(LEDGER, JSON.stringify({
        ts: new Date(Number(r.created_at)).toISOString(),
        task: r.session_id,
        model: msg?.model ?? null,
        status: 'success',
        input: u.input ?? null,
        output: u.output ?? null,
        cache_read: u.cacheRead ?? null,
        cache_write: u.cacheWrite ?? null,
        total_tokens: u.totalTokens ?? null,
        // 구독 재사용에서는 0이 맞다. null 로 두면 "모른다"가 되어 뜻이 달라진다.
        cost_usd: u.cost?.total ?? 0,
        source: 'openclaw',
        agent_id: agent,
      }) + '\n');
      written++;
    }
    wm[agent] = maxTs;
  }

  writeFileSync(STATE, JSON.stringify(wm, null, 2));
  console.log(`LEDGER_EXPORT scanned=${scanned} written=${written} agents=${AGENTS.join(',')}`);
}

main();
