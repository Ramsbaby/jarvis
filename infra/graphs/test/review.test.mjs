// review.test.mjs — 반대편 검토(10-03)가 실행으로 보인 빈틈을 막았는지. 전부 임시 HOME·임시 상태 폴더.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import {
  sandbox, run, counts, readPending, statusJson, occurrences, openDb, appWith, fakeClaude,
  at, T0, HOUR, DAY,
} from "./helpers.mjs";

const LG = `import { StateGraph, Annotation, START, END, interrupt } from "@langchain/langgraph";\n`;

test("승인 대기가 동시에 2개면 받지 않는다 — 답 하나가 둘 다 승인하지 않게", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { multi: `${LG}
const State = Annotation.Root({ a: Annotation(), b: Annotation() });
export const input = () => ({});
export const summarize = (v) => \`a=\${v.a} b=\${v.b}\`;
export function build({ checkpointer }) {
  return new StateGraph(State)
    .addNode("ask_a", (s) => ({ a: interrupt("A 수정 반영?") }))
    .addNode("ask_b", (s) => ({ b: interrupt("B 수정 반영?") }))
    .addEdge(START, "ask_a").addEdge(START, "ask_b").addEdge("ask_a", END).addEdge("ask_b", END)
    .compile({ checkpointer });
}
` });
  const s = lg(sb.env, ["start", "multi", "p1"]);
  assert.equal(s.code, 1);
  assert.match(s.first, /^ERROR p1 multi-interrupt 승인 대기 2개가 .*A 수정 반영\? \/ B 수정 반영\?/);
  const r = lg(sb.env, ["resume", "p1", "approved"]);
  assert.equal(r.code, 1);
  assert.match(r.first, /^ERROR p1 multi-interrupt /);
  assert.doesNotMatch(r.out, /DONE/);
});

test("정적 중단점(검사기를 피해 넣은 것)으로 멈추면 blocked — retry 가 승인 없이 지나가지 않는다", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { brk: `${LG}
const State = Annotation.Root({ draft: Annotation(), published: Annotation() });
export const input = () => ({});
export const summarize = (v) => \`게시: \${v.published}\`;
export function build({ checkpointer }) {
  const key = ["interrupt", "Before"].join(""); // 실행기 방어를 시험하려고 검사기 눈을 피해 넣는다
  return new StateGraph(State)
    .addNode("write", (s) => ({ draft: "초안" }))
    .addNode("publish", (s) => ({ published: true }))
    .addEdge(START, "write").addEdge("write", "publish").addEdge("publish", END)
    .compile({ checkpointer, [key]: ["publish"] });
}
` });
  const s = lg(sb.env, ["start", "brk", "b1"]);
  assert.equal(s.code, 1);
  assert.match(s.first, /^ERROR b1 blocked /);
  const r = lg(sb.env, ["retry", "b1"]);
  assert.equal(r.code, 1);
  assert.match(r.first, /^ERROR b1 blocked /);
  assert.equal(lg(sb.env, ["resume", "b1", "approved"]).code, 1);
  assert.equal(JSON.parse(lg(sb.env, ["status", "b1", "--json"]).out).status, "blocked");
});

test("만료 알림은 사라지지 않는다: 명령이 실패해도 붙고, status 는 확정·소비하지 않는다", (t) => {
  const sb = sandbox(t);
  assert.equal(run(sb.env, ["start", "smoke", "e1"], at(T0)).code, 0);
  assert.equal(run(sb.env, ["start", "smoke", "e2"], at(T0)).code, 0);

  const st = run(sb.env, ["status", "e1"], at(T0 + 49 * HOUR));
  assert.match(st.first, /^EXPIRED e1 /, "status 는 기한 지남을 보여 준다");
  assert.equal(statusJson(sb, at(T0 + 49 * HOUR)).counts.expired, 2);

  const bad = run(sb.env, ["start", "nosuchgraph", "x1"], at(T0 + 49 * HOUR)); // 입력 오류여도
  assert.equal(bad.code, 1);
  assert.match(bad.first, /^ERROR x1 usage 그래프 없음/);
  assert.deepEqual(bad.lines.slice(1).map((l) => l.split(" ").slice(0, 2).join(" ")).sort(), ["EXPIRED e1", "EXPIRED e2"]);
  const sw = run(sb.env, ["sweep"], at(T0 + 49 * HOUR)); // 예약 알림은 그래도 나간다(다른 명령이 알림을 가로채지 않는다)
  assert.deepEqual(sw.lines.map((l) => l.split(" ").slice(0, 2).join(" ")).sort(), ["EXPIRED e1", "EXPIRED e2"]);
  assert.equal(run(sb.env, ["sweep"], at(T0 + 49 * HOUR)).first, "NO_REPLY", "sweep 이 알린 만료는 다시 알리지 않는다");
});

test("장부와 그래프가 어긋나도 기한은 그래프 기준: failed·끊김으로 적혀도 만료, 기한이 늘지 않는다", async (t) => {
  const sb = sandbox(t);
  for (const th of ["w1", "w2", "w3"]) assert.equal(run(sb.env, ["start", "smoke", th], at(T0)).code, 0);
  const db = await openDb(sb);
  t.after(() => db.close());
  db.prepare("UPDATE lg_threads SET status='failed', note='고장 흉내' WHERE thread_id='w1'").run(); // 대기 기록은 남음
  db.prepare("UPDATE lg_threads SET status='running' WHERE thread_id='w2'").run(); // 끊긴 실행(잠금 없음)
  db.prepare("UPDATE lg_threads SET status='running', interrupt_id=NULL, waiting_since=NULL, deadline_at=NULL WHERE thread_id='w3'").run(); // 대기 기록까지 잃음

  assert.equal(run(sb.env, ["sweep"], at(T0 + 47 * HOUR)).first, "NO_REPLY");
  assert.equal(JSON.parse(run(sb.env, ["status", "w3", "--json"], at(T0 + 47 * HOUR)).out).status, "waiting", "끊긴 스레드도 그래프 상태로 대기로 되돌린다");

  const r = run(sb.env, ["resume", "w2", "approved"], at(T0 + 52 * HOUR));
  assert.equal(r.code, 1);
  assert.match(r.first, /^ERROR w2 expired /);
  assert.ok(r.lines.some((l) => /^EXPIRED w1 /.test(l)), r.out);
  assert.equal(counts(sb).finalize ?? 0, 0, "기한 지난 승인은 마무리를 돌리지 않는다");
});

test("처음 보는 대기의 기한은 체크포인트 시각부터 — 기록이 빠진 뒤 늦게 발견해도 늘지 않는다(실시간)", async (t) => {
  const sb = sandbox(t);
  const env = { ...sb.env, LG_APPROVAL_TTL_HOURS: "0.0003" }; // 약 1.1초
  assert.equal(run(env, ["start", "smoke", "c1"]).code, 0);
  const db = await openDb(sb);
  t.after(() => db.close());
  db.prepare("UPDATE lg_threads SET status='running', interrupt_id=NULL, waiting_since=NULL, deadline_at=NULL WHERE thread_id='c1'").run();
  await new Promise((r) => setTimeout(r, 1500));
  const r = run(env, ["sweep"]); // '지금부터 새 기한'이었다면 여기서 만료되지 않는다
  assert.match(r.first, /^EXPIRED c1 /, r.out);
});

test("gc: 빈 값·0일 거부, 기한 전 대기는 지우지 않음, 하루 LLM 상한은 초기화되지 않음", (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb);
  const env = { ...sb.env, LG_CLAUDE_BIN: fake.bin, LG_LLM_MAX_PER_DAY: "1" };
  for (const bad of [["gc", "--days="], ["gc", "--days", "0"], ["gc", "--days", "-3"], ["gc", "--days"]]) {
    const r = run(env, bad, at(T0));
    assert.equal(r.code, 1, bad.join(" "));
    assert.match(r.first, /^ERROR - usage /);
  }
  assert.match(run(env, ["start", "smoke", "a", "--llm"], at(T0)).first, /^WAITING a /);
  const g = run(env, ["gc", "--days", "1"], at(T0 + 36 * HOUR)); // a 는 하루 넘게 묵었지만 기한(48시간) 전
  assert.match(g.first, /^OK gc deleted=0 /);
  assert.match(readPending(sb), /"thread":"a"/);
  assert.match(run(env, ["start", "smoke", "b", "--llm"], at(T0 + 2 * HOUR)).first, /^HELD b LLM 호출 하루 상한/);
  assert.equal(fake.calls().length, 1);
});

test("gc: 다른 연결이 DB 를 잡고 있어 정리를 끝내지 못하면 OK 가 아니라 ERROR(1)", async (t) => {
  const sb = sandbox(t);
  const mark = `PLAINTEXT-CANARY-${randomUUID()}`;
  assert.equal(run(sb.env, ["start", "smoke", "g1", "--topic", mark], at(T0)).code, 0);
  assert.equal(run(sb.env, ["resume", "g1", "approved"], at(T0)).code, 0);
  const db = await openDb(sb);
  db.exec("BEGIN");
  db.prepare("SELECT count(*) AS n FROM checkpoints").get(); // 읽기 스냅숏을 쥔다
  const r = run({ ...sb.env, LG_BUSY_TIMEOUT_MS: "300" }, ["gc"], at(T0 + 15 * DAY));
  db.exec("COMMIT");
  db.close();
  assert.equal(r.code, 1, r.out);
  assert.match(r.first, /^ERROR - internal /);
  const again = run(sb.env, ["gc"], at(T0 + 15 * DAY));
  assert.equal(again.code, 0, again.out);
  assert.equal(occurrences(sb.state, mark), 0);
});

test("노드의 console 출력은 스레드 로그로 — 첫 줄 규약·stderr 깨끗함 유지", (t) => {
  const sb = sandbox(t);
  const smoke = fs.readFileSync(path.join(path.dirname(new URL(import.meta.url).pathname), "..", "graphs", "smoke.mjs"), "utf8");
  const noisy = smoke.replace('trace("collect");', 'trace("collect"); console.log("NOISE-OUT"); console.error("NOISE-ERR");');
  assert.notEqual(noisy, smoke);
  const lg = appWith(sb, { noisy });
  const r = lg(sb.env, ["start", "noisy", "n1"]);
  assert.equal(r.code, 0, r.out + r.err);
  assert.match(r.first, /^WAITING n1 /);
  assert.equal(r.err, "");
  const log = path.join(sb.state, "logs", "n1.log");
  assert.match(fs.readFileSync(log, "utf8"), /NOISE-OUT[\s\S]*NOISE-ERR/);
  assert.equal(fs.statSync(log).mode & 0o777, 0o600);
});

test("노드가 process.exit(0) 을 불러도 종료 코드 1·ERROR crashed — 경보가 묻히지 않게", (t) => {
  const sb = sandbox(t);
  const r = run(sb.env, ["start", "smoke", "q1"], { extraEnv: { LG_SMOKE_CRASH_ONCE: path.join(sb.dir, "m"), LG_SMOKE_CRASH_CODE: "0" } });
  assert.equal(r.code, 1);
  assert.match(r.first, /^ERROR q1 crashed .*코드 0/);
});

test("pid 가 살아 있어도 시작 시각이 다르면 다른 프로세스 — 그 잠금은 넘겨받는다(pid 재사용 대비)", async (t) => {
  const sb = sandbox(t);
  assert.equal(run(sb.env, ["start", "smoke", "k1"]).code, 0);
  const db = await openDb(sb);
  t.after(() => db.close());
  db.prepare("INSERT OR REPLACE INTO lg_locks(thread_id,pid,token,acquired_at,pstart) VALUES('k1',?,'x',?,?)").run(process.pid, Date.now(), "Thu Jan  1 00:00:00 1970");
  const r = run(sb.env, ["resume", "k1", "approved"]);
  assert.equal(r.code, 0, r.out);
  assert.match(r.first, /^DONE k1 /);
});

test("LG_NOW 는 시험 모드에서만 — 운영에 남아 있으면 오류로 멈춘다", (t) => {
  const sb = sandbox(t);
  const { LG_TEST_MODE, ...prod } = sb.env;
  const r = run(prod, ["status"], at(T0));
  assert.equal(r.code, 1);
  assert.match(r.first, /^ERROR - internal LG_NOW 는 시험 모드/);
});

test("같은 이유로 되풀이하는 보류는 정리 기준 시각을 미루지 않는다", (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb);
  const env = { ...sb.env, LG_CLAUDE_BIN: fake.bin, LG_LLM_MAX_PER_THREAD: "0" };
  assert.match(run(env, ["start", "smoke", "z1", "--llm"], at(T0)).first, /^HELD z1 .*상한\(LG_LLM_MAX_PER_THREAD\)을 올려야/);
  assert.match(run(env, ["retry", "z1"], at(T0 + 10 * DAY)).first, /^HELD z1 /);
  assert.match(run(env, ["gc"], at(T0 + 15 * DAY)).first, /^OK gc deleted=1 /);
  assert.equal(fake.calls().length, 0);
});

// ── 반대편 재검토(10-03)가 보인 회귀·빈틈 ─────────────────────────────
test("한 노드 안의 둘째 질문은 새 48시간을 받는다(첫 질문 기한을 물려받지 않음)", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { twoq: `${LG}
const State = Annotation.Root({ first: Annotation(), second: Annotation() });
export const input = () => ({});
export const summarize = (v) => \`\${v.first}/\${v.second}\`;
export function build({ checkpointer }) {
  return new StateGraph(State)
    .addNode("ask", (s) => {
      const first = interrupt({ question: "첫 질문?" });
      const second = interrupt({ question: "원격에 올릴까?" });
      return { first, second };
    })
    .addEdge(START, "ask").addEdge("ask", END)
    .compile({ checkpointer });
}
` });
  // 기준 시각은 실제 지금 — 체크포인트 시각(실제 시계)이 주입 시각보다 앞서야 옛 계산의 회귀가 드러난다(변이로 확인)
  const base = Date.now();
  assert.match(lg(sb.env, ["start", "twoq", "t1"], at(base)).first, /^WAITING t1 첫 질문\?/);
  const r = lg(sb.env, ["resume", "t1", "approved"], at(base + 47 * HOUR));
  assert.match(r.first, /^WAITING t1 원격에 올릴까\?/);
  assert.equal(lg(sb.env, ["sweep"], at(base + 49 * HOUR)).first, "NO_REPLY", "둘째 질문은 47시간째에 나왔으니 49시간째엔 살아 있어야 한다");
  assert.match(lg(sb.env, ["resume", "t1", "approved"], at(base + 50 * HOUR)).first, /^DONE t1 approved\/approved/);
});

test("승인 노드가 한 번 실패한 뒤 늦게 retry 해도, 질문을 보인 때부터 48시간", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { flaky: `${LG}
const State = Annotation.Root({ decision: Annotation() });
export const input = () => ({});
export const summarize = (v) => String(v.decision);
export function build({ checkpointer }) {
  return new StateGraph(State)
    .addNode("approve", (s) => {
      if (process.env.LG_TEST_APPROVE_FAIL === "1") throw new Error("승인 노드 고장 흉내");
      return { decision: interrupt({ question: "마무리할까요?" }) };
    })
    .addEdge(START, "approve").addEdge("approve", END)
    .compile({ checkpointer });
}
` });
  const base = Date.now(); // 위 시험과 같은 이유로 실제 지금 기준
  const f = lg(sb.env, ["start", "flaky", "v1"], { extraEnv: { LG_NOW: String(base), LG_TEST_APPROVE_FAIL: "1" } });
  assert.match(f.first, /^ERROR v1 failed 승인 노드 고장 흉내/);
  const r = lg(sb.env, ["retry", "v1"], at(base + 72 * HOUR));
  assert.equal(r.code, 0, r.out);
  assert.match(r.first, /^WAITING v1 마무리할까요\?/);
  assert.match(lg(sb.env, ["resume", "v1", "approved"], at(base + 100 * HOUR)).first, /^DONE v1 approved/);
});

test("옛 판이 만든 DB(빠진 칸)도 새 판이 칸을 더해 그대로 쓴다", async (t) => {
  const sb = sandbox(t);
  fs.mkdirSync(sb.state, { recursive: true });
  const { createRequire } = await import("node:module");
  const Database = createRequire(import.meta.url)("better-sqlite3");
  const old = new Database(path.join(sb.state, "checkpoints.db"));
  old.exec(`CREATE TABLE lg_threads (thread_id TEXT PRIMARY KEY, graph TEXT NOT NULL, status TEXT NOT NULL, created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL, waiting_since INTEGER, deadline_at INTEGER, question TEXT, decision TEXT, note TEXT);
    CREATE TABLE lg_locks (thread_id TEXT PRIMARY KEY, pid INTEGER NOT NULL, token TEXT NOT NULL, acquired_at INTEGER NOT NULL);`);
  old.close();
  const s = run(sb.env, ["start", "smoke", "o1"]);
  assert.equal(s.code, 0, s.out);
  assert.match(run(sb.env, ["resume", "o1", "approved"]).first, /^DONE o1 /);
  const db = await openDb(sb);
  t.after(() => db.close());
  const cols = db.prepare("PRAGMA table_info(lg_locks)").all().map((c) => c.name);
  assert.ok(cols.includes("pstart"), cols.join(","));
  assert.equal(db.pragma("user_version", { simple: true }), 2);
});

test("그래프 파일이 없어져도 대기는 장부 기한으로 만료되고(종료 0) 나중에 정리된다", (t) => {
  const sb = sandbox(t);
  const smoke = fs.readFileSync(path.join(path.dirname(new URL(import.meta.url).pathname), "..", "graphs", "smoke.mjs"), "utf8");
  const lg = appWith(sb, { gone: smoke });
  assert.match(lg(sb.env, ["start", "gone", "z1"], at(T0)).first, /^WAITING z1 /);
  fs.rmSync(path.join(sb.dir, "app", "graphs", "gone.mjs"));
  const sw = lg(sb.env, ["sweep"], at(T0 + 49 * HOUR));
  assert.equal(sw.code, 0, sw.out);
  assert.match(sw.first, /^EXPIRED z1 /);
  assert.match(lg(sb.env, ["gc"], at(T0 + 49 * HOUR + 15 * DAY)).first, /^OK gc deleted=1 /);
  assert.equal(readPending(sb), "");
});

test("장부는 대기인데 그래프는 이미 끝났으면 sweep 이 끝남으로 맞춘다(영구 대기 방지)", async (t) => {
  const sb = sandbox(t);
  assert.equal(run(sb.env, ["start", "smoke", "d1"], at(T0)).code, 0);
  assert.equal(run(sb.env, ["resume", "d1", "approved"], at(T0)).code, 0);
  const db = await openDb(sb);
  t.after(() => db.close());
  db.prepare("UPDATE lg_threads SET status='waiting', interrupt_id='x', deadline_at=? WHERE thread_id='d1'").run(T0 + HOUR);
  assert.equal(run(sb.env, ["sweep"], at(T0 + 2 * HOUR)).first, "NO_REPLY");
  assert.equal(JSON.parse(run(sb.env, ["status", "d1", "--json"], at(T0 + 2 * HOUR)).out).status, "done");
  assert.equal(readPending(sb), "");
});

test("답을 적용하다 승인 노드가 실패하면 기한이 남아 sweep 이 만료시킨다(영구 대기 방지)", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { flaky: `${LG}
const State = Annotation.Root({ decision: Annotation() });
export const input = () => ({});
export const summarize = (v) => String(v.decision);
export function build({ checkpointer }) {
  return new StateGraph(State)
    .addNode("approve", (s) => {
      if (process.env.LG_TEST_APPROVE_FAIL === "1") throw new Error("승인 노드 고장 흉내");
      return { decision: interrupt({ question: "마무리할까요?" }) };
    })
    .addEdge(START, "approve").addEdge("approve", END)
    .compile({ checkpointer });
}
` });
  const base = Date.now();
  assert.match(lg(sb.env, ["start", "flaky", "r1"], at(base)).first, /^WAITING r1 /);
  const f = lg(sb.env, ["resume", "r1", "approved"], { extraEnv: { LG_NOW: String(base + HOUR), LG_TEST_APPROVE_FAIL: "1" } });
  assert.match(f.first, /^ERROR r1 failed 승인 노드 고장 흉내/);
  const sw = lg(sb.env, ["sweep"], at(base + 49 * HOUR));
  assert.match(sw.first, /^EXPIRED r1 /, sw.out);
});
