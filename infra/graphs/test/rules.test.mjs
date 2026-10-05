// rules.test.mjs — 0b 입구·규칙: 그래프 정적 검사(양성·음성), 명령 허용 목록(S15 포함), run() 입구, effect()(그림자·실제·중복·결과 모름),
// 사용자 훅 누수 자가 시험, gc 가 판정 기록을 지우지 않음, 관문 해석, lg-report 집계. 임시 폴더에서만.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { sandbox, run, appWith, fakeClaude, counts, at, T0, DAY, HOUR, NODE, ROOT } from "./helpers.mjs";
import { tickEnv, writeRegistry, writeUsage, metrics, effects, lineCount, CMD_FIXTURE, FX, STEPS } from "./helpers0b.mjs";
import { checkGraphSource, checkGraphFile } from "../scripts/check-graph-rules.mjs";
import { loadRegistry, resolveCommand, createRun } from "../lib/run.mjs";
import { createEffect } from "../lib/effects.mjs";
import { parseUsage, quietGate, diskGate } from "../lib/gates.mjs";
import { classifyLlmFailure } from "../lib/claude.mjs";
import { loadConfig } from "../lib/config.mjs";

const HEAD = `import { StateGraph, interrupt } from "@langchain/langgraph";\n`;
function reg(sb) { return loadRegistry(writeRegistry(sb)); }
const rules = (src, r, file = "g.mjs") => checkGraphSource(src, file, r).map((p) => p.rule).sort();

test("정적 검사 양성: child_process(정적·동적·require)·process.binding·목록 밖 cmdId·글자값 아닌 cmdId·effect 밖 부수효과·Store·네트워크", (t) => {
  const r = reg(sandbox(t));
  assert.deepEqual(rules(`${HEAD}import { execFileSync } from "node:child_process";\nconst g = x.addNode("a", (s) => ({}));`, r), ["child-process"]);
  assert.deepEqual(rules(`${HEAD}const g = x.addNode("a", async (s) => { const cp = await import("child_process"); return {}; });`, r), ["child-process"]);
  assert.deepEqual(rules(`${HEAD}const cp = require("node:child_process");`, r), ["child-process"]);
  assert.deepEqual(rules(`${HEAD}const w = process.binding("spawn_sync");`, r), ["child-process"]);
  assert.deepEqual(rules(`${HEAD}const g = x.addNode("a", (s) => tools.run("git.push", {}));`, r), ["cmd-unknown"]);
  assert.deepEqual(rules(`${HEAD}const id = "test.echo";\nconst g = x.addNode("a", (s) => tools.run(id, {}));`, r), ["cmd-literal"]);
  assert.deepEqual(rules(`${HEAD}const g = x.addNode("a", (s) => tools.run(\`test.\${s.x}\`, {}));`, r), ["cmd-literal"]);
  assert.deepEqual(rules(`${HEAD}const g = x.addNode("a", async (s) => { await tools.run("test.append", { file: "/tmp/x" }); return {}; });`, r), ["effect-scope"]);
  assert.deepEqual(rules(`${HEAD}const g = x.addNode("a", (s) => tools.launch("nope.cmd", {}));`, r), ["cmd-unknown"]);
  assert.deepEqual(rules(`import { InMemoryStore } from "@langchain/langgraph";\nconst store = new InMemoryStore();`, r), ["store", "store"]);
  assert.deepEqual(rules(`${HEAD}const app = g.compile({ checkpointer, store: s });`, r), ["store"]);
  assert.deepEqual(rules(`${HEAD}const g = x.addNode("a", async (s) => { await fetch("http://127.0.0.1:18789/rpc"); return {}; });`, r), ["network"]);
  assert.deepEqual(rules(`${HEAD}import http from "node:http";`, r), ["network"]);
});

test("정적 검사 음성: 허용 목록 cmdId·effect 안 부수효과·문자열·주석 속 낱말은 통과, 실제 graphs/ 위반 0(CLI 종료 0)", (t) => {
  const r = reg(sandbox(t));
  const ok = `${HEAD}// child_process 나 fetch( 는 주석일 뿐 — run("git.push") 도
const note = "child_process InMemoryStore fetch(";
const g = x
  .addNode("a", async (s) => ({ out: (await tools.run("test.echo", { word: "hi" })).stdout }))
  .addNode("b", async (s) => tools.effect("commit:1", "commit", () => tools.run("test.append", { file: "/tmp/x" })))
  .addNode("c", (s) => ({ job: tools.launch("test.sleep", { ms: "10", file: "/tmp/y" }, { node: "c", attempt: 1 }) }))
  .addNode("d", async (s) => ({ text: (await llm.ask("요약")).text, job: llm.launchAsk("고쳐", { node: "d" }) }));`;
  assert.deepEqual(checkGraphSource(ok, "ok.mjs", r), []);
  const cli = spawnSync(NODE, [path.join(ROOT, "scripts", "check-graph-rules.mjs")], { cwd: ROOT, encoding: "utf8" });
  assert.equal(cli.status, 0, cli.stdout);
  assert.match(cli.stdout, /^OK graph-rules 파일 \d+개 · 명령 \d+개 허용 · 위반 0/);
});

test("정적 검사: 가져온 모듈까지 따라간다 — 도우미에 숨긴 child_process, 실행기 내부(lib/) 가져오기는 위반", (t) => {
  const sb = sandbox(t);
  const r = reg(sb);
  fs.mkdirSync(path.join(sb.dir, "helpers"));
  fs.writeFileSync(path.join(sb.dir, "helpers", "sh.mjs"), `import { spawnSync } from "node:child_process";\nexport const sh = (c) => spawnSync(c);\n`);
  const g = path.join(sb.dir, "g.mjs");
  fs.writeFileSync(g, `${HEAD}import { sh } from "./helpers/sh.mjs";\nconst x = y.addNode("a", (s) => ({ o: sh("ls") }));\n`);
  assert.deepEqual(checkGraphFile(g, r).map((p) => p.rule), ["child-process"]);
  const g2 = path.join(ROOT, "graphs", "__lib_import_probe.mjs");
  fs.writeFileSync(g2, `${HEAD}import { createRun } from "../lib/run.mjs";\nconst x = y.addNode("a", (s) => ({}));\n`);
  t.after(() => fs.rmSync(g2, { force: true }));
  assert.deepEqual(checkGraphFile(g2, r).map((p) => p.rule), ["lib-import"]);
});

test("실행기는 규칙 위반 그래프를 열지 않는다 — 수동 start 는 ERROR(1), 틱은 코드 결함 HOLD(0)", (t) => {
  const sb = sandbox(t);
  const bad = STEPS.replace('import fs from "node:fs";', 'import fs from "node:fs";\nimport { execSync } from "node:child_process";');
  const lg = appWith(sb, { badsteps: bad });
  const env = tickEnv(sb);
  const s = lg(env, ["start", "badsteps", "b1"]);
  assert.equal(s.code, 1);
  assert.match(s.first, /^ERROR b1 internal 그래프 규칙 위반 1건\(graphs\/badsteps\.mjs:\d+ child-process\)/);
  // 대기열에 들어간 뒤 그래프가 망가지면: 틱은 HOLD(code_defect)
  const lg2 = appWith(sb, { later: STEPS });
  assert.equal(lg2(env, ["start", "later", "b2", "--queue"]).code, 0);
  fs.writeFileSync(path.join(sb.dir, "app", "graphs", "later.mjs"), bad);
  const r = lg2(env, ["tick"]);
  assert.equal(r.code, 0);
  assert.equal(r.first, "NO_REPLY");
  const v = JSON.parse(lg2(env, ["status", "b2", "--json"]).out);
  assert.equal(v.status, "held");
  assert.equal(v.hold, "code_defect");
  assert.deepEqual(counts(sb), {});
});

test("허용 목록 검사(S15): OpenClaw CLI·셸·env·인터프리터 즉석 코드·비밀 환경변수·그림자 부수효과는 목록에 올릴 수 없다", (t) => {
  const sb = sandbox(t);
  const bad = (cmd) => {
    const f = path.join(sb.dir, `r-${Math.random().toString(36).slice(2)}.json`);
    fs.writeFileSync(f, JSON.stringify({ version: 1, commands: { "x.cmd": { modes: ["shadow"], ...cmd } } }));
    return () => loadRegistry(f);
  };
  assert.throws(bad({ bin: "/Users/me/bin/openclaw", argv: ["automations", "list"] }), /OpenClaw/);
  assert.throws(bad({ bin: "/usr/bin/git", argv: ["-C", "/x", "openclaw"] }), /OpenClaw CLI 금지/);
  assert.throws(bad({ bin: NODE, argv: ["/usr/local/lib/node_modules/openclaw/dist/cli.js", "cron"] }), /OpenClaw CLI 금지/);
  assert.doesNotThrow(bad({ bin: "/usr/bin/git", argv: ["-C", path.join(os.homedir(), ".openclaw-data/runtime/graphs/gostop/sandbox/s1"), "status"] }), "경로에 .openclaw 가 든 인자는 정상");
  assert.throws(bad({ bin: "/bin/sh", argv: ["-c", "ls"] }), /셸·env/);
  assert.throws(bad({ bin: "/usr/bin/env", argv: ["node"] }), /셸·env/);
  assert.throws(bad({ bin: NODE, argv: ["-e", "1"] }), /즉석 코드/);
  assert.throws(bad({ bin: NODE, argv: ["{script}"], params: { script: "^.*$" } }), /고정된 절대경로/);
  assert.throws(bad({ bin: "/bin/echo", argv: ["{a}"], params: { a: "x" } }), /\^…\$/);
  assert.throws(bad({ bin: "/bin/echo", argv: ["pre{a}"], params: { a: "^x$" } }), /항목 전체/);
  assert.throws(bad({ bin: "/bin/echo", argv: [], envPass: ["GITHUB_TOKEN"] }), /비밀류/);
  assert.throws(bad({ bin: "/usr/bin/git", argv: [], effect: true }), /그림자 모드에 올리지 않는다/);
  assert.throws(bad({ bin: "echo", argv: [] }), /절대경로/);
  assert.throws(bad({ bin: "/bin/echo", argv: [], timeoutSec: 60, maxSeconds: 60 }), /maxSeconds/, "최대 시간은 시간 제한보다 커야 한다");
  assert.throws(bad({ bin: "/bin/echo", argv: [], maxSeconds: 100_000 }), /maxSeconds/);
  const withMax = bad({ bin: "/bin/echo", argv: [], timeoutSec: 60, maxSeconds: 90 })();
  assert.equal(resolveCommand(withMax, "x.cmd", {}, { mode: "shadow", scratch: sb.dir }).maxMs, 90_000);
  assert.equal(resolveCommand(bad({ bin: "/bin/echo", argv: [] })(), "x.cmd", {}, { mode: "shadow", scratch: sb.dir }).maxMs, null, "없으면 null(실행기가 LG_DETACH_MAX_SEC)");
  assert.equal(Object.keys(loadRegistry(path.join(ROOT, "cmd-registry.json")).commands).every((id) => !/openclaw/i.test(id)), true);
  const { LG_TEST_MODE, ...prod } = sb.env;
  assert.throws(() => loadConfig({ ...prod, LG_CMD_REGISTRY: "/tmp/x.json" }), /시험 모드/);
});

test("run() 입구: 목록 밖·모드 밖·effect 밖·형식 밖 인자는 거부, 허용된 것은 셸 없이 실행하고 출력을 돌려준다, 시간 초과는 끈다", async (t) => {
  const sb = sandbox(t);
  const r = loadRegistry(writeRegistry(sb, { "test.slow": { bin: "/bin/sleep", argv: ["5"], modes: ["shadow"], timeoutSec: 1 } }));
  const cfg = { stateDir: sb.state };
  const shadow = createRun({ cfg, registry: r, thread: "r1", mode: "shadow" });
  await assert.rejects(shadow("nope.x"), { name: "CmdNotAllowed", message: /허용 목록에 없는/ });
  await assert.rejects(shadow("test.liveonly"), { name: "CmdNotAllowed", message: /shadow 모드에서 허용되지 않는다/ });
  await assert.rejects(shadow("test.echo", { word: "a; rm -rf /" }), { name: "CmdNotAllowed", message: /형식에 맞지 않는다/ });
  await assert.rejects(shadow("test.echo", { word: "hi", extra: "1" }), { message: /모르는 인자/ });
  const out = await shadow("test.echo", { word: "hello" });
  assert.equal(out.code, 0);
  assert.equal(out.stdout, "hello\n");
  const slow = await shadow("test.slow");
  assert.equal(slow.timedOut, true);
  const live = createRun({ cfg, registry: r, thread: "r1", mode: "live" });
  await assert.rejects(live("test.append", { file: path.join(sb.dir, "x") }), { message: /effect\(key, kind, fn\) 안에서만/ });
  assert.equal(fs.existsSync(path.join(sb.dir, "x")), false);
  assert.throws(() => resolveCommand(r, "test.append", { file: "/tmp/x" }, { mode: "shadow", inEffect: true }), /shadow 모드에서 허용되지 않는다/);
});

test("effect: 그림자는 wouldRun 만 적고 실행하지 않는다 · 실제는 한 번 · 같은 key 재실행 0 · 실패는 다시 · 결과 모름은 보류", async (t) => {
  const sb = sandbox(t);
  const cfg = { stateDir: sb.state, effectsPath: path.join(sb.state, "effects.jsonl") };
  let n = 0;
  const fn = async () => { n++; return "ok"; };
  const shadow = createEffect({ cfg, now: () => T0, thread: "e1", mode: "shadow" });
  assert.deepEqual(await shadow("commit:a", "commit", fn), { ran: false, shadow: true });
  await shadow("commit:a", "commit", fn);
  assert.equal(n, 0, "그림자는 실행하지 않는다");
  assert.deepEqual(effects(sb).map((e) => [e.key, e.status, e.wouldRun]), [["commit:a", "would_run", true]], "같은 key 는 한 줄");
  const live = createEffect({ cfg, now: () => T0, thread: "e1", mode: "live" });
  assert.equal((await live("commit:a", "commit", fn)).ran, true, "그림자 기록은 실제 실행을 막지 않는다");
  assert.deepEqual(await live("commit:a", "commit", fn), { ran: false, dedup: true });
  const other = createEffect({ cfg, now: () => T0, thread: "e2", mode: "live" });
  assert.deepEqual(await other("commit:a", "commit", fn), { ran: false, dedup: true }, "다른 스레드라도 같은 key 는 다시 안 한다");
  assert.equal(n, 1);
  await assert.rejects(live("push:b", "push", async () => { throw new Error("원격 거부"); }), /원격 거부/);
  assert.equal((await live("push:b", "push", fn)).ran, true, "실패한 것은 다시 한다");
  assert.equal(n, 2);
  fs.appendFileSync(cfg.effectsPath, `${JSON.stringify({ key: "deploy:c", kind: "deploy", mode: "live", status: "started", thread: "gone" })}\n`);
  await assert.rejects(live("deploy:c", "deploy", fn), { name: "EffectHeld" });
  assert.equal(n, 2, "결과 모르는 부수효과는 다시 내지 않는다");
  assert.deepEqual(await live("deploy:c", "deploy", fn, { verify: async () => true }), { ran: false, recovered: true });
  assert.deepEqual(await live("deploy:c", "deploy", fn), { ran: false, dedup: true });
  await assert.rejects(live("bad\nkey", "commit", fn), TypeError);
  await assert.rejects(live("k", "Commit!", fn), TypeError);
  // 동시에 같은 key: 둘 중 하나만 실행
  let m = 0;
  const slowFn = async () => { m++; await new Promise((r) => setTimeout(r, 300)); };
  await Promise.all([live("tag:d", "tag", slowFn), other("tag:d", "tag", slowFn)]);
  assert.equal(m, 1);
});

test("그래프 안 effect: 그림자로 시작한 스레드는 LIVE 를 켜도 그림자(모드 고정), 실제 스레드는 한 번만 — 노드가 다시 돌아도", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { fx: FX });
  const file = path.join(sb.dir, "fx.txt");
  const env = { ...tickEnv(sb), LG_CMD_REGISTRY: writeRegistry(sb), LG_TEST_FX_FILE: file };
  assert.match(lg(env, ["start", "fx", "s1", "--topic", "k1", "--queue"]).first, /^OK s1 queued shadow/);
  fs.writeFileSync(path.join(sb.state, "LIVE"), "");
  assert.match(lg(env, ["tick"]).first, /^DONE s1 shadow:shadow$/);
  assert.equal(lineCount(file), 0, "그림자는 실행하지 않는다");
  assert.deepEqual(effects(sb).map((e) => [e.key, e.mode, e.status]), [["commit:k1", "shadow", "would_run"]]);
  // 실제: effect 뒤에 노드가 실패 → 다음 틱에 노드가 다시 돌아도 부수효과는 한 번
  assert.match(lg(env, ["start", "fx", "l1", "--topic", "k2", "--queue"]).first, /^OK l1 queued live/);
  assert.equal(lg({ ...env, LG_TEST_FAIL_AFTER_EFFECT: "1" }, ["tick"]).first, "NO_REPLY");
  assert.equal(lineCount(file), 1);
  assert.match(lg(env, ["tick"]).first, /^DONE l1 live:dedup$/);
  assert.equal(lineCount(file), 1, "같은 key 는 다시 실행하지 않는다");
  assert.equal(counts(sb).act, 3);
  const m = metrics(sb).filter((e) => e.ev === "effect").map((e) => `${e.thread}:${e.outcome}`);
  assert.deepEqual(m, ["s1:would_run", "l1:ran", "l1:dedup"]);
});

test("S6 자가 시험: 사용자 훅 로그에 graphs 쪽 claude 호출 흔적이 있으면 selftest·tick 이 ERROR(1)로 멈춘다", (t) => {
  const sb = sandbox(t);
  const hook = path.join(sb.dir, "stop-mistake-extract.log");
  fs.writeFileSync(hook, `[2026-10-03 15:50:38] [stop-mistake-extract] start cwd=${path.join(os.homedir(), ".openclaw/workspace")}
`);
  const env = { ...tickEnv(sb), LG_HOOK_LOGS: hook };
  assert.match(run(env, ["selftest"]).first, /^OK selftest .* 훅 누수 0\(1개 로그\)/);
  assert.equal(run(env, ["tick"]).first, "NO_REPLY");
  fs.appendFileSync(hook, "[2026-10-04 10:00:00] [stop-mistake-extract] start cwd=/var/folders/ab/T/lg-claude-cwd-501\n");
  const s = run(env, ["selftest"]);
  assert.equal(s.code, 1);
  assert.match(s.first, /^ERROR - selftest 사용자 훅 로그 .* graphs 쪽 claude 호출 흔적 1줄/);
  const tk = run(env, ["tick"]);
  assert.equal(tk.code, 1);
  assert.match(tk.first, /^ERROR - selftest /);
});

test("S17: gc 는 판정 기록(metrics·effects)을 지우지 않는다, 지운 스레드의 분리 실행 폴더는 지운다", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { fx: FX });
  const env = { ...tickEnv(sb), LG_CMD_REGISTRY: writeRegistry(sb), LG_TEST_FX_FILE: path.join(sb.dir, "fx.txt") };
  assert.equal(lg(env, ["start", "fx", "g1", "--topic", "k1"], at(T0)).code, 0);
  fs.mkdirSync(path.join(sb.state, "jobs", "g1", "n", "1"), { recursive: true });
  const before = [fs.statSync(path.join(sb.state, "metrics.jsonl")).size, fs.statSync(path.join(sb.state, "effects.jsonl")).size];
  const r = lg(env, ["gc", "--days", "1"], at(T0 + 15 * DAY));
  assert.match(r.first, /^OK gc deleted=1 /);
  assert.deepEqual([fs.statSync(path.join(sb.state, "metrics.jsonl")).size, fs.statSync(path.join(sb.state, "effects.jsonl")).size], before);
  assert.equal(fs.existsSync(path.join(sb.state, "jobs", "g1")), false);
  for (const f of ["metrics.jsonl", "effects.jsonl"]) assert.equal(fs.statSync(path.join(sb.state, f)).mode & 0o777, 0o600, f);
});

test("관문 해석: 감지기 스냅샷 모양·자정 넘는 야간 구간·디스크 계산식·로그인/한도 문구", (t) => {
  const sb = sandbox(t);
  const real = parseUsage("# 자비스 오케스트레이터 스냅샷 — 2026-10-03 14:00 KST\n\n| 클로드 사용량 | session 45% · week (all models) 69% · week (Fable) 100% |\n");
  assert.equal(real.at, Date.parse("2026-10-03T14:00:00+09:00"));
  assert.equal(real.maxWeekly, 69, "Fable 주간(100%)은 빼고 본다 — 쓰지 않는 모델");
  assert.equal(parseUsage("| 클로드 사용량 | session 99% |").maxWeekly, null, "주간 줄이 없으면 못 읽음");
  const g = { quiet: [23 * 60, 2 * 60] };
  assert.ok(quietGate(g, new Date(2026, 0, 1, 23, 30).getTime()));
  assert.ok(quietGate(g, new Date(2026, 0, 1, 1, 0).getTime()));
  assert.equal(quietGate(g, new Date(2026, 0, 1, 2, 0).getTime()), null);
  const fake = () => ({ bavail: 17 * 2 ** 18, bsize: 4096 }); // 17GiB
  assert.equal(diskGate({ diskPath: "/", diskFloorGiB: 15, copyEstGiB: 1, diskMarginGiB: 1 }, fake), null, "17 = 15 + 1 + 1 이면 통과");
  assert.match(diskGate({ diskPath: "/", diskFloorGiB: 15, copyEstGiB: 1.5, diskMarginGiB: 1 }, fake).detail, /17\.0GiB < 17\.5GiB/);
  assert.equal(classifyLlmFailure("API Error: 401 OAuth token has expired"), "login");
  assert.equal(classifyLlmFailure("Claude AI usage limit reached|1760000000"), "usage_limit");
  assert.equal(classifyLlmFailure("API Error: 429 rate_limit_error"), "usage_limit", "429 는 로그인 고장이 아니다(09-30 오판 전례)");
  assert.equal(classifyLlmFailure("가짜 실패: 인증 오류 흉내"), null);
  const cfg = loadConfig({ HOME: sb.home, LG_STATE_DIR: sb.state });
  assert.equal(cfg.gates.diskFloorGiB + cfg.gates.copyEstGiB + cfg.gates.diskMarginGiB, 16.2, "기본 관문 = 15 + 사본 실측 0.2(1a, 10-03) + 1");
  assert.deepEqual(cfg.gates.quiet, [90, 270]);
  assert.equal(cfg.tickBudgetMs, 480_000);
  assert.equal(cfg.lockStuckMs, 30 * 60_000);
});

test("lg-report: 끊김→이어서 끝냄(M1)·부수효과(M3)·만료(M4)·토큰(M6)을 표로, M2·M5·M8 은 칸을 낸다", (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb, "tokens");
  const env = { ...tickEnv(sb), LG_CLAUDE_BIN: fake.bin };
  // 끊김: think 에서 한 번 죽는다 → 틱이 잇는다 → 대기 → 답 → 틱이 끝낸다
  const crash = { extraEnv: { LG_SMOKE_CRASH_ONCE: path.join(sb.dir, "crash.marker") } };
  assert.match(run(env, ["start", "smoke", "m1", "--llm"], crash).first, /^ERROR m1 crashed /);
  assert.match(run(env, ["tick"], crash).first, /^WAITING m1 /);
  assert.equal(run(env, ["answer", "m1", "approved"]).code, 0);
  assert.match(run(env, ["tick"]).first, /^DONE m1 /);
  assert.equal(run(env, ["start", "smoke", "m2"], at(Date.now() - 50 * HOUR)).code, 0);
  run(env, ["tick"]); // m2 만료 보고
  const rep = spawnSync(NODE, [path.join(ROOT, "lg-report.mjs")], { env, encoding: "utf8" });
  assert.equal(rep.status, 0, rep.stderr);
  for (const h of ["## M1", "## M3", "## M4", "## M6", "## M2", "## M5", "## M8"]) assert.ok(rep.stdout.includes(h), h);
  assert.match(rep.stdout, /\| 1 \| 1 \| 1 \| 0 \| 0 \| 100% \|/, "M1: 끊긴 1 · 이어 감 1 · 끝냄 1");
  const j = JSON.parse(spawnSync(NODE, [path.join(ROOT, "lg-report.mjs"), "--json"], { env, encoding: "utf8" }).stdout);
  assert.deepEqual([j.m1.interrupted, j.m1.continued, j.m1.finished, j.m1.rate], [1, 1, 1, "100%"]);
  assert.equal(j.m4.expired_reported, 1);
  assert.equal(j.m4.abandoned_unreported, 0);
  assert.equal(j.m6.days[0].total, 1350, "LLM 1회(끊김은 호출 전 — 다시 돌 때 한 번) × 1350 토큰");
  assert.equal(j.m6.fable_calls, 0);
  assert.equal(j.m2.done, 1);
  assert.equal(j.m5.requests, 2);
  assert.equal(j.m3.duplicates, 0);
});

test("R12: 틱 안의 LLM·명령 시간 제한은 잡 상한(600초)까지 남은 시간 안으로 줄고, 30초도 못 남으면 다음 틱으로(pending)", async (t) => {
  const { fitTimeout } = await import("../lib/claude.mjs");
  assert.equal(fitTimeout(300_000, null), 300_000, "틱 밖(수동 명령)은 그대로");
  assert.equal(fitTimeout(300_000, () => 200_000), 180_000, "남은 200초 − 여유 20초");
  assert.equal(fitTimeout(60_000, () => 500_000), 60_000);
  assert.throws(() => fitTimeout(300_000, () => 45_000), (e) => e.pending === true);
  const sb = sandbox(t);
  const r = loadRegistry(writeRegistry(sb));
  const tight = createRun({ cfg: { stateDir: sb.state }, registry: r, thread: "r2", mode: "shadow", timeLeft: () => 40_000 });
  await assert.rejects(tight("test.echo", { word: "hi" }), (e) => e.pending === true);
  const roomy = createRun({ cfg: { stateDir: sb.state }, registry: r, thread: "r2", mode: "shadow", timeLeft: () => 400_000 });
  assert.equal((await roomy("test.echo", { word: "hi" })).stdout, "hi\n");
});
