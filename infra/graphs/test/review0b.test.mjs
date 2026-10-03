// review0b.test.mjs — 0b 독립 검토(10-03, 실행기 의미 A · 입구·안전층 B)가 재현한 결함을 막았는지. 전부 임시 HOME·임시 상태 폴더.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { sandbox, run, counts, appWith, fakeClaude, at, T0, HOUR, DAY, NODE, ROOT } from "./helpers.mjs";
import { tickEnv, writeRegistry, STEPS, CMD_FIXTURE } from "./helpers0b.mjs";
import { loadRegistry } from "../lib/run.mjs";
import * as detach from "../lib/detach.mjs";
import { createEffect } from "../lib/effects.mjs";
import { createClaude } from "../lib/claude.mjs";
import { loadConfig } from "../lib/config.mjs";
import { Store } from "../lib/store.mjs";

const LG = `import fs from "node:fs";\nimport { StateGraph, Annotation, START, END, interrupt } from "@langchain/langgraph";\n`;
const statusOf = (lg, env, th, extra) => JSON.parse(lg(env, ["status", th, "--json"], extra).out);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── B상1: 허용 목록 우회 임의 실행 — 정적 검사를 피한 코드도 실행 차단층이 막는다 ──────────
test("B상1: 정적 검사를 피한 우회(getBuiltinModule 문자열 조합)도 실행 때 막힌다 — 수동 ERROR(1)·틱 보류(0), 표식 파일 0", (t) => {
  const sb = sandbox(t);
  const marker = path.join(sb.dir, "PWNED");
  const pwn = `${LG}
const State = Annotation.Root({ out: Annotation() });
export const input = () => ({});
export const summarize = (v) => String(v.out);
export function build({ checkpointer, tools }) {
  return new StateGraph(State)
    .addNode("x", async () => {
      await tools.run("test.echo", { word: "hi" }); // 허가된 입구를 한 번 거친 뒤에도 허가 범위가 새지 않아야 한다
      const g = globalThis["pro" + "cess"]["getBuiltin" + "Module"]("node:child_" + "process");
      g["exe" + "cFileSync"]("/usr/bin/touch", [${JSON.stringify(marker)}]);
      return { out: "ran" };
    })
    .addEdge(START, "x").addEdge("x", END)
    .compile({ checkpointer });
}
`;
  const lg = appWith(sb, { pwn });
  const env = { ...tickEnv(sb), LG_CMD_REGISTRY: writeRegistry(sb) };
  const s = lg(env, ["start", "pwn", "p1"]);
  assert.equal(s.code, 1, s.out);
  assert.match(s.first, /^ERROR p1 failed child_process\.execFileSync 직접 실행 금지/);
  assert.equal(fs.existsSync(marker), false, "명령이 실행되면 안 된다");
  assert.equal(lg(env, ["start", "pwn", "p2", "--queue"]).code, 0);
  const r = lg(env, ["tick"]);
  assert.equal(r.code, 0);
  assert.equal(r.first, "NO_REPLY");
  assert.equal(statusOf(lg, env, "p2").hold, "code_defect");
  assert.equal(fs.existsSync(marker), false);
});

test("B상1: 정적 검사 — createRequire·getBuiltinModule·eval·Function·constructor·글자값 아닌 import·허용 밖 패키지·위험 이름 글자값", async () => {
  const { checkGraphSource } = await import("../scripts/check-graph-rules.mjs");
  const reg = { commands: {} };
  const H = `import { StateGraph } from "@langchain/langgraph";\n`;
  const rules = (src) => [...new Set(checkGraphSource(src, "g.mjs", reg).map((p) => p.rule))].sort();
  assert.deepEqual(rules(`import { createRequire } from "node:module";\nconst r = createRequire(import.meta.url);`), ["escape", "import-allow"]);
  assert.deepEqual(rules(`${H}const cp = process.getBuiltinModule("x");`), ["escape"]);
  assert.deepEqual(rules(`${H}const m = "a" + "b";\nconst cp = await import(m);`), ["escape"]);
  assert.deepEqual(rules(`import execa from "execa";`), ["import-allow"]);
  assert.deepEqual(rules(`${H}eval("1");`), ["escape"]);
  assert.deepEqual(rules(`${H}const f = new Function("return 1");`), ["escape"]);
  assert.deepEqual(rules(`${H}const f = (() => {}).constructor("return 1");`), ["escape"]);
  assert.deepEqual(rules(`${H}const k = "execSync";`), ["escape"]);
  assert.deepEqual(rules(`import { Worker } from "node:worker_threads";`), ["import-allow"]);
  assert.deepEqual(rules(`${H}import fs from "node:fs";\nimport path from "node:path";\nimport { z } from "zod";\nconst h = await import("./helper.mjs");\nconst s = "hello";`), []);
});

// ── A상3: 답이 적힌 스레드도 기한에 걸린다 ───────────────────────────
test("A상3: 답을 받고도 관문에 막혀 진행 못 하면 답한 때부터 48시간 뒤 EXPIRED — 3주 뒤 옛 승인으로 실행되지 않는다", (t) => {
  const sb = sandbox(t);
  const envAt = (ms, over = {}) => ({ ...tickEnv(sb, { now: ms }), ...over });
  assert.match(run(envAt(T0), ["start", "smoke", "a1"], at(T0)).first, /^WAITING a1 /);
  assert.equal(run(envAt(T0), ["answer", "a1", "approved"], at(T0 + HOUR)).code, 0);
  const blocked = { LG_DISK_FLOOR_GIB: "100000" };
  assert.equal(run(envAt(T0 + 48 * HOUR, blocked), ["tick"], at(T0 + 48 * HOUR)).first, "NO_REPLY", "답 뒤 47시간 — 아직");
  const r = run(envAt(T0 + 50 * HOUR, blocked), ["tick"], at(T0 + 50 * HOUR));
  assert.match(r.first, /^EXPIRED a1 /, r.out);
  assert.match(run(envAt(T0 + 500 * HOUR), ["tick"], at(T0 + 500 * HOUR)).first, /^NO_REPLY$/, "관문이 풀려도 만료된 스레드는 돌지 않는다");
  assert.equal(counts(sb).finalize ?? 0, 0);
});

// ── A중4: 답은 질문 번호에 묶인다 ──────────────────────────────────
test("A중4: 같은 문구로 다시 묻는 재확인은 새 번호로 다시 알리고, 되풀이된 옛 답은 받지 않는다", (t) => {
  const sb = sandbox(t);
  const confirm = `${LG}
const State = Annotation.Root({ n: Annotation(), d: Annotation({ reducer: (a, b) => a.concat(b), default: () => [] }) });
export const input = () => ({ n: 0 });
export const summarize = (v) => v.d.join("/");
export function build({ checkpointer }) {
  return new StateGraph(State)
    .addNode("confirm", (s) => ({ d: [interrupt({ question: "정말 지울까요?" })], n: s.n + 1 }))
    .addEdge(START, "confirm")
    .addConditionalEdges("confirm", (s) => (s.n < 2 ? "confirm" : END))
    .compile({ checkpointer });
}
`;
  const lg = appWith(sb, { confirm });
  const env = tickEnv(sb);
  assert.match(lg(env, ["start", "confirm", "c1"]).lines[1], /질문 #1/);
  assert.equal(lg(env, ["answer", "c1", "approved"]).code, 0);
  const r = lg(env, ["tick"]);
  assert.match(r.first, /^WAITING c1 정말 지울까요\? · 질문 #2 /, `같은 문구라도 다시 알린다: ${r.out}`);
  assert.match(lg(env, ["answer", "c1", "approved"]).first, /^ERROR c1 need-qid /, "번호 없는 되풀이 답은 받지 않는다");
  assert.match(lg(env, ["answer", "c1", "approved", "1"]).first, /^ERROR c1 stale-question /, "옛 번호는 받지 않는다");
  assert.equal(lg(env, ["answer", "c1", "rejected", "#2"]).code, 0);
  assert.match(lg(env, ["tick"]).first, /^DONE c1 approved\/rejected$/);
});

// ── A중5: 배포로 노드가 사라지면 '끝남'이 아니다 ─────────────────────
test("A중5: 이어가기 중 다음 노드가 배포로 사라지면 DONE 이 아니라 코드 결함 보류", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { steps: STEPS });
  const env = { ...tickEnv(sb), LG_TICK_BUDGET_SEC: "0.5", LG_TEST_STEP_MS: "600" };
  assert.equal(lg(env, ["start", "steps", "v1", "--queue"]).code, 0);
  assert.equal(lg(env, ["tick"]).first, "NO_REPLY");
  const v = statusOf(lg, env, "v1");
  assert.equal(v.status, "continue");
  const next = /다음 노드\(([a-d])\)/.exec(v.note)[1];
  const f = path.join(sb.dir, "app", "graphs", "steps.mjs");
  const src = fs.readFileSync(f, "utf8");
  fs.writeFileSync(f, src.replace(new RegExp(`\\.addNode\\("${next}"`), `.addNode("${next}2"`).replace(new RegExp(`"${next}"\\)`, "g"), `"${next}2")`).replace(new RegExp(`addEdge\\("${next}"`), `addEdge("${next}2"`));
  const r = lg(env, ["tick"]);
  assert.equal(r.first, "NO_REPLY", r.out);
  const after = statusOf(lg, env, "v1");
  assert.equal(after.status, "held");
  assert.equal(after.hold, "code_defect");
  assert.match(after.note, /가 그래프에 없다/);
});

// ── A하7: 그래프 모듈의 console 출력이 틱 알림에 새지 않는다 ──────────
test("A하7: 그래프 모듈 최상위·build() 의 console 출력은 스레드 로그로 — 틱 출력은 알림 줄만", (t) => {
  const sb = sandbox(t);
  const noisy = STEPS.replace("export function build({ checkpointer }) {", 'console.log("[debug] graph loaded");\nexport function build({ checkpointer }) {\n  console.error("[debug] building");');
  const lg = appWith(sb, { noisy });
  const env = tickEnv(sb);
  assert.equal(lg(env, ["start", "noisy", "n1", "--queue"]).code, 0);
  const r = lg(env, ["tick"]);
  assert.equal(r.out, "DONE n1 a>b>c>d\n");
  assert.equal(r.err, "");
});

// ── A하8: LLM 상한 보류는 풀릴 때까지 노드를 다시 돌리지 않는다 ───────
test("A하8: 하루 LLM 상한 보류는 그날 다시 돌리지 않고(노드 앞부분 되풀이 없음) 다음 날 잇는다", (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb);
  const envAt = (ms) => ({ ...tickEnv(sb, { now: ms }), LG_CLAUDE_BIN: fake.bin, LG_LLM_MAX_PER_DAY: "1" });
  assert.match(run(envAt(T0), ["start", "smoke", "b1", "--llm"], at(T0)).first, /^WAITING b1 /);
  assert.equal(run(envAt(T0), ["start", "smoke", "b2", "--llm", "--queue"], at(T0)).code, 0);
  for (let h = 0; h < 3; h++) assert.equal(run(envAt(T0 + h * HOUR), ["tick"], at(T0 + h * HOUR)).first, "NO_REPLY");
  assert.equal(counts(sb).think, 2, "b1 1회 + b2 1회(보류된 뒤 같은 날 다시 돌지 않는다)");
  assert.equal(JSON.parse(run(envAt(T0), ["status", "b2", "--json"], at(T0)).out).hold, "llm_day");
  assert.match(run(envAt(T0 + DAY), ["tick"], at(T0 + DAY)).first, /^WAITING b2 /);
});

// ── A하9 · B중2: ps 가 실패해도 살아 있는 주인을 죽은 것으로 보지 않는다 ──
test("A하9·B중2: ps 실패(시작 시각 못 읽음) 때 분리 실행은 running, effect 잠금은 넘겨받지 않는다(S1 과 같게)", async (t) => {
  const sb = sandbox(t);
  const h = detach.launch(path.join(sb.state, "jobs"), { thread: "s1", node: "n", attempt: 1, cmdId: "test.sleep" },
    { bin: NODE, argv: [CMD_FIXTURE, "sleep", "1500", path.join(sb.dir, "o.txt")], cwd: "/", env: { PATH: "/usr/bin:/bin" }, timeoutMs: 30_000 });
  let st;
  for (let i = 0; i < 100 && !(st = detach.check(h)).pid; i++) await sleep(30);
  const saved = [process.env.LG_TEST_MODE, process.env.LG_TEST_PS_FAIL];
  process.env.LG_TEST_MODE = "1"; process.env.LG_TEST_PS_FAIL = "1";
  try {
    assert.equal(detach.check(h).state, "running", "살아 있는 일을 dead 로 보고 죽이면 안 된다");
    const cfg = { stateDir: sb.state, effectsPath: path.join(sb.state, "effects.jsonl") };
    const lockDir = path.join(sb.state, "effect-locks");
    fs.mkdirSync(lockDir, { recursive: true });
    const { createHash } = await import("node:crypto");
    const d = path.join(lockDir, createHash("sha1").update("k:x").digest("hex"));
    fs.mkdirSync(d);
    fs.writeFileSync(path.join(d, "owner.json"), JSON.stringify({ pid: process.pid, pstart: "Thu Jan  1 00:00:00 2099" }));
    const live = createEffect({ cfg, now: () => T0, thread: "e", mode: "live" });
    let ran = 0;
    await assert.rejects(live("k:x", "commit", async () => { ran++; }), (e) => e.pending === true);
    assert.equal(ran, 0);
  } finally {
    [process.env.LG_TEST_MODE, process.env.LG_TEST_PS_FAIL] = saved;
    if (saved[0] === undefined) delete process.env.LG_TEST_MODE;
    if (saved[1] === undefined) delete process.env.LG_TEST_PS_FAIL;
  }
  for (let i = 0; i < 100 && detach.check(h).state !== "done"; i++) await sleep(50);
  assert.equal(detach.check(h).state, "done");
});

// ── B중1: 동기 명령 자식은 실행기와 함께 끝난다 ─────────────────────
test("B중1: 실행기가 SIGTERM 으로 끝나면 동기 run() 자식도 끈다(고아 0)", async (t) => {
  const sb = sandbox(t);
  const pidFile = path.join(sb.dir, "child.pid");
  const hang = path.join(sb.dir, "hang.mjs");
  fs.writeFileSync(hang, `require("node:fs").writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); setInterval(() => {}, 1000);\n`.replace('require("node:fs")', '(await import("node:fs")).default'));
  const reg = writeRegistry(sb, { "test.hang": { bin: NODE, argv: [hang], modes: ["shadow", "live"], timeoutSec: 600 } });
  const g = `${LG}
const State = Annotation.Root({ out: Annotation() });
export const input = () => ({});
export const summarize = (v) => String(v.out);
export function build({ checkpointer, tools }) {
  return new StateGraph(State)
    .addNode("x", async () => ({ out: (await tools.run("test.hang", {})).code }))
    .addEdge(START, "x").addEdge("x", END)
    .compile({ checkpointer });
}
`;
  appWith(sb, { hang: g });
  const child = spawn(NODE, [path.join(sb.dir, "app", "run.mjs"), "start", "hang", "h1"], { env: { ...tickEnv(sb), LG_CMD_REGISTRY: reg } });
  const closed = new Promise((r) => child.on("close", r));
  let pid = null;
  for (let i = 0; i < 200 && !pid; i++) { await sleep(50); try { pid = Number(fs.readFileSync(pidFile, "utf8")); } catch { /* 아직 */ } }
  assert.ok(pid > 0, "자식이 떠야 한다");
  child.kill("SIGTERM");
  await closed;
  const alive = () => { try { process.kill(pid, 0); return true; } catch { return false; } };
  for (let i = 0; i < 100 && alive(); i++) await sleep(50);
  assert.equal(alive(), false, "동기 명령 자식이 고아로 남으면 안 된다");
});

// ── B하1·B하2·B하3 ───────────────────────────────────────────────
test("B하1~3: 비밀류 환경변수 이름(PAT·WEBHOOK·URL) 금지 · 쓰기 도구는 작업 폴더 필수 · metrics 에 effect key 원문 없음", async (t) => {
  const sb = sandbox(t);
  for (const k of ["GITHUB_PAT", "DISCORD_WEBHOOK", "DATABASE_URL", "AWS_CREDENTIALS"]) {
    const f = path.join(sb.dir, `r-${k}.json`);
    fs.writeFileSync(f, JSON.stringify({ version: 1, commands: { "x.cmd": { bin: "/bin/echo", argv: [], modes: ["shadow"], envPass: [k] } } }));
    assert.throws(() => loadRegistry(f), /비밀류/, k);
  }
  const cfg = loadConfig({ HOME: sb.home, LG_STATE_DIR: sb.state, LG_CLAUDE_BIN: fakeClaude(sb).bin });
  const store = new Store(cfg);
  t.after(() => store.close());
  const llm = createClaude({ store, cfg, now: () => T0, thread: "w1" });
  await assert.rejects(llm.ask("고쳐", { model: "haiku", tools: ["Edit"] }), { name: "LlmModelBlocked", message: /작업 폴더/ });
  assert.equal(store.llmCounts(T0, "w1").thread, 0, "막힌 호출은 상한을 쓰지 않는다");
  const lines = [];
  const eff = createEffect({ cfg: { stateDir: sb.state, effectsPath: path.join(sb.state, "effects.jsonl") }, now: () => T0, thread: "e", mode: "shadow", metric: (ev, f) => lines.push(f) });
  await eff("commit:비밀스러운-이름", "commit", async () => {});
  assert.ok(lines.length === 1 && !JSON.stringify(lines).includes("비밀스러운"), JSON.stringify(lines));
});

// ── A중6: 판정 집계 ─────────────────────────────────────────────────
test("A중6: 집계 — M4 는 대기열·답 받은 스레드도 세고, M1 은 사람이 답 안 한 승인 만료를 '버려짐'으로 안 세고, M3 는 verify 뒤 재실행을 중복으로 안 센다", (t) => {
  const sb = sandbox(t);
  fs.mkdirSync(sb.state, { recursive: true });
  const old = Date.now() - 300 * HOUR;
  const ev = (o) => JSON.stringify({ ts: "x", ...o });
  fs.writeFileSync(path.join(sb.state, "metrics.jsonl"), [
    ev({ t: old, ev: "start", thread: "q-old" }), // 대기열에서 300시간
    ev({ t: old, ev: "answered", thread: "ans-old" }), // 답 받고 300시간
    ev({ t: old, ev: "interrupted", thread: "i1" }), ev({ t: old + 1, ev: "node_end", ok: true, thread: "i1" }), ev({ t: old + 2, ev: "waiting", thread: "i1" }),
    ev({ t: old + 3, ev: "expired", kind: "approval", thread: "i1" }), // 이어 갔고 사람이 답하지 않음
    ev({ t: old, ev: "interrupted", thread: "i2" }), ev({ t: old + 1, ev: "gave_up", thread: "i2" }), // 이어 가지 못함
  ].join("\n") + "\n");
  fs.writeFileSync(path.join(sb.state, "effects.jsonl"), [
    { key: "k1", mode: "live", status: "started" }, { key: "k1", mode: "live", status: "cleared", verified: false },
    { key: "k1", mode: "live", status: "started" }, { key: "k1", mode: "live", status: "ok" },
  ].map((o) => JSON.stringify({ t: old, ...o })).join("\n") + "\n");
  const rep = JSON.parse(spawnSync(NODE, [path.join(ROOT, "lg-report.mjs"), "--json"], { env: sb.env, encoding: "utf8" }).stdout);
  assert.deepEqual(rep.m4.list.sort(), ["ans-old", "q-old"]);
  assert.deepEqual([rep.m1.interrupted, rep.m1.continued, rep.m1.abandoned, rep.m1.rate], [2, 1, 1, "50%"]);
  assert.equal(rep.m3.duplicates, 0);
});
