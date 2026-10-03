// runner.test.mjs — 실행기 안전장치 시험. 전부 임시 HOME·임시 상태 폴더에서, 실제 프로세스로 돈다.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import {
  sandbox, run, runAsync, counts, readPending, statusJson, occurrences, deadPid, openDb,
  at, T0, HOUR, DAY, NODE, FIXTURES,
} from "./helpers.mjs";

test("고장 뒤 재개: think 에서 한 번 죽으면 retry 가 think 부터 다시 돈다", (t) => {
  const sb = sandbox(t);
  const crash = { extraEnv: { LG_SMOKE_CRASH_ONCE: path.join(sb.dir, "crash.marker") } };
  const r1 = run(sb.env, ["start", "smoke", "c1"], crash);
  assert.equal(r1.code, 1);
  assert.match(r1.first, /^ERROR c1 crashed /);
  assert.deepEqual(counts(sb), { collect: 1, think: 1 });
  assert.equal(JSON.parse(run(sb.env, ["status", "c1", "--json"]).out).status, "failed");

  const r2 = run(sb.env, ["retry", "c1"], crash);
  assert.equal(r2.code, 0, r2.out + r2.err);
  assert.match(r2.first, /^WAITING c1 /);
  assert.deepEqual(counts(sb), { collect: 1, think: 2 }, "collect 는 다시 돌지 않고 think 부터");

  const r3 = run(sb.env, ["resume", "c1", "approved"]);
  assert.equal(r3.code, 0);
  assert.match(r3.first, /^DONE c1 완료 — 요약: /);
  assert.equal(counts(sb).finalize, 1);
});

// 잠금을 끈 변이로 이 시험이 잡는지 확인했다. 출발선(LG_TEST_START_AT)이 없으면 모듈 적재 시간 차로 경합이 흩어져 변이가 가끔 통과했다.
test("동시 재개 5회 → finalize 는 1회, 이긴 쪽 결정만 저장된다 (스레드 3개 동시)", async (t) => {
  const sb = sandbox(t);
  const threads = ["r1", "r2", "r3"];
  for (const th of threads) assert.equal(run(sb.env, ["start", "smoke", th]).code, 0);
  const decisions = ["approved", "rejected", "approved", "rejected", "approved"];
  const jobs = threads.flatMap((th) => decisions.map((d) => ({ th, d })));
  const go = { extraEnv: { LG_TEST_START_AT: String(Date.now() + 2500) } };
  const rs = await Promise.all(jobs.map(({ th, d }) => runAsync(sb.env, ["resume", th, d], go).then((r) => ({ ...r, th, d }))));
  assert.ok(rs.some((r) => / busy /.test(r.first)), `실제로 경합이 일어나야 한다:\n${rs.map((r) => r.first).join("\n")}`);
  assert.equal(counts(sb).finalize, threads.length, rs.map((r) => r.first).join("\n"));
  for (const th of threads) {
    const mine = rs.filter((r) => r.th === th);
    const won = mine.filter((r) => r.code === 0);
    assert.equal(won.length, 1, mine.map((r) => r.first).join("\n"));
    assert.match(won[0].first, new RegExp(`^DONE ${th} `));
    for (const r of mine.filter((x) => x.code !== 0)) assert.match(r.first, new RegExp(`^ERROR ${th} (busy|not-waiting) `));
    const v = JSON.parse(run(sb.env, ["status", th, "--json"]).out);
    assert.equal(v.status, "done");
    assert.equal(v.decision, won[0].d);
    assert.match(v.note, won[0].d === "approved" ? /^완료 — / : /^반려됨$/);
  }
});

test("이미 있는 스레드에 start 가 오면 거부하고 아무것도 다시 돌리지 않는다", (t) => {
  const sb = sandbox(t);
  const r1 = run(sb.env, ["start", "smoke", "d1", "--topic", "첫번째"]);
  assert.equal(r1.code, 0);
  const r2 = run(sb.env, ["start", "smoke", "d1", "--topic", "두번째"]);
  assert.equal(r2.code, 1);
  assert.match(r2.first, /^ERROR d1 exists /);
  assert.deepEqual(counts(sb), { collect: 1, think: 1 });
  const v = JSON.parse(run(sb.env, ["status", "d1", "--json"]).out);
  assert.equal(v.status, "waiting");
  assert.match(v.question, /첫번째/);
});

test("잠금: 살아 있는 프로세스가 쥐면 거부, 죽은 pid 의 잠금은 넘겨받는다", async (t) => {
  const sb = sandbox(t);
  assert.equal(run(sb.env, ["start", "smoke", "k1"]).code, 0);
  const db = await openDb(sb);
  t.after(() => db.close());
  const setLock = (pid) => db.prepare("INSERT OR REPLACE INTO lg_locks(thread_id,pid,token,acquired_at) VALUES('k1',?,'x',?)").run(pid, Date.now());

  setLock(process.pid); // 이 시험 프로세스 = 살아 있음
  const busy = run(sb.env, ["resume", "k1", "approved"]);
  assert.equal(busy.code, 1);
  assert.match(busy.first, /^ERROR k1 busy /);
  assert.equal(counts(sb).finalize ?? 0, 0);

  setLock(deadPid());
  const ok = run(sb.env, ["resume", "k1", "approved"]);
  assert.equal(ok.code, 0, ok.out + ok.err);
  assert.match(ok.first, /^DONE k1 /);
  assert.equal(db.prepare("SELECT count(*) n FROM lg_locks").get().n, 0, "끝나면 잠금을 푼다");

  // 실행 중으로 적혔는데 잠금 주인이 죽었으면 '멈춤'으로 보인다
  assert.equal(run(sb.env, ["start", "smoke", "k2"]).code, 0);
  db.prepare("UPDATE lg_threads SET status='running' WHERE thread_id='k2'").run();
  db.prepare("INSERT INTO lg_locks(thread_id,pid,token,acquired_at) VALUES('k2',?,'y',?)").run(deadPid(), Date.now());
  assert.equal(JSON.parse(run(sb.env, ["status", "k2", "--json"]).out).status, "stalled");
  const re = run(sb.env, ["retry", "k2"]);
  assert.equal(re.code, 0);
  assert.match(re.first, /^WAITING k2 /);
});

test("승인 기한 만료 → 자동 취소(EXPIRED), 재개·이어가기 거부 (시간 주입)", (t) => {
  const sb = sandbox(t);
  assert.equal(run(sb.env, ["start", "smoke", "e1"], at(T0)).code, 0);
  assert.match(readPending(sb), /"thread":"e1"/);

  assert.match(run(sb.env, ["status", "e1"], at(T0 + 47 * HOUR)).first, /^WAITING e1 /);
  assert.equal(run(sb.env, ["sweep"], at(T0 + 47 * HOUR)).first, "NO_REPLY");

  // 다른 명령도 지나간 기한을 치운다 — 첫 줄은 그 명령의 결과, EXPIRED 는 뒤에
  const r = run(sb.env, ["start", "smoke", "e2"], at(T0 + 49 * HOUR));
  assert.equal(r.code, 0);
  assert.match(r.first, /^WAITING e2 /);
  assert.ok(r.lines.some((l) => /^EXPIRED e1 /.test(l)), r.out);
  assert.doesNotMatch(readPending(sb), /"thread":"e1"/);
  assert.match(readPending(sb), /"thread":"e2"/);

  const res = run(sb.env, ["resume", "e1", "approved"], at(T0 + 49 * HOUR));
  assert.equal(res.code, 1);
  assert.match(res.first, /^ERROR e1 expired /);
  assert.equal(run(sb.env, ["retry", "e1"], at(T0 + 49 * HOUR)).code, 1);
  assert.equal(counts(sb).finalize ?? 0, 0, "만료된 스레드는 마무리 노드를 돌리지 않는다");

  const sw = run(sb.env, ["sweep"], at(T0 + 98 * HOUR));
  assert.equal(sw.code, 0);
  assert.deepEqual(sw.lines.map((l) => l.split(" ").slice(0, 2).join(" ")), ["EXPIRED e1", "EXPIRED e2"], "예약 sweep 이 아직 안 알린 만료를 모두 알린다");
  assert.equal(run(sb.env, ["sweep"], at(T0 + 98 * HOUR)).first, "NO_REPLY");
  const v = statusJson(sb, at(T0 + 98 * HOUR));
  assert.equal(v.counts.expired, 2);
  assert.equal(v.counts.waiting, 0);
  assert.equal(readPending(sb), "");
});

test("gc 뒤 상태 폴더 어디에도 평문 표식이 남지 않는다, 권한 700/600", (t) => {
  const sb = sandbox(t);
  const mark = `PLAINTEXT-CANARY-${randomUUID()}`;
  assert.equal(run(sb.env, ["start", "smoke", "g-old", "--topic", mark], at(T0)).code, 0);
  assert.equal(run(sb.env, ["resume", "g-old", "approved"], at(T0)).code, 0);
  assert.ok(occurrences(sb.state, mark) > 0, "정리 전에는 표식이 파일에 있어야 이 시험이 의미가 있다");
  assert.equal(run(sb.env, ["start", "smoke", "g-new", "--topic", "평범한 주제"], at(T0 + 10 * DAY)).code, 0);

  const r = run(sb.env, ["gc"], at(T0 + 15 * DAY));
  assert.equal(r.code, 0, r.out + r.err);
  assert.match(r.first, /^OK gc deleted=1 /);
  assert.equal(occurrences(sb.state, mark), 0);
  assert.deepEqual(statusJson(sb, at(T0 + 15 * DAY)).threads.map((x) => x.thread), ["g-new"]);

  assert.equal(fs.statSync(sb.state).mode & 0o777, 0o700);
  for (const f of fs.readdirSync(sb.state)) {
    const st = fs.statSync(path.join(sb.state, f));
    if (st.isFile()) assert.equal(st.mode & 0o777, 0o600, f);
  }
});

test("추적 변수를 넣어도 네트워크 시도 0 (닫힌 프록시·NODE_USE_ENV_PROXY=1)", (t) => {
  const sb = sandbox(t);
  const spyLog = path.join(sb.dir, "netspy.log");
  const proxy = "http://127.0.0.1:9";
  const env = {
    ...sb.env, NETSPY_LOG: spyLog, NODE_USE_ENV_PROXY: "1",
    HTTPS_PROXY: proxy, HTTP_PROXY: proxy, https_proxy: proxy, http_proxy: proxy,
    LANGSMITH_TRACING: "true", LANGSMITH_TRACING_V2: "true", LANGCHAIN_TRACING: "true", LANGCHAIN_TRACING_V2: "true",
    LANGSMITH_API_KEY: "fake-not-a-key", LANGCHAIN_API_KEY: "fake-not-a-key", LANGSMITH_ENDPOINT: "https://api.smith.langchain.com",
  };
  const spy = ["--import", pathToFileURL(path.join(FIXTURES, "netspy.mjs")).href];
  const read = () => fs.readFileSync(spyLog, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));

  // 대조군: 감시 모듈이 실제 시도를 잡는지 먼저 본다 — 0 이 '못 본 것'이 아니게
  spawnSync(NODE, [...spy, "-e", "fetch('https://api.smith.langchain.com/info').catch(() => {})"], { env, timeout: 30_000 });
  assert.ok(read().some((e) => e.kind !== "spy.loaded"), "감시 모듈이 fetch 시도를 기록해야 한다");
  fs.writeFileSync(spyLog, "");

  const t0 = Date.now();
  const r1 = run(env, ["start", "smoke", "n1"], { nodeArgs: spy });
  const r2 = run(env, ["resume", "n1", "approved"], { nodeArgs: spy });
  assert.equal(r1.code, 0, r1.out + r1.err);
  assert.equal(r2.code, 0, r2.out + r2.err);
  const ev = read();
  assert.equal(ev.filter((e) => e.kind === "spy.loaded").length, 2, "두 실행 모두 감시 아래에서 돌았다");
  assert.deepEqual(ev.filter((e) => e.kind !== "spy.loaded"), []);
  assert.ok(Date.now() - t0 < 20_000, "추적이 켜졌다면 종료가 수십 초 늦어진다");
});

test("env-guard: LANGSMITH_*·LANGCHAIN_* 를 지우고 umask 077 을 건다", () => {
  const guard = pathToFileURL(path.join(FIXTURES, "..", "..", "lib", "env-guard.mjs")).href;
  const code = `await import(${JSON.stringify(guard)}); console.log(JSON.stringify({ left: Object.keys(process.env).filter((k) => /^LANG(SMITH|CHAIN)_/.test(k)), keep: process.env.KEEP_ME, umask: process.umask() }));`;
  const r = spawnSync(NODE, ["--input-type=module", "-e", code], {
    env: { PATH: process.env.PATH, LANGSMITH_TRACING: "true", LANGCHAIN_TRACING_V2: "true", LANGSMITH_API_KEY: "x", KEEP_ME: "1" }, encoding: "utf8",
  });
  assert.deepEqual(JSON.parse(r.stdout), { left: [], keep: "1", umask: 0o077 });
});
