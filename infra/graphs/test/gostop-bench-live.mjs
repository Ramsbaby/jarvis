#!/usr/bin/env node
// gostop-bench-live.mjs — 벤치 실주행(설계 §9 1a '벤치 2건 재현·진단 끝까지'). 진짜 고스톱 저장소(읽기만)·진짜 flutter·진짜 claude(sonnet 진단 + haiku 요약).
// 기본 시험 묶음에 들지 않는다(이름이 *.test.mjs 가 아니다). 사람이 보고 있을 때 손으로 돌린다 — 구독 한도를 쓴다.
//   node test/gostop-bench-live.mjs <출력폴더> hist-69a0144 hist-02d61dc
//   LG_GOSTOP_STAGE=1b node test/gostop-bench-live.mjs <출력폴더> hist-69a0144   (1b: 빨간 시험·수정·격리 검증·검토 + 숨긴 정답 채점)
// 상태는 임시 폴더(LG_STATE_DIR) — 운영 상태·대기열은 건드리지 않는다. 사본도 그 아래에 만든다.
// 1b 는 격리 실행 뿌리(/private/tmp) 아래에 상태를 둔다. 호출 상한 LG_GOSTOP_SONNET_CAP(기본 6)·LG_GOSTOP_OPUS_CAP(기본 3).
// 채점(1b): 그래프가 끝난 뒤 대상 커밋을 새로 내보내 pub get(사람 코드) → 숨긴 정답 시험을 넣어 격리 실행(대조군: 빨강이어야)
//   → 정본 패치를 얹어 다시 격리 실행(초록이면 hidden_pass). 정답 시험은 그래프가 끝난 뒤에만 사본 밖 채점 폴더에 쓴다.
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
const STAGE = process.env.LG_GOSTOP_STAGE === "1b" ? "1b" : "1a";
const state = process.env.LG_BENCH_STATE || (STAGE === "1b" ? fs.mkdtempSync("/private/tmp/lg-1b-bench-") : fs.mkdtempSync(path.join(HOME, ".cache", "lg-1a-bench-")));
const env = {
  PATH: process.env.PATH, HOME, LANG: "en_US.UTF-8", TMPDIR: os.tmpdir(), USER: os.userInfo().username,
  LG_STATE_DIR: path.join(state, "state"), LG_GOSTOP_REPO: REPO, LG_DAILY: "", LG_TICK_BUDGET_SEC: "480", LG_GOSTOP_STAGE: STAGE,
  ...(STAGE === "1b" ? { LG_GOSTOP_SONNET_CAP: process.env.LG_GOSTOP_SONNET_CAP ?? "6", LG_GOSTOP_OPUS_CAP: process.env.LG_GOSTOP_OPUS_CAP ?? "3" } : {}),
  ...Object.fromEntries(["LG_DISK_FLOOR_GIB", "LG_COPY_EST_GIB", "LG_DISK_MARGIN_GIB", "LG_QUIET"].filter((k) => process.env[k] != null).map((k) => [k, process.env[k]])),
};
const MAX_MIN = Number(process.env.LG_BENCH_MAX_MIN ?? (STAGE === "1b" ? 180 : 30));
const NODE = process.execPath;
const SBRUN = path.join(ROOT, "lib", "sandbox", "sandboxed-run.mjs");
const sh = (bin, args, opts = {}) => spawnSync(bin, args, { encoding: "utf8", maxBuffer: 64 << 20, timeout: 3_600_000, ...opts });
// 격리 실행 한 번 — 요약 줄(+N -M)과 실패 시험 이름만
function sbTest(copy, tmp, args) {
  const r = sh(NODE, [SBRUN, "--copy", copy, "--tmp", tmp, "--timeout-sec", "1500", "--", "flutter", "test", "--timeout", "none", ...args]);
  const out = String(r.stdout ?? "") + String(r.stderr ?? "");
  const tail = out.split("\n").filter((l) => /^\d\d:\d\d \+\d+/.test(l)).pop() ?? "";
  const failed = [...new Set(out.split("\n").map((l) => /^\d\d:\d\d \+\d+(?: ~\d+)? -\d+: (.+?) \[E\]\s*$/.exec(l)?.[1]).filter(Boolean))];
  return { rc: r.status, summary: tail.slice(0, 200), failed: failed.slice(0, 20) };
}
// 숨긴 정답 채점(1b) — 그래프 밖. 대상 커밋 새 내보내기(pub get) → 정답 시험(대조군) → 정본 패치 → 정답 시험·다른 씨앗
function grade(c, res, root) {
  if (!res?.fullPatch?.file || !c.hiddenTests?.length) return { skipped: "패치 또는 정답 시험 없음" };
  const dir = path.join(root, "grade"), tmp = path.join(root, "grade-tmp"), tar = path.join(root, "grade.tar");
  for (const d of [dir, tmp]) { fs.rmSync(d, { recursive: true, force: true }); fs.mkdirSync(d, { recursive: true, mode: 0o700 }); }
  const base = git(["rev-parse", c.rev]);
  if (sh("/usr/bin/git", ["-C", REPO, "archive", "--format=tar", "-o", tar, base]).status !== 0) return { error: "git archive 실패" };
  sh("/usr/bin/tar", ["-xf", tar, "-C", dir, "--exclude", ".claude", "--exclude", ".mcp.json", "--exclude", "android/key.properties", "--exclude", "*.jks", "--exclude", "*.keystore", "--exclude", "android/app/google-services.json", "--exclude", "ios/Runner/GoogleService-Info.plist"]);
  fs.rmSync(tar, { force: true });
  const pg = sh("/opt/homebrew/bin/flutter", ["pub", "get", "--offline"], { cwd: dir }); // 사람 코드일 때만(패치 전)
  if (pg.status !== 0) return { error: `pub get 실패 ${pg.status}` };
  for (const t of c.hiddenTests) {
    const body = sh("/usr/bin/git", ["-C", REPO, "show", `${c.origin}:${t}`]).stdout;
    fs.mkdirSync(path.dirname(path.join(dir, t)), { recursive: true });
    fs.writeFileSync(path.join(dir, t), body);
  }
  const control = c.hiddenTests.map((t) => ({ test: t, ...sbTest(dir, tmp, [t]) }));
  const ap = sh("/usr/bin/patch", ["-p1", "-N", "-t", "-s", "-d", dir, "-i", res.fullPatch.file]);
  if (ap.status !== 0) return { control, error: `패치 적용 실패 ${ap.status}: ${String(ap.stdout + ap.stderr).slice(0, 300)}` };
  const patched = c.hiddenTests.map((t) => ({ test: t, ...sbTest(dir, tmp, [t]) }));
  const seeds = (c.alsoSeeds ?? []).map((sd) => ({ seed: sd, ...sbTest(dir, tmp, [c.test, "--dart-define", "REPLAY_GAMES=1", "--dart-define", `REPLAY_SEED_BASE=${sd}`]) }));
  const origSeed = c.kind === "seed" ? { seed: c.defines.join(" "), ...sbTest(dir, tmp, [c.test, ...c.defines.flatMap((d) => ["--dart-define", d])]) } : null;
  const hiddenPass = patched.every((p) => p.rc === 0);
  return { controlRed: control.every((x) => x.rc !== 0), control, patched, hiddenPass, seeds, origSeed, allPass: hiddenPass && seeds.every((x) => x.rc === 0) && (!origSeed || origSeed.rc === 0) };
}
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
  for (let i = 0; Date.now() - t0 < MAX_MIN * 60_000; i++) {
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
  let graded = null;
  if (STAGE === "1b" && st?.status === "done") { try { graded = grade(c, res, path.join(env.LG_STATE_DIR, "gostop", "sandbox", sig.sigkey.replace(/[^A-Za-z0-9._-]/g, "_"))); } catch (e) { graded = { error: String(e?.message ?? e).slice(0, 300) }; } }
  if (res?.fullPatch?.file && fs.existsSync(res.fullPatch.file)) fs.copyFileSync(res.fullPatch.file, path.join(outDir, `${id}.patch.diff`));
  if (res?.reproTest && res?.work && fs.existsSync(path.join(res.work, res.reproTest))) fs.copyFileSync(path.join(res.work, res.reproTest), path.join(outDir, `${id}.repro_test.dart`));
  results.push({ id, thread, status: st?.status, note: st?.note, secs, plan: res?.status ?? null, planNote: res?.note ?? null, repro: res?.repro ?? null, graded,
    stage1b: STAGE === "1b" ? { reproTest: res?.reproTest, threePath: res?.threePath, rtAttempt: res?.rtAttempt, rtError: res?.rtError, redRuns: res?.redRuns, fixAttempt: res?.fixAttempt, fixError: res?.fixError,
      patchFiles: res?.fullPatch?.files, aiCheck: res?.aiCheck, scopeFinal: res?.scopeFinal?.reasons, steps: res?.steps?.map((x) => ({ phase: x.phase, fix: x.fix, id: x.id, ok: x.ok, rc: x.rc, secs: x.secs, detail: String(x.detail).slice(0, 200) })),
      review: res?.review, violation: res?.violation, commit: res?.commit, calls: res?.calls } : undefined,
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
console.log(JSON.stringify({ repoUnchanged: summary.repoUnchanged, calls: calls.length, results: results.map((r) => ({ id: r.id, status: r.status, plan: r.plan, repro: r.repro, match: r.match, secs: r.secs, hiddenPass: r.graded?.hiddenPass ?? null, allPass: r.graded?.allPass ?? null })) }));
