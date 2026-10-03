// detach.test.mjs — 분리 실행(띄우기 → 확인): 판정 3종, (스레드, 노드, 시도) 이중 실행 잠금, heartbeat, 부모가 죽어도 자식은 산다,
// 최대 시간 초과·시간 제한 때 묶음째 끄기(손주까지), LLM 분리 실행(토큰은 한 번만 적음). 실제 프로세스로 돈다. 상태는 임시 폴더.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";
import { sandbox, fakeClaude, NODE, ROOT, T0 } from "./helpers.mjs";
import { CMD_FIXTURE, metrics } from "./helpers0b.mjs";
import * as detach from "../lib/detach.mjs";
import { createClaude } from "../lib/claude.mjs";
import { loadConfig } from "../lib/config.mjs";
import { Store } from "../lib/store.mjs";
import { createMetrics } from "../lib/metrics.mjs";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 15_000) {
  const end = Date.now() + ms;
  for (;;) { const v = fn(); if (v) return v; if (Date.now() > end) return null; await sleep(50); }
}
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
const spec = (ms, file) => ({ bin: NODE, argv: [CMD_FIXTURE, "sleep", String(ms), file], cwd: "/", env: { PATH: "/usr/bin:/bin" }, timeoutMs: 60_000, heartbeatSec: 1 });

test("판정 3종: 진행 중(running) → 끝(done, 결과는 원자적으로) / 껍데기가 결과 없이 죽으면 dead(남은 자식도 끈다)", async (t) => {
  const sb = sandbox(t);
  const jobs = path.join(sb.state, "jobs");
  const out = path.join(sb.dir, "a.txt");
  const h = detach.launch(jobs, { thread: "t1", node: "work", attempt: 1, cmdId: "test.sleep" }, spec(1500, out));
  const r1 = await until(() => { const s = detach.check(h); return s.state === "running" && s.pid ? s : null; });
  assert.ok(r1, "곧 running(pid 있음)");
  for (let i = 0; i < 20; i++) { const s = detach.check(h); assert.ok(["running", "done"].includes(s.state), JSON.stringify(s)); await sleep(20); } // 반쯤 쓴 결과를 읽지 않는다
  const d = await until(() => { const s = detach.check(h); return s.state === "done" ? s : null; });
  assert.equal(d.code, 0);
  assert.equal(detach.readOutput(h), "done 1500\n");
  const meta = JSON.parse(fs.readFileSync(path.join(h.dir, "meta.json"), "utf8"));
  assert.equal(meta.cmdId, "test.sleep");
  assert.ok(Number.isInteger(meta.pid) && meta.startedAt > 0);
  for (const f of fs.readdirSync(h.dir)) assert.equal(fs.statSync(path.join(h.dir, f)).mode & 0o777, 0o600, f);

  // 죽음: 껍데기를 SIGKILL — 결과 파일이 없으니 dead, 남은 자식(sleep)도 끈다
  const h2 = detach.launch(jobs, { thread: "t1", node: "work", attempt: 2, cmdId: "test.sleep" }, spec(30_000, path.join(sb.dir, "b.txt")));
  const m2 = await until(() => { try { const m = JSON.parse(fs.readFileSync(path.join(h2.dir, "meta.json"), "utf8")); return m.childPid ? m : null; } catch { return null; } });
  process.kill(m2.pid, "SIGKILL");
  await until(() => !alive(m2.pid));
  const dead = detach.check(h2);
  assert.equal(dead.state, "dead", JSON.stringify(dead));
  assert.ok(await until(() => !alive(m2.childPid), 5000), "남은 자식도 끝나야 재시도와 겹치지 않는다");
  assert.equal(detach.check({ dir: path.join(jobs, "t1", "work", "9") }).state, "dead", "없는 작업은 dead");
});

test("(스레드, 노드, 시도) 잠금: 같은 시도를 두 번 띄워도 한 번만 돈다", async (t) => {
  const sb = sandbox(t);
  const jobs = path.join(sb.state, "jobs");
  const out = path.join(sb.dir, "count.txt");
  const s = { bin: NODE, argv: [CMD_FIXTURE, "append", out], cwd: "/", env: { PATH: "/usr/bin:/bin" }, timeoutMs: 10_000 };
  const ids = { thread: "t2", node: "build", attempt: 1, cmdId: "test.append" };
  const a = detach.launch(jobs, ids, s);
  const b = detach.launch(jobs, ids, s);
  assert.equal(a.already, undefined);
  assert.equal(b.already, true);
  assert.equal(a.dir, b.dir);
  await until(() => detach.check(a).state === "done");
  await sleep(300);
  assert.equal(fs.readFileSync(out, "utf8").split("\n").filter(Boolean).length, 1, "한 번만 실행");
  assert.throws(() => detach.launch(jobs, { ...ids, node: "../x" }, s), /이름이 이상하다/);
  assert.throws(() => detach.launch(jobs, { ...ids, attempt: 0 }, s), /attempt/);
});

test("heartbeat 는 주기마다 갱신된다(시험은 1초)", async (t) => {
  const sb = sandbox(t);
  const h = detach.launch(path.join(sb.state, "jobs"), { thread: "t3", node: "hb", attempt: 1, cmdId: "test.sleep" }, spec(3500, path.join(sb.dir, "c.txt")));
  const hb = path.join(h.dir, "heartbeat");
  const first = await until(() => { try { return JSON.parse(fs.readFileSync(hb, "utf8")).t; } catch { return null; } });
  const second = await until(() => { try { const v = JSON.parse(fs.readFileSync(hb, "utf8")).t; return v > first ? v : null; } catch { return null; } }, 5000);
  assert.ok(second > first, "1초 주기로 다시 쓴다");
  const st = detach.check(h);
  assert.equal(st.state, "running");
  assert.ok(st.heartbeatAgeMs < 3000, String(st.heartbeatAgeMs));
  await until(() => detach.check(h).state === "done");
});

test("부모(띄운 프로세스)가 SIGKILL 로 죽어도 분리 실행 자식은 끝까지 돌고 결과를 남긴다", async (t) => {
  const sb = sandbox(t);
  const jobs = path.join(sb.state, "jobs");
  const out = path.join(sb.dir, "survived.txt");
  const dirFile = path.join(sb.dir, "dir.txt");
  const code = `const d = await import(${JSON.stringify(pathToFileURL(path.join(ROOT, "lib", "detach.mjs")).href)});
const h = d.launch(${JSON.stringify(jobs)}, { thread: "p1", node: "long", attempt: 1, cmdId: "test.sleep" },
  { bin: ${JSON.stringify(NODE)}, argv: [${JSON.stringify(CMD_FIXTURE)}, "sleep", "2000", ${JSON.stringify(out)}], cwd: "/", env: { PATH: "/usr/bin:/bin" }, timeoutMs: 60000 });
require("node:fs").writeFileSync(${JSON.stringify(dirFile)}, h.dir);
setTimeout(() => process.kill(process.pid, "SIGKILL"), 300);`.replace('require("node:fs")', '(await import("node:fs")).default');
  const parent = spawn(NODE, ["--input-type=module", "-e", code], { stdio: "ignore" });
  const exit = await new Promise((r) => parent.on("exit", (c, s) => r(s)));
  assert.equal(exit, "SIGKILL", "부모는 죽었다");
  const dir = fs.readFileSync(dirFile, "utf8");
  const meta = await until(() => { try { return JSON.parse(fs.readFileSync(path.join(dir, "meta.json"), "utf8")); } catch { return null; } });
  assert.ok(meta.pid !== parent.pid);
  const done = await until(() => { const s = detach.check(dir); return s.state === "done" ? s : null; }, 10_000);
  assert.ok(done, "자식이 결과를 남겨야 한다");
  assert.equal(done.code, 0);
  assert.equal(fs.readFileSync(out, "utf8"), "slept");
});

// 손주가 준비되면 쓰는 "자식pid 손주pid"(cmd-fixture tree → hang)
const treePids = (file) => until(() => { try { return fs.readFileSync(file, "utf8").split(" ").map(Number); } catch { return null; } });

test("최대 시간(설계 §6): 시작 + maxMs 를 넘기면 살아 있어도 묶음째 끈다 — SIGTERM 을 무시한 손주까지(SIGKILL), dead(timeout)", async (t) => {
  const sb = sandbox(t);
  const pidsFile = path.join(sb.dir, "tree.pids");
  const h = detach.launch(path.join(sb.state, "jobs"), { thread: "m1", node: "work", attempt: 1, cmdId: "test.tree" },
    { bin: NODE, argv: [CMD_FIXTURE, "tree", pidsFile, "term-ignore"], cwd: "/", env: { PATH: "/usr/bin:/bin" }, timeoutMs: 60_000, maxMs: 120_000 });
  const [child, grand] = await treePids(pidsFile);
  const meta = JSON.parse(fs.readFileSync(path.join(h.dir, "meta.json"), "utf8"));
  assert.equal(meta.childPid, child, "손주의 부모는 명령(자식)이다");
  // 시간 주입: 한계 1ms 전은 running(끄지 않는다), 한계에 닿으면 timeout
  const before = detach.check(h, { now: meta.startedAt + 120_000 - 1 });
  assert.equal(before.state, "running", JSON.stringify(before));
  assert.equal(before.deadline, meta.startedAt + 120_000);
  assert.ok([meta.pid, child, grand].every(alive), "아직 셋 다 산다");
  const t0 = Date.now();
  const st = detach.check(h, { now: meta.startedAt + 120_000, killGraceMs: 500 });
  assert.equal(st.state, "dead", JSON.stringify(st));
  assert.equal(st.reason, "timeout");
  assert.equal(st.signal, "SIGKILL", "손주가 SIGTERM 을 무시해 유예 뒤 SIGKILL 까지 갔다");
  assert.ok(Date.now() - t0 < 8000, "유예만큼만 기다린다");
  for (const p of [grand, child, meta.pid]) assert.ok(await until(() => !alive(p), 5000), `남은 프로세스 ${p}`);
  assert.equal(detach.check(h).reason, "timeout", "다시 확인해도 timeout — 끄는 사이 껍데기가 쓴 결과보다 표식이 이긴다");
});

test("껍데기 시간 제한(timeoutMs)으로 끝날 때도 묶음째 — SIGTERM 을 무시한 손주도 남지 않는다(done, timedOut)", async (t) => {
  const sb = sandbox(t);
  const pidsFile = path.join(sb.dir, "tree2.pids");
  const h = detach.launch(path.join(sb.state, "jobs"), { thread: "m2", node: "work", attempt: 1, cmdId: "test.tree" },
    { bin: NODE, argv: [CMD_FIXTURE, "tree", pidsFile, "term-ignore"], cwd: "/", env: { PATH: "/usr/bin:/bin" }, timeoutMs: 3000 });
  const [child, grand] = await treePids(pidsFile);
  assert.ok(alive(grand), "손주가 떴다");
  const d = await until(() => { const s = detach.check(h); return s.state === "done" ? s : null; }, 20_000);
  assert.ok(d, "결과를 남긴다");
  assert.equal(d.timedOut, true);
  for (const p of [grand, child]) assert.ok(await until(() => !alive(p), 5000), `남은 프로세스 ${p}`);
});

test("LLM 분리 실행: launchAsk → checkAsk(running → done), 같은 시도는 한 번만 띄우고 상한도 한 번만, 토큰은 한 번만 기록", async (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb, "slow"); // 1.5초 뒤 답
  const cfg = loadConfig({ HOME: sb.home, LG_STATE_DIR: sb.state, LG_CLAUDE_BIN: fake.bin });
  const store = new Store(cfg);
  t.after(() => store.close());
  const metric = createMetrics({ file: cfg.metricsPath, now: () => T0 });
  const llm = createClaude({ store, cfg, now: () => T0, thread: "L1", metric });
  const h = llm.launchAsk("요약하라", { model: "haiku", node: "fix", attempt: 1 });
  const again = llm.launchAsk("요약하라", { model: "haiku", node: "fix", attempt: 1 });
  assert.equal(again.already, true);
  assert.equal(JSON.parse(fs.readFileSync(path.join(h.dir, "spec.json"), "utf8")).maxMs, 1_350_000, "LLM 최대 시간은 시간 제한(15분)의 1.5배");
  assert.equal(store.llmCounts(T0, "L1").thread, 1, "같은 시도는 상한을 한 번만 쓴다");
  assert.equal(llm.checkAsk(h).state === "running" || llm.checkAsk(h).state === "done", true);
  const d = await until(() => { const s = llm.checkAsk(h); return s.state === "done" ? s : null; });
  assert.equal(d.text, "가짜 요약 문장");
  llm.checkAsk(h);
  metric.close();
  const llmLines = metrics(sb).filter((e) => e.ev === "llm");
  assert.equal(llmLines.length, 1, "토큰은 한 번만 적는다");
  assert.equal(llmLines[0].detached, true);
  assert.equal(fake.calls().length, 1);
  assert.deepEqual(fake.calls()[0].args.slice(0, 2), ["-p", "--restricted"]);
});

test("LLM 분리 실행 실패는 던지지 않고 failed(종류) — 로그인 만료면 관문 표식을 남긴다", async (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb, "auth");
  const cfg = loadConfig({ HOME: sb.home, LG_STATE_DIR: sb.state, LG_CLAUDE_BIN: fake.bin });
  const store = new Store(cfg);
  t.after(() => store.close());
  const llm = createClaude({ store, cfg, now: () => T0, thread: "L2" });
  const h = llm.launchAsk("x", { model: "haiku", node: "n", attempt: 1 });
  const r = await until(() => { const s = llm.checkAsk(h); return s.state !== "running" ? s : null; });
  assert.equal(r.state, "failed");
  assert.equal(r.kind, "login");
  assert.equal(JSON.parse(fs.readFileSync(cfg.llmHoldPath, "utf8")).reason, "login");
});
