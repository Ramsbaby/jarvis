#!/usr/bin/env node
// gostop-bench-live.mjs — 벤치 실주행(설계 §9 1a '벤치 2건 재현·진단 끝까지'). 진짜 고스톱 저장소(읽기만)·진짜 flutter·진짜 claude(sonnet 진단 + haiku 요약).
// 기본 시험 묶음에 들지 않는다(이름이 *.test.mjs 가 아니다). 사람이 보고 있을 때 손으로 돌린다 — 구독 한도를 쓴다.
//   node test/gostop-bench-live.mjs <출력폴더> hist-69a0144 hist-02d61dc
// 상태는 임시 폴더(LG_STATE_DIR) — 운영 상태·대기열은 건드리지 않는다. 사본도 그 아래에 만든다.
// 본 저장소의 HEAD·git status 를 앞뒤로 재서 바뀌지 않았는지 적는다.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadBench, benchSignal, runDir } from "../graphs/gostop-common.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const RUN = path.join(ROOT, "run.mjs");
const [outDir, ...ids] = process.argv.slice(2);
if (!outDir || !ids.length) { console.error("사용: gostop-bench-live.mjs <출력폴더> <벤치 id…>"); process.exit(2); }
fs.mkdirSync(outDir, { recursive: true });
const HOME = os.userInfo().homedir;
const REPO = path.join(HOME, "projects", "gostop_app");
// LG_BENCH_STATE: 앞 실행의 상태 폴더를 이어 쓴다(이미 있는 스레드는 시작하지 않고 틱만). LG_DISK_FLOOR_GIB 등 관문 설정은 그대로 넘긴다.
const state = process.env.LG_BENCH_STATE || fs.mkdtempSync(path.join(HOME, ".cache", "lg-1a-bench-"));
const env = {
  PATH: process.env.PATH, HOME, LANG: "en_US.UTF-8", TMPDIR: os.tmpdir(), USER: os.userInfo().username,
  LG_STATE_DIR: path.join(state, "state"), LG_GOSTOP_REPO: REPO, LG_DAILY: "", LG_TICK_BUDGET_SEC: "480",
  ...Object.fromEntries(["LG_DISK_FLOOR_GIB", "LG_COPY_EST_GIB", "LG_DISK_MARGIN_GIB"].filter((k) => process.env[k] != null).map((k) => [k, process.env[k]])),
};
const lg = (args) => {
  const r = spawnSync(process.execPath, [RUN, ...args], { env, encoding: "utf8", timeout: 900_000 });
  return { code: r.status, out: String(r.stdout ?? ""), err: String(r.stderr ?? "") };
};
// 본 저장소 읽기 — status 가 .git/index 를 새로 쓰지 않게 선택 잠금을 끈다(H3 하)
const git = (args) => spawnSync("/usr/bin/git", ["-C", REPO, ...args], { encoding: "utf8", env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" } }).stdout.trim();
const repoState = () => ({ head: git(["rev-parse", "HEAD"]), status: git(["status", "--porcelain", "--untracked-files=all"]) });
const nap = (ms) => new Promise((r) => setTimeout(r, ms));

const bench = loadBench();
const before = repoState();
const results = [];
for (const id of ids) {
  const c = bench.cases.find((x) => x.id === id);
  if (!c) { results.push({ id, error: "벤치에 없다" }); continue; }
  const sig = benchSignal(c, 1);
  const thread = `gostop-fix:${sig.sigkey}`;
  const t0 = Date.now();
  const exists = JSON.parse(lg(["status", thread, "--json"]).out).status !== "not-found";
  const s = exists ? { out: "(이미 있는 스레드 — 틱으로 잇는다)" } : lg(["start", "gostop-fix", thread, `--sigkey=${sig.sigkey}`, `--signal=${JSON.stringify(sig)}`]);
  const lines = [s.out.trim()];
  let st = null;
  for (let i = 0; i < 200; i++) {
    st = JSON.parse(lg(["status", thread, "--json"]).out);
    if (["done", "gave_up", "expired", "waiting", "blocked"].includes(st.status)) break;
    if (st.status === "held" && !/busy|usage|disk/.test(st.note ?? "")) { /* 상한 보류 등 — 틱이 다시 본다 */ }
    await nap(8_000);
    const tk = lg(["tick", "--verbose"]);
    if (tk.out.trim()) lines.push(tk.out.trim().split("\n").slice(-2).join(" / "));
  }
  const secs = Math.round((Date.now() - t0) / 1000);
  let res = null;
  try { res = JSON.parse(fs.readFileSync(path.join(runDir(env.LG_STATE_DIR, sig.sigkey), "result.json"), "utf8")); } catch { /* 없음 */ }
  const plan = path.join(runDir(env.LG_STATE_DIR, sig.sigkey), "plan.md");
  if (fs.existsSync(plan)) fs.copyFileSync(plan, path.join(outDir, `${id}.plan.md`));
  results.push({ id, thread, status: st?.status, note: st?.note, secs, plan: res?.status ?? null, repro: res?.repro ?? null,
    runs: res?.runs?.map((r) => ({ rc: r.rc, secs: r.secs, sig: r.sig?.slice(0, 200) })) ?? null, diag: res?.diag ?? null, diagError: res?.diagError ?? null,
    scope: res?.scope?.reasons ?? null, match: res?.bench?.match ?? null, expect: c.expect, sizes: res?.sizes ?? null, tickLines: lines.slice(-6) });
}
const after = repoState();
const llm = JSON.parse(lg(["status", "--json", "--all"]).out).llm ?? null;
const metricsFile = path.join(env.LG_STATE_DIR, "metrics.jsonl");
const calls = fs.existsSync(metricsFile) ? fs.readFileSync(metricsFile, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((m) => m.ev === "llm")
  .map((m) => ({ thread: m.thread, node: m.node, model: m.model, models: m.models, ok: m.ok, ms: m.ms, in: m.in, out: m.out, cache_create: m.cache_create, cache_read: m.cache_read, total: m.total, cost_usd: m.cost_usd })) : [];
const summary = { at: new Date().toISOString(), stateDir: env.LG_STATE_DIR, gateOverride: { floor: env.LG_DISK_FLOOR_GIB ?? null }, repoUnchanged: JSON.stringify(before) === JSON.stringify(after), before, after, llm, calls, results };
fs.writeFileSync(path.join(outDir, "bench-live.json"), `${JSON.stringify(summary, null, 1)}\n`);
console.log(JSON.stringify({ repoUnchanged: summary.repoUnchanged, calls: calls.length, results: results.map((r) => ({ id: r.id, status: r.status, plan: r.plan, repro: r.repro, match: r.match, secs: r.secs })) }));
