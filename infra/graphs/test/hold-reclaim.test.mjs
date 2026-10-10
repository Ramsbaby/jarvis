// 디스크 관문 자가 회복 · 오래 이어진 관문 보류 알림 · 디스크 기준선 정본(10-05: 매일 QA 가 디스크 관문에 막혀 10:00·10:30 틱을 조용히 보류했다).
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { sandbox, run, at, T0, appWith } from "./helpers.mjs";
import { tickEnv, writeRegistry, STEPS } from "./helpers0b.mjs";
import { loadConfig } from "../lib/config.mjs";

const MIN = 60_000;

// 가짜 정리 도구(워크스페이스 scripts/disk-reclaim.sh 자리)를 시험용 허용 목록에 건다. 불린 횟수를 남기고 정한 JSON 을 낸다.
function fakeReclaim(sb, out = '{"ok":true,"dry":false,"free_before":15.8,"free_after":20.1,"steps":["flutter clean gostop_app"]}') {
  const calls = path.join(sb.dir, "reclaim-calls.log");
  const script = path.join(sb.dir, "fake-reclaim.sh");
  fs.writeFileSync(script, `#!/bin/sh\necho called >> "${calls}"\necho '[reclaim] 진행'\necho '${out}'\n`, { mode: 0o755 });
  const reg = writeRegistry(sb, { "graphs.disk-reclaim": { bin: script, argv: [], modes: ["shadow", "live"], timeoutSec: 30 } });
  return { calls, env: { LG_CMD_REGISTRY: reg } };
}
const metricsOf = (sb) => {
  const f = path.join(sb.state, "metrics.jsonl");
  return fs.existsSync(f) ? fs.readFileSync(f, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
};
const count = (f) => (fs.existsSync(f) ? fs.readFileSync(f, "utf8").trim().split("\n").length : 0);

test("디스크 관문에 막히고 기다리는 일이 있으면 공용 정리 도구를 부르고 다시 잰다", (t) => {
  const sb = sandbox(t);
  const fk = fakeReclaim(sb);
  const env = { ...tickEnv(sb, { now: T0 }), ...fk.env, LG_DISK_FLOOR_GIB: "100000" };
  assert.equal(run(env, ["start", "smoke", "r1", "--queue"], at(T0)).code, 0);
  const r = run(env, ["tick", "--verbose"], at(T0));
  assert.match(r.out, /HOLD disk/, "여전히 모자라면 보류는 그대로");
  assert.equal(count(fk.calls), 1, "정리 도구 1회");
  const rc = metricsOf(sb).filter((m) => m.ev === "reclaim");
  assert.equal(rc.length, 1);
  assert.equal(rc[0].ran, true);
  assert.equal(rc[0].free_after, 20.1);
  assert.deepEqual(rc[0].steps, ["flutter clean gostop_app"]);
});

test("기다리는 일이 없으면 부르지 않는다 · 다른 정리가 돌던 중(busy)이면 ran=false", (t) => {
  const sb = sandbox(t);
  const fk = fakeReclaim(sb, '{"ok":true,"busy":true,"note":"다른 정리가 도는 중"}');
  const env = { ...tickEnv(sb, { now: T0 }), ...fk.env, LG_DISK_FLOOR_GIB: "100000" };
  run(env, ["tick", "--verbose"], at(T0));
  assert.equal(count(fk.calls), 0, "일이 없으면 손대지 않는다");
  run(env, ["start", "smoke", "r2", "--queue"], at(T0));
  run(env, ["tick", "--verbose"], at(T0));
  assert.equal(count(fk.calls), 1);
  const rc = metricsOf(sb).filter((m) => m.ev === "reclaim");
  assert.equal(rc.length, 1);
  assert.equal(rc[0].ran, false);
  assert.equal(rc[0].busy, true);
});

test("일을 붙잡은 관문 보류가 30분 이어지면 알리고, 이어지면 3시간마다 다시 알린다 — 야간 보류는 알리지 않는다", (t) => {
  const sb = sandbox(t);
  const fk = fakeReclaim(sb, '{"ok":true,"free_before":15.8,"free_after":15.8,"steps":[]}');
  const env = { ...tickEnv(sb, { now: T0 }), ...fk.env, LG_DISK_FLOOR_GIB: "100000" };
  run(env, ["start", "smoke", "h1", "--queue"], at(T0));
  assert.doesNotMatch(run(env, ["tick"], at(T0)).out, /STUCK/, "처음 보류는 알리지 않는다");
  assert.doesNotMatch(run(env, ["tick"], at(T0 + 29 * MIN)).out, /STUCK/);
  const r = run(env, ["tick"], at(T0 + 31 * MIN));
  assert.match(r.out, /^STUCK h1 관문 보류 31분째\(알림 1회째\) — 디스크 여유 .* · 기다리는 일: h1/m, "알림(디스코드로 나가는 줄)");
  assert.doesNotMatch(run(env, ["tick"], at(T0 + 62 * MIN)).out, /STUCK/, "3시간 안에는 다시 알리지 않는다");
  // 10-09: 한 번만 알려 token_cap 보류 19시간이 조용했다 — 같은 보류가 이어지면 3시간마다 몇 번째인지·총 보류 시간과 함께 다시 알린다
  assert.doesNotMatch(run(env, ["tick"], at(T0 + 210 * MIN)).out, /STUCK/);
  assert.match(run(env, ["tick"], at(T0 + 212 * MIN)).out, /^STUCK h1 관문 보류 3시간 32분째\(알림 2회째\) — 디스크 여유 /m);
  assert.match(run(env, ["tick"], at(T0 + 392 * MIN)).out, /^STUCK h1 관문 보류 6시간 32분째\(알림 3회째\) — /m);
  // 다시 알리기를 끄면(0) 한 번만
  assert.doesNotMatch(run({ ...env, LG_HOLD_RENOTIFY_MIN: "0" }, ["tick"], at(T0 + 900 * MIN)).out, /STUCK/);

  const sb2 = sandbox(t);
  const two = new Date(2026, 9, 4, 2, 0).getTime();
  const quiet = { ...tickEnv(sb2, { now: two }), LG_QUIET: "01:30-04:30" };
  run(quiet, ["start", "smoke", "q1", "--queue"], at(two));
  run(quiet, ["tick"], at(two));
  assert.doesNotMatch(run(quiet, ["tick"], at(two + 40 * MIN)).out, /STUCK/, "야간(quiet) 보류는 일부러 세운 것");
});

test("디스크 기준선은 정책 파일 하나에서 — 관문 = 건강선 + 사본 + 여유(감시 경고선과 같은 선)", (t) => {
  const sb = sandbox(t);
  const pol = path.join(sb.dir, "disk-policy.json");
  fs.writeFileSync(pol, JSON.stringify({ floorGiB: 20, critGiB: 8, workCopyGiB: 0.5, workMarginGiB: 2 }));
  const g = loadConfig({ ...sb.env, LG_DISK_POLICY: pol }).gates;
  assert.equal(g.diskFloorGiB + g.copyEstGiB + g.diskMarginGiB, 22.5);
  const d = loadConfig({ ...sb.env, LG_DISK_POLICY: path.join(sb.dir, "none.json") }).gates;
  assert.equal(d.diskFloorGiB + d.copyEstGiB + d.diskMarginGiB, 16.2, "파일이 없으면 같은 기본값");
  const o = loadConfig({ ...sb.env, LG_DISK_POLICY: pol, LG_DISK_FLOOR_GIB: "1" }).gates;
  assert.equal(o.diskFloorGiB, 1, "환경변수(시험용)가 이긴다");
});

test("일하는 선만 모자라고 건강선은 지키면 이미 시작한 일은 이어 가고 새 일만 막는다 · 건강선 아래면 이어 가지도 않는다", (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { steps: STEPS });
  const fk = fakeReclaim(sb, '{"ok":true,"free_before":15.6,"free_after":15.6,"steps":[]}');
  const base = { ...tickEnv(sb), ...fk.env, LG_TICK_BUDGET_SEC: "1.2", LG_TEST_STEP_MS: "1000" };
  const statusOf = (env, th) => JSON.parse(lg(env, ["status", th, "--json"]).out);
  lg(base, ["start", "steps", "s1", "--queue"]);
  lg(base, ["tick"]);
  assert.equal(statusOf(base, "s1").status, "continue", "관문 없이 시작해 이어가기 상태");
  // 일하는 선(건강선 0 + 사본 0 + 여유 100000)은 모자라고 건강선(0)은 지킨다 — 10-05 QA 가 자기 녹화로 15.6GiB 가 된 상황
  const work = { ...base, LG_DISK_FLOOR_GIB: "0", LG_COPY_EST_GIB: "0", LG_DISK_MARGIN_GIB: "100000" };
  lg(work, ["start", "steps", "q2", "--queue"]);
  let done = false;
  for (let i = 0; i < 6 && !done; i++) {
    const r = lg(work, ["tick", "--verbose"]);
    assert.match(r.out, /HOLD disk/);
    done = statusOf(work, "s1").status === "done";
  }
  assert.ok(done, "시작한 s1 은 관문 보류 틱에서도 끝까지 간다");
  assert.equal(statusOf(work, "q2").status, "queued", "새 일 q2 는 시작하지 않는다");

  const sb2 = sandbox(t);
  const lg2 = appWith(sb2, { steps: STEPS });
  const fk2 = fakeReclaim(sb2, '{"ok":true,"steps":[]}');
  const base2 = { ...tickEnv(sb2), ...fk2.env, LG_TICK_BUDGET_SEC: "1.2", LG_TEST_STEP_MS: "1000" };
  lg2(base2, ["start", "steps", "s3", "--queue"]);
  lg2(base2, ["tick"]);
  const before = JSON.parse(lg2(base2, ["status", "s3", "--json"]).out);
  const unhealthy = { ...base2, LG_DISK_FLOOR_GIB: "100000" };
  lg2(unhealthy, ["tick"]);
  const after = JSON.parse(lg2(unhealthy, ["status", "s3", "--json"]).out);
  assert.equal(after.status, "continue");
  assert.equal(after.progress, before.progress, "건강선 아래면 이어 가지도 않는다");
});
