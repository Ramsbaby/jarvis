// signal.test.mjs — OpenClaw 가 시간 초과로 실행기를 끄면(SIGTERM): 장부에 남기고, 잠금을 풀고, 돌던 claude 자식도 끈다.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { sandbox, run, RUN, NODE, openDb } from "./helpers.mjs";

const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
const until = async (fn, ms = 10_000) => { const end = Date.now() + ms; while (Date.now() < end) { const v = fn(); if (v) return v; await new Promise((r) => setTimeout(r, 50)); } return null; };

test("SIGTERM: 노드 실행 중이면 ERROR crashed(1)·failed 기록·잠금 해제·claude 자식 종료, retry 로 잇는다", async (t) => {
  const sb = sandbox(t);
  const pidFile = path.join(sb.dir, "hang.pid");
  const hang = path.join(sb.dir, "claude-hang"); // 표준 입력을 받은 뒤 자기 pid 를 적고 멈춰 있는 가짜 claude
  fs.writeFileSync(hang, `#!${NODE}\nrequire("node:fs").writeFileSync(${JSON.stringify(pidFile)}, String(process.pid));\nsetInterval(() => {}, 1000);\n`, { mode: 0o755 });

  const child = spawn(NODE, [RUN, "start", "smoke", "s1", "--llm"], { env: { ...sb.env, LG_CLAUDE_BIN: hang } });
  let out = "";
  child.stdout.on("data", (d) => { out += d; });
  const closed = new Promise((r) => child.on("close", (code) => r(code)));
  const hangPid = Number(await until(() => fs.existsSync(pidFile) && fs.readFileSync(pidFile, "utf8")));
  assert.ok(hangPid > 0, "가짜 claude 가 떠야 한다");
  t.after(() => { if (alive(hangPid)) process.kill(hangPid, "SIGKILL"); });

  child.kill("SIGTERM");
  assert.equal(await closed, 1);
  assert.match(out.split("\n")[0], /^ERROR s1 crashed .*신호 SIGTERM/);
  assert.ok(await until(() => !alive(hangPid), 5000), "실행기가 끝나면 claude 자식도 끝나야 한다");

  const db = await openDb(sb);
  t.after(() => db.close());
  assert.equal(db.prepare("SELECT status FROM lg_threads WHERE thread_id='s1'").get().status, "failed");
  assert.equal(db.prepare("SELECT count(*) n FROM lg_locks").get().n, 0);

  // 원인이 풀리면(여기선 LLM 없이) retry 로 이어진다 — think 부터
  db.prepare("UPDATE lg_threads SET note=NULL WHERE thread_id='s1'").run();
  const fake = path.join(sb.dir, "claude-ok");
  fs.writeFileSync(fake, `#!${NODE}\nrequire("node:fs").readFileSync(0);\nprocess.stdout.write(JSON.stringify({ subtype: "success", is_error: false, result: "다시 쓴 요약", modelUsage: { "claude-haiku-4-5": {} } }));\n`, { mode: 0o755 });
  const r = run({ ...sb.env, LG_CLAUDE_BIN: fake }, ["retry", "s1"]);
  assert.equal(r.code, 0, r.out + r.err);
  assert.match(r.first, /^WAITING s1 .*다시 쓴 요약/);
});
