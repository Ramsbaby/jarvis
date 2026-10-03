// gostop-qa 그래프 — 가짜 일꾼(fake-gqa)·가짜 claude 로 책갈피·재개·분기·effect 중복 막기를 본다. 실호출 없음.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { sandbox, run, fakeClaude, NODE, FIXTURES } from "./helpers.mjs";
import { tickEnv, effects } from "./helpers0b.mjs";
import os from "node:os";
import { appendOrder, lastJson, input } from "../graphs/gostop-qa.mjs";
import { loadRegistry } from "../lib/run.mjs";

const FAKE = path.join(FIXTURES, "fake-gqa.mjs");
const RUN = "^[A-Za-z0-9._-]{1,80}$";
const DAY = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$";

// 실제 허용 목록과 같은 cmdId·같은 자리 표시 — bin 만 가짜 일꾼으로
function registry(sb) {
  const c = (argv, params = {}) => ({ bin: NODE, argv: [FAKE, ...argv], params, modes: ["shadow", "live"], timeoutSec: 60, maxSeconds: 90, envPass: ["FAKE_GQA_DIR"] });
  const commands = {
    "gostop.qa-gate": c(["gate"]),
    "gostop.qa-build": c(["build", "--rev", "{rev}"], { rev: "^[A-Za-z0-9._/-]{1,60}$" }),
    "gostop.qa-emu-up": c(["emu-up"]),
    "gostop.qa-emu-down": c(["emu-down"]),
    "gostop.qa-install": c(["install", "--apk", "{apk}"], { apk: "^/[A-Za-z0-9._/-]+\\.apk$" }),
    "gostop.qa-play": c(["play", "--run", "{run}", "--seed", "{seed}", "--games", "{games}", "--diffs", "{diffs}", "--rev", "{rev}"],
      { run: RUN, seed: "^[0-9]{1,9}$", games: "^[0-9]{1,2}$", diffs: "^[0-2](,[0-2]){0,5}$", rev: "^[0-9a-f]{7,40}$" }),
    "gostop.qa-analyze": c(["analyze", "--run", "{run}", "--day", "{day}"], { run: RUN, day: DAY }),
    "gostop.qa-eye-prompt": c(["eye-batch-prompt", "--batch", "{batch}", "--runs", "{runs}", "--stage", "{stage}", "--day", "{day}"],
      { batch: RUN, runs: "^[A-Za-z0-9._-]{1,80}(,[A-Za-z0-9._-]{1,80}){0,40}$", stage: "^(first|confirm)$", day: DAY }),
    "gostop.qa-eye-record": c(["eye-batch-record", "--batch", "{batch}", "--stage", "{stage}", "--day", "{day}"], { batch: RUN, stage: "^(first|confirm)$", day: DAY }),
    "gostop.qa-clip": c(["clip", "--run", "{run}", "--day", "{day}"], { run: RUN, day: DAY }),
    "gostop.qa-signal": c(["signal", "--run", "{run}", "--day", "{day}"], { run: RUN, day: DAY }),
    "gostop.qa-cleanup": c(["cleanup", "--run", "{run}"], { run: RUN }),
  };
  const file = path.join(sb.dir, "reg.json");
  fs.writeFileSync(file, JSON.stringify({ version: 1, commands }));
  return file;
}

function setup(t, { live = false } = {}) {
  const sb = sandbox(t);
  const fake = path.join(sb.dir, "fake");
  fs.mkdirSync(fake);
  const claude = fakeClaude(sb, "ok");
  const env = { ...tickEnv(sb), LG_CMD_REGISTRY: registry(sb), FAKE_GQA_DIR: fake, LG_CLAUDE_BIN: claude.bin,
    GQA_STATE: path.join(sb.home, "qa-state"), GQA_ORDERS: path.join(sb.home, "orders.md") };
  if (live) { fs.mkdirSync(sb.state, { recursive: true }); fs.writeFileSync(path.join(sb.state, "LIVE"), ""); }
  const calls = () => (fs.existsSync(path.join(fake, "calls.jsonl")) ? fs.readFileSync(path.join(fake, "calls.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l)) : []);
  return { sb, env, fake, calls, claude };
}

// 끝날 때까지 틱(분리 실행은 다음 틱이 확인한다)
async function tickUntilDone(env, thread, max = 60) {
  for (let i = 0; i < max; i++) {
    const r = run(env, ["tick", "--verbose"]);
    if (r.lines.some((l) => l.startsWith(`DONE ${thread}`))) return { ticks: i + 1, line: r.lines.find((l) => l.startsWith(`DONE ${thread}`)) };
    if (r.lines.some((l) => /^(GAVE_UP|ERROR|EXPIRED)/.test(l))) throw new Error(r.out + r.err);
    await new Promise((res) => setTimeout(res, 250));
  }
  throw new Error(`${max}틱 안에 끝나지 않음`);
}

test("순수 함수 — 입력 기본값·마지막 JSON 줄·지시함 한 번만", (t) => {
  const i = input({ games: "20", day: "2026-10-03" });
  assert.equal(i.games, 20);
  assert.equal(i.perLaunch, 5);
  assert.equal(i.eyeEvery, 2, "20판·5판씩 = 4묶음 → 눈 검사 2번(스레드 LLM 상한 5회 안: 2 × (1차 + 확인) = 4)");
  assert.deepEqual(lastJson("잡소리\n{\"a\":1}\n끝"), { a: 1 });
  assert.deepEqual(lastJson("x\n{\"a\":1}\n{\"b\":2}"), { b: 2 });
  const sb = sandbox(t);
  const f = path.join(sb.dir, "orders.md");
  fs.writeFileSync(f, "## 다른 절\n- [ ] 다른 일\n");
  assert.equal(appendOrder(f, "2026-10-03", "- [ ] 첫째 (id A1)", "A1"), true);
  assert.equal(appendOrder(f, "2026-10-03", "- [ ] 첫째 다시 (id A1)", "A1"), false, "같은 id 는 다시 쓰지 않는다");
  assert.equal(appendOrder(f, "2026-10-03", "- [ ] 둘째 (id B2)", "B2"), true);
  const txt = fs.readFileSync(f, "utf8");
  assert.equal(txt.split("## 고스톱 실기 QA 자동 — 2026-10-03").length, 2, "제목은 한 번");
  assert.match(txt, /- \[ \] 다른 일\n\n## 고스톱 실기 QA 자동 — 2026-10-03\n- \[ \] 첫째 \(id A1\)\n- \[ \] 둘째 \(id B2\)\n$/);
});

test("정상 흐름(그림자) — 4판·2판씩: 판 두 묶음, 묶음마다 눈 검사 1차+확인, 지시함은 '했을 일' 1번", async (t) => {
  const { env, calls, claude, sb } = setup(t);
  assert.match(run(env, ["start", "gostop-qa", "qa-t1", "--queue", "--games=4", "--per=2", "--seed=100", "--day=2026-10-03"]).first, /^OK qa-t1 queued shadow/);
  const done = await tickUntilDone(env, "qa-t1");
  assert.match(done.line, /판 4\/4/);
  const c = calls();
  const plays = c.filter((x) => x.cmd === "play");
  assert.deepEqual(plays.map((x) => [x.seed, x.games]), [["100", "2"], ["102", "2"]]);
  assert.equal(c.filter((x) => x.cmd === "analyze").length, 2);
  assert.equal(claude.calls().length, 4, "눈 검사 1차·확인 × 2묶음");
  assert.ok(claude.calls().every((x) => x.args.includes("--restricted")), "claude 는 --restricted 로만");
  assert.ok(claude.calls().every((x) => x.args.includes("Read")), "읽기 도구만");
  const eff = effects(sb).filter((e) => e.kind === "orders_append");
  assert.equal(eff.length, 1, "같은 발견 id 는 '했을 일'도 한 줄");
  assert.equal(fs.existsSync(env.GQA_ORDERS), false, "그림자 — 지시함을 쓰지 않는다");
  assert.ok(c.some((x) => x.cmd === "cleanup"), "눈 검사가 끝난 묶음은 원본을 지운다");
  assert.ok(c.at(-1).cmd === "emu-down", "끝나면 우리 에뮬레이터를 끈다");
});

test("책갈피 — 판 두기 중 기기가 사라지면 에뮬레이터부터 다시, 같은 판부터(끝난 판은 다시 두지 않는다)", async (t) => {
  const { env, calls, fake } = setup(t);
  fs.writeFileSync(path.join(fake, "die-once"), "");
  run(env, ["start", "gostop-qa", "qa-t2", "--queue", "--games=4", "--per=2", "--seed=200", "--day=2026-10-03"]);
  await tickUntilDone(env, "qa-t2");
  const c = calls();
  const seq = c.filter((x) => ["play", "emu-up"].includes(x.cmd)).map((x) => (x.cmd === "play" ? `play:${x.seed}` : "emu"));
  assert.deepEqual(seq, ["emu", "play:200", "emu", "play:200", "play:202"]);
});

test("관문 — 막히면 보류(판을 두지 않음), 풀리면 이어 간다", async (t) => {
  const { env, calls, fake } = setup(t);
  fs.writeFileSync(path.join(fake, "gate-hold"), "");
  run(env, ["start", "gostop-qa", "qa-t3", "--queue", "--games=2", "--per=2", "--seed=300", "--day=2026-10-03"]);
  for (let i = 0; i < 3; i++) run(env, ["tick"]);
  assert.equal(calls().filter((x) => x.cmd === "play").length, 0);
  const st = JSON.parse(run(env, ["status", "qa-t3", "--json"]).out);
  assert.equal(st.status, "held", JSON.stringify(st));
  fs.rmSync(path.join(fake, "gate-hold"));
  await tickUntilDone(env, "qa-t3");
  assert.equal(calls().filter((x) => x.cmd === "play").length, 1);
});

test("판 두기가 세 번 실패하면 그 판을 건너뛰고 다음 판으로(무한 반복 없음)", async (t) => {
  const { env, calls, fake } = setup(t);
  fs.writeFileSync(path.join(fake, "play-fail"), "");
  run(env, ["start", "gostop-qa", "qa-t4", "--queue", "--games=2", "--per=1", "--seed=400", "--day=2026-10-03"]);
  const d = await tickUntilDone(env, "qa-t4", 80);
  assert.match(d.line, /판 2\/2/);
  const plays = calls().filter((x) => x.cmd === "play").map((x) => x.seed);
  assert.deepEqual(plays, ["400", "400", "400", "401", "401", "401"]);
});

test("실제 모드 — 지시함에 하루 제목 아래 한 줄, 다음 스레드가 같은 발견을 내도 다시 쓰지 않는다", async (t) => {
  const { env } = setup(t, { live: true });
  run(env, ["start", "gostop-qa", "qa-t5", "--queue", "--games=1", "--per=1", "--seed=500", "--day=2026-10-03"]);
  await tickUntilDone(env, "qa-t5");
  run(env, ["start", "gostop-qa", "qa-t6", "--queue", "--games=1", "--per=1", "--seed=600", "--day=2026-10-03"]);
  await tickUntilDone(env, "qa-t6");
  const txt = fs.readFileSync(env.GQA_ORDERS, "utf8");
  assert.equal(txt.match(/id D1-aaaa\)/g)?.length, 1, txt);
  assert.match(txt, /## 고스톱 실기 QA 자동 — 2026-10-03/);
});

test("허용 목록의 '~/' 는 홈으로 펼친 뒤 같은 검사를 받는다(공개 저장소에 사용자 경로를 박지 않는다)", (t) => {
  const sb = sandbox(t);
  const f = path.join(sb.dir, "r.json");
  fs.writeFileSync(f, JSON.stringify({ version: 1, commands: { "x.py": { bin: "/opt/homebrew/bin/python3", argv: ["~/w/gqa.py", "gate"], modes: ["shadow"] } } }));
  assert.equal(loadRegistry(f).commands["x.py"].argv[0], path.join(os.homedir(), "w/gqa.py"));
  fs.writeFileSync(f, JSON.stringify({ version: 1, commands: { "x.sh": { bin: "~/bin/sh", argv: [], modes: ["shadow"] } } }));
  assert.throws(() => loadRegistry(f), /셸·env/, "펼친 뒤에도 셸 금지는 그대로");
  const real = loadRegistry(path.join(path.dirname(new URL(import.meta.url).pathname), "..", "cmd-registry.json"));
  for (const [id, c] of Object.entries(real.commands)) if (id.startsWith("gostop.qa-")) assert.ok(path.isAbsolute(c.argv[0]) && !c.argv[0].includes("~"), id);
});
