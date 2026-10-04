// duty-verify.test.mjs — 당직 D0 그림자(PLAN §13.3): 틱 고리 접수(재시작마다 스레드 하나) · 3분 대기 · 확인 ok/broken ·
// 그림자 effect(실행 안 함) · 당직 장부 대조 · 재시작 생존 실측 · 끄기 스위치 · 고리 고장 격리.
// 전부 임시 HOME·임시 상태 폴더·가짜 파일(재시작 기록·대화 기록·게이트웨이 로그·장부)·가짜 lsof/ps/curl(fake-gw.mjs).
// 진짜 게이트웨이·OpenClaw·당직 장부는 건드리지 않는다 — 진짜 장부의 지문을 시험 앞뒤로 대조한다.
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { sandbox, run, NODE, FIXTURES, ROOT } from "./helpers.mjs";
import { tickEnv, metrics, effects } from "./helpers0b.mjs";
import { parseEtime, restartEvents, nextDutyJudgement, scanTranscripts, AUTHORITY_CLOSED } from "../graphs/duty-verify-common.mjs";
import { checkGraphFile } from "../scripts/check-graph-rules.mjs";
import { checkFile } from "../scripts/check-interrupt-nodes.mjs";
import { loadRegistry } from "../lib/run.mjs";

// 진짜 당직 장부 — 이 시험 파일 전체가 끝난 뒤에도 한 바이트도 달라지지 않아야 한다
const REAL_LEDGER = path.join(os.userInfo().homedir, ".openclaw", "workspace", "state", "duty", "ledger.jsonl");
const sha = (f) => (fs.existsSync(f) ? createHash("sha256").update(fs.readFileSync(f)).digest("hex") : "(없음)");
const REAL_BEFORE = sha(REAL_LEDGER);
after(() => assert.equal(sha(REAL_LEDGER), REAL_BEFORE, "진짜 당직 장부가 바뀌었다"));

const MIN = 60_000;
const R0 = Date.parse("2026-10-04T16:55:49+09:00"); // 재시작 시도 시각(가짜 기록)
const FAKE_GW = path.join(FIXTURES, "fake-gw.mjs");
const isoZ = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

function registryFile(sb) {
  const pass = ["LG_TEST_GW_FILE", "LG_NOW"];
  const commands = {
    "gateway.listen-pid": { bin: NODE, argv: [FAKE_GW, "lsof", "{spec}"], params: { spec: "^TCP:[0-9]{2,5}$" }, modes: ["shadow", "live"], cwd: "/", envPass: pass, timeoutSec: 15 },
    "gateway.proc": { bin: NODE, argv: [FAKE_GW, "ps", "{pid}"], params: { pid: "^[1-9][0-9]{0,6}$" }, modes: ["shadow", "live"], cwd: "/", envPass: pass, timeoutSec: 10 },
    "gateway.health": { bin: NODE, argv: [FAKE_GW, "curl", "{url}"], params: { url: "^http://127\\.0\\.0\\.1:[0-9]{2,5}/health$" }, modes: ["shadow", "live"], cwd: "/", envPass: pass, timeoutSec: 10 },
  };
  const file = path.join(sb.dir, "cmd-registry.json");
  fs.writeFileSync(file, JSON.stringify({ version: 1, commands }, null, 1));
  return file;
}

function box(t, { over = {} } = {}) {
  const sb = sandbox(t);
  const f = {
    restartLog: path.join(sb.dir, "gateway-restart.log"), projects: path.join(sb.dir, "projects"), gwLogDir: path.join(sb.dir, "oclogs"),
    gwLog: path.join(sb.dir, "gateway.log"), ledger: path.join(sb.dir, "ledger.jsonl"), gw: path.join(sb.dir, "gw.json"),
  };
  fs.mkdirSync(path.join(f.projects, "-proj"), { recursive: true });
  fs.mkdirSync(f.gwLogDir);
  fs.writeFileSync(f.restartLog, "[2026-10-01T07:55:56Z] openclaw restart attempt source=handoff mode=start-after-exit target=gui/501/ai.openclaw.gateway pid=82190 interactive=0\n");
  fs.writeFileSync(f.ledger, `${JSON.stringify({ ts: "2026-10-03T10:00:00+09:00", key: "disk.free", verified: true })}\n`);
  const env = tickEnv(sb, { now: R0 - 30 * MIN, over: {
    LG_CMD_REGISTRY: registryFile(sb), LG_DUTY_VERIFY: "1", LG_TEST_GW_FILE: f.gw, LG_DV_RESTART_LOG: f.restartLog, LG_DV_CLAUDE_PROJECTS: f.projects,
    LG_DV_GW_LOG_DIR: f.gwLogDir, LG_DV_GW_LOG: f.gwLog, LG_DV_DUTY_LEDGER: f.ledger, ...over } });
  const gw = (o) => fs.writeFileSync(f.gw, JSON.stringify({ up: true, health: true, ...o }));
  const tick = (ms, extra = {}) => run(env, ["tick", "--verbose"], { extraEnv: { LG_NOW: String(ms), ...extra } });
  const threads = () => JSON.parse(run(env, ["status", "--all", "--json"]).out).threads;
  const dv = () => threads().filter((x) => x.graph === "duty-verify");
  const restart = (at, oldPid) => fs.appendFileSync(f.restartLog,
    `[${new Date(at - 30_000).toISOString()}] openclaw gateway lifecycle source=safe-rpc action=restart mode=deferred pid=${oldPid} interactive=0\n`
    + `[${isoZ(at)}] openclaw restart attempt source=handoff mode=start-after-exit target=gui/501/ai.openclaw.gateway pid=${oldPid} interactive=0\n`
    + `[${isoZ(at + 2000)}] openclaw restart done source=handoff mode=start-after-exit interactive=0\n`);
  const transcript = (lines) => fs.appendFileSync(path.join(f.projects, "-proj", "s1.jsonl"), `${lines.map((l) => JSON.stringify(l)).join("\n")}\n`);
  const dvm = (phase) => metrics(sb).filter((r) => r.ev === "lg.duty.verify" && (!phase || r.phase === phase));
  // 부팅(처음 틱 — 지금부터 본다) → 재시작(옛 pid 100 → 새 pid 200, 기록 줄) 까지 깔아 둔다
  const bootAndRestart = () => {
    gw({ pid: 100, start_ms: R0 - 3 * 3_600_000 });
    tick(R0 - 20 * MIN);
    restart(R0, 100);
    gw({ pid: 200, start_ms: R0 + 2000 });
  };
  return { sb, env, f, gw, tick, threads, dv, restart, transcript, dvm, bootAndRestart };
}

const use = (id, name, at) => ({ timestamp: new Date(at).toISOString(), message: { content: [{ type: "tool_use", id, name }] } });
const result = (id, at, { error = false, text = "[]" } = {}) => ({ timestamp: new Date(at).toISOString(),
  message: { content: [{ type: "tool_result", tool_use_id: id, is_error: error, content: [{ type: "text", text }] }] } });

test("D0 그래프·공용 모듈은 정적 규칙을 지키고, 운영 허용 목록의 확인 명령은 읽기 전용 셋뿐이다", () => {
  const reg = loadRegistry(path.join(ROOT, "cmd-registry.json"));
  for (const g of ["duty-verify", "duty-verify-common"]) {
    assert.deepEqual(checkGraphFile(path.join(ROOT, "graphs", `${g}.mjs`), reg), [], g);
    assert.deepEqual(checkFile(path.join(ROOT, "graphs", `${g}.mjs`), g).problems, [], g);
  }
  const gwc = Object.values(reg.commands).filter((c) => c.id.startsWith("gateway."));
  assert.deepEqual(gwc.map((c) => c.id).sort(), ["gateway.health", "gateway.listen-pid", "gateway.proc"]);
  assert.deepEqual(gwc.map((c) => c.bin).sort(), ["/bin/ps", "/usr/bin/curl", "/usr/sbin/lsof"]);
  assert.ok(gwc.every((c) => !c.effect), "확인 명령은 부수효과가 아니다");
  assert.equal(new RegExp(reg.commands["gateway.health"].params.url).test("http://example.com:80/health"), false, "health 는 127.0.0.1 만");
});

test("접수: 처음 틱은 지금부터 보고, 재시작 하나에 스레드 하나(기록 줄 + pid 바뀜이 겹쳐도 하나) — 틱을 되풀이해도 그대로", (t) => {
  const b = box(t);
  b.gw({ pid: 100, start_ms: R0 - 3 * 3_600_000 });
  const boot = b.tick(R0 - 20 * MIN);
  assert.equal(boot.code, 0, boot.out);
  assert.equal(b.dv().length, 0, "처음 틱은 지난 재시작(10-01 기록)을 올리지 않는다");
  const hb = metrics(b.sb).filter((r) => r.ev === "lg.restart.heartbeat");
  assert.equal(hb.length, 1);
  assert.equal(hb[0].gw_pid, 100);
  assert.equal(hb[0].gw_start_ms, R0 - 3 * 3_600_000);

  b.restart(R0, 100);
  b.gw({ pid: 200, start_ms: R0 + 2000 });
  const r1 = b.tick(R0 + 1 * MIN);
  assert.equal(r1.code, 0, r1.out);
  assert.match(r1.out, new RegExp(`QUEUED dv-${R0 / 1000} `));
  for (const at of [R0 + 2 * MIN, R0 + 2.5 * MIN]) assert.equal(b.tick(at).code, 0);
  const dv = b.dv();
  assert.deepEqual(dv.map((x) => x.thread), [`dv-${R0 / 1000}`], "재시작 하나에 스레드 하나");
  assert.equal(dv[0].mode, "shadow");
  const starts = metrics(b.sb).filter((r) => r.ev === "start" && r.by === "duty-intake");
  assert.equal(starts.length, 1);
  assert.equal(starts[0].source, "restart_log");
  assert.equal(metrics(b.sb).filter((r) => r.ev === "lg.restart.heartbeat").length, 4, "틱마다 heartbeat 하나");
  assert.ok(fs.readFileSync(`${b.f.gw}.calls`, "utf8").includes("lsof TCP:18789"), "가짜 확인 명령이 불렸다(진짜 lsof 아님)");
});

test("접수: 기록에 없는 재시작(pid 만 바뀜)도 하나 — 다음 틱에 다시 올리지 않는다", (t) => {
  const b = box(t);
  b.gw({ pid: 100, start_ms: R0 - 3 * 3_600_000 });
  b.tick(R0 - 20 * MIN);
  b.gw({ pid: 300, start_ms: R0 });
  const r = b.tick(R0 + 10 * MIN);
  assert.equal(r.code, 0, r.out);
  b.tick(R0 + 40 * MIN);
  const dv = b.dv();
  assert.deepEqual(dv.map((x) => x.thread), [`dv-${R0 / 1000}`]);
  assert.equal(metrics(b.sb).find((x) => x.ev === "start" && x.by === "duty-intake").source, "pid_change");
});

test("대기: 재시작 + 3분 전에는 CONTINUE(확인 안 함), 지나면 확인 → ok · 그림자 effect 만 · 장부 무변", (t) => {
  const b = box(t);
  b.bootAndRestart();
  const ledgerBefore = sha(b.f.ledger);
  b.transcript([use("tu0", "mcp__openclaw__sessions_list", R0 - 5 * MIN), result("tu0", R0 - 4 * MIN, { error: true, text: `${AUTHORITY_CLOSED} sessions.list.` }), // 재시작 전 실패 — 세지 않음
    use("tu1", "mcp__openclaw__sessions_list", R0 + 60_000), result("tu1", R0 + 61_000)]);
  const r1 = b.tick(R0 + 1 * MIN);
  assert.equal(r1.code, 0, r1.out);
  const th = b.dv()[0];
  assert.equal(th.status, "continue");
  assert.match(th.note, /wait/);
  assert.equal(b.dvm().length, 0, "3분 전에는 판정 기록이 없다");
  assert.equal(effects(b.sb).length, 0);

  const r2 = b.tick(R0 + 4 * MIN);
  assert.equal(r2.code, 0, r2.out);
  const v = b.dvm("verify");
  assert.equal(v.length, 1);
  assert.equal(v[0].verdict, "ok", JSON.stringify(v[0]));
  assert.equal(v[0].pid_before, 100);
  assert.equal(v[0].pid_after, 200);
  assert.equal(v[0].new_pid, true);
  assert.equal(v[0].tool_fail, 0);
  assert.equal(v[0].tool_ok, 1);
  assert.equal(v[0].agreement, "pending");
  assert.equal(v[0].trigger, "safe-rpc:deferred");
  const fx = effects(b.sb);
  assert.equal(fx.length, 1);
  assert.equal(fx[0].status, "would_run");
  assert.equal(fx[0].mode, "shadow");
  assert.match(fx[0].key, /^would append ledger line key=gateway\.tool_authority verified=true restart=/);
  assert.ok(!fx.some((x) => ["started", "ok", "failed"].includes(x.status)), "그림자 effect 는 실행되지 않는다");
  assert.equal(sha(b.f.ledger), ledgerBefore, "장부(가짜)도 그대로");
  assert.equal(b.dv()[0].status, "continue", "당직 판정 줄이 없으면 compare 가 기다린다");
});

test("확인 broken: 재시작 뒤 오픈클로 도구 '권한 끊김'(감지기와 같은 판별) — 인용·다른 도구는 세지 않는다", (t) => {
  const b = box(t);
  b.bootAndRestart();
  b.transcript([
    use("q1", "Bash", R0 + 30_000), result("q1", R0 + 31_000, { error: true, text: `${AUTHORITY_CLOSED} node.list` }), // 다른 도구
    use("q2", "mcp__openclaw__sessions_list", R0 + 32_000), result("q2", R0 + 33_000, { text: `grep 결과: ${AUTHORITY_CLOSED}` }), // 오류 아님(인용)
    use("tu2", "mcp__openclaw__sessions_list", R0 + 90_000), result("tu2", R0 + 91_000, { error: true, text: `${AUTHORITY_CLOSED} sessions.list.` }),
  ]);
  b.tick(R0 + 4 * MIN);
  const v = b.dvm("verify");
  assert.equal(v[0].verdict, "broken");
  assert.equal(v[0].tool_fail, 1);
  assert.deepEqual(v[0].tool_fail_methods, ["sessions.list"]);
  assert.deepEqual(v[0].reasons, ["tool_authority_closed"]);
  assert.match(effects(b.sb)[0].key, /verified=false/);
});

test("확인 broken: 게이트웨이 로그의 같은 문구 · 옛 pid 그대로 · 포트 주인 없음", async (t) => {
  await t.test("게이트웨이 로그", (tt) => {
    const b = box(tt);
    b.bootAndRestart();
    fs.writeFileSync(path.join(b.f.gwLogDir, "openclaw-2026-10-04.log"),
      `${JSON.stringify({ 0: "CU_FAIL Gateway client authority closed before dispatching node.list.", time: new Date(R0 + 100_000).toISOString() })}\n`);
    b.tick(R0 + 4 * MIN);
    const v = b.dvm("verify")[0];
    assert.equal(v.verdict, "broken");
    assert.equal(v.gwlog_fail, 1);
  });
  await t.test("옛 pid 그대로(재시작이 안 먹음)", (tt) => {
    const b = box(tt);
    b.bootAndRestart();
    b.gw({ pid: 100, start_ms: R0 - 3 * 3_600_000 });
    b.tick(R0 + 4 * MIN);
    const v = b.dvm("verify")[0];
    assert.equal(v.verdict, "broken");
    assert.deepEqual(v.reasons, ["same_pid", "started_before_restart"]);
  });
  await t.test("포트 주인 없음", (tt) => {
    const b = box(tt);
    b.bootAndRestart();
    b.tick(R0 + 1 * MIN); // 접수(새 게이트웨이 pid 200 을 본다)
    b.gw({ up: false });
    b.tick(R0 + 4 * MIN);
    const v = b.dvm("verify")[0];
    assert.equal(v.verdict, "broken");
    assert.deepEqual(v.reasons, ["gateway_down"]);
  });
});

test("대조: 이 재시작을 부른 장부 줄은 빼고 다음 판정(verified:true)과 일치 → 끝(알림 없음) · 판정 줄이 없으면 창이 지나 none", async (t) => {
  await t.test("일치", (tt) => {
    const b = box(tt);
    b.bootAndRestart();
    // ts 는 재시작 뒤지만 이 재시작을 부른 줄(first_seen 이 앞·조치에 재시작·verified false) — 판정이 아니다
    fs.appendFileSync(b.f.ledger, `${JSON.stringify({ ts: "2026-10-04T16:57:00+09:00", mode: "call", key: "gateway.tool_authority", first_seen: "2026-10-04T16:55:00+09:00", fix: "조치표 절차: gateway restart --safe", verified: false })}\n`);
    fs.appendFileSync(b.f.ledger, `${JSON.stringify({ ts: "2026-10-04T19:45:42+09:00", mode: "call", key: "gateway.tool_authority", first_seen: "2026-10-04T16:55:00+09:00", fix: "확인만 — 재시작 후 도구 경로 정상", verified: true })}\n`);
    const before = sha(b.f.ledger);
    const r = run(b.env, ["tick"], { extraEnv: { LG_NOW: String(R0 + 4 * MIN) } }); // 예약 잡과 같은 조용한 틱
    assert.equal(r.code, 0, r.out);
    assert.equal(r.out.trim(), "NO_REPLY", "끝나도 주인님께 알리지 않는다(lg. 기록만)");
    const c = b.dvm("compare");
    assert.equal(c.length, 1);
    assert.equal(c[0].agreement, true);
    assert.equal(c[0].kind, "same");
    assert.equal(c[0].duty, "ok");
    assert.equal(c[0].duty_ts, "2026-10-04T19:45:42+09:00");
    assert.equal(b.dv()[0].status, "done");
    assert.equal(sha(b.f.ledger), before);
  });
  await t.test("판정 줄 없음 → 창(LG_DV_COMPARE_H) 안에서는 CONTINUE, 지나면 none", (tt) => {
    const b = box(tt, { over: { LG_DV_COMPARE_H: "1" } });
    b.bootAndRestart();
    b.tick(R0 + 4 * MIN);
    assert.equal(b.dv()[0].status, "continue");
    assert.equal(b.dvm("compare").length, 0);
    b.tick(R0 + 61 * MIN);
    const c = b.dvm("compare");
    assert.equal(c[0].agreement, "none");
    assert.equal(b.dv()[0].status, "done");
  });
  await t.test("나중 끊김(당직 broken 이 우리 확인 뒤에 처음 보임) → false·later_break", (tt) => {
    const b = box(tt);
    b.bootAndRestart();
    fs.appendFileSync(b.f.ledger, `${JSON.stringify({ ts: "2026-10-04T22:00:00+09:00", key: "gateway.tool_authority", first_seen: "2026-10-04T21:58:00+09:00", fix: "gateway restart --safe", verified: false })}\n`);
    b.tick(R0 + 4 * MIN);
    const c = b.dvm("compare")[0];
    assert.equal(c.agreement, false);
    assert.equal(c.kind, "later_break");
  });
});

test("생존 실측: 재시작을 건넌 대기 스레드·분리 실행이 재시작 뒤 이어 갔나(heartbeat 대조)", (t) => {
  const b = box(t);
  b.gw({ pid: 100, start_ms: R0 - 3 * 3_600_000 });
  b.tick(R0 - 25 * MIN); // 부팅
  const s = run(b.env, ["start", "smoke", "smoke-1"], { extraEnv: { LG_NOW: String(R0 - 22 * MIN) } });
  assert.match(s.out, /^WAITING smoke-1/);
  // 재시작을 건널 분리 실행(가짜): 시작만 있고 결과 없음 → heartbeat 가 '돌고 있음'으로 적는다
  const job = path.join(b.sb.state, "jobs", "smoke-1", "think", "1");
  fs.mkdirSync(job, { recursive: true });
  fs.writeFileSync(path.join(job, "meta.json"), JSON.stringify({ pid: 4242, startedAt: R0 - 21 * MIN }));
  b.tick(R0 - 20 * MIN); // 재시작 전 heartbeat: smoke-1 대기 · 분리 실행 1
  const pre = metrics(b.sb).filter((r) => r.ev === "lg.restart.heartbeat").at(-1);
  assert.ok(pre.open.includes("waiting smoke-1"), JSON.stringify(pre.open));
  assert.deepEqual(pre.jobs, ["smoke-1/think/1 4242"]);
  b.restart(R0, 100);
  b.gw({ pid: 200, start_ms: R0 + 2000 });
  fs.writeFileSync(path.join(job, "result.json"), JSON.stringify({ code: 0, endedAt: R0 + 60_000 })); // 재시작 뒤 결과를 씀 = 살아남음
  fs.appendFileSync(b.f.ledger, `${JSON.stringify({ ts: "2026-10-04T18:00:00+09:00", key: "gateway.tool_authority", first_seen: "2026-10-04T16:55:00+09:00", fix: "확인", verified: true })}\n`);
  run(b.env, ["answer", "smoke-1", "approved"], { extraEnv: { LG_NOW: String(R0 + 3 * MIN) } });
  b.tick(R0 + 4 * MIN);
  const c = b.dvm("compare")[0];
  assert.ok(c, JSON.stringify(b.dvm()));
  const sv = c.survival;
  assert.equal(sv.measured, true);
  assert.equal(sv.tick_after, true);
  assert.equal(sv.gw_changed, true);
  assert.equal(sv.open, 1);
  assert.equal(sv.progressed, 1, JSON.stringify(sv));
  assert.equal(sv.jobs, 1);
  assert.equal(sv.jobs_survived, 1);
  assert.equal(sv.jobs_killed, 0);
  // 집계(lg-report D0 칸)가 같은 값을 센다
  const rep = spawnSync(NODE, [path.join(ROOT, "lg-report.mjs"), "--json"], { env: b.env, encoding: "utf8" });
  const d0 = JSON.parse(rep.stdout).d0;
  assert.equal(d0.compared, 1);
  assert.equal(d0.agreement.true, 1);
  assert.equal(d0.agreement_rate, "100%");
  assert.equal(d0.survival.with_load, 1);
  assert.equal(d0.gw_changes, 1);
  const txt = spawnSync(NODE, [path.join(ROOT, "lg-report.mjs")], { env: b.env, encoding: "utf8" }).stdout;
  assert.match(txt, /## D0 당직 그림자/);
});

test("LIVE 스위치가 켜져 있어도 D0 스레드는 그림자로 등록되고 effect 는 '했을 일'만", (t) => {
  const b = box(t);
  fs.mkdirSync(b.sb.state, { recursive: true });
  fs.writeFileSync(path.join(b.sb.state, "LIVE"), "");
  b.bootAndRestart();
  b.tick(R0 + 4 * MIN);
  assert.equal(b.dv()[0].mode, "shadow");
  const fx = effects(b.sb);
  assert.deepEqual(fx.map((x) => [x.mode, x.status]), [["shadow", "would_run"]]);
});

test("끄기: DUTY_VERIFY_OFF 면 heartbeat·접수 모두 없음 · 고리 고장(확인 명령이 목록에 없음)은 틱을 멈추지 않는다", async (t) => {
  await t.test("끄기 스위치", (tt) => {
    const b = box(tt);
    fs.mkdirSync(b.sb.state, { recursive: true });
    fs.writeFileSync(path.join(b.sb.state, "DUTY_VERIFY_OFF"), "");
    b.bootAndRestart();
    const r = b.tick(R0 + 4 * MIN);
    assert.equal(r.code, 0);
    assert.equal(metrics(b.sb).filter((x) => x.ev === "lg.restart.heartbeat").length, 0);
    assert.equal(b.dv().length, 0);
  });
  await t.test("고리 고장 격리", (tt) => {
    const b = box(tt);
    fs.writeFileSync(b.env.LG_CMD_REGISTRY, JSON.stringify({ version: 1, commands: {} }));
    b.gw({ pid: 100, start_ms: R0 });
    const r = run(b.env, ["tick"], { extraEnv: { LG_NOW: String(R0) } });
    assert.equal(r.code, 0, r.out);
    assert.equal(r.out.trim(), "NO_REPLY");
    const h = metrics(b.sb).find((x) => x.ev === "held" && x.scope === "duty");
    assert.ok(h, "고리 고장은 보류 기록으로 남는다");
    assert.ok(metrics(b.sb).some((x) => x.ev === "tick"), "틱은 끝까지 간다");
  });
});

test("파서: etime · 재시작 기록(계기·결과) · 장부 판정(부른 줄 제외) · 대화 기록 시간 창", () => {
  assert.equal(parseEtime("46:33"), 46 * 60 + 33);
  assert.equal(parseEtime("01:02:03"), 3723);
  assert.equal(parseEtime("2-01:00:00"), 2 * 86400 + 3600);
  assert.equal(parseEtime("x"), null);
  const log = `[2026-10-04T07:55:19.921Z] openclaw gateway lifecycle source=safe-rpc action=restart mode=deferred pid=32477 interactive=0
[2026-10-04T07:55:49Z] openclaw restart attempt source=handoff mode=start-after-exit target=gui/501/ai.openclaw.gateway pid=32477 interactive=0
[2026-10-04T07:55:51Z] openclaw restart done source=handoff mode=start-after-exit interactive=0
Bootstrap failed: 5: Input/output error
[2026-10-04T09:00:00Z] openclaw restart attempt source=handoff mode=kickstart target=gui/501/ai.openclaw.gateway pid=81216 interactive=0
[2026-10-04T09:00:01Z] openclaw restart failed source=handoff mode=kickstart status=37 interactive=0`;
  const ev = restartEvents(log, 0);
  assert.deepEqual(ev.map((e) => [e.pid, e.trigger, e.outcome]), [[32477, "safe-rpc:deferred", "done"], [81216, null, "failed"]]);
  assert.equal(restartEvents(log, Date.parse("2026-10-04T07:55:49Z")).length, 1, "커서 뒤만");
  const restart = Date.parse("2026-10-04T16:55:49+09:00");
  const L = [
    { ts: "2026-10-04T16:57:00+09:00", key: "gateway.tool_authority", first_seen: "2026-10-04T16:55:00+09:00", fix: "gateway restart --safe", verified: false },
    { ts: "2026-10-04T17:10:00+09:00", key: "other.key", verified: true },
    { ts: "2026-10-04T19:45:42+09:00", key: "gateway.tool_authority", first_seen: "2026-10-04T16:55:00+09:00", fix: "확인만 — 재시작 후 정상", verified: true },
  ].map((x) => JSON.stringify(x)).join("\n");
  const d = nextDutyJudgement(L, restart);
  assert.equal(d.verified, true);
  assert.equal(d.ts, Date.parse("2026-10-04T19:45:42+09:00"));
  assert.equal(nextDutyJudgement(L, Date.parse("2026-10-04T20:00:00+09:00")), null);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lg-test-dvp-"));
  try {
    fs.writeFileSync(path.join(dir, "a.jsonl"), [use("x", "mcp__openclaw__nodes", restart + 1000), result("x", restart + 2000, { error: true, text: `${AUTHORITY_CLOSED} node.list` }),
      result("unknown", restart + 3000, { error: true, text: `${AUTHORITY_CLOSED} sessions.list.` })].map((l) => JSON.stringify(l)).join("\n"));
    const all = scanTranscripts(dir, restart, restart + 10_000);
    assert.equal(all.fail, 2, "이름 모르는 도구 결과는 감지기처럼 오픈클로로 본다");
    assert.equal(scanTranscripts(dir, restart, restart + 2500).fail, 1, "확인 시각 뒤 줄은 세지 않는다");
    assert.equal(scanTranscripts(path.join(dir, "없음"), restart).readable, false);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
