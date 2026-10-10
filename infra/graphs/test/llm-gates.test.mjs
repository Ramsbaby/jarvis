// LLM 예산 관문은 LLM 호출만 막는다 · 호출당·스레드당 토큰 상한 · 관문 보류 알림 되풀이(10-10 주간 감사).
//   10-09 token_cap 39틱 · 10-10 usage_high 29틱 동안 토큰을 쓰지 않는 QA 단계(빌드·판 두기·분석)까지 틱째 서서 매일 40판이 10판·0판에서 멈췄다.
//   10-09 01:00 opus 수정 호출 하나가 47턴을 돌아 4,019,409 토큰(하루 상한 3,000,000)을 썼다 — 프롬프트는 4.5KB, 호출당 상한이 없었다.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { sandbox, run, at, T0, HOUR, DAY, counts, fakeClaude, appWith, statusJson } from "./helpers.mjs";
import { tickEnv, metrics, STEPS } from "./helpers0b.mjs";
import { claudeArgs, judge, createClaude, LlmModelBlocked } from "../lib/claude.mjs";
import { loadConfig } from "../lib/config.mjs";
import { Store } from "../lib/store.mjs";
import { spawnSync } from "node:child_process";
import { ROOT, NODE } from "./helpers.mjs";
import { findIssues, HELD_DAY_MAX } from "../scripts/lg-watch.mjs";

const MIN = 60_000;
const statusOf = (env, th, extra) => JSON.parse(run(env, ["status", th, "--json"], extra).out);
const hold = (sb, reason, atMs = Date.now()) => {
  fs.mkdirSync(sb.state, { recursive: true });
  fs.writeFileSync(path.join(sb.state, "llm-hold.json"), JSON.stringify({ reason, at: atMs }));
};

// LLM 을 막으려는 관문 다섯 — 걸렸을 때의 틱 환경
const LLM_GATES = [
  ["usage_high", (sb) => tickEnv(sb, { usage: { week: 85 } })],
  ["usage_unreadable", (sb) => ({ ...tickEnv(sb), LG_USAGE_FILE: path.join(sb.dir, "없음.md") })],
  ["usage_stale", (sb) => tickEnv(sb, { usage: { at: Date.now() - 14 * HOUR } })],
  ["login", (sb) => { hold(sb, "login"); return tickEnv(sb); }],
  ["usage_limit", (sb) => { hold(sb, "usage_limit"); return tickEnv(sb); }],
];

test("LLM 예산 관문만 걸리면 LLM 을 안 쓰는 일은 대기열에서 시작해 끝까지 간다 — 5종", (t) => {
  for (const [gate, setup] of LLM_GATES) {
    const sb = sandbox(t);
    assert.match(run(tickEnv(sb), ["start", "smoke", "n1", "--queue"]).first, /^OK n1 queued/);
    const env = setup(sb);
    const r = run(env, ["tick"]);
    assert.equal(r.code, 0, `${gate}: ${r.out}${r.err}`);
    assert.match(r.first, /^WAITING n1 /, `${gate}: LLM 없는 단계(collect·think)는 돌아 승인 대기까지 간다 — ${r.out}`);
    assert.deepEqual(counts(sb), { collect: 1, think: 1 }, gate);
    const ev = metrics(sb);
    assert.ok(!ev.some((e) => e.ev === "held" && e.scope === "tick"), `${gate}: 틱 전체 보류가 아니다`);
    assert.ok(ev.some((e) => e.ev === "held" && e.scope === "llm" && e.reasons.includes(gate)), `${gate}: LLM 관문이 걸렸다는 기록은 남는다`);
  }
});

test("LLM 예산 관문: LLM 을 부르려는 순간에만 그 스레드가 보류된다 — 앞 단계는 한 번만 돌고, 관문이 풀리면 이어 간다", (t) => {
  for (const [gate, setup] of LLM_GATES) {
    const sb = sandbox(t);
    const fake = fakeClaude(sb);
    assert.equal(run(tickEnv(sb), ["start", "smoke", "k1", "--llm", "--queue"]).code, 0);
    const env = { ...setup(sb), LG_CLAUDE_BIN: fake.bin };
    assert.equal(run(env, ["tick"]).first, "NO_REPLY", gate);
    const v = statusOf(env, "k1");
    assert.equal(v.status, "held", `${gate}: ${JSON.stringify(v)}`);
    assert.equal(v.hold, gate);
    assert.equal(v.fails, 0, "관문 보류는 재시도로 세지 않는다");
    assert.equal(fake.calls().length, 0, `${gate}: claude 를 부르지 않는다`);
    assert.deepEqual(counts(sb), { collect: 1, think: 1 }, `${gate}: collect 는 돌았고 think 는 호출 앞에서 섰다`);
    // 관문이 걸린 동안은 그 노드를 틱마다 되풀이하지 않는다
    assert.equal(run(env, ["tick"]).first, "NO_REPLY");
    assert.deepEqual(counts(sb), { collect: 1, think: 1 }, `${gate}: 걸린 동안 다시 돌지 않는다`);
    assert.equal(fake.calls().length, 0);
    // 풀림 — 사용량 정상·표식 없음
    fs.rmSync(path.join(sb.state, "llm-hold.json"), { force: true });
    const ok = { ...tickEnv(sb), LG_CLAUDE_BIN: fake.bin };
    assert.match(run(ok, ["tick"]).first, /^WAITING k1 .*가짜 요약 문장/, gate);
    assert.equal(fake.calls().length, 1);
    assert.equal(counts(sb).collect, 1, "앞 단계는 다시 돌지 않는다");
  }
});

test("하루 토큰 상한에 닿은 날에도 LLM 없는 일은 간다 — LLM 을 쓰는 스레드만 다음 날까지 보류", (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb, "tokens");
  const env = { ...tickEnv(sb, { now: T0 }), LG_CLAUDE_BIN: fake.bin, LG_DAY_TOKEN_CAP: "1000" };
  run(env, ["start", "smoke", "a1", "--llm", "--queue"], at(T0));
  assert.match(run(env, ["tick"], at(T0)).first, /^WAITING a1 /);
  assert.equal(statusJson({ ...sb, env }, at(T0)).llm.tokensToday, 1350, "상한 1000 을 넘겼다");
  run(env, ["start", "smoke", "n2", "--queue"], at(T0));
  run(env, ["start", "smoke", "k3", "--llm", "--queue"], at(T0));
  const r = run(env, ["tick"], at(T0 + 30 * MIN));
  assert.match(r.out, /^WAITING n2 /m, `LLM 없는 n2 는 간다 — ${r.out}`);
  const v = statusOf(env, "k3", at(T0 + 30 * MIN));
  assert.equal(v.status, "held");
  assert.equal(v.hold, "token_cap");
  assert.equal(fake.calls().length, 1, "상한을 넘긴 뒤에는 claude 를 부르지 않는다");
  const env2 = { ...tickEnv(sb, { now: T0 + DAY }), LG_CLAUDE_BIN: fake.bin, LG_DAY_TOKEN_CAP: "1000" };
  assert.match(run(env2, ["tick"], at(T0 + DAY)).out, /^WAITING k3 /m, "다음 날 이어 간다");
});

test("디스크·야간·멈춤 관문은 전처럼 틱 전체를 세운다 — LLM 관문이 같이 걸려도", (t) => {
  const two = new Date(2026, 9, 4, 2, 0).getTime();
  const cases = [
    ["disk", (sb) => ({ ...tickEnv(sb, { usage: { week: 85 } }), LG_DISK_FLOOR_GIB: "100000" }), {}],
    ["quiet", (sb) => ({ ...tickEnv(sb, { now: two, usage: { week: 85 } }), LG_QUIET: "01:30-04:30" }), at(two)],
  ];
  for (const [gate, setup, extra] of cases) {
    const sb = sandbox(t);
    run(tickEnv(sb), ["start", "smoke", "h1", "--queue"]);
    const env = setup(sb);
    assert.equal(run(env, ["tick"], extra).out, "NO_REPLY\n", gate);
    assert.deepEqual(counts(sb), {}, `${gate}: 노드가 돌면 안 된다`);
    const held = metrics(sb).filter((e) => e.ev === "held" && e.scope === "tick");
    assert.ok(held.some((e) => e.reasons.includes(gate) && e.reasons.includes("usage_high")), JSON.stringify(held));
  }
});

// a(LLM 없음) → b(LLM) → c(LLM 없음) → d(LLM): 스레드 하나가 LLM 을 두 번 부른다
const TWO_CALLS = `import fs from "node:fs";
import { StateGraph, Annotation, START, END } from "@langchain/langgraph";
const trace = (n) => { const f = process.env.LG_TEST_MODE === "1" && process.env.LG_SMOKE_TRACE; if (f) fs.appendFileSync(f, \`\${process.pid} \${n}\\n\`); };
const State = Annotation.Root({ log: Annotation({ reducer: (a, b) => a.concat(b), default: () => [] }) });
export const input = () => ({});
export const summarize = (v) => v.log.join(">");
export function build({ checkpointer, llm }) {
  return new StateGraph(State)
    .addNode("a", () => { trace("a"); return { log: ["a"] }; })
    .addNode("b", async () => { trace("b"); await llm.ask("요약하라: b", { model: "haiku", node: "b" }); return { log: ["b"] }; })
    .addNode("c", () => { trace("c"); return { log: ["c"] }; })
    .addNode("d", async () => { trace("d"); await llm.ask("요약하라: d", { model: "haiku", node: "d" }); return { log: ["d"] }; })
    .addEdge(START, "a").addEdge("a", "b").addEdge("b", "c").addEdge("c", "d").addEdge("d", END)
    .compile({ checkpointer });
}
`;

test("스레드당 하루 토큰 상한: 한 스레드가 제 몫을 다 쓰면 그 스레드만 다음 날까지 보류 — 다른 스레드는 부른다", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { two: TWO_CALLS });
  const fake = fakeClaude(sb, "tokens"); // 호출 하나에 1,350 토큰
  const env = { ...tickEnv(sb, { now: T0 }), LG_CLAUDE_BIN: fake.bin, LG_THREAD_DAY_TOKEN_CAP: "1000", LG_DAY_TOKEN_CAP: "1000000" };
  const st = (th, ms) => JSON.parse(lg(env, ["status", th, "--json"], at(ms)).out);
  lg(env, ["start", "two", "t1", "--queue"], at(T0));
  assert.equal(lg(env, ["tick"], at(T0)).first, "NO_REPLY");
  let v = st("t1", T0);
  assert.equal(v.status, "held", JSON.stringify(v));
  assert.equal(v.hold, "token_thread");
  assert.match(v.note, /스레드 하루 토큰 상한 1000/);
  assert.deepEqual(counts(sb), { a: 1, b: 1, c: 1, d: 1 }, "첫 호출(b)과 LLM 없는 c 까지 가고 둘째 호출(d) 앞에서 선다");
  assert.equal(fake.calls().length, 1);
  // 같은 날: 그 스레드는 다시 돌지 않고, 다른 스레드는 제 몫으로 부른다
  lg(env, ["start", "two", "t2", "--queue"], at(T0 + HOUR));
  lg(env, ["tick"], at(T0 + HOUR));
  assert.equal(counts(sb).d, 2, "t2 는 자기 d 앞에서 서고, t1 의 d 는 다시 돌지 않는다");
  assert.equal(fake.calls().length, 2, "t2 의 첫 호출은 된다");
  assert.equal(st("t1", T0 + HOUR).status, "held");
  // 다음 날: 이어 간다
  const env2 = { ...tickEnv(sb, { now: T0 + DAY }), LG_CLAUDE_BIN: fake.bin, LG_THREAD_DAY_TOKEN_CAP: "1000", LG_DAY_TOKEN_CAP: "1000000" };
  assert.match(lg(env2, ["tick"], at(T0 + DAY)).out, /^DONE t1 a>b>c>d$/m);
});

test("호출당 상한: claude 를 달러 어림 상한(--max-budget-usd)과 함께 부른다 — 기본 1달러, 호출마다 더 낮출 수만 있다", async (t) => {
  assert.deepEqual(claudeArgs("opus", ["Read"], { maxBudgetUsd: 1 }).slice(-4), ["--max-budget-usd", "1", "--tools", "Read"], "--tools 는 값을 여러 개 받아 맨 뒤");
  assert.ok(!claudeArgs("opus").includes("--max-budget-usd"), "값을 안 주면 붙이지 않는다");
  const sb = sandbox(t);
  const fake = fakeClaude(sb);
  assert.equal(loadConfig(sb.env).llm.callBudgetUsd, 1, "기본 1달러");
  const r = run(sb.env, ["start", "smoke", "b1", "--llm"], { extraEnv: { LG_CLAUDE_BIN: fake.bin } });
  assert.match(r.first, /^WAITING b1 /, r.out + r.err);
  const a = fake.calls()[0].args;
  assert.equal(a[a.indexOf("--max-budget-usd") + 1], "1", a.join(" "));
  // 호출 옵션으로는 낮추기만
  const cfg = loadConfig({ ...sb.env, LG_CLAUDE_BIN: fake.bin });
  const store = new Store(cfg);
  t.after(() => store.close());
  const llm = createClaude({ store, cfg, now: () => T0, thread: "u1" });
  await llm.ask("짧게", { model: "haiku", maxBudgetUsd: 0.25 });
  await llm.ask("짧게", { model: "haiku", maxBudgetUsd: 50 });
  const [, lo, hi] = fake.calls().map((c) => c.args[c.args.indexOf("--max-budget-usd") + 1]);
  assert.equal(lo, "0.25");
  assert.equal(hi, "1", "설정값보다 올리지 못한다");
});

test("호출당 상한에 닿아 CLI 가 멈춘 호출: 실패로 판정하되 쓴 토큰은 장부에 남긴다(10-10 실측 모양)", (t) => {
  // `claude -p --max-budget-usd 0.00001` 실측(2.1.285, 구독 로그인): 종료 1, 표준 출력은 아래 JSON — usage 는 0 이고 modelUsage 에 실제 값이 있다
  const out = JSON.stringify({ type: "result", subtype: "error_max_budget_usd", is_error: true, num_turns: 1, result: null, terminal_reason: "budget_exhausted",
    total_cost_usd: 0.003975, usage: { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
    modelUsage: { "claude-haiku-4-5-20251001": { inputTokens: 3640, outputTokens: 67, cacheReadInputTokens: 0, cacheCreationInputTokens: 0, costUSD: 0.003975 } } });
  const v = judge({ code: 1, signal: null, out, err: "", timedOut: false });
  assert.equal(v.ok, false);
  assert.equal(v.kind, "call_cap");
  assert.match(v.msg, /호출당 상한/);
  assert.equal(v.usage.in + v.usage.out, 3707, "잘린 호출이 쓴 토큰도 하루 상한에 센다");

  const sb = sandbox(t);
  const fake = fakeClaude(sb, "budget");
  const r = run({ ...sb.env, LG_CLAUDE_BIN: fake.bin }, ["start", "smoke", "c1", "--llm"]);
  assert.equal(r.code, 1);
  assert.match(r.first, /^ERROR c1 failed .*호출당 상한/);
  assert.equal(statusJson(sb).llm.tokensToday, 3707);
  assert.equal(metrics(sb).find((e) => e.ev === "llm").kind, "call_cap");
});

test("입력 크기 상한: 프롬프트가 한도(기본 10만 자)를 넘으면 부르지 않는다 — 코드 결함으로 보류", async (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb);
  const cfg = loadConfig({ ...sb.env, LG_CLAUDE_BIN: fake.bin });
  assert.equal(cfg.llm.maxPromptChars, 100_000);
  const store = new Store(cfg);
  t.after(() => store.close());
  const llm = createClaude({ store, cfg, now: () => T0, thread: "p1" });
  await assert.rejects(() => llm.ask("가".repeat(100_001), { model: "haiku" }), (e) => e instanceof LlmModelBlocked && /프롬프트가 100001자/.test(e.message));
  assert.throws(() => llm.launchAsk("가".repeat(100_001), { model: "haiku", node: "x" }), LlmModelBlocked);
  assert.equal(fake.calls().length, 0);
  assert.equal(store.llmCounts(T0, "p1").thread, 0, "자리도 잡지 않는다");
  await llm.ask("가".repeat(100_000), { model: "haiku" });
  assert.equal(fake.calls().length, 1);
});

test("관문 보류 알림: LLM 관문이 붙잡은 스레드도 30분이면 알리고, 같은 보류가 이어지면 3시간마다 다시 — 몇 번째인지·총 보류 시간", (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb);
  const envAt = (ms) => ({ ...tickEnv(sb, { now: ms, usage: { week: 85 } }), LG_CLAUDE_BIN: fake.bin });
  const tick = (ms) => run(envAt(ms), ["tick"], at(ms)).out;
  run(envAt(T0), ["start", "smoke", "k1", "--llm", "--queue"], at(T0));
  run(envAt(T0), ["start", "smoke", "n1", "--queue"], at(T0));
  const first = tick(T0);
  assert.match(first, /^WAITING n1 /m, "LLM 없는 n1 은 간다");
  assert.doesNotMatch(first, /STUCK/, "처음 보류는 알리지 않는다");
  assert.doesNotMatch(tick(T0 + 29 * MIN), /STUCK/);
  assert.match(tick(T0 + 31 * MIN), /^STUCK k1 관문 보류 31분째\(알림 1회째\) — 주간 사용량 85% ≥ 80% · 기다리는 일: k1$/m, "LLM 을 기다리는 스레드만 센다(n1 은 승인 대기)");
  assert.doesNotMatch(tick(T0 + 62 * MIN), /STUCK/, "3시간 안에는 다시 알리지 않는다");
  assert.doesNotMatch(tick(T0 + 210 * MIN), /STUCK/);
  assert.match(tick(T0 + 212 * MIN), /^STUCK k1 관문 보류 3시간 32분째\(알림 2회째\) — 주간 사용량/m, "첫 알림 3시간 뒤 다시");
  assert.doesNotMatch(tick(T0 + 300 * MIN), /STUCK/);
  assert.match(tick(T0 + 393 * MIN), /^STUCK k1 관문 보류 6시간 33분째\(알림 3회째\)/m);
  // 풀리면 처음부터 다시 잰다
  const ok = { ...tickEnv(sb, { now: T0 + 400 * MIN }), LG_CLAUDE_BIN: fake.bin };
  assert.match(run(ok, ["tick"], at(T0 + 400 * MIN)).out, /^WAITING k1 /m);
  assert.equal(fs.existsSync(path.join(sb.state, "hold-since.json")), false);
});

// 10-08 20:30~22:00 실측: 디스크(일하는 선)와 하루 토큰 상한이 같이 걸려 '시작한 일은 이어 간다'(10-05)가 꺼졌다 — 관문이 디스크 하나일 때만 켜졌기 때문
test("디스크(일하는 선)와 LLM 예산 관문이 같이 걸려도, 건강선을 지키면 시작한 일은 이어 가고 새 일만 막는다", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { steps: STEPS });
  const base = { ...tickEnv(sb), LG_TICK_BUDGET_SEC: "1.2", LG_TEST_STEP_MS: "1000" };
  const st = (env, th) => JSON.parse(lg(env, ["status", th, "--json"]).out);
  lg(base, ["start", "steps", "s1", "--queue"]);
  lg(base, ["tick"]);
  assert.equal(st(base, "s1").status, "continue", "관문 없이 시작해 이어가기 상태");
  const both = { ...tickEnv(sb, { usage: { week: 85 } }), LG_TICK_BUDGET_SEC: "1.2", LG_TEST_STEP_MS: "1000", LG_DISK_MARGIN_GIB: "100000" };
  lg(both, ["start", "steps", "q2", "--queue"]);
  let done = false;
  for (let i = 0; i < 6 && !done; i++) {
    assert.match(lg(both, ["tick", "--verbose"]).out, /HOLD disk: .* · usage_high: /);
    done = st(both, "s1").status === "done";
  }
  assert.ok(done, "시작한 s1 은 끝까지 간다");
  assert.equal(st(both, "q2").status, "queued", "새 일 q2 는 디스크 관문이 막는다");
});

test("지표: LLM 예산 관문이 걸린 채 돈 틱도 사유별 연속으로 세고(lg-report), 매일 감시(lg-watch)는 'LLM 호출이 막혔다'로 알린다", (t) => {
  const sb = sandbox(t);
  fs.mkdirSync(sb.state, { recursive: true });
  const now = Date.now(), rows = [];
  const at = (i) => ({ ts: new Date(now - (20 - i) * 30 * MIN).toISOString(), t: now - (20 - i) * 30 * MIN });
  for (let i = 0; i < 5; i++) { // 주간 사용량 관문이 걸린 채 돈 틱 5개
    rows.push({ ...at(i), ev: "held", scope: "llm", reasons: ["usage_high"], detail: "주간 사용량 82% ≥ 80%" });
    rows.push({ ...at(i), ev: "tick", ms: 10, threads: 1, outcome: "ran", llm_gates: ["usage_high"] });
  }
  fs.writeFileSync(path.join(sb.state, "metrics.jsonl"), rows.map((r) => JSON.stringify(r)).join("\n") + "\n");
  const report = () => JSON.parse(spawnSync(NODE, [path.join(ROOT, "lg-report.mjs"), "--json", "--hours", "24"], { env: sb.env, encoding: "utf8" }).stdout);
  let day = report();
  assert.equal(day.held.usage_high, 5);
  assert.deepEqual([day.held_streak.usage_high.max, day.held_streak.usage_high.current], [5, 5], "관문이 걸린 채 돈 틱은 연속을 끊지 않는다");
  fs.appendFileSync(path.join(sb.state, "metrics.jsonl"), `${JSON.stringify({ ...at(6), ev: "tick", ms: 10, threads: 0, outcome: "idle" })}\n`);
  day = report();
  assert.deepEqual([day.held_streak.usage_high.max, day.held_streak.usage_high.current], [5, 0], "관문이 풀린 틱이 끊는다");
  const base = { range: { since: new Date(now - 24 * HOUR).toISOString(), hours: 24 }, ticks: 6, held: {}, held_streak: {}, m1: { abandoned: 0 }, m2: { unverified: 0, unverified_list: [] },
    m3: { dup_list: [], unknown_list: [] }, m4: { abandoned_unreported: 0, list: [] }, m6: { fable_calls: 0 }, m7: { incidents: [] }, m8: { runs: 0, below: [], unmeasured: [] } };
  const issues = findIssues({ day: { ...base, held: day.held, held_streak: day.held_streak }, all: base, bench: base });
  assert.deepEqual(issues.map((x) => x.key), ["held:usage_high"], "연속 5틱 — 매일 감시가 올린다");
  assert.match(issues[0].detail, /LLM 호출이 막혔다 — LLM 을 안 쓰는 단계는 진행/);
  assert.ok(HELD_DAY_MAX > 5, "하루 횟수 기준이 아니라 연속 기준으로 걸린 것");
});
