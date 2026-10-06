// 발견·지표·이상을 묻지 않는다(10-06) — 그림자에서도 보고성 부수효과는 실제로 · 그래프마다 verify_log(M2) · lg-report 창·연속 보류·미측정 · lg-watch.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { sandbox, run, ROOT, NODE, T0 } from "./helpers.mjs";
import { metrics, effects } from "./helpers0b.mjs";
import { createEffect, REPORT_KINDS } from "../lib/effects.mjs";
import { fixVerifyLog } from "../graphs/gostop-fix.mjs";
import { findIssues, postOrders, HELD_STREAK_MAX } from "../scripts/lg-watch.mjs";

const H = 3_600_000;
const iso = (ms) => new Date(ms).toISOString();

test("effect: 보고성(orders_append)은 그림자에서도 실제로 한 번 — 옛 '했을 일'은 막지 않는다 · 다른 스레드·실제 스레드는 다시 안 함 · 당직 장부는 그대로 그림자", async (t) => {
  const sb = sandbox(t);
  fs.mkdirSync(sb.state, { recursive: true });
  const cfg = { stateDir: sb.state, effectsPath: path.join(sb.state, "effects.jsonl") };
  fs.writeFileSync(cfg.effectsPath, `${JSON.stringify({ key: "o:1", kind: "orders_append", mode: "shadow", status: "would_run", wouldRun: true, thread: "old" })}\n`);
  const seen = [];
  const metric = (ev, f) => seen.push(`${f.thread}:${f.outcome}${f.report ? ":보고" : ""}`);
  let n = 0;
  const fn = async () => { n++; return "썼음"; };
  const mk = (thread, mode) => createEffect({ cfg, now: () => T0, thread, mode, metric });
  assert.ok(REPORT_KINDS.has("orders_append") && !REPORT_KINDS.has("duty.ledger_append") && !REPORT_KINDS.has("git_commit_push"));
  assert.deepEqual(await mk("s1", "shadow")("o:1", "orders_append", fn), { ran: true, value: "썼음", report: true });
  assert.deepEqual(await mk("s1", "shadow")("o:1", "orders_append", fn), { ran: false, dedup: true, report: true }, "재시도·재개에도 한 번");
  assert.deepEqual(await mk("s2", "shadow")("o:1", "orders_append", fn), { ran: false, dedup: true, report: true }, "다른 그림자 스레드도 다시 안 한다");
  assert.deepEqual(await mk("l1", "live")("o:1", "orders_append", fn), { ran: false, dedup: true }, "실제 스레드도 그림자가 이미 올린 줄은 다시 안 올린다");
  assert.equal(n, 1);
  let wrote = 0;
  assert.deepEqual(await mk("s1", "shadow")("dv:1", "duty.ledger_append", async () => { wrote++; }), { ran: false, shadow: true }, "당직 장부는 공사 동결 — 그림자");
  assert.deepEqual(await mk("s1", "shadow")("c:1", "git_commit_push", async () => { wrote++; }), { ran: false, shadow: true });
  assert.equal(wrote, 0);
  assert.deepEqual(effects(sb).map((e) => [e.key, e.mode, e.status, e.report ?? false]),
    [["o:1", "shadow", "would_run", false], ["o:1", "shadow", "started", true], ["o:1", "shadow", "ok", true], ["dv:1", "shadow", "would_run", false], ["c:1", "shadow", "would_run", false]]);
  assert.deepEqual(seen, ["s1:ran:보고", "s1:dedup:보고", "s2:dedup:보고", "l1:dedup", "s1:would_run", "s1:would_run"]);
  // 보고성 fn 이 실패하면 failed 로 적고 다음에 다시 낸다(결과 모름이 아니다)
  await assert.rejects(mk("s3", "shadow")("o:2", "orders_append", async () => { throw new Error("디스크 꽉 참"); }), /디스크 꽉 참/);
  assert.equal((await mk("s3", "shadow")("o:2", "orders_append", fn)).ran, true);
});

test("gostop-fix 확인 기록(M2): 끝난 상태마다 근거가 있어야 적고, 포기·근거 없음·고칠 안 파일 없음은 비운다", (t) => {
  const sb = sandbox(t);
  const plan = path.join(sb.dir, "plan.md");
  fs.writeFileSync(plan, "# 고칠 안\n");
  const b = { stage: "1b", fixAttempt: 2, verifyOk: true, review: { pass: true },
    steps: [{ phase: "verify", fix: 1, id: "target", ok: false }, { phase: "verify", fix: 2, id: "target", ok: true }, { phase: "verify", fix: 2, id: "three_path", ok: true }] };
  assert.match(fixVerifyLog(b, "ready", plan), /^gostop-fix ready: 격리 검증 target,three_path 통과 · 검토 통과 — .*plan\.md$/, "마지막 수정의 단계만 본다");
  assert.match(fixVerifyLog(b, "would_ask", plan), /^gostop-fix would_ask: /);
  assert.equal(fixVerifyLog({ ...b, review: { pass: false } }, "ready", plan), null);
  assert.equal(fixVerifyLog({ ...b, steps: [...b.steps, { phase: "verify", fix: 2, id: "full", ok: false }] }, "ready", plan), null);
  assert.equal(fixVerifyLog({ ...b, steps: [] }, "ready", plan), null, "검증 단계가 없으면 확인 아님");
  assert.equal(fixVerifyLog(b, "gave_up", plan), null);
  assert.equal(fixVerifyLog(b, "ready", path.join(sb.dir, "없음.md")), null);
  assert.match(fixVerifyLog({ stage: "1a", repro: "reproduced", diag: { files: [] } }, "ready", plan), /^gostop-fix ready\(1a\): 재현 reproduced · 진단 있음/);
  assert.equal(fixVerifyLog({ stage: "1a", repro: "reproduced", diag: null }, "ready", plan), null);
  assert.match(fixVerifyLog({ reproRuns: [{}, {}] }, "not_reproduced", plan), /재현 실행 2회 판정/);
  assert.equal(fixVerifyLog({ reproRuns: [] }, "flaky", plan), null);
  assert.match(fixVerifyLog({ redRuns: [{}, {}] }, "no_red", plan), /빨간불 확인 2회 모두 아님/);
  assert.match(fixVerifyLog({ diag: { rule_gap: true } }, "rule_decision", plan), /규칙 공백 진단/);
});

test("smoke: 끝나면 done.verified 에 확인한 것(수집·초안·승인 답)이 남는다", (t) => {
  const sb = sandbox(t);
  assert.equal(run(sb.env, ["start", "smoke", "v1"]).code, 0);
  assert.match(run(sb.env, ["resume", "v1", "approved"]).first, /^DONE v1 /);
  const d = metrics(sb).find((m) => m.ev === "done" && m.thread === "v1");
  assert.match(d.verified, /^smoke 수집 2·초안 \d+자·승인 답 approved$/);
});

// 판정 기록 꾸러미: 지금 기준 최근 24시간·7일·오래전이 섞인 metrics·effects·당직 장부
function fixture(sb, { now = Date.now(), ticks = true, anomalies = true } = {}) {
  fs.mkdirSync(sb.state, { recursive: true });
  const m = [];
  const ev = (at, rec) => m.push({ ts: iso(at), t: at, ...rec });
  if (ticks) for (let i = 1; i <= 6; i++) ev(now - i * 0.5 * H, { ev: "tick", outcome: "idle" });
  const fx = [];
  const ledger = [];
  if (anomalies) {
    ev(now - 3 * H, { ev: "done", thread: "qa-ok", graph: "gostop-qa", mode: "shadow", verified: "gostop-qa 판 4/4 · 지시함 1/1 확인 — /x/summary.md" });
    ev(now - 2 * H, { ev: "done", thread: "fix-x", graph: "gostop-fix", mode: "shadow", verified: null });
    ev(now - 50 * H, { ev: "done", thread: "fix-old", graph: "gostop-fix", mode: "shadow", verified: null });
    ev(now - 60 * H, { ev: "start", thread: "lost-1", graph: "smoke", mode: "shadow" }); // 끝나지 않고 48시간+ → M4
    // 야간 금지(quiet) 7틱 연속은 설계상 — 세지 않는다. 디스크는 HELD_STREAK_MAX 틱 연속 → 알림
    for (let i = 0; i < 7; i++) { ev(now - 20 * H + i * 0.5 * H, { ev: "held", scope: "tick", reasons: ["quiet"] }); ev(now - 20 * H + i * 0.5 * H, { ev: "tick", outcome: "hold" }); }
    ev(now - 16 * H, { ev: "tick", outcome: "idle" });
    for (let i = 0; i < HELD_STREAK_MAX; i++) { ev(now - 10 * H + i * 0.5 * H, { ev: "held", scope: "tick", reasons: ["disk"] }); ev(now - 10 * H + i * 0.5 * H, { ev: "tick", outcome: "hold" }); }
    ev(now - 7 * H, { ev: "tick", outcome: "idle" });
    ev(now - 6 * H, { ev: "held", scope: "tick", reasons: ["busy"] }); // 한 번 — 기준 아래
    ev(now - 30 * H, { ev: "bench", thread: "b1", bench: "c1", reproduced: true, diag_match: true });
    ev(now - 5 * H, { ev: "bench", thread: "b2", bench: "c2", reproduced: false, diag_match: null });
    const f = (at, rec) => fx.push({ ts: iso(at), t: at, thread: "x", node: "n", ...rec });
    f(now - 4 * H, { key: "gostop-qa-order:D1-a", kind: "orders_append", mode: "shadow", status: "started", report: true });
    f(now - 4 * H, { key: "gostop-qa-order:D1-a", kind: "orders_append", mode: "shadow", status: "ok", report: true });
    for (const s of ["started", "ok", "started", "ok"]) f(now - 3 * H, { key: "commit:dup", kind: "git_commit_push", mode: "live", status: s });
    f(now - 40 * H, { key: "old:unknown", kind: "fad_distribute", mode: "live", status: "started" }); // 창 밖 결과 모름 — 알리지 않는다
    f(now - 1 * H, { key: "o:w", kind: "orders_append", mode: "shadow", status: "would_run", wouldRun: true });
    ledger.push({ ts: iso(now - 2 * H), key: "graphs.shadow-swallowed-findings", found_by: "owner", item: "그림자가 발견을 묻음" });
  }
  m.sort((a, b) => a.t - b.t); // 기록은 추가 전용이라 시간 순이다
  fs.writeFileSync(path.join(sb.state, "metrics.jsonl"), m.map((x) => JSON.stringify(x)).join("\n") + (m.length ? "\n" : ""));
  fs.writeFileSync(path.join(sb.state, "effects.jsonl"), fx.map((x) => JSON.stringify(x)).join("\n") + (fx.length ? "\n" : ""));
  const ledgerFile = path.join(sb.dir, "ledger.jsonl");
  fs.writeFileSync(ledgerFile, ledger.map((x) => JSON.stringify(x)).join("\n") + "\n");
  const orders = path.join(sb.dir, "orders.md");
  fs.writeFileSync(orders, "# 지시함\n\n## 옛 절\n- [ ] 다른 일\n- [x] 고스톱 멈춤 정리 (id L1-done1)\n");
  const qa = path.join(sb.dir, "qa-auto");
  const kst = (ms) => new Date(ms + 9 * H).toISOString().slice(0, 10);
  if (anomalies) {
    fs.mkdirSync(path.join(qa, kst(now)), { recursive: true });
    fs.writeFileSync(path.join(qa, kst(now), "signals.json"), JSON.stringify({ signals: [
      { sigkey: "visual:L1-done1:abc", severity: "상", report: "[상] 이미 정리됨" },
      { sigkey: "visual:D2-miss1:abc", severity: "상", report: "[상] 진행 불가" },
      { sigkey: "visual:D3-low:abc", severity: "중", report: "[중] 깜빡임" }] }));
    fs.mkdirSync(path.join(qa, "2020-01-01"), { recursive: true }); // 창 밖 날짜 — 보지 않는다
    fs.writeFileSync(path.join(qa, "2020-01-01", "signals.json"), JSON.stringify({ signals: [{ sigkey: "visual:OLD-1:abc", severity: "상" }] }));
  }
  const env = { ...sb.env, LG_LEDGER: ledgerFile, LG_WATCH_ORDERS: orders, GQA_STATE: qa };
  return { env, orders, qa };
}
const report = (env, extra = []) => JSON.parse(spawnSync(NODE, [path.join(ROOT, "lg-report.mjs"), "--json", ...extra], { env, encoding: "utf8" }).stdout);
const watch = (env, extra = []) => spawnSync(NODE, [path.join(ROOT, "scripts", "lg-watch.mjs"), ...extra], { env, encoding: "utf8" });

test("lg-report: --hours 창 · M2 미검증 목록 · M3 그림자 보고성 실행과 중복 목록 · 같은 사유 연속 보류 · M8 비율과 '한 번도 안 잰 칸'", (t) => {
  const sb = sandbox(t);
  const { env } = fixture(sb);
  const day = report(env, ["--hours", "24"]);
  const all = report(env);
  assert.equal(day.range.hours, 24);
  assert.deepEqual([day.m2.done, day.m2.verified, day.m2.unverified], [2, 1, 1]);
  assert.deepEqual(day.m2.unverified_list.map((x) => x.thread), ["fix-x"]);
  assert.equal(all.m2.unverified, 2, "창이 없으면 옛것도 센다");
  assert.equal(day.m3.report_runs, 1, "그림자의 보고성 실행도 실제 실행으로 센다");
  assert.equal(day.m3.duplicates, 1);
  assert.deepEqual(day.m3.dup_list.map((x) => x.key), ["commit:dup"]);
  assert.deepEqual(day.m3.shadow_would_run, { orders_append: 1 });
  assert.deepEqual(all.m3.unknown_list.map((x) => x.key), ["old:unknown"]);
  assert.equal(day.held_streak.disk.max, HELD_STREAK_MAX);
  assert.equal(day.held_streak.disk.current, 0, "보류 아닌 틱이 연속을 끊는다");
  assert.equal(day.held_streak.quiet.max, 7);
  assert.equal(day.held_streak.busy.max, 1);
  const b = report(env, ["--hours", "168"]).m8;
  assert.equal(b.runs, 2);
  assert.equal(b.rates.reproduced, 50);
  assert.deepEqual(b.below, ["reproduced"]);
  assert.deepEqual(b.unmeasured, ["hidden_pass", "ai_misjudge"], "값이 한 번도 안 적힌 칸은 0%가 아니라 '안 잼'");
  assert.equal(all.m4.abandoned_unreported, 1);
  assert.ok(day.last_tick);
  const md = spawnSync(NODE, [path.join(ROOT, "lg-report.mjs"), "--hours", "24"], { env, encoding: "utf8" }).stdout;
  assert.match(md, /보류 연속\(틱\): .*disk 최장 4/);
  assert.match(md, /\| 2 \| 1 \| 1 \| fix-x \|/);
});

test("lg-watch: 기준 밖이면 한국어 요약 + 지시함에 열쇠별 한 줄 · 다시 돌려도 중복 0 · 닫힌 뒤 다시 생기면 새로 · 야간 금지·한 번 보류·창 밖은 조용", (t) => {
  const sb = sandbox(t);
  const { env, orders } = fixture(sb);
  const r = watch(env);
  assert.equal(r.status, 0, r.stderr);
  const out = r.stdout;
  assert.match(out, /^랭그래프 감시 — 기준 밖 7건\. 지시함에 새로 7건 올렸습니다\.\n/);
  for (const re of [/검증 없이 끝난 일 1건\(완료 2건 중\).*fix-x\(gostop-fix\)/, /같은 부수효과가 두 번 실행됨 1건.*commit:dup/, /48시간 넘게 보고 없이 남은 일 1건.*lost-1/,
    /주인님이 먼저 찾은 루프 고장 1건.*graphs\.shadow-swallowed-findings/, /보류 'disk' 4회\(최장 연속 4틱\)/, /벤치 기준 밖.*reproduced 미달\(50%\) · hidden_pass 한 번도 안 잼 · ai_misjudge 한 번도 안 잼/,
    /고스톱 실기 QA 상급 발견 1건이 수리 목록에 없음.*D2-miss1/]) assert.match(out, re);
  assert.doesNotMatch(out, /quiet|'busy'|L1-done1|D3-low|OLD-1|old:unknown|틱 0회/);
  const txt = fs.readFileSync(orders, "utf8");
  assert.ok(txt.startsWith("# 지시함\n\n## 옛 절\n- [ ] 다른 일\n"), "앞부분은 그대로 — 끝에 덧붙이기만");
  assert.match(txt, /\n\n## \d{4}-\d{2}-\d{2} \d{2}:\d{2} — 랭그래프 감시\(lg-watch\)\n- \[ \] \(당직 몫\) \*\*랭그래프 이상 — /);
  const keys = [...txt.matchAll(/\[lg-watch:([^\]]+)\]/g)].map((m) => m[1]);
  assert.deepEqual(keys.sort(), ["held:disk", "m2", "m3", "m4", "m7", "m8", "qa-high"]);
  // 다시 — 열린 줄이 있으면 더하지 않는다. QA 상급 발견은 감시 줄이 id 를 지시함에 적었으니 이제 '목록에 있음'(다시 알리지 않는다)
  const r2 = watch(env);
  assert.match(r2.stdout, /^랭그래프 감시 — 기준 밖 6건\. 지시함에 새로 0건 올렸습니다\(6건은 이미 열려 있음\)\./);
  assert.doesNotMatch(r2.stdout, /D2-miss1/);
  assert.equal(fs.readFileSync(orders, "utf8"), txt, "지시함 그대로");
  // 하나를 닫으면(처리됨) 다음에 같은 이상이 또 있으면 그것만 새로 올린다
  fs.writeFileSync(orders, txt.replace(/- \[ \] (\(당직 몫\) \*\*랭그래프 이상 — 검증 없이)/, "- [x] $1"));
  const r3 = watch(env);
  assert.match(r3.stdout, /지시함에 새로 1건 올렸습니다\(5건은 이미 열려 있음\)/);
  assert.equal([...fs.readFileSync(orders, "utf8").matchAll(/\[lg-watch:m2\]/g)].length, 2);
  // 시험 실행은 지시함을 쓰지 않는다
  const before = fs.readFileSync(orders, "utf8");
  assert.match(watch(env, ["--dry-run"]).stdout, /시험 실행 — 지시함은 쓰지 않음/);
  assert.equal(fs.readFileSync(orders, "utf8"), before);
});

test("lg-watch: 이상이 없으면 정확히 NO_REPLY · 틱이 0회면 그것만으로 알린다 · 집계를 못 읽으면 실패 한 줄과 종료 1", (t) => {
  const sb = sandbox(t);
  const { env, orders } = fixture(sb, { anomalies: false });
  const before = fs.readFileSync(orders, "utf8");
  const r = watch(env);
  assert.equal(r.status, 0);
  assert.equal(r.stdout, "NO_REPLY\n");
  assert.equal(fs.readFileSync(orders, "utf8"), before);
  const sb2 = sandbox(t);
  const f2 = fixture(sb2, { anomalies: false, ticks: false });
  const r2 = watch(f2.env);
  assert.match(r2.stdout, /^랭그래프 감시 — 기준 밖 1건\./);
  assert.match(r2.stdout, /최근 24시간 틱 0회 — .*마지막 틱 없음/);
  assert.match(fs.readFileSync(f2.orders, "utf8"), /\[lg-watch:ticks0\]/);
  const bad = watch({ ...env, LG_DETACH_MAX_SEC: "-1" }); // 설정 오류로 lg-report 가 죽는 경우
  assert.equal(bad.status, 1);
  assert.match(bad.stdout, /^랭그래프 감시 실패 — lg-report .*실패/);
});

test("lg-watch 판정 함수: 위험 보류 사유는 1회부터 · 실행 없는 벤치는 조용 · 지시함 열쇠는 열린 줄만 본다", (t) => {
  const base = { range: { since: iso(Date.now() - 24 * H), hours: 24 }, ticks: 3, held: {}, held_streak: {}, m1: { abandoned: 0 }, m2: { unverified: 0, unverified_list: [] },
    m3: { dup_list: [], unknown_list: [] }, m4: { abandoned_unreported: 0, list: [] }, m6: { fable_calls: 0 }, m7: { incidents: [] }, m8: { runs: 0, below: [], unmeasured: [] } };
  const none = findIssues({ day: base, all: base, bench: base });
  assert.deepEqual(none, []);
  const d = { ...base, held: { effect_unknown: 1, usage_stale: 2 }, held_streak: { usage_stale: { max: 2, current: 2 } }, m6: { fable_calls: 1 } };
  assert.deepEqual(findIssues({ day: d, all: base, bench: base }).map((x) => x.key), ["fable", "held:effect_unknown"]);
  const sb = sandbox(t);
  const f = path.join(sb.dir, "o.md");
  fs.writeFileSync(f, "- [x] 끝난 것 [lg-watch:m2]\n- [ ] 다른 [lg-watch:m22]\n");
  const { added, open } = postOrders(f, [{ key: "m2", title: "t", detail: "d" }], Date.now());
  assert.deepEqual([added.length, open.length], [1, 0], "닫힌 줄·비슷한 열쇠는 막지 않는다");
});
