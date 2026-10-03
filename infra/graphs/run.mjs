#!/usr/bin/env node
// run.mjs — 그래프 실행기. OpenClaw 명령형 예약 잡과, 대화 중 자비스가 부른다. 고정 Node 로 실행한다(lg.sh).
//
//   run.mjs start <그래프> <스레드> [--topic 값] [--llm]   새 스레드를 처음부터 (이미 있는 스레드는 거부)
//   run.mjs resume <스레드> approved|rejected               승인 대기 중인 스레드에 답한다
//   run.mjs retry <스레드>                                  고장·보류로 멈춘 스레드를 마지막 체크포인트부터 잇는다
//   run.mjs status [<스레드>] [--json] [--all]              대기·만료·진행 중(멈춤·보류 포함) 스레드 — 읽기만 한다
//   run.mjs sweep                                           기한 지난 승인 대기를 자동 취소 — EXPIRED 줄, 없으면 NO_REPLY
//   run.mjs gc [--days 14]                                  오래된 스레드 삭제 + VACUUM
//   run.mjs selftest                                        저장 부품(better-sqlite3) 적재 자가 시험
//
// 표준 출력 첫 줄이 결과다: DONE · WAITING · EXPIRED · HELD · ERROR · OK · STATUS 중 하나로 시작한다.
// 종료 코드: 0 = 끝남·승인 대기·보류·만료 처리 / 1 = 오류(잠김·중복·고장·자가 시험 실패 포함).
//   OpenClaw 는 0 이 아니면 error·실패 경보로 처리한다 — 승인 대기를 경보 소음으로 만들지 않으려고 대기는 0 이다.
// 정본은 그래프 체크포인트다. 등록부(lg_threads)는 그래프 상태로 맞춘다(reconcile).
// 기한은 실행기가 그 질문을 처음 내보인 때부터 48시간. 답이 실제로 적용된 뒤에만 그 대기 기록을 놓는다(다음 질문은 새 기한).
import "./lib/env-guard.mjs"; // 반드시 첫 import — 추적 변수 삭제·umask 077
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { selftest } from "./lib/selftest.mjs";
import { loadConfig, clock, iso } from "./lib/config.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const THREAD_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/;
const GRAPH_RE = /^[a-z][a-z0-9-]{0,40}$/;
const VALUE_FLAGS = new Set(["days", "topic"]);
const STATUSES = ["waiting", "expired", "running", "stalled", "held", "failed", "blocked", "done"];

class UsageError extends Error {}

const lines = [];
const say = (s) => lines.push(String(s).replace(/\s+/g, " ").trim().slice(0, 400)); // 한 줄 요약(알림용)
const raw = (s) => lines.push(String(s)); // JSON 은 자르지 않는다
const warn = (s) => process.stderr.write(`${s}\n`);

// 종료 처리: 노드 실행 중에 프로세스가 끝나면(고장·신호) 장부에 남기고, 잠금을 풀고, 돌던 claude 자식도 끈다.
const active = { cmd: null, ctx: null, store: null, now: null, thread: null, token: null, running: false, signal: null, killChildren: null };
process.on("exit", (code) => {
  active.killChildren?.();
  const { store, thread } = active;
  if (!store || !thread) return;
  try {
    if (active.running) {
      process.exitCode = 1; // 노드가 process.exit(0) 을 불러도 경보가 나게
      const why = active.signal ? `신호 ${active.signal}` : `코드 ${code}`;
      store.updateThread(thread, { status: "failed", note: `노드 실행 중 프로세스가 끝남(${why})` }, active.now());
      fs.writeSync(1, `ERROR ${thread} crashed 노드 실행 중 프로세스가 끝남(${why}) — retry 로 이어간다\n`);
    }
    if (active.token) store.releaseLock(thread, active.token);
  } catch { /* 끝나는 중 — 할 수 있는 만큼만 */ }
});
for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(sig, () => { active.signal = sig; process.exit(1); });

function parseArgs(argv) {
  const pos = [], flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) { pos.push(a); continue; }
    const eq = a.indexOf("=");
    const key = a.slice(2, eq < 0 ? undefined : eq);
    if (eq >= 0) flags[key] = a.slice(eq + 1);
    else if (VALUE_FLAGS.has(key)) {
      if (i + 1 >= argv.length) throw new UsageError(`--${key} 값이 없다`);
      flags[key] = argv[++i];
    } else flags[key] = true;
  }
  return { pos, flags };
}
let current = "-"; // 오류 줄에 붙일 스레드 이름
function checkThread(t) {
  if (!t || !THREAD_RE.test(t)) throw new UsageError(`스레드 이름은 영문·숫자·._:- 100자 이내: ${t ?? "(없음)"}`);
  current = t;
  return t;
}

// 그래프를 연다. check=false 는 읽기(만료 확인)용 — 규칙 위반 그래프라도 기한 처리는 해야 한다.
async function openGraph(ctx, name, thread, { check = true } = {}) {
  if (!GRAPH_RE.test(name ?? "")) throw new UsageError(`그래프 이름이 이상하다: ${name ?? "(없음)"}`);
  const file = path.join(HERE, "graphs", `${name}.mjs`);
  if (!fs.existsSync(file)) throw new UsageError(`그래프 없음: ${name}`);
  if (check) {
    const { checkFile } = await import("./scripts/check-interrupt-nodes.mjs");
    const { problems } = checkFile(file, `graphs/${name}.mjs`);
    if (problems.length) {
      const p = problems[0];
      throw new Error(`그래프 규칙 위반 ${problems.length}건(${p.file}:${p.line} ${p.rule}) — scripts/check-interrupt-nodes.mjs 로 확인`);
    }
  }
  const mod = await import(pathToFileURL(file).href);
  const { Command } = await import("@langchain/langgraph");
  const { SqliteSaver } = await import("@langchain/langgraph-checkpoint-sqlite");
  const { createClaude, killActiveChildren } = await import("./lib/claude.mjs");
  active.killChildren = killActiveChildren;
  const llm = createClaude({ store: ctx.store, cfg: ctx.cfg, now: ctx.now, thread });
  const app = mod.build({ checkpointer: new SqliteSaver(ctx.store.db), llm });
  return { mod, app, Command, run: { configurable: { thread_id: thread }, durability: "sync" } };
}

const pendingInterrupts = (s) => s.tasks?.flatMap((t) => t.interrupts ?? []) ?? [];
// 같은 노드 안의 interrupt 는 id 가 같다(노드 경로의 해시) — 질문 내용까지 열쇠에 넣는다.
const interruptKey = (intr) =>
  `${intr?.id ?? "-"}:${createHash("sha1").update(JSON.stringify(intr?.value ?? null)).digest("hex").slice(0, 12)}`;
function questionOf(intr) {
  const v = intr?.value;
  if (typeof v === "string") return v.replace(/\s+/g, " ").slice(0, 300);
  const parts = [v?.question ?? "승인 대기"];
  if (v?.draft) parts.push(`초안: ${v.draft}`);
  return parts.join(" | ").replace(/\s+/g, " ").slice(0, 300);
}

async function withLock(ctx, thread, fn) {
  // 시험용 출발선: 동시성 시험에서 모든 프로세스가 같은 순간에 잠금을 잡게 한다(시험 모드에서만).
  const startAt = ctx.cfg.testMode ? Number(process.env.LG_TEST_START_AT) : 0;
  if (startAt > Date.now()) await new Promise((r) => setTimeout(r, Math.min(startAt - Date.now(), 10_000)));
  const token = ctx.store.acquireLock(thread);
  if (!token) { say(`ERROR ${thread} busy 다른 프로세스가 이 스레드를 처리 중`); return 1; }
  active.thread = thread; active.token = token;
  try { return await fn(); } finally {
    ctx.store.releaseLock(thread, token);
    active.token = null; active.thread = null;
  }
}

// 그래프 상태(정본)로 등록부의 '대기' 칸을 맞춘다. 기록된 대기와 같은 질문이면 기록한 기한을 그대로 쓴다.
// 처음 보는 질문: fresh(방금 이 프로세스가 돌려 나온 것)면 지금부터. 아니면(고장으로 기록이 빠진 것) 마지막 실행 시작과
// 체크포인트 시각 중 늦은 쪽부터 — 기록이 빠졌다고 기한이 늘지 않게, 옛 체크포인트 때문에 보이기도 전에 만료되지 않게.
// answered: 방금 답을 적용하고 돌린 직후 — 기록된 대기는 답을 받은 것이니 열쇠가 같아도 새 질문으로 본다.
async function reconcile(ctx, g, thread, { fresh = false, answered = false } = {}) {
  const s = await g.app.getState(g.run);
  const intrs = pendingInterrupts(s);
  const row = ctx.store.getThread(thread);
  const t = ctx.now();
  if (intrs.length !== 1) {
    if (!intrs.length && row?.interrupt_id != null) {
      ctx.store.updateThread(thread, { interrupt_id: null, waiting_since: null, deadline_at: null }, t, { touch: false });
    }
    return { kind: intrs.length ? "multi" : "none", s, intrs };
  }
  const intr = intrs[0], key = interruptKey(intr), q = questionOf(intr);
  let since = row?.waiting_since, deadline = row?.deadline_at;
  if (answered || row?.interrupt_id !== key || deadline == null) {
    const created = Date.parse(s.createdAt ?? "");
    const anchor = Math.max(Number.isFinite(created) ? created : 0, row?.run_started_at ?? 0);
    since = fresh || !anchor ? t : Math.min(t, anchor);
    deadline = since + ctx.cfg.approvalTtlMs;
    ctx.store.updateThread(thread, { interrupt_id: key, waiting_since: since, deadline_at: deadline, question: q }, t, { touch: false });
  }
  if (deadline <= t) {
    ctx.store.updateThread(thread, { status: "expired", note: "승인 기한 초과 — 자동 취소", notified: 0 }, t);
    ctx.expiredNow.push(thread);
    return { kind: "expired", s, q, deadline };
  }
  return { kind: "waiting", s, q, deadline };
}

const multiLine = (thread, intrs) =>
  `ERROR ${thread} multi-interrupt 승인 대기 ${intrs.length}개가 동시에 생겼다 — 답 하나가 모두를 승인할 수 있어 받지 않는다: ${intrs.map(questionOf).join(" / ")}`;

// 그래프를 돌린 뒤 결과를 장부에 맞추고 첫 줄을 낸다. fresh = 방금 이 프로세스가 그래프를 돌렸다.
async function settle(ctx, g, thread, { fresh = false, answered = false } = {}) {
  const r = await reconcile(ctx, g, thread, { fresh, answered });
  const t = ctx.now();
  if (r.kind === "multi") {
    ctx.store.updateThread(thread, { status: "failed", note: `승인 대기 ${r.intrs.length}개 동시 — 지원하지 않는다` }, t);
    say(multiLine(thread, r.intrs));
    return 1;
  }
  if (r.kind === "expired") { say(`ERROR ${thread} expired 승인 기한(${iso(r.deadline)})이 지나 자동 취소했다 — 새로 start`); return 1; }
  if (r.kind === "waiting") {
    ctx.store.updateThread(thread, { status: "waiting", question: r.q }, t);
    say(`WAITING ${thread} ${r.q}`);
    say(`답: lg.sh resume ${thread} approved|rejected · 기한 ${iso(r.deadline)}`);
    return 0;
  }
  if (!r.s.next?.length) {
    const summary = String(g.mod.summarize ? g.mod.summarize(r.s.values ?? {}) : "");
    ctx.store.updateThread(thread, { status: "done", note: summary.slice(0, 300) }, t);
    say(`DONE ${thread} ${summary}`);
    return 0;
  }
  // interrupt 없이 다음 노드가 남았다 = 정적 중단점(interruptBefore/After) 같은 멈춤. 이어가면 승인 없이 실행될 수 있어 막는다.
  ctx.store.updateThread(thread, { status: "blocked", note: `interrupt 없이 멈춤(다음: ${r.s.next.join(",")})` }, t);
  say(`ERROR ${thread} blocked interrupt 없이 ${r.s.next.join(",")} 앞에서 멈췄다(정적 중단점?) — 승인 없이 이어갈 수 있어 retry 를 막는다`);
  return 1;
}

// 노드가 찍는 표준 출력·오류는 스레드 로그(600)로 돌린다 — '첫 줄이 결과' 규약과 stderr 없는 알림을 지키려고.
function captureOutput(ctx, thread) {
  let fd = null;
  const saved = [process.stdout.write, process.stderr.write];
  const sink = (chunk, enc, cb) => {
    try {
      if (fd === null) {
        fs.mkdirSync(path.dirname(ctx.store.logPath(thread)), { recursive: true, mode: 0o700 });
        fd = fs.openSync(ctx.store.logPath(thread), "a", 0o600);
      }
      fs.writeSync(fd, typeof chunk === "string" ? chunk : Buffer.from(chunk));
    } catch { /* 로그 실패는 실행을 막지 않는다 */ }
    const done = typeof enc === "function" ? enc : cb;
    if (done) done();
    return true;
  };
  process.stdout.write = sink;
  process.stderr.write = sink;
  return () => {
    [process.stdout.write, process.stderr.write] = saved;
    if (fd !== null) { try { fs.closeSync(fd); } catch { /* 이미 닫힘 */ } fd = null; }
  };
}

// prev: 돌리기 전 등록부 행. 같은 이유로 되풀이하는 보류·실패는 정리 기준 시각(updated_at)을 늘리지 않는다.
// answered: 답을 적용하는 실행(resume). 실패하면 대기 기록(기한)을 그대로 두어 sweep 이 만료시킬 수 있게 한다.
async function drive(ctx, g, thread, invoke, prev, { answered = false } = {}) {
  const restore = captureOutput(ctx, thread);
  active.running = true;
  try {
    await invoke();
  } catch (e) {
    active.running = false;
    restore();
    const held = e?.held === true || e?.cause?.held === true; // LLM 상한(LlmBudgetHeld) 또는 노드가 스스로 보류를 낸 경우
    const status = held ? "held" : "failed";
    const note = String(e?.message ?? e).split("\n")[0].slice(0, 200);
    const same = prev?.status === status && prev?.note === note;
    ctx.store.updateThread(thread, { status, note }, ctx.now(), { touch: !same });
    if (held) { say(`HELD ${thread} ${note}`); return 0; }
    say(`ERROR ${thread} failed ${note} — 원인을 고친 뒤 retry`);
    return 1;
  }
  active.running = false;
  restore();
  return settle(ctx, g, thread, { fresh: true, answered });
}

async function cmdStart(ctx, [graph, thread], flags) {
  checkThread(thread);
  const g = await openGraph(ctx, graph, thread);
  const input = g.mod.input ? g.mod.input(flags) : {};
  return withLock(ctx, thread, async () => {
    if (ctx.store.hasCheckpoint(thread)) {
      const row = ctx.store.getThread(thread);
      say(`ERROR ${thread} exists 이미 있는 스레드(${row ? ctx.store.effective(row) : "등록 없음"}) — status 로 보고 새 이름으로 start`);
      return 1;
    }
    ctx.store.registerThread(thread, graph, ctx.now());
    return drive(ctx, g, thread, () => g.app.invoke(input, g.run), null);
  });
}

async function cmdResume(ctx, [thread, decision]) {
  checkThread(thread);
  if (!["approved", "rejected"].includes(decision)) throw new UsageError("resume <스레드> approved|rejected");
  const row0 = ctx.store.getThread(thread);
  if (!row0) { say(`ERROR ${thread} not-found 없는 스레드`); return 1; }
  const g = await openGraph(ctx, row0.graph, thread);
  return withLock(ctx, thread, async () => {
    const row = ctx.store.getThread(thread); // 잠근 뒤 다시 읽는다 — 그 사이 다른 프로세스가 끝냈을 수 있다
    if (row.status === "expired") { say(`ERROR ${thread} expired 승인 기한이 지나 자동 취소된 스레드 — 새로 start`); return 1; }
    const r = await reconcile(ctx, g, thread);
    if (r.kind === "expired") { say(`ERROR ${thread} expired 승인 기한(${iso(r.deadline)})이 지나 자동 취소했다 — 새로 start`); return 1; }
    if (r.kind === "multi") { say(multiLine(thread, r.intrs)); return 1; }
    if (r.kind === "none") { say(`ERROR ${thread} not-waiting 승인 대기 중이 아님(${ctx.store.effective(row)})`); return 1; }
    // 답을 적용한다. 대기 기록은 실행이 성공한 뒤 settle 이 놓는다(실패하면 기한이 남아 sweep 이 만료시킨다).
    ctx.store.updateThread(thread, { status: "running", decision, run_started_at: ctx.now() }, ctx.now());
    return drive(ctx, g, thread, () => g.app.invoke(new g.Command({ resume: decision }), g.run), row, { answered: true });
  });
}

async function cmdRetry(ctx, [thread]) {
  checkThread(thread);
  const row0 = ctx.store.getThread(thread);
  if (!row0) { say(`ERROR ${thread} not-found 없는 스레드`); return 1; }
  const g = await openGraph(ctx, row0.graph, thread);
  return withLock(ctx, thread, async () => {
    const row = ctx.store.getThread(thread);
    if (row.status === "expired") { say(`ERROR ${thread} expired 자동 취소된 스레드는 잇지 않는다 — 새로 start`); return 1; }
    if (row.status === "blocked") { say(`ERROR ${thread} blocked interrupt 없이 멈춘 스레드는 승인 없이 지나갈 수 있어 잇지 않는다 — 그래프를 고친 뒤 새로 start`); return 1; }
    if (!ctx.store.hasCheckpoint(thread)) { say(`ERROR ${thread} no-checkpoint 저장된 단계가 없다 — 같은 이름으로 다시 start`); return 1; }
    const r = await reconcile(ctx, g, thread);
    if (r.kind !== "none" || !r.s.next?.length) return settle(ctx, g, thread); // 대기·만료·끝남은 장부만 맞춘다
    ctx.store.updateThread(thread, { status: "running", run_started_at: ctx.now() }, ctx.now(), { touch: false });
    return drive(ctx, g, thread, () => g.app.invoke(null, g.run), row);
  });
}

// 기한 지난 승인 대기를 취소한다. 등록부로 후보를 고르고 그래프 상태로 확인한다 — 이미 답을 받아 다음 단계로 간 스레드는 취소하지 않는다.
// 끊긴 스레드(실행 중으로 적혔는데 주인이 없음)도 여기서 그래프 상태로 맞춘다. 알림 줄은 end() 가 붙인다.
async function sweep(ctx) {
  const failures = [];
  for (const row of ctx.store.sweepCandidates(ctx.now())) {
    const token = ctx.store.acquireLock(row.thread_id);
    if (!token) continue; // 지금 누가 처리 중 — 그쪽이 판단한다
    const t = ctx.now();
    try {
      let g;
      try { g = await openGraph(ctx, row.graph, row.thread_id, { check: false }); } catch (e) {
        if (!(e instanceof UsageError)) throw e;
        // 그래프 파일이 없어졌다 — 그래프 상태를 못 읽으니 장부 기한으로 처리한다(영원히 대기로 남지 않게)
        if (row.deadline_at != null && row.deadline_at <= t) {
          ctx.store.updateThread(row.thread_id, { status: "expired", note: `${e.message} — 장부 기한으로 만료`, notified: 0 }, t);
          ctx.expiredNow.push(row.thread_id);
        } else if (row.status === "running") {
          ctx.store.updateThread(row.thread_id, { status: "failed", note: e.message }, t, { touch: false });
        }
        continue;
      }
      const r = await reconcile(ctx, g, row.thread_id);
      if (r.kind === "waiting" && row.status !== "waiting") {
        ctx.store.updateThread(row.thread_id, { status: "waiting", question: r.q }, t, { touch: false });
      } else if (r.kind === "none" && row.status === "waiting") { // 장부는 대기인데 그래프엔 대기가 없다(그래프가 바뀜 등)
        const done = !r.s.next?.length;
        ctx.store.updateThread(row.thread_id, { status: done ? "done" : "failed", note: `장부는 대기였으나 그래프에 대기가 없어 ${done ? "끝남" : "멈춤"}으로 맞춤` }, t, { touch: false });
      }
    } catch (e) {
      failures.push(`ERROR ${row.thread_id} sweep 만료 확인 실패: ${String(e?.message ?? e).split("\n")[0]}`);
    } finally {
      ctx.store.releaseLock(row.thread_id, token);
    }
  }
  return failures;
}

function view(ctx, r) {
  const t = (ms) => (ms == null ? null : iso(ms));
  let status = ctx.store.effective(r), note = r.note;
  if (status === "waiting" && r.deadline_at != null && r.deadline_at <= ctx.now()) { status = "expired"; note = "기한 지남 — 다음 명령·sweep 때 취소"; }
  return {
    thread: r.thread_id, graph: r.graph, status, since: t(r.waiting_since), deadline: t(r.deadline_at),
    question: r.question, decision: r.decision, note, created: t(r.created_at), updated: t(r.updated_at),
  };
}
function viewLine(v) {
  const detail = {
    waiting: `${v.question ?? ""} · 기한 ${v.deadline}`,
    expired: `${v.question ?? ""} · ${v.note ?? ""}`,
    stalled: "멈춤(실행 중 끊김) — retry",
  }[v.status] ?? (v.note ?? "");
  return `${v.status.toUpperCase()} ${v.thread} [${v.graph}] ${detail}`;
}

// 읽기만 한다 — 만료 확정·알림은 다른 명령과 sweep 이 한다(여기서 확정하면 알림이 사라진다).
function cmdStatus(ctx, [thread], flags) {
  if (thread) {
    checkThread(thread);
    const row = ctx.store.getThread(thread);
    if (!row) { say(flags.json ? JSON.stringify({ thread, status: "not-found" }) : `ERROR ${thread} not-found 없는 스레드`); return 1; }
    const v = view(ctx, row);
    if (flags.json) raw(JSON.stringify(v)); else say(viewLine(v));
    return 0;
  }
  const all = ctx.store.listThreads().map((r) => view(ctx, r));
  const counts = Object.fromEntries(STATUSES.map((k) => [k, 0]));
  for (const v of all) counts[v.status] = (counts[v.status] ?? 0) + 1;
  const shown = flags.all ? all : all.filter((v) => v.status !== "done");
  const llm = { today: ctx.store.llmCounts(ctx.now()).day, perDay: ctx.cfg.llm.perDay };
  if (flags.json) { raw(JSON.stringify({ now: iso(ctx.now()), counts, llm, threads: shown })); return 0; }
  say(`STATUS ${STATUSES.map((k) => `${k}=${counts[k]}`).join(" ")} llm_today=${llm.today}/${llm.perDay}`);
  for (const v of shown) say(viewLine(v));
  return 0;
}

async function main() {
  const { pos, flags } = parseArgs(process.argv.slice(2));
  const cmd = pos.shift();
  active.cmd = cmd;
  if (!cmd || cmd === "help" || flags.help) {
    raw("사용: run.mjs start <그래프> <스레드> [--topic 값] [--llm] | resume <스레드> approved|rejected | retry <스레드> | status [<스레드>] [--json] [--all] | sweep | gc [--days N] | selftest");
    return cmd ? 0 : 1;
  }
  const st = selftest();
  if (!st.ok) {
    say(`ERROR - selftest ${st.what}: ${st.msg}`);
    warn(`자가 시험 실패 — ${st.hint}`);
    warn(`실행한 Node: ${process.version} (${process.execPath})`);
    return 1;
  }
  if (cmd === "selftest") { say(`OK selftest sqlite ${st.sqlite} · node ${st.node}`); return 0; }

  const cfg = loadConfig();
  const now = clock();
  const { Store } = await import("./lib/store.mjs");
  const store = new Store(cfg);
  const ctx = { cfg, now, store, expiredNow: [] };
  active.ctx = ctx; active.store = store; active.now = now;
  if (cmd === "status") return cmdStatus(ctx, pos, flags);

  const failures = await sweep(ctx);
  switch (cmd) {
    case "start": return cmdStart(ctx, pos, flags);
    case "resume": return cmdResume(ctx, pos);
    case "retry": return cmdRetry(ctx, pos);
    case "sweep": failures.forEach(say); return failures.length ? 1 : 0; // 만료 줄은 end() 가, 아무것도 없으면 NO_REPLY
    case "gc": {
      const days = flags.days === undefined ? cfg.gcDays : flags.days === true || String(flags.days).trim() === "" ? NaN : Number(flags.days);
      if (!(Number.isFinite(days) && days >= 1)) throw new UsageError(`--days 는 1 이상의 숫자: ${flags.days === true ? "(값 없음)" : JSON.stringify(flags.days)}`);
      const r = store.gc(now(), days);
      say(`OK gc deleted=${r.deleted} orphans=${r.orphans} kept=${r.kept} bytes=${r.bytes} days=${days}`);
      return 0;
    }
    default: throw new UsageError(`모르는 명령: ${cmd}`);
  }
}

// 표준 출력에 동기로 쓴다(끝나기 전에 다 나가게). 파이프가 차면 잠깐 기다렸다 다시.
function writeOut(text) {
  const buf = Buffer.from(text);
  for (let off = 0; off < buf.length;) {
    try { off += fs.writeSync(1, buf, off); } catch (e) {
      if (e.code !== "EAGAIN") throw e;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
    }
  }
}

function end(code) {
  const { store } = active;
  let notices = [];
  // 만료 알림: sweep 은 아직 알리지 않은 만료를 전부 내고, 찍은 뒤에만 '알림'으로 적는다(예약 잡의 알림이 정본).
  // 다른 명령은 자기가 이번에 만료시킨 것만 뒤에 붙이고 표시하지 않는다 — 대화 중 명령이 예약 알림을 가로채지 않게. status 는 읽기만.
  if (store && active.cmd !== "status") {
    try {
      notices = active.cmd === "sweep"
        ? store.unnotifiedExpired()
        : [...new Set(active.ctx?.expiredNow ?? [])].map((id) => store.getThread(id)).filter(Boolean);
    } catch (e) {
      lines.push(`ERROR - internal 만료 알림을 읽지 못함: ${String(e?.message ?? e).split("\n")[0]}`);
      code = 1;
    }
  }
  const out = [...lines, ...notices.map((r) => `EXPIRED ${r.thread_id} ${r.question ?? ""} — 승인 기한 초과로 자동 취소`.replace(/\s+/g, " ").slice(0, 400))];
  if (active.cmd === "sweep" && !out.length) out.push("NO_REPLY");
  let written = false;
  try { writeOut(out.length ? `${out.join("\n")}\n` : ""); written = true; } catch { code = 1; }
  if (store) {
    try {
      if (written && active.cmd === "sweep" && notices.length) store.markNotified(notices.map((r) => r.thread_id));
      if (active.cmd !== "status") store.writePending();
    } catch (e) { warn(`장부 마무리 실패: ${e.message}`); }
    store.close();
    active.store = null;
  }
  process.exitCode = code;
  setTimeout(() => process.exit(code), 3000).unref(); // 남은 핸들이 있어도 3초 안에 끝낸다
}

main().then(end, (e) => {
  const kind = e instanceof UsageError ? "usage" : "internal";
  say(`ERROR ${current} ${kind} ${String(e?.message ?? e).split("\n")[0]}`);
  if (kind === "internal" && process.env.LG_DEBUG) warn(e?.stack ?? String(e));
  end(1);
});
