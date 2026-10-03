// helpers.mjs — 시험 공용. 시험 하나마다 임시 HOME·임시 상태 폴더를 만든다(진짜 런타임 상태를 건드리지 않는다).
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const RUN = path.join(ROOT, "run.mjs");
export const NODE = process.execPath;
export const FIXTURES = path.join(ROOT, "test", "fixtures");
export const T0 = Date.parse("2026-01-01T00:00:00Z");
export const HOUR = 3_600_000;
export const DAY = 86_400_000;
export const at = (ms) => ({ extraEnv: { LG_NOW: String(ms) } });

export function sandbox(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lg-test-"));
  const home = path.join(dir, "home");
  fs.mkdirSync(home);
  const state = path.join(dir, "state");
  const env = {
    PATH: process.env.PATH, HOME: home, TMPDIR: os.tmpdir(), LANG: "en_US.UTF-8",
    LG_TEST_MODE: "1", LG_STATE_DIR: state, LG_SMOKE_TRACE: path.join(dir, "trace.log"), LG_DAILY: "", // 하루 1회 접수는 그 시험에서만 켠다
  };
  t?.after?.(() => {
    // 이 시험이 mktemp 로 만든 폴더만 지운다
    if (path.dirname(dir) === os.tmpdir() && path.basename(dir).startsWith("lg-test-")) fs.rmSync(dir, { recursive: true, force: true });
  });
  return { dir, home, state, env };
}

const shape = (code, out, err) => {
  const lines = String(out ?? "").trimEnd().split("\n");
  return { code, out: String(out ?? ""), err: String(err ?? ""), first: lines[0] ?? "", lines };
};

export function run(env, args, { extraEnv = {}, nodeArgs = [], timeout = 60_000 } = {}) {
  const r = spawnSync(NODE, [...nodeArgs, RUN, ...args], { env: { ...env, ...extraEnv }, encoding: "utf8", timeout });
  return shape(r.status, r.stdout, r.stderr);
}

export function runAsync(env, args, { extraEnv = {}, nodeArgs = [] } = {}) {
  return new Promise((resolve) => {
    const child = spawn(NODE, [...nodeArgs, RUN, ...args], { env: { ...env, ...extraEnv } });
    let out = "", err = "";
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { err += d; });
    child.on("close", (code) => resolve(shape(code, out, err)));
  });
}

// 노드가 몇 번 돌았는지(LG_SMOKE_TRACE)
export function counts(sb) {
  const f = sb.env.LG_SMOKE_TRACE;
  const c = {};
  if (fs.existsSync(f)) for (const l of fs.readFileSync(f, "utf8").split("\n").filter(Boolean)) { const n = l.split(" ")[1]; c[n] = (c[n] ?? 0) + 1; }
  return c;
}

export const readPending = (sb) => {
  const f = path.join(sb.state, "pending.jsonl");
  return fs.existsSync(f) ? fs.readFileSync(f, "utf8") : "";
};
export const statusJson = (sb, extra) => JSON.parse(run(sb.env, ["status", "--all", "--json"], extra).out);

// 폴더 아래 모든 파일에서 표식 바이트가 몇 번 나오는지
export function occurrences(dir, mark) {
  let n = 0;
  const needle = Buffer.from(mark);
  const walk = (p) => {
    for (const e of fs.readdirSync(p, { withFileTypes: true })) {
      const f = path.join(p, e.name);
      if (e.isDirectory()) walk(f);
      else if (e.isFile()) { const b = fs.readFileSync(f); for (let i = b.indexOf(needle); i >= 0; i = b.indexOf(needle, i + 1)) n++; }
    }
  };
  walk(dir);
  return n;
}

// 가짜 claude: 받은 인자·환경·입력·작업 폴더를 log 에 적고 정해진 JSON 을 낸다(mode: ok | fable | fail).
// 셸 없이 바로 Node 로 뜨는 실행 파일이다(#!node) — 환경변수 시험이 셸이 더하는 변수에 흐려지지 않게.
export function fakeClaude(sb, mode = "ok") {
  const log = path.join(sb.dir, `fake-claude-${mode}.jsonl`);
  const bin = path.join(sb.dir, `claude-${mode}`);
  const body = `require(${JSON.stringify(path.join(FIXTURES, "fake-claude.cjs"))})(${JSON.stringify(log)}, ${JSON.stringify(mode)});\n`;
  fs.writeFileSync(bin, `#!${NODE}\n${body}`, { mode: 0o755 });
  const calls = () => (fs.existsSync(log) ? fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
  return { bin, log, calls };
}

// 어떤 pid 가 확실히 죽은 pid 가 되게: 짧은 자식을 띄우고 끝나길 기다린다
export function deadPid() {
  const r = spawnSync(NODE, ["-e", "process.stdout.write(String(process.pid))"], { encoding: "utf8" });
  return Number(r.stdout);
}

// 시험 프로세스 안에서 상태 DB 를 직접 만진다(잠금·등록부 조작용)
export async function openDb(sb) {
  const { createRequire } = await import("node:module");
  const Database = createRequire(path.join(ROOT, "package.json"))("better-sqlite3");
  return new Database(path.join(sb.state, "checkpoints.db"), { timeout: 15_000 });
}

// 실행기 사본(+시험용 그래프)을 임시 폴더에 만든다. node_modules 는 원본을 가리킨다.
export function appWith(sb, graphs = {}) {
  const app = path.join(sb.dir, "app");
  if (!fs.existsSync(app)) {
    for (const f of ["run.mjs", "package.json", "lib", "graphs", "scripts"]) fs.cpSync(path.join(ROOT, f), path.join(app, f), { recursive: true });
    fs.symlinkSync(path.join(ROOT, "node_modules"), path.join(app, "node_modules"));
  }
  for (const [name, src] of Object.entries(graphs)) fs.writeFileSync(path.join(app, "graphs", `${name}.mjs`), src);
  return (env, args, { extraEnv = {}, timeout = 60_000 } = {}) => {
    const r = spawnSync(NODE, [path.join(app, "run.mjs"), ...args], { env: { ...env, ...extraEnv }, encoding: "utf8", timeout });
    return shape(r.status, r.stdout, r.stderr);
  };
}
