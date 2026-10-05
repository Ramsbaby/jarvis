#!/usr/bin/env node
// run.mjs — 그래프 실행기. OpenClaw 명령형 예약 잡(lg-tick)과, 대화 중 자비스가 부른다. 고정 Node 로 실행한다(lg.sh).
//
//   run.mjs tick [--verbose]                                 예약 잡의 정본: 관문 → 진행 가능한 스레드를 틱 예산 안에서 노드 단위로 진행
//   run.mjs answer <스레드> approved|rejected                 승인 답만 기록한다(1초). 진행은 다음 틱이 한다 — 대화 쪽 경로
//   run.mjs start <그래프> <스레드> [--topic 값] [--llm] [--queue]   새 스레드(이미 있으면 거부). --queue 면 등록만 하고 다음 틱이 시작
//   run.mjs resume <스레드> approved|rejected                 답을 바로 적용해 진행(시험·디버그용 — 대화 경로는 answer)
//   run.mjs retry <스레드>                                    멈춘 스레드를 마지막 체크포인트부터 바로 잇는다(시험·디버그용)
//   run.mjs status [<스레드>] [--json] [--all]                대기·만료·진행 중 스레드 — 읽기만 한다
//   run.mjs sweep                                             기한 지난 대기·보류를 자동 취소 — EXPIRED 줄, 없으면 NO_REPLY
//   run.mjs gc [--days 14]                                    오래된 스레드 삭제 + VACUUM (metrics·effects 원장은 건드리지 않는다)
//   run.mjs selftest                                          저장 부품 적재·사용자 훅 누수 자가 시험
//
// 노드 단위 진행: 그래프를 한 번 부를 때 한 단계(superstep)만 돌린다(interruptAfter "*"). 단계 앞마다 틱 예산(기본 8분)을 보고,
//   넘었으면 다음 노드 앞에서 멈춰 CONTINUE 로 남긴다. 다음 틱은 체크포인트에서 이어 간다(invoke(null)).
// 표준 출력: tick 은 DONE·WAITING·EXPIRED·GAVE_UP·STUCK 줄만 낸다(낼 것이 없으면 NO_REPLY). 다른 명령은 첫 줄이 결과다.
// 종료 코드: DONE·WAITING·CONTINUE·HOLD·LOCKED·EXPIRED·GAVE_UP 은 0. 진짜 오류(실행기 고장·자가 시험 실패·잘못된 사용)만 1.
//   수동 명령(start·resume·retry)은 0a 규약대로 노드 실패도 1 이다(사람이 보고 있다).
//   OpenClaw 는 0 이 아니면 error 로 적고 2회 연속이면 경보, 10회면 잡을 끈다 — 그래서 정상 상태는 전부 0 이다.
// 정본은 그래프 체크포인트다. 등록부(lg_threads)는 그래프 상태로 맞춘다(reconcile).
import "./lib/env-guard.mjs"; // 반드시 첫 import — 추적 변수 삭제·umask 077
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath, pathToFileURL } from "node:url";
import { selftest, hookLeak } from "./lib/selftest.mjs";
import { loadConfig, clock, iso } from "./lib/config.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const THREAD_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/;
const GRAPH_RE = /^[a-z][a-z0-9-]{0,40}$/;
// 값을 받는 플래그. 여기 없으면 `--games 40` 이 games=true 와 떠도는 "40" 으로 갈라져 그래프가 기본값으로 돈다
// (10-04 실측: 매일 40판 QA 잡이 1판만 돌았다 — 시험은 `--games=4` 꼴만 써서 못 잡았다). 그래프 input() 이 읽는 키를 더하면 여기도 더한다.
const VALUE_FLAGS = new Set(["days", "topic", "games", "per", "seed", "diffs", "rev", "tag", "eyeEvery", "day", "signal", "sigkey", "apk", "version", "restart_ms"]);
const STATUSES = ["queued", "running", "continue", "waiting", "held", "failed", "stalled", "gave_up", "expired", "blocked", "done"];
const NOTIFY = /^(DONE|WAITING|EXPIRED|GAVE_UP|STUCK) /;

class UsageError extends Error {}
class GraphRuleError extends Error { constructor(m) { super(m); this.codeDefect = true; } }

const lines = [];
const say = (s) => lines.push(String(s).replace(/\s+/g, " ").trim().slice(0, 400)); // 한 줄 요약(알림용)
const raw = (s) => lines.push(String(s)); // JSON 은 자르지 않는다
const warn = (s) => process.stderr.write(`${s}\n`);

// 종료 처리: 노드 실행 중에 프로세스가 끝나면(고장·신호) 장부에 남기고, 잠금을 풀고, 돌던 claude 자식도 끈다(분리 실행은 산다).
const active = { cmd: null, ctx: null, store: null, now: null, thread: null, token: null, running: false, node: null, signal: null, killChildren: null, metric: null };
process.on("exit", (code) => {
  active.killChildren?.();
  const { store, thread } = active;
  if (!store || !thread) return;
  try {
    if (active.running) {
      process.exitCode = 1; // 노드가 process.exit(0) 을 불러도 경보가 나게
      const why = active.signal ? `신호 ${active.signal}` : `코드 ${code}`;
      const row = store.getThread(thread);
      const sig = `interrupted:${active.node ?? "?"}`;
      const count = row?.fail_sig === sig ? (row.fail_count ?? 0) + 1 : 1;
      store.updateThread(thread, { status: "failed", note: `노드 실행 중 프로세스가 끝남(${why})`, fail_sig: sig, fail_count: count }, active.now());
      active.metric?.("interrupted", { thread, node: active.node, cause: active.signal ? "signal" : "exit", detail: why });
      fs.writeSync(1, `ERROR ${thread} crashed 노드 실행 중 프로세스가 끝남(${why}) — 다음 틱(또는 retry)이 잇는다\n`);
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

// ── 그래프 열기 ───────────────────────────────────────────────────
let REGISTRY = null;
async function registry(ctx) {
  if (!REGISTRY) { const { loadRegistry } = await import("./lib/run.mjs"); REGISTRY = loadRegistry(ctx.cfg.cmdRegistryPath); }
  return REGISTRY;
}

// 코드 지문 — code_defect 보류는 이 값이 바뀌어야(코드를 고쳐야) 다시 시도한다.
const hashCache = new Map();
function codeHash(graph) {
  if (hashCache.has(graph)) return hashCache.get(graph);
  const h = createHash("sha1");
  const files = [path.join(HERE, "run.mjs"), path.join(HERE, "cmd-registry.json"), path.join(HERE, "graphs", `${graph}.mjs`)];
  for (const d of ["lib", "graphs"]) for (const f of fs.readdirSync(path.join(HERE, d)).sort()) if (/\.(mjs|json)$/.test(f)) files.push(path.join(HERE, d, f));
  for (const f of [...new Set(files)]) { h.update(f); try { h.update(fs.readFileSync(f)); } catch { h.update("(없음)"); } }
  const v = h.digest("hex").slice(0, 16);
  hashCache.set(graph, v);
  return v;
}

// 그래프를 연다. check=false 는 읽기(만료 확인)용 — 규칙 위반 그래프라도 기한 처리는 해야 한다.
async function openGraph(ctx, name, thread, { check = true, mode = "shadow" } = {}) {
  if (!GRAPH_RE.test(name ?? "")) throw new UsageError(`그래프 이름이 이상하다: ${name ?? "(없음)"}`);
  const file = path.join(HERE, "graphs", `${name}.mjs`);
  if (!fs.existsSync(file)) throw new UsageError(`그래프 없음: ${name}`);
  const reg = await registry(ctx);
  if (check) {
    const { checkFile } = await import("./scripts/check-interrupt-nodes.mjs");
    const { checkGraphFile } = await import("./scripts/check-graph-rules.mjs");
    const problems = [...checkFile(file, `graphs/${name}.mjs`).problems, ...checkGraphFile(file, reg, `graphs/${name}.mjs`)];
    if (problems.length) {
      const p = problems[0];
      throw new GraphRuleError(`그래프 규칙 위반 ${problems.length}건(${p.file}:${p.line} ${p.rule}) — scripts/check-interrupt-nodes.mjs·check-graph-rules.mjs 로 확인`);
    }
  }
  // 그래프 모듈 최상위·build() 의 console 출력도 스레드 로그로 — 틱 표준 출력(알림)에 새지 않게
  const restoreOut = captureOutput(ctx, thread);
  let mod;
  try { mod = await import(pathToFileURL(file).href); } finally { restoreOut(); }
  const { Command } = await import("@langchain/langgraph");
  const { SqliteSaver } = await import("@langchain/langgraph-checkpoint-sqlite");
  const { createClaude, killActiveChildren } = await import("./lib/claude.mjs");
  const { createRun, resolveCommand, CmdNotAllowed, killRunChildren } = await import("./lib/run.mjs");
  const { createEffect, effectScope } = await import("./lib/effects.mjs");
  const detach = await import("./lib/detach.mjs");
  const { liveMode } = await import("./lib/gates.mjs");
  active.killChildren = () => { killActiveChildren(); killRunChildren(); };
  const { cfg, now, metric } = ctx;
  const timeLeft = ctx.isTick ? () => cfg.jobLimitMs - elapsedMs() : null; // 틱만 — 잡 시간 상한(600초) 안에서
  // 그래프가 스레드당 LLM 상한을 더 크게 둘 수 있다(meta.llmPerThread, 12 이하 — gostop-fix 1b 예산 11/상한 12, 설계 §5.2).
  // 보류 표식(hold_ref)은 환경 손잡이(LG_LLM_MAX_PER_THREAD) 값 그대로 — 그 값을 올려야 풀리는 것은 같다.
  const perThread = Math.max(cfg.llm.perThread, Math.min(12, Math.floor(Number(mod.meta?.llmPerThread)) || 0));
  const llmCfg = perThread === cfg.llm.perThread ? cfg : { ...cfg, llm: { ...cfg.llm, perThread, perThreadRef: cfg.llm.perThread } };
  const llm = createClaude({ store: ctx.store, cfg: llmCfg, now, thread, metric, timeLeft });
  const heartbeatSec = cfg.testMode && process.env.LG_TEST_HEARTBEAT_SEC ? Number(process.env.LG_TEST_HEARTBEAT_SEC) : 30;
  const scratch = path.join(cfg.jobsDir, thread, "_scratch");
  const BENCH = new Set(["bench", "reproduced", "diag_match", "hidden_pass", "ai_misjudge", "signal"]);
  const DUTY_FIELDS = new Set(["phase", "verdict", "restart", "source", "trigger", "outcome", "pid_before", "pid_after", "gw_start", "new_pid", "up", "health",
    "tool_fail", "tool_fail_methods", "tool_ok", "gwlog_fail", "delay_s", "reasons", "unknown", "agreement", "kind", "duty", "duty_ts", "duty_first_seen",
    "duty_mode", "survival"]);
  const tools = {
    mode,
    run: createRun({ cfg, registry: reg, thread, mode, timeLeft }),
    // 분리 실행 띄우기. 같은 (노드, 시도)는 한 번만 띄운다. 부수효과 명령은 분리 실행하지 않는다(띄운 순간 '성공'으로 적히면 안 된다).
    // 최대 시간은 목록의 maxSeconds, 없으면 LG_DETACH_MAX_SEC — 넘기면 check 가 묶음째 끄고 dead(timeout)(설계 §6).
    launch(cmdId, params = {}, { node, attempt = 1 } = {}) {
      const r = resolveCommand(reg, cmdId, params, { mode, inEffect: !!effectScope.getStore(), scratch });
      if (r.cmd.effect) throw new CmdNotAllowed(`${cmdId} 는 부수효과 명령 — 분리 실행하지 않는다(effect 안에서 run 으로)`);
      if (r.cwd === scratch) fs.mkdirSync(scratch, { recursive: true, mode: 0o700 });
      const nodeName = String(node ?? active.node ?? "node").replace(/[^A-Za-z0-9._:-]/g, "_").slice(0, 60);
      return detach.launch(cfg.jobsDir, { thread, node: nodeName, attempt, cmdId },
        { bin: r.bin, argv: r.argv, cwd: r.cwd, env: r.env, timeoutMs: r.timeoutMs, maxMs: r.maxMs ?? cfg.detachMaxSec * 1000, heartbeatSec });
    },
    check: (handle) => detach.check(handle),
    output: (handle, which = "stdout") => detach.readOutput(handle, which),
    effect: createEffect({ cfg, now, thread, mode, metric, nodeRef: () => active.node }),
    // 노드가 '아직 아니다(분리 실행 진행 중)'를 알릴 때: throw tools.pending() → CONTINUE, 재시도로 세지 않는다
    pending: (msg = "분리 실행 진행 중") => Object.assign(new Error(msg), { pending: true }),
    // 노드가 스스로 보류할 때(디스크·대화 작업 표식 등): throw tools.hold("이유")
    hold: (msg, reason = "node") => Object.assign(new Error(msg), { held: true, holdReason: reason }),
    // 판정 M8 칸(벤치 결과). 정해진 필드만 남긴다.
    bench: (fields = {}) => metric("bench", { thread, ...Object.fromEntries(Object.entries(fields).filter(([k]) => BENCH.has(k))) }),
    // 판정 §8 '격리 위반 시도'(1b): 격리 실행이 위반으로 끝남(종료 98)·검증 중 사본이 바뀜 등. 종류 낱말과 짧은 설명만 남긴다.
    sandboxViolation: (kind, detail = "") => metric("sandbox_violation", { thread, kind: String(kind).replace(/[^a-z0-9_]/g, "").slice(0, 40), detail: String(detail).replace(/\s+/g, " ").slice(0, 160) }),
    // 당직 D0 판정 기록(lg.duty.verify, PLAN §13.3). 정해진 필드만 — 원문(대화·장부 문장)은 남기지 않는다(S4)
    dutyVerify: (fields = {}) => metric("lg.duty.verify", { thread, ...Object.fromEntries(Object.entries(fields).filter(([k]) => DUTY_FIELDS.has(k))) }),
    // 다른 그래프의 스레드를 대기열에 올린다(접수 → 수정, S13). 다음 틱이 시작한다. 이미 있는 스레드면 다시 올리지 않는다(멱등).
    // 모드는 이 스레드 모드와 지금 LIVE 스위치 중 낮은 쪽 — 그림자 접수가 실제 수정을 낳지 않게.
    enqueue(graphName, threadName, input = {}) {
      const bad = (m) => Object.assign(new Error(`enqueue: ${m}`), { codeDefect: true });
      if (!GRAPH_RE.test(String(graphName ?? "")) || !fs.existsSync(path.join(HERE, "graphs", `${graphName}.mjs`))) throw bad(`그래프 없음 ${graphName}`);
      if (!THREAD_RE.test(String(threadName ?? ""))) throw bad(`스레드 이름 형식 ${threadName}`);
      const body = JSON.stringify(input ?? {});
      if (body.length > 65_536) throw bad("입력이 64KB 를 넘는다");
      return ctx.store.tx(() => {
        const row = ctx.store.getThread(threadName);
        if (row || ctx.store.hasCheckpoint(threadName)) return { ok: false, kind: "exists", status: row?.status ?? "checkpoint" };
        const childMode = mode === "live" && liveMode(cfg) === "live" ? "live" : "shadow";
        ctx.store.registerThread(threadName, graphName, now(), { mode: childMode, status: "queued", input: JSON.parse(body) });
        metric("start", { thread: threadName, graph: graphName, mode: childMode, queued: true, by: thread });
        return { ok: true, kind: "queued", mode: childMode };
      });
    },
    // 읽기 전용 값: 상태 폴더(사본·원문 파일 자리)와 실행기 시계(시험은 LG_NOW 로 주입)
    stateDir: cfg.stateDir,
    now: () => now(),
  };
  const restoreBuild = captureOutput(ctx, thread);
  let app;
  try { app = mod.build({ checkpointer: new SqliteSaver(ctx.store.db), llm, tools }); } finally { restoreBuild(); }
  // 컴파일에 박힌 정적 중단점은 노드 단위 진행이 지나쳐 버린다 — 이런 그래프는 돌리지 않는다(승인 없이 통과 방지).
  const blocked = !!(app.interruptBefore?.length || app.interruptAfter?.length);
  return { mod, app, Command, name, blocked, run: { configurable: { thread_id: thread }, durability: "sync" } };
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
  if (!token) {
    const li = ctx.store.lockInfo(thread);
    say(`ERROR ${thread} busy 다른 프로세스가 이 스레드를 처리 중${li?.stuck ? `(STUCK: pid ${li.pid}, ${Math.round(li.ageMs / 60_000)}분째 — 넘겨받지 않는다)` : ""}`);
    return 1;
  }
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
// 기한 안에 answer 로 답이 적힌 질문은 기한이 지나도 만료시키지 않는다(틱이 늦게 와도 답은 유효).
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
    // 새 질문(또는 답을 받은 뒤 같은 문구로 다시 묻는 질문)이면 번호를 올린다 — 답은 이 번호에 묶인다
    const newQuestion = answered || row?.interrupt_id !== key;
    ctx.store.updateThread(thread, { interrupt_id: key, waiting_since: since, deadline_at: deadline, question: q,
      ...(newQuestion ? { question_seq: (row?.question_seq ?? 0) + 1 } : {}) }, t, { touch: false });
  } else if (!(row?.question_seq > 0)) {
    // 질문 번호가 생기기 전 판이 남긴 대기 — 첫 질문(#1)으로 맞춘다(pending.jsonl 이 qid 1 로 알린다, 0b 재검토 C중2)
    ctx.store.updateThread(thread, { question_seq: 1 }, t, { touch: false });
  }
  const cur = ctx.store.getThread(thread);
  const answeredInTime = cur?.answer != null && cur.answer_key === key && cur.answered_at != null && cur.answered_at < deadline;
  if (deadline <= t && !answeredInTime) {
    ctx.store.updateThread(thread, { status: "expired", note: "승인 기한 초과 — 자동 취소", notified: 0 }, t);
    ctx.expiredNow.push(thread);
    ctx.metric("expired", { thread, graph: row?.graph, kind: "approval" });
    return { kind: "expired", s, q, deadline, key };
  }
  return { kind: "waiting", s, q, deadline, key, intr };
}

const waitingLine = (thread, q, seq, deadline) =>
  `WAITING ${thread} ${q ?? "승인 대기"} · 질문 #${seq} · 답: lg.sh answer ${thread} approved|rejected ${seq} · 기한 ${deadline ? iso(deadline) : "?"}`;

// 알림 줄(DONE·WAITING·GAVE_UP·STUCK). 틱은 상태 변경과 같은 트랜잭션으로 알림함에 넣고 끝에서 낸다 — 틱이 도중에 죽어도
// (게이트웨이 재시작·잡 시간 초과) 다음 틱이 낸다. 수동 명령은 바로 낸다(부른 쪽이 보고 있다).
function announce(ctx, thread, line, change) {
  if (ctx.isTick) {
    ctx.store.tx(() => { change?.(); ctx.store.addNotice(thread, line.split(" ")[0], line.replace(/\s+/g, " ").trim().slice(0, 400), ctx.now()); });
  } else {
    change?.();
    say(line);
  }
}

const multiLine = (thread, intrs) =>
  `ERROR ${thread} multi-interrupt 승인 대기 ${intrs.length}개가 동시에 생겼다 — 답 하나가 모두를 승인할 수 있어 받지 않는다: ${intrs.map(questionOf).join(" / ")}`;

// 그래프를 돌린 뒤 결과를 장부에 맞추고 결과 줄을 낸다. fresh = 방금 이 프로세스가 그래프를 돌렸다.
async function settle(ctx, g, thread, { fresh = false, answered = false } = {}) {
  const r = await reconcile(ctx, g, thread, { fresh, answered });
  const t = ctx.now();
  const row = ctx.store.getThread(thread);
  if (r.kind === "multi") {
    ctx.store.updateThread(thread, { status: "failed", note: `승인 대기 ${r.intrs.length}개 동시 — 지원하지 않는다`, hold_reason: "code_defect", hold_ref: codeHash(g.name) }, t);
    ctx.metric("held", { thread, graph: g.name, scope: "thread", reasons: ["code_defect"], detail: "multi-interrupt" });
    say(multiLine(thread, r.intrs));
    return 1;
  }
  if (r.kind === "expired") { say(`ERROR ${thread} expired 승인 기한(${iso(r.deadline)})이 지나 자동 취소했다 — 새로 start`); return 1; }
  if (r.kind === "waiting") {
    ctx.store.updateThread(thread, { status: "waiting", question: r.q }, t);
    const first = row?.waiting_notified !== r.key;
    if (first) {
      ctx.metric("waiting", { thread, graph: g.name, reason: typeof r.intr?.value?.reason === "string" ? r.intr.value.reason : null });
    }
    const mark = () => ctx.store.updateThread(thread, { waiting_notified: r.key }, t, { touch: false });
    const seq = ctx.store.getThread(thread)?.question_seq ?? 1;
    if (!ctx.isTick) {
      say(`WAITING ${thread} ${r.q}`);
      say(`답: lg.sh answer ${thread} approved|rejected ${seq} · 질문 #${seq} · 기한 ${iso(r.deadline)}`);
      mark();
    } else if (first) {
      announce(ctx, thread, waitingLine(thread, r.q, seq, r.deadline), mark);
    }
    return 0;
  }
  if (!r.s.next?.length) {
    const summary = String(g.mod.summarize ? g.mod.summarize(r.s.values ?? {}) : "");
    const finish = () => ctx.store.updateThread(thread, { status: "done", note: summary.slice(0, 300), hold_reason: null, fail_sig: null, fail_count: 0 }, t);
    // meta.quietDone: 틱에서 끝나도 주인님께 알리지 않는다(결과는 기록에만 — 당직 D0 그림자). 수동 명령은 그대로 DONE 을 낸다.
    if (ctx.isTick && g.mod.meta?.quietDone === true) { finish(); say(`OK ${thread} done(알림 없음) ${summary}`); }
    else announce(ctx, thread, `DONE ${thread} ${summary}`, finish);
    const v = r.s.values ?? {};
    ctx.metric("done", { thread, graph: g.name, mode: row?.mode ?? "shadow", verified: typeof v.verify_log === "string" ? v.verify_log : null });
    return 0;
  }
  // interrupt 없이 다음 노드가 남았다 = 노드 단위 진행 도중이다. 여기 오면 안 된다(advance 가 다음 단계를 돈다).
  ctx.store.updateThread(thread, { status: "continue", note: `다음 노드(${r.s.next.join(",")}) 앞에서 멈춤` }, t);
  say(`CONTINUE ${thread} 다음 노드(${r.s.next.join(",")}) 앞에서 멈춤`);
  return 0;
}

// 노드가 찍는 표준 출력·오류는 스레드 로그(600)로 돌린다 — '첫 줄이 결과' 규약과 stderr 없는 알림을 지키려고.
function captureOutput(ctx, thread) {
  let fd = null, restored = false;
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
    if (restored) return;
    restored = true;
    [process.stdout.write, process.stderr.write] = saved;
    if (fd !== null) { try { fs.closeSync(fd); } catch { /* 이미 닫힘 */ } fd = null; }
  };
}

// ── 오류 분류 ─────────────────────────────────────────────────────
// pending: 분리 실행 진행 중 → CONTINUE · held: 상한·로그인·한도·노드 보류 → HOLD · code_defect: 코드 결함 → HOLD(코드가 바뀔 때까지)
// transient: 그 밖 → 같은 오류 3회까지 다음 틱에 재시도, 그다음에도 같으면 GAVE_UP
const CODE_DEFECT_NAMES = new Set(["TypeError", "ReferenceError", "SyntaxError", "RangeError", "EvalError", "URIError",
  "InvalidUpdateError", "EmptyChannelError", "GraphValueError", "InvalidUpdateError", "UnreachableNodeError", "MultipleSubgraphsError"]);
function classifyError(e) {
  const pick = (k) => e?.[k] ?? e?.cause?.[k];
  if (pick("pending") === true) return { kind: "pending" };
  if (pick("held") === true) return { kind: "held", reason: pick("holdReason") ?? "node", ref: pick("holdRef") ?? null };
  if (pick("codeDefect") === true || CODE_DEFECT_NAMES.has(e?.name) || e?.code === "ERR_MODULE_NOT_FOUND") return { kind: "code_defect" };
  return { kind: "transient" };
}
const firstLine = (e) => String(e?.message ?? e).split("\n")[0].slice(0, 200);
const shape = (msg) => msg.replace(/\d+/g, "#").replace(/\s+/g, " ").slice(0, 120);
// metrics 에는 오류의 머리말만 — 콜론 뒤(모델 출력·경로 조각이 붙는 자리)는 30일 보존 기록에 남기지 않는다(S4)
const errHead = (msg) => shape(String(msg ?? "").split(/[:—]/)[0]).slice(0, 80);

function giveUp(ctx, thread, graph, node, count, note) {
  announce(ctx, thread, `GAVE_UP ${thread} ${node} 같은 오류 ${count}회 — ${note}`,
    () => ctx.store.updateThread(thread, { status: "gave_up", note: `같은 오류 ${count}회 — ${note}` }, ctx.now()));
  ctx.metric("gave_up", { thread, graph, node, count, error: errHead(note) });
  return 0;
}

// 멈출 때 기록한 다음 노드가 그래프에서 사라졌다(배포로 이름이 바뀜 등) — '끝남'으로 보고하지 않고 코드 결함으로 보류한다(0b 검토 A중5)
function holdVanished(ctx, row) {
  const note = `다음 노드(${row.next_nodes})가 그래프에 없다 — 배포로 노드가 바뀌었나. 끝남으로 보지 않는다`;
  ctx.store.updateThread(row.thread_id, { status: "held", note, hold_reason: "code_defect", hold_ref: codeHash(row.graph) }, ctx.now(), { touch: row.note !== note });
  ctx.metric("held", { thread: row.thread_id, graph: row.graph, scope: "thread", reasons: ["code_defect"], error: "vanished-node" });
  say(`HELD ${row.thread_id} ${note}`);
  return "held";
}

const PAUSE_NOTE = {
  budget: (next) => `틱 예산 소진 — 다음 노드(${next}) 앞에서 멈춤, 다음 틱이 잇는다`,
  pending: (next) => `분리 실행 진행 중(${next}) — 다음 틱이 확인한다`,
  paused: (next) => `PAUSED — 다음 노드(${next}) 앞에서 멈춤, 풀리면 다음 틱이 잇는다`,
};
function pauseThread(ctx, thread, reason, next) {
  const note = PAUSE_NOTE[reason](next.join(","));
  const row = ctx.store.getThread(thread);
  ctx.store.updateThread(thread, { status: "continue", note }, ctx.now(), { touch: row?.note !== note });
  ctx.metric("continue", { thread, graph: row?.graph, reason, next: next.join(",") });
  say(`CONTINUE ${thread} ${note}`);
  return 0;
}

// prev: 돌리기 전 등록부 행 — 같은 이유로 되풀이하는 보류·실패는 정리 기준 시각(updated_at)을 늘리지 않는다.
// cur: 지금 행 — 실패 서명·횟수는 이것으로 센다(이번 실행에서 한 단계라도 끝냈으면 서명이 비워져 있다).
function onStepError(ctx, g, thread, e, names, prev, cur = prev) {
  const cls = classifyError(e);
  const note = firstLine(e);
  const t = ctx.now();
  const node = names.join(",");
  if (cls.kind === "pending") return pauseThread(ctx, thread, "pending", names);
  if (cls.kind === "held") {
    const same = prev?.status === "held" && prev?.note === note;
    ctx.store.updateThread(thread, { status: "held", note, hold_reason: cls.reason, hold_ref: cls.ref ?? null }, t, { touch: !same });
    ctx.metric("held", { thread, graph: g.name, scope: "thread", reasons: [cls.reason], node });
    say(`HELD ${thread} ${note}`);
    return 0;
  }
  if (cls.kind === "code_defect") {
    // 재시도해도 같다 — 코드(그래프·실행기·허용 목록)가 바뀔 때까지 틱은 다시 돌리지 않는다. 기한(48시간)이 지나면 만료로 보고한다.
    const status = ctx.isTick ? "held" : "failed";
    const same = prev?.status === status && prev?.note === note;
    ctx.store.updateThread(thread, { status, note, hold_reason: "code_defect", hold_ref: codeHash(g.name) }, t, { touch: !same });
    ctx.metric("held", { thread, graph: g.name, scope: "thread", reasons: ["code_defect"], node, error: errHead(note) });
    if (ctx.isTick) { say(`HELD ${thread} 코드 결함 — ${note}`); return 0; }
    say(`ERROR ${thread} failed ${note} — 원인을 고친 뒤 retry`);
    return 1;
  }
  const sig = `${node}:${shape(note)}`;
  const count = cur?.fail_sig === sig ? (cur.fail_count ?? 0) + 1 : 1;
  if (count > ctx.cfg.maxRetries) {
    ctx.store.updateThread(thread, { fail_sig: sig, fail_count: count }, t, { touch: false });
    return giveUp(ctx, thread, g.name, node, count, note);
  }
  const same = prev?.status === "failed" && prev?.note === note;
  ctx.store.updateThread(thread, { status: "failed", note, fail_sig: sig, fail_count: count, hold_reason: null }, t, { touch: !same });
  ctx.metric("failed", { thread, graph: g.name, node, count, error: errHead(note) });
  say(`ERROR ${thread} failed ${note} — ${ctx.isTick ? `다음 틱이 다시 한다(${count}/${ctx.cfg.maxRetries})` : "원인을 고친 뒤 retry"}`);
  return ctx.isTick ? 0 : 1;
}

const elapsedMs = () => process.uptime() * 1000; // 틱 예산은 실제 경과 시간(잡의 시간 상한은 프로세스 시작부터 잰다)
const overBudget = (ctx) => elapsedMs() >= ctx.cfg.tickBudgetMs;

// 한 단계(superstep)만 돈다. 그래프 안 interrupt 와 실행기의 단계 멈춤(interruptAfter "*") 모두 여기서 멈춘다.
async function stepOnce(g, arg) {
  const nodes = [];
  const stream = await g.app.stream(arg, { ...g.run, streamMode: "updates", interruptAfter: "*" });
  for await (const ch of stream) for (const k of Object.keys(ch ?? {})) if (k !== "__interrupt__") nodes.push(k);
  return nodes;
}

// 노드 단위 진행. first: {kind:"input", value} | {kind:"resume", decision} | {kind:"null"}.
// 단계 앞마다 예산을 본다. 한 단계도 못 돌렸으면 아무것도 바꾸지 않고 skipped 를 돌려준다.
async function advance(ctx, g, thread, first, prev) {
  const restore = captureOutput(ctx, thread);
  let arg = first.kind === "input" ? first.value : first.kind === "resume" ? new g.Command({ resume: first.decision }) : null;
  let steps = 0;
  try {
    for (;;) {
      const pre = await g.app.getState(g.run);
      const names = pre.next?.length ? [...pre.next] : ["(start)"];
      // 한 단계는 꼭 돈다(틱은 예산이 남았을 때만 스레드를 고른다). 그다음부터 단계 앞마다 예산·멈춤 스위치를 본다.
      if (steps > 0 && overBudget(ctx)) { restore(); return pauseThread(ctx, thread, "budget", names); }
      if (steps > 0 && fs.existsSync(ctx.cfg.pausedPath)) { restore(); return pauseThread(ctx, thread, "paused", names); }
      if ((pre.metadata?.step ?? 0) >= ctx.cfg.maxSteps) {
        restore();
        return giveUp(ctx, thread, g.name, names.join(","), pre.metadata.step, `단계 상한 ${ctx.cfg.maxSteps}에 닿음(끝없는 되풀이?)`);
      }
      const node = names.join(",");
      ctx.metric("node_start", { thread, graph: g.name, node });
      active.running = true; active.node = node;
      const t0 = performance.now();
      let ran;
      try {
        ran = await stepOnce(g, arg);
      } catch (e) {
        active.running = false;
        // 새 스레드의 첫 단계는 돌기 전엔 다음 노드를 모른다 — 실패 뒤 상태(입력은 저장됨)에서 실제 노드 이름을 읽는다(실패 서명이 틱마다 같게)
        let failed = names;
        if (names[0] === "(start)") { try { const after = await g.app.getState(g.run); if (after.next?.length) failed = [...after.next]; } catch { /* 이름만 못 얻음 */ } }
        ctx.metric("node_end", { thread, graph: g.name, node: failed.join(","), ok: false, ms: Math.round(performance.now() - t0) });
        restore();
        return onStepError(ctx, g, thread, e, failed, prev, ctx.store.getThread(thread) ?? prev);
      }
      active.running = false;
      ctx.metric("node_end", { thread, graph: g.name, node: ran.length ? ran.join(",") : node, ok: true, ms: Math.round(performance.now() - t0) });
      const t = ctx.now();
      const s = await g.app.getState(g.run);
      const progress = { progress_at: t, fail_sig: null, fail_count: 0, hold_reason: null, hold_ref: null, next_nodes: (s.next ?? []).join(",") };
      // 답을 적용한 단계가 끝났다 — 그 대기 기록과 답을 비운다(다음 질문은 새 번호·새 기한·새 답, 같은 문구여도 다시 알린다)
      if (first.kind === "resume" && steps === 0) Object.assign(progress, { interrupt_id: null, waiting_since: null, deadline_at: null, answer: null, answer_key: null, answered_at: null, waiting_notified: null });
      ctx.store.updateThread(thread, progress, t);
      arg = null; steps++;
      if (pendingInterrupts(s).length || !s.next?.length) { restore(); return settle(ctx, g, thread, { fresh: true }); }
    }
  } finally { restore(); active.running = false; active.node = null; }
}

const codeOf = (r) => (typeof r === "number" ? r : r?.code ?? 0);

// ── 수동 명령 ─────────────────────────────────────────────────────
function pausedLine(ctx, thread) {
  if (!fs.existsSync(ctx.cfg.pausedPath)) return false;
  ctx.metric("held", { thread, scope: "command", reasons: ["paused"], cmd: active.cmd });
  say(`HELD ${thread ?? "-"} PAUSED 스위치가 켜져 있다 — 진행하지 않는다(답 기록·상태 보기는 된다)`);
  return true;
}

async function cmdStart(ctx, [graph, thread, ...extra], flags) {
  checkThread(thread);
  // 남는 위치 인자 = 값 플래그로 등록 안 된 `--키 값` 의 값 — 조용히 버리면 기본값으로 돈다
  if (extra.length) throw new UsageError(`알 수 없는 인자 ${extra.join(" ")} — 값 플래그는 --키=값 으로 쓰거나 run.mjs VALUE_FLAGS 에 더한다`);
  if (pausedLine(ctx, thread)) return 0;
  const { liveMode } = await import("./lib/gates.mjs");
  const mode = liveMode(ctx.cfg);
  const g = await openGraph(ctx, graph, thread, { mode });
  const input = g.mod.input ? g.mod.input(flags) : {};
  return withLock(ctx, thread, async () => {
    const row = ctx.store.getThread(thread);
    if (ctx.store.hasCheckpoint(thread) || row?.status === "queued") {
      say(`ERROR ${thread} exists 이미 있는 스레드(${row ? ctx.store.effective(row) : "등록 없음"}) — status 로 보고 새 이름으로 start`);
      return 1;
    }
    if (flags.queue) {
      ctx.store.registerThread(thread, graph, ctx.now(), { mode, status: "queued", input });
      ctx.metric("start", { thread, graph, mode, queued: true });
      say(`OK ${thread} queued ${mode} — 다음 틱이 시작한다`);
      return 0;
    }
    ctx.store.registerThread(thread, graph, ctx.now(), { mode, input });
    ctx.metric("start", { thread, graph, mode });
    if (g.blocked) {
      ctx.store.updateThread(thread, { status: "blocked", note: "컴파일에 정적 중단점(interruptBefore/After)이 있다" }, ctx.now());
      say(`ERROR ${thread} blocked 정적 중단점(interruptBefore/After)이 박힌 그래프는 승인 없이 지나갈 수 있어 돌리지 않는다 — interrupt() 노드로 고친 뒤 새로 start`);
      return 1;
    }
    return codeOf(await advance(ctx, g, thread, { kind: "input", value: input }, null));
  });
}

async function cmdResume(ctx, [thread, decision]) {
  checkThread(thread);
  if (!["approved", "rejected"].includes(decision)) throw new UsageError("resume <스레드> approved|rejected");
  if (pausedLine(ctx, thread)) return 0;
  const row0 = ctx.store.getThread(thread);
  if (!row0) { say(`ERROR ${thread} not-found 없는 스레드`); return 1; }
  const g = await openGraph(ctx, row0.graph, thread, { mode: row0.mode ?? "shadow" });
  return withLock(ctx, thread, async () => {
    const row = ctx.store.getThread(thread); // 잠근 뒤 다시 읽는다 — 그 사이 다른 프로세스가 끝냈을 수 있다
    if (row.status === "expired") { say(`ERROR ${thread} expired 승인 기한이 지나 자동 취소된 스레드 — 새로 start`); return 1; }
    const r = await reconcile(ctx, g, thread);
    if (r.kind === "expired") { say(`ERROR ${thread} expired 승인 기한(${iso(r.deadline)})이 지나 자동 취소했다 — 새로 start`); return 1; }
    if (r.kind === "multi") { say(multiLine(thread, r.intrs)); return 1; }
    if (r.kind === "none") { say(`ERROR ${thread} not-waiting 승인 대기 중이 아님(${ctx.store.effective(row)})`); return 1; }
    // 답을 적용한다. 대기 기록은 그 단계가 성공한 뒤 advance 가 놓는다(실패하면 기한이 남아 sweep 이 만료시킨다).
    ctx.store.updateThread(thread, { status: "running", decision, run_started_at: ctx.now() }, ctx.now());
    ctx.metric("resumed", { thread, graph: row.graph, from: "answer", via: "resume" });
    return codeOf(await advance(ctx, g, thread, { kind: "resume", decision }, row));
  });
}

async function cmdRetry(ctx, [thread]) {
  checkThread(thread);
  if (pausedLine(ctx, thread)) return 0;
  const row0 = ctx.store.getThread(thread);
  if (!row0) { say(`ERROR ${thread} not-found 없는 스레드`); return 1; }
  const g = await openGraph(ctx, row0.graph, thread, { mode: row0.mode ?? "shadow" });
  return withLock(ctx, thread, async () => {
    const row = ctx.store.getThread(thread);
    if (row.status === "expired") { say(`ERROR ${thread} expired 자동 취소된 스레드는 잇지 않는다 — 새로 start`); return 1; }
    if (row.status === "blocked") { say(`ERROR ${thread} blocked interrupt 없이 멈춘 스레드는 승인 없이 지나갈 수 있어 잇지 않는다 — 그래프를 고친 뒤 새로 start`); return 1; }
    if (row.status === "gave_up") { say(`ERROR ${thread} gave_up 같은 오류로 포기한 스레드 — 원인을 고친 뒤 새로 start`); return 1; }
    if (!ctx.store.hasCheckpoint(thread)) { say(`ERROR ${thread} no-checkpoint 저장된 단계가 없다 — 같은 이름으로 다시 start`); return 1; }
    const r = await reconcile(ctx, g, thread);
    if (r.kind === "none" && !r.s.next?.length && row.next_nodes) { holdVanished(ctx, row); return 1; }
    if (r.kind !== "none" || !r.s.next?.length) return settle(ctx, g, thread); // 대기·만료·끝남은 장부만 맞춘다
    ctx.store.updateThread(thread, { status: "running", run_started_at: ctx.now() }, ctx.now(), { touch: false });
    ctx.metric("resumed", { thread, graph: row.graph, from: row.status, via: "retry" });
    return codeOf(await advance(ctx, g, thread, { kind: "null" }, row));
  });
}

// 답만 적는다 — 그래프를 열지 않고, 잠금도 잡지 않고, 정리(sweep)도 하지 않는다(1초 안에). 진행은 다음 틱이 한다.
function cmdAnswer(ctx, [thread, decision, qidArg]) {
  checkThread(thread);
  if (!["approved", "rejected"].includes(decision)) throw new UsageError("answer <스레드> approved|rejected [질문번호]");
  let qid = null;
  if (qidArg !== undefined) {
    if (!/^#?\d{1,6}$/.test(qidArg)) throw new UsageError(`질문 번호는 WAITING 의 '질문 #N' 숫자: ${qidArg}`);
    qid = Number(qidArg.replace("#", ""));
  }
  const r = ctx.store.recordAnswer(thread, decision, ctx.now(), qid);
  if (!r.ok) { say(`ERROR ${thread} ${r.kind} ${r.msg}`); return 1; }
  if (r.kind === "recorded") ctx.metric("answered", { thread, graph: r.row.graph, decision });
  say(`OK ${thread} answered ${decision} — 다음 틱이 이어 간다${fs.existsSync(ctx.cfg.pausedPath) ? "(지금은 PAUSED — 풀려야 진행)" : ""}`);
  return 0;
}

// ── 정리(만료) ────────────────────────────────────────────────────
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
      try { g = await openGraph(ctx, row.graph, row.thread_id, { check: false, mode: row.mode ?? "shadow" }); } catch (e) {
        // 그래프 파일이 없어졌거나 불러오다 죽는다 — 그래프 상태를 못 읽으니 장부 기한으로 처리한다(영원히 대기로 남지 않게)
        if (row.deadline_at != null && row.deadline_at <= t) {
          ctx.store.updateThread(row.thread_id, { status: "expired", note: `${e.message} — 장부 기한으로 만료`, notified: 0 }, t);
          ctx.expiredNow.push(row.thread_id);
          ctx.metric("expired", { thread: row.thread_id, graph: row.graph, kind: "approval", detail: "graph-missing" });
        } else if (row.status === "running") {
          ctx.store.updateThread(row.thread_id, { status: "failed", note: e.message }, t, { touch: false });
        }
        continue;
      }
      const r = await reconcile(ctx, g, row.thread_id);
      if (r.kind === "waiting" && !["waiting", "failed", "held"].includes(row.status)) {
        ctx.store.updateThread(row.thread_id, { status: "waiting", question: r.q }, t, { touch: false });
      } else if (r.kind === "waiting" && row.status !== "waiting" && row.answer == null) {
        ctx.store.updateThread(row.thread_id, { status: "waiting", question: r.q }, t, { touch: false });
      } else if (r.kind === "none" && row.status === "waiting" && !r.s.next?.length && row.next_nodes) {
        holdVanished(ctx, row); // 대기하던 노드가 그래프에서 사라졌다 — 끝남이 아니다
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

// 진척 없이 48시간(LG_HOLD_TTL_HOURS)을 넘긴 보류·이어가기·대기열·실패 스레드를 만료시킨다(S9). 승인 기한이 걸린 것은 sweep 이 본다.
function expireIdle(ctx) {
  const t = ctx.now();
  // 차례 대기(S13) 판정은 만료를 시작하기 전 모습으로 — 앞 스레드가 이번 틱에 만료돼도 뒤 대기열은 같은 틱에 따라 만료되지 않는다(재검토 B)
  const blockedGraphs = new Set(ctx.store.openThreads().filter((r) => r.status !== "queued").map((r) => r.graph));
  for (const row of ctx.store.idleCandidates(t, ctx.cfg.holdTtlMs)) { // 답 없는 승인 대기는 후보에서 이미 빠졌다(승인 기한이 정한다)
    const token = ctx.store.acquireLock(row.thread_id);
    if (!token) continue;
    try {
      const cur = ctx.store.getThread(row.thread_id);
      if (!cur || !["queued", "continue", "held", "failed", "running", "waiting"].includes(cur.status)) continue;
      if (cur.answer == null && cur.deadline_at != null) continue; // 잠그는 사이 바뀌었다 — 승인 기한으로
      // 차례를 기다리는 대기열(같은 그래프에 시작한 미완 스레드가 있음 — S13)은 놀고 있는 것이 아니다. 앞 스레드가 끝나거나 만료되면 시작한다(H3 중1)
      if (cur.status === "queued" && blockedGraphs.has(cur.graph)) continue;
      const h = Math.round(ctx.cfg.holdTtlMs / 3_600_000);
      ctx.store.updateThread(cur.thread_id, { status: "expired", note: `진척 없이 ${h}시간(${cur.status}${cur.hold_reason ? `:${cur.hold_reason}` : ""}) — 보류 기한 초과로 자동 취소`, notified: 0 }, t);
      ctx.expiredNow.push(cur.thread_id);
      ctx.metric("expired", { thread: cur.thread_id, graph: cur.graph, kind: "hold", status: cur.status, reason: cur.hold_reason ?? null });
    } finally {
      ctx.store.releaseLock(row.thread_id, token);
    }
  }
}

// ── 틱 ────────────────────────────────────────────────────────────
// 살아 있는 주인이 기준 시간보다 오래 쥔 잠금 — 넘겨받지 않고 STUCK 을 한 번만 알린다(같은 잠금은 다시 알리지 않는다).
function noteStuck(ctx, row, li) {
  const key = `${li.pid}:${li.acquiredAt}`;
  if (row.stuck_key === key) return;
  announce(ctx, row.thread_id, `STUCK ${row.thread_id} pid ${li.pid} 가 ${Math.round(li.ageMs / 60_000)}분째 잠금을 쥐고 있다(살아 있음 — 넘겨받지 않고 이 스레드는 보류)`,
    () => ctx.store.updateThread(row.thread_id, { stuck_key: key }, ctx.now(), { touch: false }));
  ctx.metric("stuck", { thread: row.thread_id, graph: row.graph, pid: li.pid, age_min: Math.round(li.ageMs / 60_000) });
  ctx.metric("held", { thread: row.thread_id, graph: row.graph, scope: "thread", reasons: ["stuck"] });
}

// 하루 1회 시작(PLAN §3 '하루 1회 정리·접수'): LG_DAILY 의 그래프마다 '<그래프>:<날짜>' 스레드를 정한 시각 뒤 첫 틱에 대기열에 올린다.
// 관문을 통과한 틱에서만 부른다. 그날 스레드가 이미 있으면(끝났어도) 다시 올리지 않는다. 시작 입력은 { day }.
async function dailyStart(ctx) {
  if (!ctx.cfg.daily.length) return;
  const { liveMode } = await import("./lib/gates.mjs");
  const t = ctx.now();
  const d = new Date(t);
  const mins = d.getHours() * 60 + d.getMinutes();
  const day = ctx.storeMod.localDay(t);
  for (const { graph, after } of ctx.cfg.daily) {
    if (mins < after || !fs.existsSync(path.join(HERE, "graphs", `${graph}.mjs`))) continue;
    const thread = `${graph}:${day}`;
    if (ctx.store.getThread(thread) || ctx.store.hasCheckpoint(thread)) continue;
    const mode = liveMode(ctx.cfg);
    ctx.store.registerThread(thread, graph, t, { mode, status: "queued", input: { day } });
    ctx.metric("start", { thread, graph, mode, queued: true, by: "daily" });
  }
}

// 사본 정리(설계 §2 '사본은 3일 보관', H3 중4): 상태 폴더의 <묶음>/sandbox/<키> 중 3일(LG_SANDBOX_KEEP_DAYS) 넘은 것.
// 관문 앞에서 틱마다 본다 — 디스크 관문에 걸린 날에도 오래된 사본이 비켜 주게. 끝나지 않은 스레드의 사본은 남긴다(그 스레드는 48시간 진척이 없으면 만료된다).
function pruneSandboxes(ctx) {
  const keepMs = ctx.cfg.sandboxKeepDays * 86_400_000;
  const live = new Set(ctx.store.openThreads().map((r) => r.thread_id.replace(/[^A-Za-z0-9._-]/g, "_")));
  let removed = 0;
  let groups = [];
  try { groups = fs.readdirSync(ctx.cfg.stateDir, { withFileTypes: true }).filter((e) => e.isDirectory()); } catch { return; }
  for (const g of groups) {
    const root = path.join(ctx.cfg.stateDir, g.name, "sandbox");
    let ents = [];
    try { ents = fs.readdirSync(root, { withFileTypes: true }); } catch { continue; }
    for (const e of ents) {
      if (!e.isDirectory() || [...live].some((t) => t.endsWith(e.name))) continue;
      const p = path.join(root, e.name);
      // 겹친 틱이 먼저 지웠거나 지우는 중일 수 있다 — 정리 실패가 틱을 죽이지 않게(재검토 B 하5). 다음 틱이 다시 본다
      try {
        const ref = fs.existsSync(path.join(p, ".ready")) ? path.join(p, ".ready") : p;
        if (ctx.now() - fs.statSync(ref).mtimeMs > keepMs) { fs.rmSync(p, { recursive: true, force: true }); removed++; }
      } catch (err) {
        ctx.metric("gc", { ok: false, sandboxes: 0, error: errHead(firstLine(err)) });
      }
    }
  }
  if (removed) ctx.metric("gc", { ok: true, sandboxes: removed });
}

// 원문 파일(runs/<키>/ — 고칠 안·재현 로그·CI 로그)도 gc 기간(14일)이 지나면 지운다(S4 평문 누적, H3 하)
function pruneRuns(ctx) {
  const root = path.join(ctx.cfg.stateDir, "runs");
  let ents = [];
  try { ents = fs.readdirSync(root, { withFileTypes: true }); } catch { return 0; }
  let n = 0;
  for (const e of ents) {
    const p = path.join(root, e.name);
    try {
      if (e.isDirectory() && ctx.now() - fs.statSync(p).mtimeMs > ctx.cfg.gcDays * 86_400_000) { fs.rmSync(p, { recursive: true, force: true }); n++; }
    } catch { /* 겹친 틱이 먼저 지움 — 다음 날 다시 */ }
  }
  return n;
}

function dailyGc(ctx) {
  const { localDay } = ctx.storeMod;
  const today = localDay(ctx.now());
  let last = "";
  try { last = fs.readFileSync(ctx.cfg.lastGcPath, "utf8").trim(); } catch { /* 처음 */ }
  if (last === today) return;
  try {
    const r = ctx.store.gc(ctx.now(), ctx.cfg.gcDays);
    ctx.metric("gc", { ok: true, deleted: r.deleted, bytes: r.bytes, runs: pruneRuns(ctx) });
    fs.writeFileSync(ctx.cfg.lastGcPath, today, { mode: 0o600 });
  } catch (e) {
    ctx.metric("gc", { ok: false, error: errHead(firstLine(e)) }); // 다음 틱에 다시
  }
}

// 틱이 고를 순서: 답이 적힌 대기 → 끊긴 실행 → 이어가기 → 실패(재시도) → 보류 → 대기열(새 일은 마지막)
const RANK = { waiting: 0, running: 1, continue: 2, failed: 3, held: 4, queued: 5 };
function tickCandidates(ctx) {
  return ctx.store.openThreads()
    .filter((r) => r.status in RANK && (r.status !== "waiting" || (r.answer != null && r.answer_key === r.interrupt_id)))
    .sort((a, b) => RANK[a.status] - RANK[b.status] || (a.progress_at ?? a.created_at) - (b.progress_at ?? b.created_at));
}

// 스레드 하나의 예상 밖 오류(그래프의 summarize·상태 읽기 등)는 그 스레드만 코드 결함으로 보류하고 틱은 계속 간다 —
// 그래프 하나의 고장이 틱 전체를 매번 죽여(종료 1) 잡이 꺼지는 일을 막는다. 저장소 자체가 고장이면 보류 기록도 실패해 그대로 던진다.
async function tickThread(ctx, row0) {
  try {
    return await tickThreadInner(ctx, row0);
  } catch (e) {
    active.running = false;
    if (/^SQLITE_/.test(e?.code ?? "")) {
      if (/^SQLITE_(BUSY|LOCKED)/.test(e.code)) { say(`HELD ${row0.thread_id} 저장소가 잠시 바쁨(${e.code}) — 다음 틱에`); return "busy"; } // 일시 — 코드 결함이 아니다
      throw e; // 저장소 고장은 틱 전체의 진짜 오류
    }
    const note = `예상 밖 오류 — ${firstLine(e)}`;
    ctx.store.updateThread(row0.thread_id, { status: "held", note, hold_reason: "code_defect", hold_ref: codeHash(row0.graph) }, ctx.now());
    ctx.metric("held", { thread: row0.thread_id, graph: row0.graph, scope: "thread", reasons: ["code_defect"], error: errHead(firstLine(e)) });
    say(`HELD ${row0.thread_id} ${note}`);
    if (process.env.LG_DEBUG) warn(e?.stack ?? String(e));
    return "held";
  }
}

async function tickThreadInner(ctx, row0) {
  const thread = row0.thread_id;
  current = thread;
  const li = ctx.store.lockInfo(thread);
  if (li?.live) return "locked";
  const token = ctx.store.acquireLock(thread);
  if (!token) return "locked";
  active.thread = thread; active.token = token;
  try {
    let row = ctx.store.getThread(thread);
    if (!row || !(row.status in RANK)) return "skip";
    if (row.status === "waiting" && !(row.answer != null && row.answer_key === row.interrupt_id)) return "skip";
    if (row.hold_reason === "code_defect" && row.hold_ref === codeHash(row.graph)) return "skip"; // 코드가 그대로면 다시 해도 같다
    if (row.hold_reason === "effect_unknown") return "skip"; // 결과 모르는 부수효과 — 사람이 확인해야 한다(기한이 지나면 만료 보고)
    // LLM 상한 보류: 풀릴 수 없는 동안은 노드를 다시 돌리지 않는다(앞부분 일을 틱마다 되풀이하지 않게)
    if ((row.hold_reason === "llm_day" || row.hold_reason === "token_cap") && row.hold_ref === ctx.storeMod.localDay(ctx.now())) return "skip";
    if (row.hold_reason === "llm_thread" && row.hold_ref === String(ctx.cfg.llm.perThread)) return "skip";
    const t = ctx.now();
    if (row.status === "running") {
      // 실행 중으로 적혔는데 잠금 주인이 없다 = 끊김(게이트웨이 재시작·SIGKILL). 재시도로 센다.
      const sig = "interrupted:stalled";
      const count = row.fail_sig === sig ? (row.fail_count ?? 0) + 1 : 1;
      ctx.metric("interrupted", { thread, graph: row.graph, cause: "stalled" });
      ctx.store.updateThread(thread, { status: "failed", note: "실행 중 끊김(주인 없음)", fail_sig: sig, fail_count: count }, t, { touch: false });
      row = ctx.store.getThread(thread);
    }
    if (row.status === "failed" && (row.fail_count ?? 0) > ctx.cfg.maxRetries) {
      giveUp(ctx, thread, row.graph, String(row.fail_sig ?? "?").split(":")[0], row.fail_count, row.note ?? "");
      return "gave_up";
    }
    let g;
    try {
      g = await openGraph(ctx, row.graph, thread, { mode: row.mode ?? "shadow" });
      if (g.blocked) throw new GraphRuleError("컴파일에 정적 중단점(interruptBefore/After)이 있다 — 노드 단위 진행이 승인 없이 지나칠 수 있다");
    } catch (e) {
      // 허용 목록은 틱 시작 때 이미 읽었다 — 여기서 나는 오류는 그 그래프 몫(파일 없음·규칙 위반·불러오다 죽음)이다. 다른 스레드는 계속 간다.
      const note = firstLine(e);
      const same = row.status === "held" && row.note === note;
      ctx.store.updateThread(thread, { status: "held", note, hold_reason: "code_defect", hold_ref: codeHash(row.graph) }, t, { touch: !same });
      ctx.metric("held", { thread, graph: row.graph, scope: "thread", reasons: ["code_defect"], error: errHead(note) });
      say(`HELD ${thread} 코드 결함 — ${note}`);
      return "held";
    }
    // S13 한 번에 하나(그래프 meta.serial): 같은 그래프에 이미 시작한 미완 스레드가 있으면 대기열 것은 다음 틱으로 미룬다(상태 그대로)
    if (row.status === "queued" && g.mod.meta?.serial === true
      && ctx.store.openThreads().some((r) => r.graph === row.graph && r.thread_id !== thread && r.status !== "queued")) return "skip";
    let first;
    if (!ctx.store.hasCheckpoint(thread)) {
      if (row.input_json == null) { // 입력을 모르는 옛 스레드 — 시작할 수 없다
        ctx.store.updateThread(thread, { status: "held", note: "저장된 단계도 시작 입력도 없다 — 같은 이름으로 다시 start", hold_reason: "code_defect", hold_ref: codeHash(row.graph) }, t);
        return "held";
      }
      first = { kind: "input", value: JSON.parse(row.input_json) };
      if (row.status === "queued") ctx.metric("start", { thread, graph: row.graph, mode: row.mode ?? "shadow", from: "queue" });
    } else {
      const r = await reconcile(ctx, g, thread);
      if (r.kind === "expired") return "expired";
      if (r.kind === "multi") return codeOf(await settle(ctx, g, thread)) ? "error" : "ok";
      if (r.kind === "waiting") {
        const cur = ctx.store.getThread(thread);
        if (!(cur.answer != null && cur.answer_key === cur.interrupt_id)) { await settle(ctx, g, thread); return "waiting"; }
        first = { kind: "resume", decision: cur.answer };
        ctx.store.updateThread(thread, { decision: cur.answer }, t, { touch: false });
        ctx.metric("resumed", { thread, graph: row.graph, from: "answer" });
      } else if (!r.s.next?.length) {
        if (row.next_nodes) return holdVanished(ctx, row); // 멈출 때 다음 노드가 있었는데 그래프에서 사라졌다 — '끝남'이 아니다
        await settle(ctx, g, thread);
        return "done";
      } else {
        first = { kind: "null" };
        ctx.metric("resumed", { thread, graph: row.graph, from: row.status });
      }
    }
    const before = ctx.store.getThread(thread);
    // 대기열에서 처음 시작할 때는 진척 시각을 지금으로 — 차례를 기다린 시간(S13)이 보류 48시간에 들어가지 않게(H3 중1)
    ctx.store.updateThread(thread, { status: "running", run_started_at: t, ...(before.status === "queued" ? { progress_at: t } : {}) }, t, { touch: false });
    await advance(ctx, g, thread, first, before);
    return "ok";
  } finally {
    ctx.store.releaseLock(thread, token);
    active.token = null; active.thread = null;
  }
}

// 자원 관문을 건너뛰는 그래프 — 읽기 전용·LLM 없음·사본 없음인 것만(당직 D0, PLAN §13.3). PAUSED 는 이들도 막는다.
const GATE_EXEMPT_GRAPHS = new Set(["duty-verify"]);

// 관문 보류가 일을 붙잡고 오래 가면 한 번 알린다(10-05: 매일 QA 가 디스크 관문에 막힌 걸 아무도 몰랐다 — HOLD 는 알림 대상이 아니었다).
// 야간(quiet)·멈춤(paused)은 일부러 세우는 것이라 빼고 센다. 같은 이유의 보류가 이어지는 동안은 한 번만, 풀리면 처음부터 다시 잰다.
function noteHold(ctx, gates, pendingWork) {
  const f = path.join(ctx.cfg.stateDir, "hold-since.json");
  const reasons = gates.map((x) => x.gate).filter((x) => x !== "quiet" && x !== "paused");
  const waiting = reasons.length ? pendingWork() : [];
  if (!waiting.length) { fs.rmSync(f, { force: true }); return; }
  const key = reasons.join(",");
  let st = null;
  try { st = JSON.parse(fs.readFileSync(f, "utf8")); } catch { st = null; }
  const now = ctx.now();
  if (!st || st.key !== key) {
    fs.writeFileSync(f, JSON.stringify({ key, since: now, notified: false }), { mode: 0o600 });
    return;
  }
  if (st.notified || now - st.since < ctx.cfg.gates.holdNotifyMs) return;
  const mins = Math.round((now - st.since) / 60_000);
  const detail = gates.filter((x) => reasons.includes(x.gate)).map((x) => x.detail).join(" / ");
  const names = waiting.slice(0, 3).map((r) => r.thread_id).join(", ") + (waiting.length > 3 ? ` 외 ${waiting.length - 3}` : "");
  announce(ctx, waiting[0].thread_id, `STUCK ${waiting[0].thread_id} 관문 보류 ${mins}분째 — ${detail} · 기다리는 일: ${names}`,
    () => fs.writeFileSync(f, JSON.stringify({ ...st, notified: true }), { mode: 0o600 }));
}

// 당직 D0 틱 고리(lib/duty-intake.mjs): 게이트웨이 heartbeat 기록 + 재시작마다 duty-verify 스레드(그림자) 대기열 등록.
// 고리의 고장은 틱을 멈추지 않는다 — 보류 기록(held scope duty)으로 남기고 틱은 계속 간다(그래프 하나가 잡 전체를 꺼뜨리지 않게와 같은 원칙).
async function dutyHook(ctx) {
  try {
    const { dutyTick } = await import("./lib/duty-intake.mjs");
    const r = await dutyTick({ cfg: ctx.cfg, store: ctx.store, metric: ctx.metric, now: ctx.now, registry: await registry(ctx),
      timeLeft: () => ctx.cfg.jobLimitMs - elapsedMs(), graphExists: (g) => fs.existsSync(path.join(HERE, "graphs", `${g}.mjs`)) });
    if (r.created?.length) say(`QUEUED ${r.created.join(" ")} 게이트웨이 재시작 확인(당직 D0 그림자)`);
  } catch (e) {
    ctx.metric("held", { scope: "duty", reasons: ["duty_hook"], error: errHead(firstLine(e)) });
    say(`HELD duty-intake ${firstLine(e)}`);
    if (process.env.LG_DEBUG) warn(e?.stack ?? String(e));
  }
}

async function cmdTick(ctx) {
  ctx.isTick = true;
  const t0 = performance.now();
  const { checkGates } = await import("./lib/gates.mjs");
  if (fs.existsSync(ctx.cfg.pausedPath)) { // 전체 정지 — 정리·만료도 하지 않는다
    ctx.metric("held", { scope: "tick", reasons: ["paused"] });
    ctx.metric("tick", { ms: Math.round(performance.now() - t0), outcome: "paused" });
    return 0;
  }
  const leak = hookLeak(ctx.cfg);
  if (!leak.ok) { // 사용자 훅이 graphs 쪽 claude 호출에서 돌았다 — 위키·RAG 오염 위험(S6·S7). 사람이 볼 때까지 멈춘다.
    ctx.metric("held", { scope: "tick", reasons: ["hook_leak"], detail: leak.msg });
    say(`ERROR - selftest ${leak.msg}`);
    return 1;
  }
  await registry(ctx); // 허용 목록이 망가졌으면 여기서 진짜 오류(1) — 스레드마다 보류로 숨기지 않는다
  await dutyHook(ctx); // 당직 D0: heartbeat + 게이트웨이 재시작 접수(관문 앞 — 보류 틱에도 기록·접수는 한다)
  const failures = await sweep(ctx);
  for (const f of failures) ctx.metric("held", { scope: "sweep", reasons: ["sweep_error"], detail: errHead(f) });
  expireIdle(ctx);
  // 아직 알리지 못한 대기(끊긴 실행을 정리가 대기로 맞춘 경우 등)는 여기서 알린다 — 주인님이 못 본 질문이 조용히 만료되지 않게
  for (const row of ctx.store.openThreads()) {
    if (row.status !== "waiting" || !row.interrupt_id || row.waiting_notified === row.interrupt_id || row.answer != null) continue;
    announce(ctx, row.thread_id, waitingLine(row.thread_id, row.question, row.question_seq || 1, row.deadline_at),
      () => ctx.store.updateThread(row.thread_id, { waiting_notified: row.interrupt_id }, ctx.now(), { touch: false }));
    ctx.metric("waiting", { thread: row.thread_id, graph: row.graph, reason: null, late: true });
  }
  for (const row of ctx.store.openThreads()) {
    const li = ctx.store.lockInfo(row.thread_id);
    if (li?.stuck) noteStuck(ctx, row, li);
  }
  dailyGc(ctx);
  pruneSandboxes(ctx);
  let gates = checkGates(ctx.cfg, ctx.store, ctx.now());
  const pendingWork = () => tickCandidates(ctx).filter((r) => !GATE_EXEMPT_GRAPHS.has(r.graph));
  // 디스크 관문 자가 회복(10-05): 기다리는 일이 있으면 다시 만들 수 있는 것부터 치우고(당직과 같은 도구) 한 번 다시 잰다.
  if (gates.some((x) => x.gate === "disk") && pendingWork().length) {
    const { reclaimDisk } = await import("./lib/reclaim.mjs");
    const { createRun } = await import("./lib/run.mjs");
    const rc = await reclaimDisk(createRun({ cfg: ctx.cfg, registry: await registry(ctx), thread: "_tick", mode: "shadow" }));
    ctx.metric("reclaim", { scope: "tick", ...rc });
    gates = checkGates(ctx.cfg, ctx.store, ctx.now());
  }
  noteHold(ctx, gates, pendingWork);
  if (gates.length) {
    ctx.metric("held", { scope: "tick", reasons: gates.map((x) => x.gate), detail: gates.map((x) => x.detail).join(" / ") });
    say(`HOLD ${gates.map((x) => `${x.gate}: ${x.detail}`).join(" · ")}`);
    // 자원 관문(디스크·사용량·토큰·LLM 보류·야간)은 사본을 만들고 LLM 을 부르는 무거운 그래프를 막으려는 것이다.
    // 읽기 전용·LLM 없는 당직 확인(GATE_EXEMPT_GRAPHS)은 시스템이 나쁠 때일수록 돌아야 한다 — 10-04 실측: 디스크 관문(13.2 < 16.2GiB)이
    // D0 대조를 막았다. PAUSED(멈춤 스위치)는 예외 없이 지킨다.
    let n = 0;
    if (!gates.some((x) => x.gate === "paused")) {
      const seen = new Set();
      for (;;) {
        if (overBudget(ctx) || fs.existsSync(ctx.cfg.pausedPath)) break;
        const row = tickCandidates(ctx).find((r) => GATE_EXEMPT_GRAPHS.has(r.graph) && !seen.has(r.thread_id));
        if (!row) break;
        seen.add(row.thread_id);
        const r = await tickThread(ctx, row);
        if (r !== "locked" && r !== "skip") n++;
      }
    }
    ctx.metric("tick", { ms: Math.round(performance.now() - t0), outcome: "hold", exempt_threads: n });
    failures.forEach(say);
    return 0;
  }
  await dailyStart(ctx);
  const seen = new Set();
  let n = 0, outcome = "idle";
  for (;;) {
    if (overBudget(ctx)) { outcome = "budget"; break; }
    if (fs.existsSync(ctx.cfg.pausedPath)) { outcome = "paused"; break; } // 틱 도중 멈춤 — 다음 스레드를 고르지 않는다
    const row = tickCandidates(ctx).find((r) => !seen.has(r.thread_id));
    if (!row) break;
    seen.add(row.thread_id);
    const r = await tickThread(ctx, row);
    if (r !== "locked" && r !== "skip") { n++; outcome = "ran"; }
  }
  ctx.metric("tick", { ms: Math.round(performance.now() - t0), threads: n, outcome });
  failures.forEach(say);
  return 0;
}

// ── 상태 보기 ─────────────────────────────────────────────────────
function view(ctx, r) {
  const t = (ms) => (ms == null ? null : iso(ms));
  let status = ctx.store.effective(r), note = r.note;
  if (status === "waiting" && r.deadline_at != null && r.deadline_at <= ctx.now() && r.answer == null) { status = "expired"; note = "기한 지남 — 다음 명령·틱 때 취소"; }
  return {
    thread: r.thread_id, graph: r.graph, status, mode: r.mode ?? "shadow", since: t(r.waiting_since), deadline: t(r.deadline_at),
    question: r.question, answer: r.answer ?? null, decision: r.decision, note, hold: r.hold_reason ?? null, fails: r.fail_count ?? 0,
    created: t(r.created_at), updated: t(r.updated_at), progress: t(r.progress_at),
  };
}
function viewLine(v) {
  const detail = {
    waiting: `${v.question ?? ""} · 기한 ${v.deadline}${v.answer ? ` · 답 ${v.answer}(다음 틱이 적용)` : ""}`,
    expired: `${v.question ?? ""} · ${v.note ?? ""}`,
    stalled: "멈춤(실행 중 끊김) — 다음 틱이 잇는다",
    held: `${v.hold ?? ""} ${v.note ?? ""}`,
  }[v.status] ?? (v.note ?? "");
  return `${v.status.toUpperCase()} ${v.thread} [${v.graph}·${v.mode}] ${detail}`;
}

// 읽기만 한다 — 만료 확정·알림은 다른 명령과 틱이 한다(여기서 확정하면 알림이 사라진다).
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
  const c = ctx.store.llmCounts(ctx.now());
  const llm = { today: c.day, perDay: ctx.cfg.llm.perDay, tokensToday: c.tokens, tokenCap: ctx.cfg.llm.dayTokenCap };
  const switches = { paused: fs.existsSync(ctx.cfg.pausedPath), live: fs.existsSync(ctx.cfg.livePath) };
  if (flags.json) { raw(JSON.stringify({ now: iso(ctx.now()), counts, llm, switches, threads: shown })); return 0; }
  say(`STATUS ${STATUSES.map((k) => `${k}=${counts[k]}`).join(" ")} llm_today=${llm.today}/${llm.perDay} tokens_today=${llm.tokensToday}/${llm.tokenCap}${switches.paused ? " PAUSED" : ""}${switches.live ? " LIVE" : " shadow"}`);
  for (const v of shown) say(viewLine(v));
  return 0;
}

async function main() {
  const { pos, flags } = parseArgs(process.argv.slice(2));
  const cmd = pos.shift();
  active.cmd = cmd;
  if (!cmd || cmd === "help" || flags.help) {
    raw("사용: run.mjs tick [--verbose] | answer <스레드> approved|rejected | start <그래프> <스레드> [--topic 값] [--llm] [--queue] | resume <스레드> approved|rejected | retry <스레드> | status [<스레드>] [--json] [--all] | sweep | gc [--days N] | selftest");
    return cmd ? 0 : 1;
  }
  const st = selftest();
  if (!st.ok) {
    say(`ERROR - selftest ${st.what}: ${st.msg}`);
    warn(`자가 시험 실패 — ${st.hint}`);
    warn(`실행한 Node: ${process.version} (${process.execPath})`);
    return 1;
  }
  const cfg = loadConfig();
  if (cmd === "selftest") {
    const leak = hookLeak(cfg);
    if (!leak.ok) { say(`ERROR - selftest ${leak.msg}`); return 1; }
    const { loadRegistry } = await import("./lib/run.mjs");
    let reg;
    try { reg = loadRegistry(cfg.cmdRegistryPath); } catch (e) { say(`ERROR - selftest ${firstLine(e)}`); return 1; }
    say(`OK selftest sqlite ${st.sqlite} · node ${st.node} · 훅 누수 0(${leak.checked}개 로그) · 허용 명령 ${Object.keys(reg.commands).length}개`);
    return 0;
  }

  const now = clock();
  const storeMod = await import("./lib/store.mjs");
  const { createMetrics } = await import("./lib/metrics.mjs");
  const store = new storeMod.Store(cfg);
  // 실행 시 차단층: 이제부터 프로세스는 실행기 내부(allowSpawn)만 띄운다 — 그래프 코드는 어떤 우회로로도 못 띄운다(lib/guard.mjs)
  (await import("./lib/guard.mjs")).installGuard();
  const metric = createMetrics({ file: cfg.metricsPath, now });
  const ctx = { cfg, now, store, storeMod, metric, expiredNow: [], isTick: false };
  active.ctx = ctx; active.store = store; active.now = now; active.metric = metric;
  if (cmd === "status") return cmdStatus(ctx, pos, flags);
  if (cmd === "answer") return cmdAnswer(ctx, pos);
  if (cmd === "tick") return cmdTick(ctx);

  const paused = fs.existsSync(cfg.pausedPath);
  if (cmd === "sweep" && paused) return 0; // 전체 정지 — 만료 처리도 하지 않는다(NO_REPLY)
  const failures = paused ? [] : await sweep(ctx);
  if (cmd === "sweep") expireIdle(ctx);
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
  const ownsNotices = active.cmd === "sweep" || active.cmd === "tick"; // 예약 잡의 알림이 정본 — 대화 중 명령은 가로채지 않는다
  let notices = [];
  // 만료 알림: 예약 잡(tick·sweep)은 아직 알리지 않은 만료를 전부 내고, 찍은 뒤에만 '알림'으로 적는다.
  // 다른 명령은 자기가 이번에 만료시킨 것만 뒤에 붙이고 표시하지 않는다. status·answer 는 만료를 다루지 않는다.
  if (store && !["status", "answer"].includes(active.cmd)) {
    try {
      notices = ownsNotices
        ? store.unnotifiedExpired()
        : [...new Set(active.ctx?.expiredNow ?? [])].map((id) => store.getThread(id)).filter(Boolean);
    } catch (e) {
      lines.push(`ERROR - internal 만료 알림을 읽지 못함: ${String(e?.message ?? e).split("\n")[0]}`);
      code = 1;
    }
  }
  // 틱 알림함: 이번 틱과 앞서 도중에 죽은 틱이 남긴 알림을 낸다(꺼내면서 지우고, 내지 못하면 되돌린다)
  let outbox = [];
  if (store && active.cmd === "tick") {
    try { outbox = store.claimNotices(); } catch (e) { lines.push(`ERROR - internal 알림함을 읽지 못함: ${String(e?.message ?? e).split("\n")[0]}`); code = 1; }
  }
  let out = [...lines, ...outbox.map((r) => r.line), ...notices.map((r) => `EXPIRED ${r.thread_id} ${r.question ?? r.note ?? ""} — ${r.note?.includes("보류") ? "보류 기한 초과로 자동 취소" : "승인 기한 초과로 자동 취소"}`.replace(/\s+/g, " ").slice(0, 400))];
  // 알림 필터: 예약 잡(tick)은 주인님께 갈 줄만 — DONE·WAITING·EXPIRED·GAVE_UP·STUCK(+진짜 오류 ERROR). 낼 것이 없으면 NO_REPLY.
  if (active.cmd === "tick" && !active.verbose) out = out.filter((l) => NOTIFY.test(l) || (code !== 0 && /^ERROR /.test(l)));
  if (ownsNotices && !out.length) out.push("NO_REPLY");
  let written = false;
  try { writeOut(out.length ? `${out.join("\n")}\n` : ""); written = true; } catch { code = 1; }
  if (!written && outbox.length) { try { store.restoreNotices(outbox); } catch { /* 다음 틱도 못 낸다 — 상태는 그대로 */ } }
  if (store) {
    try {
      if (written && ownsNotices && notices.length) store.markNotified(notices.map((r) => r.thread_id));
      if (active.cmd !== "status") store.writePending();
    } catch (e) { warn(`장부 마무리 실패: ${e.message}`); }
    store.close();
    active.store = null;
  }
  active.metric?.close?.();
  process.exitCode = code;
  setTimeout(() => process.exit(code), 3000).unref(); // 남은 핸들이 있어도 3초 안에 끝낸다
}

active.verbose = process.argv.includes("--verbose");
main().then(end, (e) => {
  const kind = e instanceof UsageError ? "usage" : "internal";
  say(`ERROR ${current} ${kind} ${String(e?.message ?? e).split("\n")[0]}`);
  if (kind === "internal" && process.env.LG_DEBUG) warn(e?.stack ?? String(e));
  end(1);
});
