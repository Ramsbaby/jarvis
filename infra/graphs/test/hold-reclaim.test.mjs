// 디스크 관문 자가 회복 · 오래 이어진 관문 보류 알림(10-05: 매일 QA 가 디스크 관문에 막혀 10:00·10:30 틱을 조용히 보류했다).
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { sandbox, run, at, T0 } from "./helpers.mjs";
import { tickEnv, writeRegistry } from "./helpers0b.mjs";

const MIN = 60_000;

// 가짜 flutter(불린 기록 + build/ 지움)와 가짜 pgrep(돌고 있는 flutter 없음/있음)을 허용 목록(시험용)에 건다.
function fakes(sb, { flutterRunning = false, name = "gostop_app" } = {}) {
  const app = path.join(sb.dir, name, "gostop_app");
  fs.mkdirSync(path.join(app, "build", "x"), { recursive: true });
  const calls = path.join(sb.dir, `${name}-flutter-calls.log`);
  const flutter = path.join(sb.dir, `${name}-fake-flutter`);
  fs.writeFileSync(flutter, `#!/bin/sh\necho "$PWD $*" >> "${calls}"\nrm -rf build\nexit 0\n`, { mode: 0o755 });
  const pgrep = path.join(sb.dir, `${name}-fake-pgrep`);
  fs.writeFileSync(pgrep, `#!/bin/sh\nexit ${flutterRunning ? 0 : 1}\n`, { mode: 0o755 });
  const reg = writeRegistry(sb, {
    "graphs.flutter-running": { bin: pgrep, argv: ["-f", "flutter_tools.snapshot"], modes: ["shadow", "live"], timeoutSec: 10 },
    "graphs.flutter-clean": { bin: flutter, argv: ["clean"], cwd: "{repo}", params: { repo: "^/(?:(?!\\.{1,2}/)[A-Za-z0-9._-]+/)*gostop_app$" }, modes: ["shadow", "live"], timeoutSec: 30 },
  });
  return { app, calls, env: { LG_RECLAIM_FLUTTER_DIRS: app, LG_CMD_REGISTRY: reg } };
}
const metricsOf = (sb) => {
  const f = path.join(sb.state, "metrics.jsonl");
  return fs.existsSync(f) ? fs.readFileSync(f, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
};

test("디스크 관문에 막히고 기다리는 일이 있으면 flutter build/ 를 정리 명령으로 치우고 다시 잰다", (t) => {
  const sb = sandbox(t);
  const fk = fakes(sb);
  const env = { ...tickEnv(sb, { now: T0 }), ...fk.env, LG_DISK_FLOOR_GIB: "100000" };
  assert.equal(run(env, ["start", "smoke", "r1", "--queue"], at(T0)).code, 0);
  const r = run(env, ["tick", "--verbose"], at(T0));
  assert.match(r.out, /HOLD disk/, "여전히 모자라면 보류는 그대로");
  assert.match(fs.readFileSync(fk.calls, "utf8"), new RegExp(`${fk.app} clean`), "그 폴더에서 flutter clean");
  assert.ok(!fs.existsSync(path.join(fk.app, "build")), "build/ 가 치워졌다");
  const rc = metricsOf(sb).filter((m) => m.ev === "reclaim");
  assert.equal(rc.length, 1);
  assert.equal(rc[0].ran, true);
});

test("기다리는 일이 없거나, 대화 작업 표식·돌고 있는 flutter 가 있으면 치우지 않는다", (t) => {
  const sb = sandbox(t);
  const fk = fakes(sb);
  const env = { ...tickEnv(sb, { now: T0 }), ...fk.env, LG_DISK_FLOOR_GIB: "100000" };
  run(env, ["tick", "--verbose"], at(T0));
  assert.ok(!fs.existsSync(fk.calls), "일이 없으면 손대지 않는다");
  run(env, ["start", "smoke", "r2", "--queue"], at(T0));
  fs.writeFileSync(path.join(fk.app, ".jarvis-busy"), "");
  run(env, ["tick", "--verbose"], at(T0));
  assert.ok(!fs.existsSync(fk.calls), "대화 작업 중이면 치우지 않는다");
  fs.rmSync(path.join(fk.app, ".jarvis-busy"));
  const busy = fakes(sb, { flutterRunning: true, name: "second" });
  run({ ...env, ...busy.env }, ["tick", "--verbose"], at(T0));
  assert.ok(!fs.existsSync(busy.calls), "flutter 가 돌고 있으면 치우지 않는다");
  assert.ok(fs.existsSync(path.join(busy.app, "build")));
  assert.deepEqual(metricsOf(sb).filter((m) => m.ev === "reclaim").flatMap((m) => m.dirs.map((d) => d.skip)), ["busy", "flutter_running"]);
});

test("일을 붙잡은 관문 보류가 30분 이어지면 한 번만 알린다 — 야간 보류는 알리지 않는다", (t) => {
  const sb = sandbox(t);
  const env = { ...tickEnv(sb, { now: T0 }), LG_RECLAIM_FLUTTER_DIRS: "", LG_DISK_FLOOR_GIB: "100000" };
  run(env, ["start", "smoke", "h1", "--queue"], at(T0));
  assert.doesNotMatch(run(env, ["tick"], at(T0)).out, /STUCK/, "처음 보류는 알리지 않는다");
  assert.doesNotMatch(run(env, ["tick"], at(T0 + 29 * MIN)).out, /STUCK/);
  const r = run(env, ["tick"], at(T0 + 31 * MIN));
  assert.match(r.out, /^STUCK h1 관문 보류 31분째 — 디스크 여유 .* · 기다리는 일: h1/m, "알림(디스코드로 나가는 줄)");
  assert.doesNotMatch(run(env, ["tick"], at(T0 + 62 * MIN)).out, /STUCK/, "같은 보류는 한 번만");

  const sb2 = sandbox(t);
  const two = new Date(2026, 9, 4, 2, 0).getTime();
  const quiet = { ...tickEnv(sb2, { now: two }), LG_RECLAIM_FLUTTER_DIRS: "", LG_QUIET: "01:30-04:30" };
  run(quiet, ["start", "smoke", "q1", "--queue"], at(two));
  run(quiet, ["tick"], at(two));
  assert.doesNotMatch(run(quiet, ["tick"], at(two + 40 * MIN)).out, /STUCK/, "야간(quiet) 보류는 일부러 세운 것");
});
