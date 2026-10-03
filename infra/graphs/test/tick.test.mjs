// tick.test.mjs — 0b 틱 실행 방식: 예산·CONTINUE·answer·관문·만료·재시도·STUCK·알림 필터. 전부 임시 HOME·임시 상태 폴더, 실제 프로세스.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { sandbox, run, counts, openDb, appWith, fakeClaude, statusJson, at, T0, HOUR, NODE } from "./helpers.mjs";
import { tickEnv, writeRegistry, metrics, STEPS, FLAKY, DETACHED } from "./helpers0b.mjs";

const NOTIFY_OR_NOREPLY = /^(DONE|WAITING|EXPIRED|GAVE_UP|STUCK) |^NO_REPLY$/;
const statusOf = (lg, env, th, extra) => JSON.parse(lg(env, ["status", th, "--json"], extra).out);
const sum = (o) => Object.values(o).reduce((a, b) => a + b, 0);
const onlyNotify = (r) => r.lines.filter(Boolean).forEach((l) => assert.match(l, NOTIFY_OR_NOREPLY, `알림 필터 밖의 줄: ${l}`));

test("틱 예산: 다음 노드 앞에서 멈춰 CONTINUE(알림 없음), 다음 틱이 체크포인트에서 잇는다 — 노드는 각각 한 번", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { steps: STEPS });
  const env = { ...tickEnv(sb), LG_TICK_BUDGET_SEC: "1.2", LG_TEST_STEP_MS: "1000" };
  assert.match(lg(env, ["start", "steps", "s1", "--queue"]).first, /^OK s1 queued shadow/);
  const t0 = Date.now();
  const t1 = lg(env, ["tick"]);
  assert.equal(t1.code, 0, t1.out + t1.err);
  assert.equal(t1.out, "NO_REPLY\n", "CONTINUE 는 알리지 않는다");
  assert.ok(Date.now() - t0 < 1200 + 2 * 1000 + 3000, "예산 + 한 단계 남짓 안에 끝난다");
  const ran1 = sum(counts(sb));
  assert.ok(ran1 >= 1 && ran1 <= 2, `첫 틱은 예산 안에서 1~2 단계: ${JSON.stringify(counts(sb))}`);
  const v = statusOf(lg, env, "s1");
  assert.equal(v.status, "continue");
  assert.match(v.note, /틱 예산 소진 — 다음 노드\([bc]\) 앞에서 멈춤/);
  let done = null, ticks = 1;
  while (!done && ticks < 6) {
    const r = lg(env, ["tick"]);
    ticks++;
    assert.equal(r.code, 0);
    onlyNotify(r);
    if (/^DONE s1 a>b>c>d$/m.test(r.out)) done = r;
  }
  assert.ok(done, "몇 틱 안에 끝나야 한다");
  assert.ok(ticks >= 2, "한 틱에 다 돌면 예산 시험이 아니다");
  assert.deepEqual(counts(sb), { a: 1, b: 1, c: 1, d: 1 }, "이어 갈 때 앞 노드를 다시 돌리지 않는다");
  const m = metrics(sb);
  assert.ok(m.filter((e) => e.ev === "continue" && e.reason === "budget").length >= 1);
  assert.deepEqual(m.filter((e) => e.ev === "node_end" && e.ok).map((e) => e.node), ["a", "b", "c", "d"]);
  assert.ok(m.filter((e) => e.ev === "resumed" && e.from === "continue").length >= 1);
});

test("answer: 답만 1초 안에 기록(잠금이 잡혀 있어도) → 진행은 다음 틱이 Command(resume) 로", async (t) => {
  const sb = sandbox(t);
  const env = tickEnv(sb);
  assert.match(run(env, ["start", "smoke", "a1"]).first, /^WAITING a1 /);
  const db = await openDb(sb);
  t.after(() => db.close());
  db.prepare("INSERT INTO lg_locks(thread_id,pid,token,acquired_at) VALUES('a1',?,'tick',?)").run(process.pid, Date.now()); // 틱이 쥐고 있는 흉내
  const t0 = Date.now();
  const r = run(env, ["answer", "a1", "approved"]);
  const ms = Date.now() - t0;
  assert.equal(r.code, 0, r.out + r.err);
  assert.match(r.first, /^OK a1 answered approved — 다음 틱이 이어 간다/);
  assert.ok(ms < 1000, `answer 는 1초 안에: ${ms}ms`);
  assert.equal(counts(sb).finalize ?? 0, 0, "answer 는 진행하지 않는다");
  const v = JSON.parse(run(env, ["status", "a1", "--json"]).out);
  assert.equal(v.status, "waiting");
  assert.equal(v.answer, "approved");
  assert.equal(run(env, ["tick"]).first, "NO_REPLY", "잠금이 살아 있으면 틱도 건드리지 않는다");
  db.prepare("DELETE FROM lg_locks").run();
  const tk = run(env, ["tick"]);
  assert.equal(tk.code, 0);
  assert.match(tk.first, /^DONE a1 완료 — /);
  assert.equal(counts(sb).finalize, 1);
  const done = JSON.parse(run(env, ["status", "a1", "--json"]).out);
  assert.equal(done.status, "done");
  assert.equal(done.decision, "approved");
  assert.equal(done.answer, null, "적용한 답은 비운다");
  assert.match(run(env, ["answer", "a1", "approved"]).first, /^ERROR a1 not-waiting /);
  const m = metrics(sb);
  assert.equal(m.filter((e) => e.ev === "answered").length, 1);
  assert.equal(m.filter((e) => e.ev === "resumed" && e.from === "answer").length, 1);
});

test("answer 거절·멱등: 없는 스레드·기한 지남·다른 답은 1, 같은 답 되풀이는 0 — 기한 안에 적힌 답은 틱이 늦어도 적용", (t) => {
  const sb = sandbox(t);
  const env = tickEnv(sb, { now: T0 + 50 * HOUR });
  assert.match(run(env, ["answer", "nope", "approved"]).first, /^ERROR nope not-found /);
  assert.equal(run(env, ["answer", "nope", "maybe"]).code, 1);
  for (const th of ["w1", "w2", "w3"]) assert.equal(run(env, ["start", "smoke", th], at(T0)).code, 0);
  const late = run(env, ["answer", "w1", "approved"], at(T0 + 49 * HOUR));
  assert.equal(late.code, 1);
  assert.match(late.first, /^ERROR w1 expired /);
  assert.equal(run(env, ["answer", "w2", "approved"], at(T0 + 47 * HOUR)).code, 0);
  assert.equal(run(env, ["answer", "w2", "approved"], at(T0 + 47 * HOUR)).code, 0, "같은 답 되풀이는 괜찮다");
  const other = run(env, ["answer", "w2", "rejected"], at(T0 + 47 * HOUR));
  assert.equal(other.code, 1);
  assert.match(other.first, /^ERROR w2 already-answered /);
  // 틱은 기한(48h)이 지난 50h 에 온다 — w2 는 기한 안에 답했으니 진행, w1·w3 은 만료
  const tk = run(env, ["tick"], at(T0 + 50 * HOUR));
  assert.equal(tk.code, 0, tk.out);
  onlyNotify(tk);
  assert.ok(tk.lines.some((l) => /^DONE w2 완료/.test(l)), tk.out);
  assert.deepEqual(tk.lines.filter((l) => l.startsWith("EXPIRED")).map((l) => l.split(" ")[1]).sort(), ["w1", "w3"]);
});

test("옛 답은 새 질문에 쓰지 않는다 — 같은 노드의 둘째 질문은 틱이 WAITING 으로 한 번 알린다", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { twoq: `import { StateGraph, Annotation, START, END, interrupt } from "@langchain/langgraph";
const State = Annotation.Root({ first: Annotation(), second: Annotation() });
export const input = () => ({});
export const summarize = (v) => \`\${v.first}/\${v.second}\`;
export function build({ checkpointer }) {
  return new StateGraph(State)
    .addNode("ask", (s) => ({ first: interrupt({ question: "첫 질문?" }), second: interrupt({ question: "원격에 올릴까?" }) }))
    .addEdge(START, "ask").addEdge("ask", END)
    .compile({ checkpointer });
}
` });
  const env = tickEnv(sb);
  assert.match(lg(env, ["start", "twoq", "q1"]).first, /^WAITING q1 첫 질문\?/);
  assert.equal(lg(env, ["answer", "q1", "approved"]).code, 0);
  const t1 = lg(env, ["tick"]);
  assert.match(t1.first, /^WAITING q1 원격에 올릴까\? · 답: lg\.sh answer q1 approved\|rejected/);
  assert.equal(statusOf(lg, env, "q1").answer, null, "첫 답은 둘째 질문에 넘어가지 않는다");
  assert.equal(lg(env, ["tick"]).first, "NO_REPLY", "같은 질문은 다시 알리지 않는다");
  assert.equal(lg(env, ["answer", "q1", "rejected"]).code, 0);
  assert.match(lg(env, ["tick"]).first, /^DONE q1 approved\/rejected$/);
});

test("관문: 걸리면 HOLD(종료 0·NO_REPLY), 노드는 하나도 돌지 않고 사유는 metrics 에 — 7종", async (t) => {
  const cases = [
    ["paused", (sb, env) => { fs.mkdirSync(sb.state, { recursive: true }); fs.writeFileSync(path.join(sb.state, "PAUSED"), ""); return env; }],
    ["disk", (sb, env) => ({ ...env, LG_DISK_FLOOR_GIB: "100000" })],
    ["usage_high", (sb) => tickEnv(sb, { usage: { week: 85 } })],
    ["usage_unreadable", (sb, env) => ({ ...env, LG_USAGE_FILE: path.join(sb.dir, "없음.md") })],
    ["usage_unreadable", (sb) => tickEnv(sb, { usage: { row: false } })],
    ["usage_stale", (sb) => tickEnv(sb, { usage: { at: Date.now() - 7 * HOUR } })],
    ["login", (sb, env) => { fs.mkdirSync(sb.state, { recursive: true }); fs.writeFileSync(path.join(sb.state, "llm-hold.json"), JSON.stringify({ reason: "login", at: Date.now() })); return env; }],
    ["usage_limit", (sb, env) => { fs.mkdirSync(sb.state, { recursive: true }); fs.writeFileSync(path.join(sb.state, "llm-hold.json"), JSON.stringify({ reason: "usage_limit", at: Date.now() })); return env; }],
    ["quiet", (sb) => { const two = new Date(2026, 9, 4, 2, 0).getTime(); return { ...tickEnv(sb, { now: two }), LG_QUIET: "01:30-04:30", LG_NOW: String(two) }; }],
  ];
  for (const [gate, setup] of cases) {
    const sb = sandbox(t);
    assert.match(run(tickEnv(sb), ["start", "smoke", "g1", "--queue"]).first, /^OK g1 queued/);
    const env = setup(sb, tickEnv(sb));
    const r = run(env, ["tick"]);
    assert.equal(r.code, 0, `${gate}: ${r.out}${r.err}`);
    assert.equal(r.out, "NO_REPLY\n", gate);
    assert.deepEqual(counts(sb), {}, `${gate}: 노드가 돌면 안 된다`);
    const held = metrics(sb).filter((e) => e.ev === "held" && e.scope === "tick");
    assert.ok(held.some((e) => e.reasons.includes(gate)), `${gate}: ${JSON.stringify(held)}`);
    assert.equal(JSON.parse(run(env, ["status", "g1", "--json"]).out).status, "queued");
  }
});

test("관문: 하루 토큰 상한 — 응답 usage 로 센 토큰이 상한에 닿으면 다음 틱은 HOLD", (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb, "tokens");
  const env = { ...tickEnv(sb), LG_CLAUDE_BIN: fake.bin, LG_DAY_TOKEN_CAP: "1000" };
  assert.equal(run(env, ["start", "smoke", "k1", "--llm", "--queue"]).code, 0);
  assert.match(run(env, ["tick"]).first, /^WAITING k1 .*가짜 요약 문장/);
  assert.equal(statusJson({ ...sb, env }).llm.tokensToday, 1350, "입력 100 + 출력 50 + 캐시 생성 200 + 캐시 읽기 1000");
  assert.equal(run(env, ["start", "smoke", "k2", "--llm", "--queue"]).code, 0);
  assert.equal(run(env, ["tick"]).first, "NO_REPLY");
  assert.ok(metrics(sb).some((e) => e.ev === "held" && e.scope === "tick" && e.reasons.includes("token_cap")));
  assert.equal(fake.calls().length, 1, "상한을 넘긴 뒤에는 claude 를 부르지 않는다");
});

test("로그인 만료(오류 문구) → 재시도로 세지 않고 HOLD·표식, 다음 틱은 관문에서 쉼, 기다림이 지나면 한 번 다시 시도", (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb, "auth");
  const env = { ...tickEnv(sb), LG_CLAUDE_BIN: fake.bin };
  assert.equal(run(env, ["start", "smoke", "l1", "--llm", "--queue"]).code, 0);
  assert.equal(run(env, ["tick"]).first, "NO_REPLY");
  const v = JSON.parse(run(env, ["status", "l1", "--json"]).out);
  assert.equal(v.status, "held");
  assert.equal(v.hold, "login");
  assert.equal(v.fails, 0, "로그인 만료는 재시도 횟수에 넣지 않는다");
  assert.ok(fs.existsSync(path.join(sb.state, "llm-hold.json")));
  assert.equal(run(env, ["tick"]).first, "NO_REPLY");
  assert.equal(fake.calls().length, 1, "표식이 있는 동안은 부르지 않는다");
  // 6시간 뒤: 관문이 한 번 다시 시도하게 둔다(사용량 스냅샷도 그 시각 것으로)
  const later = Date.now() + 7 * HOUR;
  const env2 = { ...tickEnv(sb, { now: later }), LG_CLAUDE_BIN: fakeClaude(sb, "ok").bin };
  const r = run(env2, ["tick"], at(later));
  assert.match(r.first, /^WAITING l1 /, r.out);
  assert.equal(fs.existsSync(path.join(sb.state, "llm-hold.json")), false, "성공하면 표식을 지운다");
});

test("48시간 만료: 진척 없는 보류·대기열은 EXPIRED 로 알린다(시간 주입) — 관문에 막혀 있어도", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { flaky: FLAKY });
  const envAt = (ms, over = {}) => ({ ...tickEnv(sb, { now: ms }), ...over });
  assert.equal(lg(envAt(T0), ["start", "flaky", "h1", "--queue"], at(T0)).code, 0);
  assert.equal(lg(envAt(T0), ["start", "flaky", "h2", "--queue"], at(T0)).code, 0);
  // h1 은 보류된다(노드가 스스로 보류). h2 는 디스크 관문 때문에 시작도 못 한다
  const r1 = lg(envAt(T0, { LG_TEST_FAIL: "held" }), ["tick"], at(T0));
  assert.equal(r1.first, "NO_REPLY");
  assert.equal(statusOf(lg, envAt(T0), "h1", at(T0)).status, "held");
  assert.equal(lg(envAt(T0 + 47 * HOUR, { LG_DISK_FLOOR_GIB: "100000" }), ["tick"], at(T0 + 47 * HOUR)).first, "NO_REPLY");
  const r2 = lg(envAt(T0 + 49 * HOUR, { LG_DISK_FLOOR_GIB: "100000" }), ["tick"], at(T0 + 49 * HOUR));
  assert.equal(r2.code, 0);
  assert.deepEqual(r2.lines.map((l) => l.split(" ").slice(0, 2).join(" ")).sort(), ["EXPIRED h1", "EXPIRED h2"]);
  assert.match(r2.out, /보류 기한 초과로 자동 취소/);
  assert.equal(lg(envAt(T0 + 50 * HOUR), ["tick"], at(T0 + 50 * HOUR)).first, "NO_REPLY", "만료 알림은 한 번만");
  const ex = metrics(sb).filter((e) => e.ev === "expired");
  assert.deepEqual(ex.map((e) => [e.thread, e.kind]).sort(), [["h1", "hold"], ["h2", "hold"]]);
});

test("재시도: 같은 오류는 3회까지 다음 틱에 다시, 그다음 GAVE_UP 한 줄 — 이후 다시 돌리지 않는다", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { flaky: FLAKY });
  const env = { ...tickEnv(sb), LG_TEST_FAIL: "transient" };
  assert.equal(lg(env, ["start", "flaky", "f1", "--queue"]).code, 0);
  for (let i = 1; i <= 3; i++) {
    const r = lg(env, ["tick"]);
    assert.equal(r.code, 0, "노드 실패는 틱의 오류가 아니다");
    assert.equal(r.first, "NO_REPLY");
    assert.equal(statusOf(lg, env, "f1").fails, i);
  }
  const g = lg(env, ["tick"]);
  assert.equal(g.code, 0);
  assert.match(g.first, /^GAVE_UP f1 work 같은 오류 4회 — 일시 오류 흉내/);
  assert.equal(counts(sb).work, 4);
  assert.equal(lg(env, ["tick"]).first, "NO_REPLY");
  assert.equal(counts(sb).work, 4, "포기한 스레드는 다시 돌리지 않는다");
  assert.equal(statusOf(lg, env, "f1").status, "gave_up");
  const m = metrics(sb);
  assert.equal(m.filter((e) => e.ev === "failed").length, 3);
  assert.equal(m.filter((e) => e.ev === "gave_up").length, 1);
});

test("코드 결함(TypeError)은 재시도하지 않고 HOLD — 코드가 바뀌면 다시 해 본다", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { flaky: FLAKY });
  const env = { ...tickEnv(sb), LG_TEST_FAIL: "type" };
  assert.equal(lg(env, ["start", "flaky", "c1", "--queue"]).code, 0);
  assert.equal(lg(env, ["tick"]).first, "NO_REPLY");
  let v = statusOf(lg, env, "c1");
  assert.equal(v.status, "held");
  assert.equal(v.hold, "code_defect");
  assert.equal(lg(env, ["tick"]).first, "NO_REPLY");
  assert.equal(counts(sb).work, 1, "코드가 그대로면 다시 돌리지 않는다");
  const f = path.join(sb.dir, "app", "graphs", "flaky.mjs");
  fs.appendFileSync(f, "\n// 고침\n");
  assert.match(lg({ ...env, LG_TEST_FAIL: "" }, ["tick"]).first, /^DONE c1 ok$/);
  assert.equal(counts(sb).work, 2);
});

test("S1: 살아 있는 pid 의 잠금은 나이와 상관없이 넘겨받지 않는다 — STUCK 한 줄(한 번만), 그 스레드는 보류", async (t) => {
  const sb = sandbox(t);
  const env = tickEnv(sb);
  assert.match(run(env, ["start", "smoke", "k1"]).first, /^WAITING k1 /);
  assert.equal(run(env, ["answer", "k1", "approved"]).code, 0);
  const db = await openDb(sb);
  t.after(() => db.close());
  db.prepare("INSERT INTO lg_locks(thread_id,pid,token,acquired_at) VALUES('k1',?,'old',?)").run(process.pid, Date.now() - 7 * HOUR);
  const r = run(env, ["tick"]);
  assert.equal(r.code, 0);
  assert.match(r.first, /^STUCK k1 pid \d+ 가 4\d\d분째 잠금을 쥐고 있다/);
  assert.equal(counts(sb).finalize ?? 0, 0, "넘겨받지 않았다");
  assert.equal(run(env, ["tick"]).first, "NO_REPLY", "같은 잠금은 다시 알리지 않는다");
  const busy = run(env, ["resume", "k1", "approved"]);
  assert.equal(busy.code, 1);
  assert.match(busy.first, /^ERROR k1 busy .*STUCK/);
  assert.equal(db.prepare("SELECT pid FROM lg_locks WHERE thread_id='k1'").get().pid, process.pid, "잠금은 그대로");
  assert.ok(metrics(sb).some((e) => e.ev === "stuck" && e.thread === "k1"));
  db.prepare("DELETE FROM lg_locks").run();
  assert.match(run(env, ["tick"]).first, /^DONE k1 /);
});

test("끊김(SIGKILL — 종료 처리도 못 함)도 다음 틱이 잇는다: interrupted 기록 → 이어서 끝냄(M1)", async (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { steps: STEPS });
  const env = tickEnv(sb);
  assert.equal(lg(env, ["start", "steps", "x1", "--queue"]).code, 0);
  const child = spawn(NODE, [path.join(sb.dir, "app", "run.mjs"), "tick"], { env: { ...env, LG_TEST_STEP_MS: "20000" } });
  const closed = new Promise((r) => child.on("close", r));
  const until = Date.now() + 15_000;
  while (!counts(sb).a && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
  assert.equal(counts(sb).a, 1, "노드 a 가 돌기 시작해야 한다");
  child.kill("SIGKILL");
  await closed;
  assert.equal(statusOf(lg, env, "x1").status, "stalled", "주인 없는 실행 중 = 멈춤");
  const r = lg(env, ["tick"]);
  assert.match(r.first, /^DONE x1 a>b>c>d$/, r.out);
  assert.deepEqual(counts(sb), { a: 2, b: 1, c: 1, d: 1 }, "끊긴 노드만 다시 돈다");
  const m = metrics(sb);
  assert.ok(m.some((e) => e.ev === "interrupted" && e.thread === "x1" && e.cause === "stalled"));
  assert.ok(m.some((e) => e.ev === "done" && e.thread === "x1"));
});

test("알림 필터: 한 틱에 대기·실패·보류·이어가기가 섞여도 WAITING 만 나가고, 다음 틱은 NO_REPLY", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { flaky: FLAKY, steps: STEPS });
  const env = { ...tickEnv(sb), LG_TEST_FAIL: "transient", LG_TICK_BUDGET_SEC: "1.5", LG_TEST_STEP_MS: "500" };
  assert.equal(lg(env, ["start", "smoke", "n1", "--queue"]).code, 0);
  assert.equal(lg(env, ["start", "flaky", "n2", "--queue"]).code, 0);
  assert.equal(lg(env, ["start", "steps", "n3", "--queue"]).code, 0);
  const r = lg(env, ["tick"]);
  assert.equal(r.code, 0);
  onlyNotify(r);
  assert.deepEqual(r.lines.map((l) => l.split(" ").slice(0, 2).join(" ")), ["WAITING n1"], r.out);
  const v = lg(env, ["tick", "--verbose"]);
  assert.ok(v.lines.some((l) => /^(CONTINUE|ERROR|DONE) n[23] /.test(l)), `--verbose 는 다 보여 준다: ${v.out}`);
  assert.ok(!v.lines.some((l) => /^WAITING n1 /.test(l)), "같은 대기는 다시 알리지 않는다");
});

test("PAUSED: 틱·start·retry 는 진행하지 않고(0), answer·status 는 된다", (t) => {
  const sb = sandbox(t);
  const env = tickEnv(sb);
  assert.match(run(env, ["start", "smoke", "p1"]).first, /^WAITING p1 /);
  fs.writeFileSync(path.join(sb.state, "PAUSED"), "");
  assert.match(run(env, ["start", "smoke", "p2"]).first, /^HELD p2 PAUSED/);
  assert.equal(run(env, ["retry", "p1"]).code, 0);
  const a = run(env, ["answer", "p1", "approved"]);
  assert.equal(a.code, 0);
  assert.match(a.first, /PAUSED — 풀려야 진행/);
  assert.equal(run(env, ["tick"]).first, "NO_REPLY");
  assert.equal(counts(sb).finalize ?? 0, 0);
  assert.equal(statusJson({ ...sb, env }).switches.paused, true);
  fs.rmSync(path.join(sb.state, "PAUSED"));
  assert.match(run(env, ["tick"]).first, /^DONE p1 /);
});

test("분리 실행 그래프: 띄우기 → 확인(진행 중이면 CONTINUE, 재시도로 안 셈) → 끝나면 DONE, 같은 시도는 한 번만 띄운다", async (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { detached: DETACHED });
  const doneFile = path.join(sb.dir, "slept.txt");
  const env = { ...tickEnv(sb), LG_CMD_REGISTRY: writeRegistry(sb), LG_TEST_DONE_FILE: doneFile };
  assert.equal(lg(env, ["start", "detached", "d1", "--topic", "3000", "--queue"]).code, 0);
  assert.equal(lg(env, ["tick"]).first, "NO_REPLY");
  assert.equal(statusOf(lg, env, "d1").status, "continue");
  assert.equal(lg(env, ["tick"]).first, "NO_REPLY");
  assert.equal(counts(sb).start_job, 1, "띄우기 노드는 한 번");
  assert.equal(statusOf(lg, env, "d1").fails, 0, "진행 중은 실패가 아니다");
  await new Promise((r) => setTimeout(r, 3500));
  const r = lg(env, ["tick"]);
  assert.match(r.first, /^DONE d1 code=0 done 3000$/, r.out);
  assert.equal(fs.readFileSync(doneFile, "utf8"), "slept");
  const jobs = path.join(sb.state, "jobs", "d1", "work");
  assert.deepEqual(fs.readdirSync(jobs), ["1"], "시도 1 하나뿐");
  assert.ok(metrics(sb).filter((e) => e.ev === "continue" && e.reason === "pending").length >= 2);
});
