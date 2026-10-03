// selftest.test.mjs — 저장 부품이 안 뜨면 조용히 죽지 않고 원인을 말하고 1 로 끝나는지.
// 실제 고장 모양(설치 스크립트 건너뜀 → build 폴더 없음 → 'Could not locate the bindings file')을 임시 사본으로 재현한다.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { sandbox, ROOT, NODE } from "./helpers.mjs";

function brokenCopy(sb) {
  const app = path.join(sb.dir, "app");
  fs.mkdirSync(app);
  for (const f of ["run.mjs", "package.json", "lib", "graphs", "scripts"]) fs.cpSync(path.join(ROOT, f), path.join(app, f), { recursive: true });
  const nm = path.join(app, "node_modules");
  fs.mkdirSync(nm);
  for (const e of fs.readdirSync(path.join(ROOT, "node_modules"))) {
    if (e === "better-sqlite3") continue;
    fs.symlinkSync(path.join(ROOT, "node_modules", e), path.join(nm, e));
  }
  // better-sqlite3 는 JS 만 복사하고 네이티브 build/ 는 뺀다
  const src = path.join(ROOT, "node_modules", "better-sqlite3");
  const dst = path.join(nm, "better-sqlite3");
  fs.mkdirSync(dst);
  fs.cpSync(path.join(src, "package.json"), path.join(dst, "package.json"));
  fs.cpSync(path.join(src, "lib"), path.join(dst, "lib"), { recursive: true });
  return app;
}

test("자가 시험 실패: 네이티브 부품이 없으면 원인·처방을 말하고 1 로 끝난다, 상태 파일은 만들지 않는다", (t) => {
  const sb = sandbox(t);
  const app = brokenCopy(sb);
  for (const args of [["selftest"], ["status"], ["start", "smoke", "x1"]]) {
    const r = spawnSync(NODE, [path.join(app, "run.mjs"), ...args], { env: sb.env, encoding: "utf8", timeout: 30_000 });
    assert.equal(r.status, 1, `${args}: ${r.stdout}${r.stderr}`);
    assert.match(r.stdout.split("\n")[0], /^ERROR - selftest better-sqlite3 적재 실패: .*bindings/);
    assert.match(r.stderr, /npm install-scripts approve better-sqlite3/);
  }
  assert.equal(fs.existsSync(sb.state), false, "자가 시험 전에는 상태 폴더를 건드리지 않는다");
});

test("자가 시험 통과: 정상 설치에서는 OK 한 줄", (t) => {
  const sb = sandbox(t);
  const r = spawnSync(NODE, [path.join(ROOT, "run.mjs"), "selftest"], { env: sb.env, encoding: "utf8" });
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /^OK selftest sqlite \d+\.\d+\.\d+ · node v\d+/);
  assert.equal(r.stderr, "");
});
