// gostop.test.mjs — 1a 시험(설계 §9 1a): 고스톱 접수(gostop-intake)·수정(gostop-fix 1a판) 그래프.
// 전부 임시 HOME·임시 상태 폴더·가짜 고스톱 저장소에서 돈다. git·tar 는 진짜(운영 허용 목록 그대로), flutter·gh·claude 는 가짜.
// 진짜 고스톱 저장소·진짜 모델은 부르지 않는다(실호출은 RUN_LLM=1 의 gostop-live.test.mjs, 벤치 실주행은 scripts/gostop-bench-live.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { sandbox, run, runAsync, fakeClaude, appWith, ROOT, NODE, FIXTURES, T0 } from "./helpers.mjs";
import { tickEnv, metrics, writeUsage } from "./helpers0b.mjs";
import * as C from "../graphs/gostop-common.mjs";
import { soakSignals, ciFailures, ciTestOf, DAY_CAP } from "../graphs/gostop-intake.mjs";
import { loadRegistry, resolveCommand } from "../lib/run.mjs";
import { checkGraphFile } from "../scripts/check-graph-rules.mjs";
import { checkFile } from "../scripts/check-interrupt-nodes.mjs";
import { claudeArgs } from "../lib/claude.mjs";
import { diskGate } from "../lib/gates.mjs";
import { loadConfig } from "../lib/config.mjs";

const FAKE_FLUTTER = path.join(FIXTURES, "fake-flutter.mjs");
const FAKE_GH = path.join(FIXTURES, "fake-gh.mjs");
const PROD = JSON.parse(fs.readFileSync(path.join(ROOT, "cmd-registry.json"), "utf8"));
const GOSTOP_IDS = ["git.rev-parse", "git.last-commit-time", "git.archive", "tar.extract-sandbox", "flutter.pub-get-offline", "flutter.test-defines", "flutter.test-file", "gh.run-list", "gh.run-log-failed"];
const OLD = "2026-01-01T09:00:00+09:00"; // 가짜 저장소 커밋 시각(대화 작업 표식에 안 걸리게 오래전)

// ── 준비 ─────────────────────────────────────────────────────────
function git(repo, args, date = OLD) {
  const env = { PATH: "/usr/bin:/bin", HOME: path.dirname(repo), GIT_CONFIG_NOSYSTEM: "1", GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.invalid",
    GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.invalid", GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date };
  const r = spawnSync("/usr/bin/git", ["-C", repo, ...args], { encoding: "utf8", env });
  assert.equal(r.status, 0, `git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.trim();
}
const put = (root, rel, text) => { fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true }); fs.writeFileSync(path.join(root, rel), text); };

// 가짜 고스톱 저장소: base(사본 대상) → answer(정답 커밋 — 사본에 보이면 안 된다)
function fakeRepo(sb) {
  const repo = path.join(sb.dir, "gostop_app");
  fs.mkdirSync(repo);
  git(repo, ["init", "-q", "-b", "master"]);
  put(repo, "pubspec.yaml", "name: gostop_app\n");
  put(repo, "CLAUDE.md", "# 고스톱 프로젝트 규칙\n");
  put(repo, "docs/rules/GAME_MECHANICS.md", "# 규칙\n## 4.2 9월 국진 선택\n");
  put(repo, "lib/domain/game/turn_manager.dart", "class TurnManager { int score() => 4; }\n");
  put(repo, "lib/presentation/providers/game_provider.dart", "class GameProvider {}\n");
  put(repo, "test/domain/game/live_replay_differential_test.dart", "void main() {}\n");
  put(repo, ".claude/settings.json", '{"permissions":{"allow":["Bash(*)"]}}\n');
  put(repo, ".mcp.json", "{}\n");
  put(repo, "android/app/google-services.json", '{"api_key":"FAKE-SECRET-VALUE"}\n');
  put(repo, "android/app/upload.jks", "FAKE-KEYSTORE\n");
  git(repo, ["add", "-A"]);
  git(repo, ["commit", "-q", "-m", "base"]);
  const base = git(repo, ["rev-parse", "HEAD"]);
  put(repo, "test/presentation/providers/gukjin_answer_test.dart", "// ANSWER-MARKER-7f3a 정답 시험\nvoid main() {}\n");
  put(repo, "lib/domain/game/turn_manager.dart", "class TurnManager { int score() => 6; } // ANSWER-MARKER-7f3a\n");
  git(repo, ["add", "-A"]);
  git(repo, ["commit", "-q", "-m", "fix: 국진 ANSWER-MARKER-7f3a"]);
  const answer = git(repo, ["rev-parse", "HEAD"]);
  return { repo, base, answer };
}
const repoState = (repo) => ({ head: git(repo, ["rev-parse", "HEAD"]), status: git(repo, ["status", "--porcelain", "--untracked-files=all"]) });

// 시험 허용 목록 = 운영 목록 그대로 + flutter·gh 만 가짜로(인자 모양·자리·정규식은 운영과 같다)
function gostopRegistry(sb, { flutter = {}, gh = {}, over = {} } = {}) {
  const flCtl = path.join(sb.dir, "fake-flutter.json");
  const ghCtl = path.join(sb.dir, "fake-gh.json");
  fs.writeFileSync(flCtl, JSON.stringify({ mode: "mismatch", trace: path.join(sb.dir, "flutter-trace.jsonl"), ...flutter }));
  fs.writeFileSync(ghCtl, JSON.stringify({ runs: [], log: "", trace: path.join(sb.dir, "gh-trace.jsonl"), ...gh }));
  const commands = {};
  for (const [id, c] of Object.entries(PROD.commands)) {
    if (id.startsWith("flutter.")) commands[id] = { ...c, bin: NODE, argv: [FAKE_FLUTTER, flCtl, ...c.argv] };
    else if (id.startsWith("gh.")) commands[id] = { ...c, bin: NODE, argv: [FAKE_GH, ghCtl, ...c.argv] };
    else commands[id] = c;
    if (over[id]) commands[id] = { ...commands[id], ...over[id] };
  }
  const file = path.join(sb.dir, "cmd-registry.json");
  fs.writeFileSync(file, JSON.stringify({ version: 1, commands }, null, 1));
  return { file, flCtl, ghCtl, setFlutter: (o) => fs.writeFileSync(flCtl, JSON.stringify({ trace: path.join(sb.dir, "flutter-trace.jsonl"), ...o })) };
}
const traceOf = (sb, name) => { const f = path.join(sb.dir, name); return fs.existsSync(f) ? fs.readFileSync(f, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []; };

// 고스톱 그래프를 돌리는 환경 하나
function setup(t, { flutter, gh, over, claudeMode = "diag", diag, extra = {} } = {}) {
  const sb = sandbox(t);
  const fr = fakeRepo(sb);
  const reg = gostopRegistry(sb, { flutter, gh, over });
  const fc = fakeClaude(sb, claudeMode);
  fs.writeFileSync(`${fc.log}.answer.json`, JSON.stringify(diag ?? {
    hypothesis: "라이브 사람 경로의 confirmDrawnCardChoice 에서 9월 국진을 묻지 않아 열끗으로 굳는다.", files: ["lib/presentation/providers/game_provider.dart"],
    rule_gap: false, confidence: 0.8, evidence: ["lib/presentation/providers/game_provider.dart:1 — 국진 선택 누락"] }));
  const soak = path.join(sb.dir, "soak");
  fs.mkdirSync(soak);
  const env = tickEnv(sb, { over: { LG_CMD_REGISTRY: reg.file, LG_CLAUDE_BIN: fc.bin, LG_GOSTOP_REPO: fr.repo, LG_GOSTOP_SOAK_DIR: soak, LG_TICK_BUDGET_SEC: "60", LG_GOSTOP_STAGE: "1a", ...extra } });
  return { sb, ...fr, reg, fc, soak, env };
}
const benchSig = (fr, over = {}) => ({ source: "bench", kind: "seed", rev: `${fr.answer.slice(0, 12)}^`, test: C.DIFF_TEST,
  defines: ["REPLAY_GAMES=1", "REPLAY_SEED_BASE=202656775"], bench: { id: "t1", expect: { files: ["lib/presentation/providers/game_provider.dart"], keywords: ["국진"], ruleGap: false } }, ...over });
const startFix = (x, sigkey, signal) => run(x.env, ["start", "gostop-fix", `gostop-fix:${sigkey}`, `--sigkey=${sigkey}`, `--signal=${JSON.stringify(signal)}`]);
const status = (x, thread) => JSON.parse(run(x.env, ["status", thread, "--json"]).out);
const listThreads = (x) => JSON.parse(run(x.env, ["status", "--json", "--all"]).out).threads;
// 분리 실행을 기다리며 틱을 되풀이한다(끝나거나 대기면 멈춘다)
async function drive(x, thread, { max = 60, until = ["done", "waiting", "gave_up", "expired"] } = {}) {
  for (let i = 0; i < max; i++) {
    const st = status(x, thread);
    if (until.includes(st.status)) return st;
    run(x.env, ["tick"]);
    await new Promise((r) => setTimeout(r, 150));
  }
  return status(x, thread);
}
const resultOf = (x, sigkey) => JSON.parse(fs.readFileSync(path.join(C.runDir(x.sb.state, sigkey), "result.json"), "utf8"));
function grepTree(dir, needle) {
  const hits = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.isFile() && fs.readFileSync(p).includes(needle)) hits.push(path.relative(dir, p));
    }
  };
  walk(dir);
  return hits;
}

// ── 사본·재현·진단 끝까지 ─────────────────────────────────────────
test("1a 끝까지: 역사 없는 사본(정답 커밋·정답 시험 안 보임, 비밀·설정 제외) → 재현 2회 → 진단(--restricted·읽기 도구·JSON 스키마) → ready · 본 저장소 불변", async (t) => {
  const x = setup(t);
  const before = repoState(x.repo);
  const sig = benchSig(x);
  const r = startFix(x, "bench:t1:r1", sig);
  assert.equal(r.code, 0, r.out + r.err);
  const st = await drive(x, "gostop-fix:bench:t1:r1");
  assert.equal(st.status, "done", JSON.stringify(st));
  const res = resultOf(x, "bench:t1:r1");
  assert.equal(res.status, "ready");
  assert.equal(res.repro, "reproduced");
  assert.equal(res.runs.length, 2);
  assert.equal(res.base, x.base, "대상 = 정답 커밋의 부모");
  // 사본: 역사 없음 — .git 없음, 정답 커밋 해시·정답 시험·정답 줄이 어디에도 없다
  const work = path.join(C.sandboxDir(x.sb.state, "bench:t1:r1"), "work");
  const clean = path.join(C.sandboxDir(x.sb.state, "bench:t1:r1"), "clean");
  for (const d of [work, clean]) {
    assert.ok(!fs.existsSync(path.join(d, ".git")), "사본에 .git 이 없다");
    assert.ok(!fs.existsSync(path.join(d, "test/presentation/providers/gukjin_answer_test.dart")), "정답 시험이 없다");
    assert.deepEqual(grepTree(d, "ANSWER-MARKER-7f3a"), [], "정답 줄이 없다");
    assert.deepEqual(grepTree(d, x.answer.slice(0, 12)), [], "정답 커밋 해시가 없다");
    for (const rel of [".claude", ".mcp.json", "android/app/google-services.json", "android/app/upload.jks"]) assert.ok(!fs.existsSync(path.join(d, rel)), `${rel} 는 빼고 푼다`);
    assert.ok(fs.existsSync(path.join(d, "CLAUDE.md")) && fs.existsSync(path.join(d, "lib/domain/game/turn_manager.dart")));
  }
  assert.ok(!fs.existsSync(path.join(C.sandboxDir(x.sb.state, "bench:t1:r1"), "src.tar")), "내보낸 tar 는 지운다");
  assert.ok(!fs.existsSync(path.join(work, "build")) && !fs.existsSync(path.join(work, ".dart_tool")), "끝나면 build·.dart_tool 을 지운다");
  // 재현은 사본 안에서, 사람이 쓴 기존 시험으로 2회 + pub get 1회
  const fl = traceOf(x.sb, "flutter-trace.jsonl");
  assert.deepEqual(fl.map((c) => c.sub), ["pub", "test", "test"]);
  assert.ok(fl.every((c) => fs.realpathSync(c.cwd) === fs.realpathSync(work)), "flutter 는 사본에서만");
  assert.ok(fl[1].args.includes("REPLAY_SEED_BASE=202656775") && fl[1].args.includes("--no-pub"));
  // 진단: sonnet · --restricted · 읽기 도구만 · JSON 스키마 · 작업 폴더 = 사본 · 프롬프트에 정답이 없다
  const calls = x.fc.calls();
  const diag = calls.find((c) => c.input.includes("정해진 JSON 으로만 답한다"));
  assert.ok(diag, "진단 호출이 있다");
  assert.equal(fs.realpathSync(diag.cwd), fs.realpathSync(work));
  for (const f of ["--restricted", "--strict-mcp-config", "--no-session-persistence", "--json-schema"]) assert.ok(diag.args.includes(f), f);
  assert.equal(diag.args[diag.args.indexOf("--model") + 1], "sonnet");
  assert.deepEqual(diag.args.slice(diag.args.indexOf("--tools") + 1), ["Read", "Grep", "Glob"]);
  assert.ok(!diag.input.includes("ANSWER-MARKER") && !diag.input.includes(x.answer.slice(0, 7)) && !diag.input.includes("gukjin_answer_test"), "정답이 프롬프트에 없다");
  assert.ok(diag.input.includes("seat0 국진 쌍피"), "재현 발췌가 들어간다");
  assert.equal(calls.length, 2, "진단 1 + 요약(haiku) 1");
  assert.equal(calls[1].args[calls[1].args.indexOf("--model") + 1], "haiku");
  // 고칠 안·판정 기록
  const md = fs.readFileSync(res.planPath ?? path.join(C.runDir(x.sb.state, "bench:t1:r1"), "plan.md"), "utf8");
  assert.match(md, /상태: \*\*ready\*\*/);
  assert.match(md, /진단 일치: true/);
  const b = metrics(x.sb).filter((m) => m.ev === "bench");
  assert.equal(b.length, 1);
  assert.equal(b[0].reproduced, true);
  assert.equal(b[0].diag_match, true);
  const done = metrics(x.sb).find((m) => m.ev === "done" && m.thread === "gostop-fix:bench:t1:r1");
  assert.match(done.verified, /^gostop-fix ready\(1a\): 재현 reproduced · 진단 있음 — .*plan\.md$/, "M2 — 끝난 상태를 뒷받침하는 확인 기록");
  assert.deepEqual(repoState(x.repo), before, "본 저장소 HEAD·status 불변");
});

test("흔들림: 두 번 결과가 다르면 flaky — 진단하지 않는다", async (t) => {
  const x = setup(t, { flutter: { mode: "flaky" } });
  assert.equal(startFix(x, "bench:t1:r1", benchSig(x)).code, 0);
  assert.equal((await drive(x, "gostop-fix:bench:t1:r1")).status, "done");
  const res = resultOf(x, "bench:t1:r1");
  assert.equal(res.status, "flaky");
  assert.equal(x.fc.calls().filter((c) => c.input.includes("정해진 JSON")).length, 0, "진단 호출 0");
  assert.match(metrics(x.sb).find((m) => m.ev === "done").verified, /^gostop-fix flaky: 재현 실행 2회 판정 — /, "M2");
});

test("재현 안 됨: 두 번 다 초록이면 not_reproduced", async (t) => {
  const x = setup(t, { flutter: { mode: "pass" } });
  assert.equal(startFix(x, "bench:t1:r1", benchSig(x)).code, 0);
  assert.equal((await drive(x, "gostop-fix:bench:t1:r1")).status, "done");
  assert.equal(resultOf(x, "bench:t1:r1").status, "not_reproduced");
});

// 10-10: 소크 신호를 접수(04:30) 때의 커밋에 고정해 재현하던 탓에, 그 사이 당직·대화가 이미 고친 문제를 옛 코드에서 다시 재현하고
// 진단·수정에 AI 를 썼다(씨앗 203013939 한 스레드 477만 토큰, 줄 선 4건이 전부 고쳐진 신호). 소크는 지금 master 에서 본다.
test("소크 신호는 지금 master 에서 재현한다 — 신호 커밋 뒤에 이미 고쳐졌으면 AI 0회로 not_reproduced · 벤치는 신호 커밋 그대로", async (t) => {
  const x = setup(t, { flutter: { mode: "mismatch-old" } }); // 옛 코드(base)면 불일치 · 고쳐진 코드(answer = master)면 통과
  const sig = soakSignals({ ...soakSummary("20261005", [11]), head: x.base.slice(0, 7) }).signals[0];
  assert.equal(sig.rev, x.base.slice(0, 7), "신호는 소크가 돈 옛 커밋을 가리킨다");
  assert.equal(startFix(x, sig.sigkey, sig).code, 0);
  assert.equal((await drive(x, `gostop-fix:${sig.sigkey}`)).status, "done");
  const res = resultOf(x, sig.sigkey);
  assert.equal(res.base, x.answer, "사본 기준 = 지금 master(신호 커밋이 아니다)");
  assert.equal(res.status, "not_reproduced");
  assert.equal(x.fc.calls().length, 0, "이미 고쳐진 신호에 AI 0회(요약도 정해진 문장)");
  assert.match(fs.readFileSync(path.join(C.runDir(x.sb.state, sig.sigkey), "plan.md"), "utf8"), /## 요약\n지금 코드\([0-9a-f]{8}\)에서 같은 씨앗을 두 번 돌렸지만 문제가 나오지 않았다/);
  assert.match(metrics(x.sb).find((m) => m.ev === "done").verified, /^gostop-fix not_reproduced: 재현 실행 2회 판정 — /, "M2");
  // 아직 안 고쳐진 소크 신호(master 도 옛 코드)는 전처럼 재현된다 — 느슨해진 것이 아니다
  const z = setup(t, { flutter: { mode: "mismatch" } });
  const sz = soakSignals({ ...soakSummary("20261005", [12]), head: z.base.slice(0, 7) }).signals[0];
  assert.equal(startFix(z, sz.sigkey, sz).code, 0);
  await drive(z, `gostop-fix:${sz.sigkey}`);
  assert.equal(resultOf(z, sz.sigkey).repro, "reproduced");
  // 벤치는 그대로 신호 커밋에서 — 옛 코드라 재현된다(기준 커밋이 곧 문제다)
  const y = setup(t, { flutter: { mode: "mismatch-old" } });
  assert.equal(startFix(y, "bench:t1:r1", benchSig(y)).code, 0);
  await drive(y, "gostop-fix:bench:t1:r1");
  const rb = resultOf(y, "bench:t1:r1");
  assert.equal(rb.base, y.base, "벤치 사본 기준 = 신호 커밋");
  assert.equal(rb.repro, "reproduced");
});

test("제보만 있는 신호는 재현을 건너뛰고 진단 — 규칙 공백이면 rule_decision(승인 질문 없이)", async (t) => {
  const x = setup(t, { diag: { hypothesis: "판이 끝날 때 뻑 더미 속 조커의 귀속을 규칙서가 정하지 않는다. 엔진은 스톱한 사람에게 준다.", files: ["lib/domain/game/turn_manager.dart"],
    rule_gap: true, rule_gap_detail: "판 끝 바닥 조커 귀속 조항 없음", confidence: 0.7, evidence: ["docs/rules/GAME_MECHANICS.md:3 — §3 에 판 끝 귀속 없음"] } });
  fs.mkdirSync(x.sb.state, { recursive: true }); fs.writeFileSync(path.join(x.sb.state, "LIVE"), ""); // 실제 모드여도 규칙 공백은 interrupt 가 아니다
  const sig = { source: "bench", kind: "report", rev: x.base.slice(0, 10), report: "고/스톱 창 3점에서 스톱했는데 바닥 조커가 붙어 6점 정산",
    bench: { id: "joker", expect: { status: "rule_decision", ruleGap: true, keywords: ["조커"] } } };
  assert.equal(startFix(x, "bench:joker:r1", sig).code, 0);
  const st = await drive(x, "gostop-fix:bench:joker:r1");
  assert.equal(st.status, "done", JSON.stringify(st));
  const res = resultOf(x, "bench:joker:r1");
  assert.equal(res.repro, "skipped");
  assert.equal(res.status, "rule_decision");
  assert.equal(res.bench.match.ok, true, JSON.stringify(res.bench.match));
  assert.equal(traceOf(x.sb, "flutter-trace.jsonl").filter((c) => c.sub === "test").length, 0, "재현 시험을 돌리지 않는다");
});

test("범위 미리 보기: AI 영역·허용 목록 밖 → 그림자는 would_ask 로 적기만, 실제 모드는 owner_gate(순수 interrupt)에서 묻는다", async (t) => {
  const diag = { hypothesis: "MCTSConstants 탐색 깊이가 어려움 AI 수읽기를 끊는다", files: ["lib/domain/ai/mcts/mcts_engine.dart", "lib/core/constants.dart"], rule_gap: false, confidence: 0.6, evidence: [] };
  const x = setup(t, { diag });
  assert.equal(startFix(x, "bench:t1:r1", benchSig(x)).code, 0);
  assert.equal((await drive(x, "gostop-fix:bench:t1:r1")).status, "done");
  const res = resultOf(x, "bench:t1:r1");
  assert.equal(res.status, "would_ask");
  assert.equal(res.scope.ai.length, 1);
  assert.deepEqual(res.scope.outside, ["lib/core/constants.dart"]);
  assert.match(fs.readFileSync(path.join(C.runDir(x.sb.state, "bench:t1:r1"), "plan.md"), "utf8"), /물었을 것: 게임 AI 영역/);
  assert.equal(metrics(x.sb).filter((m) => m.ev === "waiting").length, 0, "그림자는 묻지 않는다");
  // 실제 모드
  const y = setup(t, { diag });
  fs.mkdirSync(y.sb.state, { recursive: true }); fs.writeFileSync(path.join(y.sb.state, "LIVE"), "");
  assert.equal(startFix(y, "bench:t1:r2", benchSig(y)).code, 0);
  const w = await drive(y, "gostop-fix:bench:t1:r2");
  assert.equal(w.status, "waiting", JSON.stringify(w));
  assert.match(w.question, /승인이 필요합니다/);
  assert.equal(run(y.env, ["answer", "gostop-fix:bench:t1:r2", "approved"]).code, 0);
  assert.equal((await drive(y, "gostop-fix:bench:t1:r2", { until: ["done", "gave_up", "expired"] })).status, "done");
  assert.equal(resultOf(y, "bench:t1:r2").status, "ready");
});

test("대화 작업 표식: .jarvis-busy 또는 30분 안 커밋이면 HOLD(busy), 치우면 다음 틱에 이어 간다", async (t) => {
  const x = setup(t);
  fs.writeFileSync(path.join(x.repo, ".jarvis-busy"), "");
  const r = startFix(x, "bench:t1:r1", benchSig(x));
  assert.equal(r.code, 0, r.out);
  let st = status(x, "gostop-fix:bench:t1:r1");
  assert.equal(st.status, "held");
  assert.match(st.note, /대화 작업 표식/);
  assert.equal(traceOf(x.sb, "flutter-trace.jsonl").length, 0, "사본도 만들지 않는다");
  assert.ok(!fs.existsSync(C.sandboxDir(x.sb.state, "bench:t1:r1")));
  fs.rmSync(path.join(x.repo, ".jarvis-busy"));
  // 30분 안 커밋(실행기 시계를 커밋 10분 뒤로 주입)
  const now = Date.now();
  put(x.repo, "docs/note.md", "x\n");
  git(x.repo, ["add", "-A"]);
  git(x.repo, ["commit", "-q", "-m", "대화 중 커밋"], new Date(now).toISOString());
  run(x.env, ["tick"], { extraEnv: { LG_NOW: String(now + 10 * 60_000) } });
  st = status(x, "gostop-fix:bench:t1:r1");
  assert.equal(st.status, "held");
  assert.match(st.note, /분 전 커밋/);
  // 40분 뒤 — 이어 간다(분리 실행이 시험 폴더를 치우기 전에 끝나게 끝까지 돌린다)
  run(x.env, ["tick"], { extraEnv: { LG_NOW: String(now + 40 * 60_000) } });
  assert.notEqual(status(x, "gostop-fix:bench:t1:r1").status, "held");
  assert.ok(metrics(x.sb).some((m) => m.ev === "held" && (m.reasons ?? []).includes("busy")));
  x.env.LG_NOW = String(now + 45 * 60_000);
  assert.equal((await drive(x, "gostop-fix:bench:t1:r1")).status, "done");
});

test("분리 실행 고장: 시간 제한에 걸린 재현(SIGTERM 무시·손주 포함)은 묶음째 꺼지고 같은 회차를 다시 띄운다 — 3회면 gave_up", async (t) => {
  const x = setup(t, { flutter: { mode: "hang" }, over: { "flutter.test-defines": { timeoutSec: 1, maxSeconds: 3 } } });
  assert.equal(startFix(x, "bench:t1:r1", benchSig(x)).code, 0);
  const st = await drive(x, "gostop-fix:bench:t1:r1", { max: 120 });
  assert.equal(st.status, "done", JSON.stringify(st));
  const res = resultOf(x, "bench:t1:r1");
  assert.equal(res.status, "gave_up");
  assert.equal(res.repro, "failed");
  assert.equal(traceOf(x.sb, "flutter-trace.jsonl").filter((c) => c.sub === "test").length, 3, "같은 회차 3번 띄움");
  await new Promise((r) => setTimeout(r, 300));
  const ps = spawnSync("/bin/ps", ["-A", "-o", "pid=,command="], { encoding: "utf8" }).stdout;
  assert.ok(!ps.includes("lg-fake-flutter-grandchild"), "손주까지 없어졌다");
});

test("분리 실행 죽음: 재현 껍데기가 결과 없이 죽으면(dead) 다시 띄워 이어 간다", async (t) => {
  const x = setup(t, { flutter: { mode: "hang" } });
  assert.equal(startFix(x, "bench:t1:r1", benchSig(x)).code, 0);
  assert.equal(status(x, "gostop-fix:bench:t1:r1").status, "continue");
  // 껍데기를 SIGKILL — 결과 파일 없이 죽는다
  const jobs = path.join(x.sb.state, "jobs", "gostop-fix:bench:t1:r1", "reproduce_1", "1");
  for (let i = 0; i < 50 && !fs.existsSync(path.join(jobs, "meta.json")); i++) await new Promise((r) => setTimeout(r, 100));
  const meta = JSON.parse(fs.readFileSync(path.join(jobs, "meta.json"), "utf8"));
  process.kill(-meta.pid, "SIGKILL");
  x.reg.setFlutter({ mode: "mismatch" });
  const st = await drive(x, "gostop-fix:bench:t1:r1");
  assert.equal(st.status, "done");
  const res = resultOf(x, "bench:t1:r1");
  assert.equal(res.repro, "reproduced");
  assert.ok(fs.existsSync(path.join(x.sb.state, "jobs", "gostop-fix:bench:t1:r1", "reproduce_1", "2")), "시도 2로 다시 띄웠다");
});

test("이중 실행: 틱 둘이 겹쳐도 같은 (스레드, 노드, 시도)의 재현은 한 번만 띄운다", async (t) => {
  const x = setup(t, { flutter: { mode: "mismatch" } });
  const sig = benchSig(x);
  const q = run(x.env, ["start", "gostop-fix", "gostop-fix:bench:t1:r1", "--sigkey=bench:t1:r1", `--signal=${JSON.stringify(sig)}`, "--queue"]);
  assert.equal(q.code, 0, q.out);
  await Promise.all([runAsync(x.env, ["tick"]), runAsync(x.env, ["tick"]), runAsync(x.env, ["tick"])]);
  const st = await drive(x, "gostop-fix:bench:t1:r1");
  assert.equal(st.status, "done");
  const tests = traceOf(x.sb, "flutter-trace.jsonl").filter((c) => c.sub === "test");
  assert.equal(tests.length, 2, "재현 2회(1·2회차 각 한 번)");
  assert.equal(traceOf(x.sb, "flutter-trace.jsonl").filter((c) => c.sub === "pub").length, 1, "사본도 한 번");
});

test("진단 JSON 이 형식에 안 맞으면 sonnet 을 한 번 더(최대 2회), 그래도 안 되면 gave_up", async (t) => {
  const x = setup(t, { claudeMode: "diag-bad" });
  assert.equal(startFix(x, "bench:t1:r1", benchSig(x)).code, 0);
  assert.equal((await drive(x, "gostop-fix:bench:t1:r1")).status, "done");
  const res = resultOf(x, "bench:t1:r1");
  assert.equal(res.status, "gave_up");
  assert.match(res.diagError, /형식/);
  assert.equal(x.fc.calls().filter((c) => c.input.includes("정해진 JSON")).length, 2);
  // 본문 속 JSON(구조화 출력이 없을 때)도 받는다
  const y = setup(t, { claudeMode: "diag-text" });
  assert.equal(startFix(y, "bench:t1:r1", benchSig(y)).code, 0);
  assert.equal((await drive(y, "gostop-fix:bench:t1:r1")).status, "done");
  assert.equal(resultOf(y, "bench:t1:r1").status, "ready");
});

test("회귀 주입 사례: 사본(work·clean)에만 사람이 적은 변형을 넣고, 0곳·여러 곳이면 거부", async (t) => {
  const x = setup(t, { flutter: { mode: "fail" } });
  const sig = { source: "bench", kind: "inject", rev: x.base.slice(0, 10), test: "test/domain/game/live_replay_differential_test.dart",
    inject: { file: "lib/domain/game/turn_manager.dart", find: "score() => 4", replace: "score() => 5" }, bench: { id: "inj", expect: { files: ["lib/presentation/providers/game_provider.dart"] } } };
  const before = repoState(x.repo);
  assert.equal(startFix(x, "bench:inj:r1", sig).code, 0);
  assert.equal((await drive(x, "gostop-fix:bench:inj:r1")).status, "done");
  const root = C.sandboxDir(x.sb.state, "bench:inj:r1");
  for (const d of ["work", "clean"]) assert.match(fs.readFileSync(path.join(root, d, "lib/domain/game/turn_manager.dart"), "utf8"), /score\(\) => 5/);
  assert.match(fs.readFileSync(path.join(x.repo, "lib/domain/game/turn_manager.dart"), "utf8"), /score\(\) => 6/, "본 저장소는 그대로");
  assert.deepEqual(repoState(x.repo), before);
  assert.equal(resultOf(x, "bench:inj:r1").repro, "reproduced");
  const tmp = fs.mkdtempSync(path.join(x.sb.dir, "inj-"));
  put(tmp, "lib/a.dart", "x x");
  assert.throws(() => C.applyInject(tmp, { file: "lib/a.dart", find: "x", replace: "y" }), /2곳/);
  assert.throws(() => C.applyInject(tmp, { file: "lib/a.dart", find: "z", replace: "y" }), /0곳/);
  assert.throws(() => C.applyInject(tmp, { file: "../a.dart", find: "x", replace: "y" }), /형식/);
});

// ── 접수 ─────────────────────────────────────────────────────────
const soakSummary = (day, seeds, problems = []) => ({ day, head: "abc1234", dirty: 0, diff: { rc: seeds.length ? 1 : 0, games: 100, mismatch: seeds.length },
  problems, mismatch_details: seeds.map((s) => `seed=${s}: 라이브와 엔진의 끝 상태가 다르다\n    seat0 점수: 라이브 4 / 엔진 6`) });

test("접수: 어젯밤 소크 불일치 → 씨앗 신호, 하루 3건까지만 올리고 같은 신호는 다시 안 올린다(LLM 0회)", async (t) => {
  const x = setup(t);
  const day = "2026-10-05";
  fs.mkdirSync(path.join(x.soak, "20261005"));
  fs.writeFileSync(path.join(x.soak, "20261005", "summary.json"), JSON.stringify(soakSummary("20261005", [11, 22, 33, 44])));
  const r = run(x.env, ["start", "gostop-intake", `gostop-intake:${day}`, `--day=${day}`]);
  assert.equal(r.code, 0, r.out);
  assert.equal(status(x, `gostop-intake:${day}`).status, "done");
  const queued = listThreads(x).filter((v) => v.graph === "gostop-fix");
  assert.equal(queued.length, DAY_CAP);
  assert.deepEqual(queued.map((v) => v.status), ["queued", "queued", "queued"]);
  assert.ok(queued.every((v) => /^gostop-fix:soak:normal:\d+:abc1234$/.test(v.thread)));
  assert.equal(x.fc.calls().length, 0, "접수는 LLM 0회");
  const doneOf = (th) => metrics(x.sb).find((m) => m.ev === "done" && m.thread === th);
  assert.match(doneOf(`gostop-intake:${day}`).verified, /^gostop-intake 올림 3\(이미 있음 0\) · 장부 확인\(다시 올림 0 · 오늘 3\/3\) — .*intake-state\.json$/, "M2");
  // 같은 날 다시: 새 신호 없음(이미 읽은 소크) → 벤치로 가지 않고, 하루 상한도 찼다
  const r2 = run(x.env, ["start", "gostop-intake", `gostop-intake:${day}-b`, `--day=${day}`]);
  assert.equal(r2.code, 0);
  assert.equal(listThreads(x).filter((v) => v.graph === "gostop-fix").length, DAY_CAP);
  assert.match(doneOf(`gostop-intake:${day}-b`).verified, /^gostop-intake 올림 0\(이미 있음 0\)/, "같은 것을 다시 올리지 않았다는 확인");
});

test("접수: CI 실패(읽기 전용 gh) → 실패 로그 발췌를 남기고 시험 파일이 보이면 그 시험으로 재현. gh 가 막히면 적고 넘어간다", async (t) => {
  const now = Date.parse("2026-10-05T09:00:00+09:00");
  const runs = [
    { conclusion: "failure", headSha: "f".repeat(40), name: "Flutter CI", workflowName: "Flutter CI", url: "https://example.invalid/r/2", databaseId: 2, createdAt: "2026-10-05T00:00:00Z", status: "completed" },
    { conclusion: "success", headSha: "e".repeat(40), name: "Flutter CI", workflowName: "Flutter CI", url: "https://example.invalid/r/1", databaseId: 1, createdAt: "2026-10-04T00:00:00Z", status: "completed" },
    { conclusion: "failure", headSha: "d".repeat(40), name: "AI Balance", workflowName: "AI Balance Simulation", url: "u", databaseId: 3, createdAt: "2026-10-04T23:00:00Z", status: "completed" },
    { conclusion: "success", headSha: "c".repeat(40), name: "AI Balance", workflowName: "AI Balance Simulation", url: "u", databaseId: 4, createdAt: "2026-10-05T01:00:00Z", status: "completed" },
  ];
  const x = setup(t, { gh: { runs, log: `${"앞부분 ".repeat(20000)}\nFAILED: test/domain/game/end_game_board_joker_test.dart\n끝` } });
  const r = run(x.env, ["start", "gostop-intake", "gostop-intake:2026-10-05", "--day=2026-10-05"], { extraEnv: { LG_NOW: String(now) } });
  assert.equal(r.code, 0, r.out);
  const q = listThreads(x).filter((v) => v.graph === "gostop-fix");
  assert.deepEqual(q.map((v) => v.thread), [`gostop-fix:ci:flutter-ci:${"f".repeat(8)}`], "지금도 빨간 워크플로만(뒤에 초록이 된 것은 뺌)");
  const logFile = path.join(C.runDir(x.sb.state, `ci:flutter-ci:${"f".repeat(8)}`), "ci-log.txt");
  assert.ok(fs.statSync(logFile).size <= 48 * 1024, "로그 발췌 상한");
  assert.ok(fs.readFileSync(logFile, "utf8").endsWith("끝"));
  const gh = traceOf(x.sb, "gh-trace.jsonl");
  assert.deepEqual(gh.map((c) => c.args.slice(0, 2).join(" ")), ["run list", "run view"]);
  assert.ok(gh.every((c) => fs.realpathSync(c.cwd) === fs.realpathSync(x.repo)));
  // gh 인증 실패 흉내 — 접수는 계속(벤치로)
  const y = setup(t, { gh: { rc: 4 } });
  const r2 = run(y.env, ["start", "gostop-intake", "gostop-intake:2026-10-05", "--day=2026-10-05"]);
  assert.equal(r2.code, 0, r2.out);
  const q2 = listThreads(y).filter((v) => v.graph === "gostop-fix");
  assert.equal(q2.length, 1);
  assert.match(q2[0].thread, /^gostop-fix:bench:/, "신호가 없으니 벤치 1건");
  assert.match(run(y.env, ["status", "gostop-intake:2026-10-05", "--json"]).out, /CI 못 읽음/);
});

test("S13 한 번에 하나: gostop-fix 대기열 둘이면 앞 것이 끝나야 뒤 것이 시작 · 접수가 만든 스레드는 그림자", async (t) => {
  const x = setup(t, { flutter: { mode: "pass" } });
  const day = "2026-10-05";
  fs.mkdirSync(path.join(x.soak, "20261005"));
  fs.writeFileSync(path.join(x.soak, "20261005", "summary.json"), JSON.stringify({ ...soakSummary("20261005", [11, 22]), head: x.base.slice(0, 7) }));
  assert.equal(run(x.env, ["start", "gostop-intake", `gostop-intake:${day}`, `--day=${day}`]).code, 0);
  const threads = () => listThreads(x).filter((v) => v.graph === "gostop-fix");
  assert.ok(threads().every((v) => v.mode === "shadow"));
  run(x.env, ["tick"]);
  let v = threads();
  assert.equal(v.filter((r) => r.status !== "queued").length, 1, "하나만 시작");
  for (let i = 0; i < 80 && threads().some((r) => r.status !== "done"); i++) { run(x.env, ["tick"]); await new Promise((r) => setTimeout(r, 100)); }
  v = threads();
  assert.deepEqual(v.map((r) => r.status), ["done", "done"]);
  const starts = metrics(x.sb).filter((m) => m.ev === "start" && m.from === "queue" && /gostop-fix/.test(m.thread));
  const ends = metrics(x.sb).filter((m) => m.ev === "done" && /gostop-fix/.test(m.thread));
  assert.equal(starts.length, 2);
  assert.equal(ends.length, 2);
  assert.equal(ends[0].thread, starts[0].thread);
  assert.ok(ends[0].t <= starts[1].t, "앞 스레드가 끝난 뒤에 뒤 스레드 시작");
});

test("하루 1회 접수: 04:30 전 틱은 올리지 않고, 뒤 첫 틱이 gostop-intake:<날짜> 를 한 번만 올린다", (t) => {
  const x = setup(t, { extra: { LG_DAILY: "gostop-intake@04:30" } });
  const at = (hhmm) => Date.parse(`2026-10-05T${hhmm}:00+09:00`);
  const tickAt = (hhmm) => { writeUsage(x.env.LG_USAGE_FILE, { at: at(hhmm) }); return run(x.env, ["tick"], { extraEnv: { LG_NOW: String(at(hhmm)) } }); };
  tickAt("04:10");
  assert.equal(listThreads(x).filter((v) => v.graph === "gostop-intake").length, 0);
  tickAt("04:40");
  tickAt("05:10");
  const v = listThreads(x).filter((r) => r.graph === "gostop-intake");
  assert.deepEqual(v.map((r) => r.thread), ["gostop-intake:2026-10-05"]);
  assert.equal(metrics(x.sb).filter((m) => m.ev === "start" && m.by === "daily").length, 1);
  assert.throws(() => loadConfig({ LG_DAILY: "gostop-intake@25:00" }), /형식/);
  assert.deepEqual(loadConfig({ HOME: x.sb.home }).daily, [{ graph: "gostop-intake", after: 270 }], "운영 기본값 04:30");
});

// ── 정적 검사·허용 목록·관문 ───────────────────────────────────────
test("cmdId 허용 목록: 고스톱 명령은 읽기·사본 안 명령뿐(effect 0) · 최대 시간 > 시간 제한 · gh 는 run list/run view 만 · 그래프는 글자값 cmdId 만", () => {
  const reg = loadRegistry(path.join(ROOT, "cmd-registry.json"));
  for (const id of GOSTOP_IDS) {
    const c = reg.commands[id];
    assert.ok(c, id);
    assert.equal(c.effect, false, `${id} effect 아님`);
    assert.deepEqual(c.envPass, [], `${id} 환경변수 전달 없음`);
    assert.ok(c.maxSeconds > c.timeoutSec, `${id} maxSeconds`);
    assert.deepEqual([...c.modes].sort(), ["live", "shadow"]);
  }
  assert.deepEqual(reg.commands["gh.run-list"].argv.slice(0, 2), ["run", "list"]);
  assert.deepEqual(reg.commands["gh.run-log-failed"].argv.slice(0, 2), ["run", "view"]);
  assert.ok(reg.commands["git.archive"].argv.includes("archive") && !reg.commands["git.archive"].argv.some((a) => /^(push|commit|reset|checkout|clean)$/.test(a)));
  // 자리 정규식: 사본 밖·위로 올라가기·본 저장소 아닌 경로는 거부
  const ok = (id, p) => { try { resolveCommand(reg, id, p, { mode: "shadow", scratch: "/tmp" }); return true; } catch { return false; } };
  assert.ok(ok("flutter.test-file", { dir: "/x/state/graphs/gostop/sandbox/bench_a/work", test: "test/a/b_test.dart" }));
  assert.ok(!ok("flutter.test-file", { dir: "/x/gostop/sandbox/../../etc/work", test: "test/a/b_test.dart" }));
  assert.ok(!ok("flutter.test-file", { dir: "/Users/x/projects/gostop_app", test: "test/a/b_test.dart" }), "본 저장소에서 시험을 돌리지 않는다");
  assert.ok(!ok("flutter.test-file", { dir: "/x/gostop/sandbox/a/work", test: "../evil_test.dart" }));
  assert.ok(!ok("flutter.test-defines", { dir: "/x/gostop/sandbox/a/work", test: "test/a_test.dart", d1: "FOO=1", d2: "LG_NOOP=1", d3: "LG_NOOP=1" }));
  assert.ok(!ok("git.archive", { repo: "/x/gostop_app", out: "/tmp/elsewhere.tar", rev: "HEAD" }), "tar 는 사본 자리에만");
  assert.ok(!ok("git.rev-parse", { repo: "/x/gostop_app", rev: "--output=/tmp/x" }));
  assert.ok(!ok("gh.run-log-failed", { repo: "/x/gostop_app", run_id: "1;rm" }));
  // 그래프 정적 검사: 양성 0건, 음성(변수 cmdId·목록 밖·child_process) 은 위반
  for (const g of ["gostop-fix", "gostop-intake", "gostop-common"]) assert.deepEqual(checkGraphFile(path.join(ROOT, "graphs", `${g}.mjs`), reg), [], g);
  assert.deepEqual(checkFile(path.join(ROOT, "graphs", "gostop-fix.mjs"), "gostop-fix").problems, []);
  const tmp = fs.mkdtempSync(path.join(process.env.TMPDIR ?? "/tmp", "lg-gostop-rules-"));
  const src = fs.readFileSync(path.join(ROOT, "graphs", "gostop-fix.mjs"), "utf8").replace('from "./gostop-common.mjs"', `from ${JSON.stringify(path.join(ROOT, "graphs", "gostop-common.mjs"))}`);
  const bad = (name, code) => { const f = path.join(tmp, `${name}.mjs`); fs.writeFileSync(f, code); return checkGraphFile(f, reg).map((p) => p.rule); };
  assert.ok(bad("v1", src.replace('tools.run("git.rev-parse", { repo, rev })', "tools.run(s.cmd, { repo, rev })")).includes("cmd-literal"));
  assert.ok(bad("v2", src.replace('tools.run("git.rev-parse"', 'tools.run("git.push"')).includes("cmd-unknown"));
  assert.ok(bad("v3", `import { execFileSync } from "node:child_process";\n${src}`).includes("child-process"));
  fs.rmSync(tmp, { recursive: true, force: true });
});

test("디스크 관문: 경고선 15 + 사본 실측(LG_COPY_EST_GIB 기본값) + 1 GiB", () => {
  const cfg = loadConfig({ HOME: "/tmp/nohome" });
  const est = cfg.gates.copyEstGiB;
  assert.ok(est > 0 && est < 1, `사본 실측값 ${est}`);
  const need = 15 + est + 1;
  const statfs = (free) => () => ({ bavail: Math.floor((free * 2 ** 30) / 4096), bsize: 4096 });
  assert.equal(diskGate(cfg.gates, statfs(need - 0.05))?.gate, "disk");
  assert.equal(diskGate(cfg.gates, statfs(need + 0.05)), null);
  assert.match(diskGate(cfg.gates, statfs(need - 0.05)).detail, new RegExp(`사본 ${est}`));
});

// ── 도우미 단위 ───────────────────────────────────────────────────
test("M8 AI 분기 오판: 비교 판정과 사례 기대가 어긋날 때만 true · 못 쟀으면 null · 옛 기준 커밋엔 AI 비교 시험(.dart)만 얹는다(10-07)", () => {
  assert.equal(C.aiMisjudge("pass", null), false, "규칙 결함 사례(기본: AI 결정 안 바뀜)에서 같음 = 옳은 판정");
  assert.equal(C.aiMisjudge("fail", null), true, "규칙 수정인데 AI 결정이 바뀌었다고 판정 = 오판");
  assert.equal(C.aiMisjudge("fail", { aiChange: true }), false);
  assert.equal(C.aiMisjudge("pass", { aiChange: true }), true);
  assert.equal(C.aiMisjudge("unavailable", null), null);
  const tmp = fs.mkdtempSync(path.join(process.env.TMPDIR || "/tmp", "lg-aip-")), repo = path.join(tmp, "repo"), dir = path.join(tmp, "copy");
  fs.mkdirSync(dir);
  fs.mkdirSync(path.join(repo, "test", "ai_policy"), { recursive: true });
  for (const f of ["ai_policy_gen_test.dart", "ai_policy_compare_test.dart", "ai_policy_core.dart", "README.md"]) fs.writeFileSync(path.join(repo, "test", "ai_policy", f), "// x\n");
  assert.equal(C.hasAiPolicy(dir), false);
  assert.deepEqual(C.overlayAiPolicy(repo, dir), ["test/ai_policy/ai_policy_compare_test.dart", "test/ai_policy/ai_policy_core.dart", "test/ai_policy/ai_policy_gen_test.dart"]);
  assert.equal(C.aiPolicyErrors("  error • The named parameter 'aiDifficulty' isn't defined • test/ai_policy/ai_policy_corpus.dart:439:7 • undefined_named_parameter\n1 issue found."), 1);
  assert.equal(C.aiPolicyErrors("  error • x • lib/a.dart:1:2 • y\n  warning • z • test/ai_policy/a.dart:1:2 • w\n2 issues found."), 0, "다른 파일 오류·경고는 세지 않는다");
  assert.equal(C.hasAiPolicy(dir), true);
  assert.equal(fs.existsSync(path.join(dir, "test", "ai_policy", "README.md")), false, "README 는 사례 이름이 적혀 있어 얹지 않는다");
  fs.rmSync(tmp, { recursive: true, force: true });
});

test("전체 시험 견주기: 사본 경로(work/·base/)가 달라도 같은 실패는 같다 · 시험 실행기 연결 고장으로 못 실은 파일만 따로 센다(10-07)", () => {
  const SB = "/Users/x/.openclaw-data/runtime/state/graphs/gostop/sandbox/bench_t";
  const full = (dir, extra = "") => [
    `00:31 +10 -1: ${SB}/${dir}/test/data/services/push_test.dart: 알림 타입 8개 [E]`,
    `  Expected: 8`,
    extra,
    `00:40 +11 -2: Some tests failed.`,
  ].join("\n");
  const w = C.readTestOutput(full("work"), 1), b = C.readTestOutput(full("base"), 1);
  assert.deepEqual(w.failed, ["test/data/services/push_test.dart: 알림 타입 8개"]);
  const base = new Set(C.failureItems(b));
  assert.deepEqual(C.failureItems(w).filter((x) => !base.has(x)), [], "기존 실패를 이번 수정의 새 실패로 세지 않는다");
  assert.equal(C.relTestName(`loading ${SB}/work/test/a/b_test.dart`), "loading test/a/b_test.dart");
  assert.equal(C.relTestName("조커 시험"), "조커 시험");
  // 실행기 연결 고장 — 파일을 싣기도 전에 죽음(시험 코드 탓 아님)
  const sock = [
    "Shell: [ERROR:flutter/shell/testing/tester_main.cc(686)] Unhandled exception",
    "Shell: Exception: SocketException: Connection failed (OS Error: Operation not permitted, errno = 1), address = 127.0.0.1, port = 62245",
    `Shell: #12     main (file://${SB}/tmp/10/t/flutter_tools.x/flutter_test_listener.y/listener.dart:51:13)`,
    `02:06 +2940 ~2 -151: loading ${SB}/work/test/presentation/providers/gukjin_live_test.dart [E]`,
    `  Failed to load "${SB}/work/test/presentation/providers/gukjin_live_test.dart": Shell subprocess cleanly reported an error.`,
  ].join("\n");
  assert.deepEqual(C.runnerLoadFlakes(full("work", sock)), ["test/presentation/providers/gukjin_live_test.dart"]);
  // 컴파일 오류로 못 실은 것은 실행기 고장이 아니다(수정 탓일 수 있다)
  const comp = `test/presentation/providers/gukjin_live_test.dart:3:1: Error: x\n02:06 +1 -1: loading ${SB}/work/test/presentation/providers/gukjin_live_test.dart [E]\n  Failed to load "x": Compilation failed`;
  assert.deepEqual(C.runnerLoadFlakes(comp), []);
  assert.deepEqual(C.runnerLoadFlakes(full("work")), []);
});

test("판독·판정 도우미: 재현 출력 서명(메모·결정 수 제외)·흔들림·진단 JSON·범위·벤치 대조·표식·--json-schema 자리", () => {
  const out = (memo) => `★ 라이브↔엔진 재생 대조: 1판 / 결정 18건 재생 / 불일치 1\n  ⛔ seed=7: 라이브와 엔진의 끝 상태가 다르다\n    seat0 확정 점수: 라이브 4 / 엔진 6\n    결정 18건, 완주=true, 메모: ${memo}\n00:18 +0 -1: Some tests failed.\n`;
  const a = C.readTestOutput(out("1"), 1), b = C.readTestOutput(out("2"), 1);
  assert.equal(a.sig, b.sig, "매번 바뀌는 메모는 서명에서 뺀다");
  assert.equal(C.judgeRepro([a, b]), "reproduced");
  assert.equal(C.judgeRepro([a, C.readTestOutput("00:01 +3: All tests passed!", 0)]), "flaky");
  assert.equal(C.judgeRepro([C.readTestOutput("ok", 0), C.readTestOutput("ok", 0)]), "not_reproduced");
  assert.equal(C.judgeRepro([C.readTestOutput("lib/a.dart:1:2: Error: x", 1), a]), "compile_error");
  assert.deepEqual(C.readTestOutput("00:02 +3 -1: 조커 시험 [E]\n", 1).failed, ["조커 시험"]);
  const d = { hypothesis: "h", files: ["./lib/domain/game/turn_manager.dart:12"], rule_gap: false, confidence: 0.5, evidence: [] };
  assert.deepEqual(C.parseDiag(d, "").files, ["lib/domain/game/turn_manager.dart"]);
  assert.equal(C.parseDiag(null, "```json\n" + JSON.stringify(d) + "\n```").hypothesis, "h");
  assert.equal(C.parseDiag(null, "모름"), null);
  assert.equal(C.parseDiag({ ...d, confidence: 3 }, ""), null);
  assert.deepEqual(C.scopeOf({ files: ["lib/domain/game/x.dart", "test/a_test.dart"], hypothesis: "" }).reasons, []);
  assert.equal(C.scopeOf({ files: ["lib/presentation/screens/shop_screen.dart"], hypothesis: "" }).reasons.length, 1);
  assert.equal(C.scopeOf({ files: ["lib/domain/ai/ai_player.dart"], hypothesis: "" }).ai.length, 1);
  assert.equal(C.diagMatch({ files: ["lib/a.dart"], keywords: ["국진|gukjin"] }, { ...d, files: ["lib/a.dart"], hypothesis: "gukjin 누락" }).ok, true);
  assert.equal(C.diagMatch({ files: ["lib/a.dart"] }, { ...d, files: ["lib/b.dart"] }).ok, false);
  const repo = fs.mkdtempSync(path.join(process.env.TMPDIR ?? "/tmp", "lg-busy-"));
  assert.equal(C.busyReason(repo, T0, (T0 - 3_600_000) / 1000), null);
  assert.match(C.busyReason(repo, T0, (T0 - 60_000) / 1000), /1분 전/);
  fs.writeFileSync(path.join(repo, ".jarvis-busy"), "");
  assert.match(C.busyReason(repo, T0, 0), /표식/);
  fs.rmSync(repo, { recursive: true, force: true });
  const args = claudeArgs("sonnet", ["Read", "Grep"], { jsonSchema: C.DIAG_SCHEMA });
  assert.ok(args.indexOf("--json-schema") < args.indexOf("--tools"), "--tools 는 값을 여러 개 받으므로 맨 뒤");
  assert.deepEqual(JSON.parse(args[args.indexOf("--json-schema") + 1]).required, C.DIAG_SCHEMA.required);
  assert.deepEqual(claudeArgs("haiku").slice(-2), ["--tools", ""]);
  assert.equal(C.keyDir("bench:hist-69a0144:r1"), "bench_hist-69a0144_r1");
  // 접수 판독
  const ss = soakSignals(soakSummary("20261005", [5], ["멈춤 1"]));
  assert.deepEqual(ss.signals.map((x) => x.kind), ["seed"]);
  assert.equal(ss.reportOnly.length, 1, "씨앗 없는 문제는 기록만(H3 중5)");
  const dirty = soakSignals({ ...soakSummary("20261005", [5]), dirty: 2 });
  assert.equal(dirty.signals.length, 0, "미커밋 소크는 수정 스레드로 보내지 않는다");
  assert.match(dirty.reportOnly[0].why, /dirty/);
  assert.equal(ciFailures([{ conclusion: "failure", workflowName: "W", createdAt: "2026-01-01T00:00:00Z", headSha: "a".repeat(40), databaseId: 1 }], Date.parse("2026-01-02")).length, 0, "기준 시각 전 실패는 이미 본 것");
  assert.equal(ciTestOf("x test/domain/game/a_b_test.dart:12 y"), "test/domain/game/a_b_test.dart");
});

test("벤치 목록: 역사 2건 + 회귀 주입 6건 이상, 사례마다 빨간불 확인 기록이 있다", () => {
  const b = C.loadBench();
  const hist = b.cases.filter((c) => c.id.startsWith("hist-"));
  const inj = b.cases.filter((c) => c.kind === "inject");
  assert.deepEqual(hist.map((c) => c.origin).sort(), ["02d61dc", "69a0144"]);
  assert.ok(inj.length >= 6, `회귀 주입 ${inj.length}건`);
  for (const c of b.cases) {
    assert.ok(c.red && c.red.verified && c.red.rc !== 0, `${c.id} 빨간불 확인`);
    assert.ok(c.expect, `${c.id} 기대값`);
    if (c.kind === "inject") assert.ok(c.inject.file && c.inject.find && c.inject.replace !== undefined && c.test && c.green?.rc === 0, c.id);
  }
  assert.equal(hist.find((c) => c.origin === "02d61dc").expect.status, "rule_decision");
  for (const c of b.cases) assert.deepEqual(c.leakCheck?.hits, [], `${c.id} 사본 규칙 뒤 정답 표지 0(H3 상1)`);
  assert.equal(new Set(b.cases.map((c) => c.id)).size, b.cases.length, "id 겹침 없음");
});

// ── 고장 주입 도구(PLAN §5 1a) ────────────────────────────────────
const FAULT = path.join(ROOT, "scripts", "lg-fault.mjs");
const fault = (env, args) => { const r = spawnSync(NODE, [FAULT, ...args], { env, encoding: "utf8", timeout: 30_000 }); return { code: r.status, lines: String(r.stdout).trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)) }; };

test("고장 주입 kill-job: 살아 있는 재현 묶음을 SIGKILL → 그래프가 다시 띄워 끝까지 · fault 기록과 lg-report M1 '주입 뒤 이어 감'", async (t) => {
  const x = setup(t, { flutter: { mode: "hang" } });
  assert.equal(startFix(x, "bench:t1:r1", benchSig(x)).code, 0);
  const thread = "gostop-fix:bench:t1:r1";
  let jobs = [];
  for (let i = 0; i < 50 && !jobs.length; i++) { jobs = fault(x.env, ["list", thread]).lines[0].jobs; if (!jobs.length) await new Promise((r) => setTimeout(r, 100)); }
  assert.equal(jobs.length, 1);
  assert.equal(jobs[0].node, "reproduce_1");
  const k = fault(x.env, ["kill-job", thread]);
  assert.equal(k.code, 0);
  assert.equal(k.lines[0].ok, true);
  assert.equal(fault(x.env, ["kill-job", "gostop-fix:없음"]).code, 1, "없는 스레드는 아무것도 끄지 않는다");
  x.reg.setFlutter({ mode: "mismatch" });
  assert.equal((await drive(x, thread)).status, "done");
  assert.equal(resultOf(x, "bench:t1:r1").repro, "reproduced");
  assert.equal(metrics(x.sb).filter((m) => m.ev === "fault").length, 1);
  const rep = JSON.parse(spawnSync(NODE, [path.join(ROOT, "lg-report.mjs"), "--json"], { env: x.env, encoding: "utf8" }).stdout);
  assert.deepEqual(rep.m1.faults, { injected: 1, continued: 1 });
});

test("고장 주입 kill-tick: 잠금을 쥔 실행기(run.mjs)만 SIGKILL → 다음 틱이 끊김(interrupted)으로 적고 잇는다", async (t) => {
  const sb = sandbox(t);
  const lg = appWith(sb, { steps: (await import("./helpers0b.mjs")).STEPS });
  const env = { ...tickEnv(sb), LG_TEST_STEP_MS: "2500" };
  assert.equal(lg(env, ["start", "steps", "s1", "--queue"]).code, 0);
  const appFault = path.join(sb.dir, "app", "scripts", "lg-fault.mjs");
  const tick = spawnSync(NODE, ["-e", `require("node:child_process").spawn(process.execPath,[${JSON.stringify(path.join(sb.dir, "app", "run.mjs"))},"tick"],{env:process.env,stdio:"ignore",detached:true}).unref()`], { env });
  assert.equal(tick.status, 0);
  // 노드가 돌고 있을 때(잠금 + 실행 중) 끈다 — 잠금만 잡고 시작 전이면 끊김이 아니라 아직 시작 안 한 것이다
  let locks = [];
  for (let i = 0; i < 100; i++) {
    const r = spawnSync(NODE, [appFault, "list"], { env, encoding: "utf8" });
    locks = JSON.parse(r.stdout.trim().split("\n")[0]).locks;
    if (locks.length && JSON.parse(lg(env, ["status", "s1", "--json"]).out).status === "running") break;
    await new Promise((r2) => setTimeout(r2, 100));
  }
  assert.equal(locks.length, 1, "틱이 잠금을 쥐고 노드를 돌리는 중");
  const k = spawnSync(NODE, [appFault, "kill-tick", "s1"], { env, encoding: "utf8" });
  assert.equal(k.status, 0, k.stdout + k.stderr);
  await new Promise((r) => setTimeout(r, 300));
  for (let i = 0; i < 10; i++) { lg(env, ["tick"], { extraEnv: { LG_TEST_STEP_MS: "0" } }); if (JSON.parse(lg(env, ["status", "s1", "--json"]).out).status === "done") break; }
  assert.equal(JSON.parse(lg(env, ["status", "s1", "--json"]).out).status, "done");
  const m = metrics(sb);
  assert.ok(m.some((r) => r.ev === "interrupted" && r.thread === "s1"), "끊김으로 적혔다");
  assert.ok(m.some((r) => r.ev === "fault" && r.kind === "kill-tick"));
});

// ── 독립 검토(H3) 회귀 시험 ─────────────────────────────────────────
test("H3 상1: 사본에서 기록 문서(docs/release·context·QA 보고·루트 md)를 빼고 규칙서·CLAUDE.md 는 남긴다 · 정답 표지가 남으면 진단하지 않고 gave_up", async (t) => {
  const x = setup(t);
  // 기록 문서에 정답을 적어 둔다(실제 저장소의 NEXT_ACTIONS·context/bugs 와 같은 모양)
  put(x.repo, "docs/release/NEXT_ACTIONS.md", `국진 두 길 수정 ${x.answer.slice(0, 7)} ANSWER-MARKER-7f3a\n`);
  put(x.repo, "context/bugs/gukjin.md", "ANSWER-MARKER-7f3a\n");
  put(x.repo, "QA_REPORT.md", "ANSWER-MARKER-7f3a\n");
  put(x.repo, "docs/tech/notes.md", "ANSWER-MARKER-7f3a\n");
  git(x.repo, ["add", "-A"]);
  git(x.repo, ["commit", "-q", "-m", "기록 문서"]);
  const base2 = git(x.repo, ["rev-parse", "HEAD"]);
  const sig = { ...benchSig(x), rev: base2.slice(0, 12), bench: { id: "t1", expect: null, leakTerms: ["ANSWER-MARKER-7f3a"] } };
  assert.equal(startFix(x, "bench:t1:r1", sig).code, 0);
  assert.equal((await drive(x, "gostop-fix:bench:t1:r1")).status, "done");
  const work = path.join(C.sandboxDir(x.sb.state, "bench:t1:r1"), "work");
  for (const rel of ["docs/release", "context", "QA_REPORT.md", "docs/tech"]) assert.ok(!fs.existsSync(path.join(work, rel)), `${rel} 빠짐`);
  assert.ok(fs.existsSync(path.join(work, "docs/rules/GAME_MECHANICS.md")) && fs.existsSync(path.join(work, "CLAUDE.md")), "규칙서·CLAUDE.md 는 남는다");
  assert.equal(resultOf(x, "bench:t1:r1").status, "ready", "기록 문서를 뺐으니 누설 없음");
  // 빼는 목록 밖(도구 폴더)에 정답 표지가 남으면 — 진단하지 않고 gave_up
  const y = setup(t);
  put(y.repo, "tools/memo.txt", "ANSWER-MARKER-7f3a\n");
  git(y.repo, ["add", "-A"]);
  git(y.repo, ["commit", "-q", "-m", "도구"]);
  const sig2 = { ...benchSig(y), rev: git(y.repo, ["rev-parse", "HEAD"]).slice(0, 12), bench: { id: "t1", expect: null, leakTerms: ["ANSWER-MARKER-7f3a"] } };
  assert.equal(startFix(y, "bench:t1:r1", sig2).code, 0);
  assert.equal((await drive(y, "gostop-fix:bench:t1:r1")).status, "done");
  const r2 = resultOf(y, "bench:t1:r1");
  assert.equal(r2.status, "gave_up");
  assert.match(r2.note, /누설.*tools\/memo\.txt/);
  assert.equal(y.fc.calls().length, 0, "누설이면 LLM 을 부르지 않는다");
  assert.equal(traceOf(y.sb, "flutter-trace.jsonl").filter((c) => c.sub === "test").length, 0);
});

test("H3 상2: 채점은 '기대 파일 1~2위 + 근거 줄이 정답 자리 ±15' — 실패한 시험 이름을 되풀이한 진단은 틀림", () => {
  const expect = { files: ["lib/domain/game/turn_manager.dart"], lines: { "lib/domain/game/turn_manager.dart": [[1572, 1572]] } };
  const echo = { hypothesis: "winner_attribution_regression_test 의 승자 귀속 시험이 실패한다. selectWinner 승자 판정 문제.", rule_gap: false, confidence: 0.6,
    files: ["lib/domain/game/turn_manager.dart", "lib/domain/game/game_engine.dart"], evidence: ["lib/domain/game/turn_manager.dart:40 — 클래스 머리"] };
  assert.equal(C.diagMatch(expect, echo).ok, false, "낱말·파일만 맞은 메아리");
  assert.equal(C.diagMatch(expect, { ...echo, evidence: ["lib/domain/game/turn_manager.dart:1580 — byStopDeclaration 무시"] }).ok, true);
  assert.equal(C.diagMatch(expect, { ...echo, evidence: ["lib/domain/game/turn_manager.dart:1560-1575 — 승자"] }).ok, true, "범위 근거");
  assert.equal(C.diagMatch(expect, { ...echo, files: ["a.dart", "b.dart", "lib/domain/game/turn_manager.dart"], evidence: ["lib/domain/game/turn_manager.dart:1572 — x"] }).ok, false, "3위 이하는 틀림");
  assert.equal(C.diagMatch({ ...expect, ruleGap: true, status: "rule_decision" }, { ...echo, evidence: ["lib/domain/game/turn_manager.dart:1572"] }, "ready").ok, false);
  // 벤치 목록: 모든 사례에 정답 자리(줄 범위)가 있다
  for (const c of C.loadBench().cases) assert.ok(Object.values(c.expect.lines ?? {}).flat().length, `${c.id} expect.lines`);
});

test("H3 상3: 진단이 사용량 한도로 끝나면 쉼(llm_wait) 뒤 새 실행 번호로 다시 띄워 끝까지 — 같은 결과 파일을 되읽지 않는다", async (t) => {
  const x = setup(t, { claudeMode: "limit" });
  const ok = fakeClaude(x.sb, "diag");
  fs.writeFileSync(`${ok.log}.answer.json`, fs.readFileSync(`${x.fc.log}.answer.json`));
  const T = Date.now();
  const at = (ms) => ({ ...x.env, LG_NOW: String(ms) });
  const env0 = x.env;
  x.env = at(T);
  assert.equal(startFix(x, "bench:t1:r1", benchSig(x)).code, 0);
  const st = await drive(x, "gostop-fix:bench:t1:r1", { until: ["done", "gave_up", "expired", "held"] });
  assert.equal(st.status, "held", JSON.stringify(st));
  // 한 시간 안: 계속 쉼
  x.env = { ...at(T + 30 * 60_000), LG_CLAUDE_BIN: ok.bin };
  writeUsage(env0.LG_USAGE_FILE, { at: T + 30 * 60_000 });
  run(x.env, ["tick"]);
  assert.equal(status(x, "gostop-fix:bench:t1:r1").status, "held");
  assert.equal(ok.calls().length, 0);
  // 두 시간 뒤: 다시 띄워 끝까지
  x.env = { ...at(T + 2 * 3_600_000), LG_CLAUDE_BIN: ok.bin };
  writeUsage(env0.LG_USAGE_FILE, { at: T + 2 * 3_600_000 });
  assert.equal((await drive(x, "gostop-fix:bench:t1:r1")).status, "done");
  assert.equal(resultOf(x, "bench:t1:r1").status, "ready");
  assert.ok(fs.existsSync(path.join(x.sb.state, "jobs", "gostop-fix:bench:t1:r1", "diagnose", "2")), "실행 번호 2");
  assert.equal(x.fc.calls().filter((c) => c.input.includes("정해진 JSON")).length, 1, "한도에 걸린 호출은 한 번뿐");
});

test("H3 중1: 차례를 기다리는 대기열은 앞 스레드가 묶여 있는 동안 만료되지 않는다(앞 것이 만료되면 시작)", async (t) => {
  const x = setup(t, { flutter: { mode: "pass" } });
  const T = Date.now();
  fs.writeFileSync(path.join(x.repo, ".jarvis-busy"), "");
  assert.equal(run(x.env, ["start", "gostop-fix", "gostop-fix:bench:a:r1", "--sigkey=bench:a:r1", `--signal=${JSON.stringify(benchSig(x))}`], { extraEnv: { LG_NOW: String(T) } }).code, 0);
  assert.equal(status(x, "gostop-fix:bench:a:r1").status, "held");
  assert.equal(run(x.env, ["start", "gostop-fix", "gostop-fix:bench:b:r1", "--sigkey=bench:b:r1", `--signal=${JSON.stringify(benchSig(x))}`, "--queue"], { extraEnv: { LG_NOW: String(T + 3_600_000) } }).code, 0);
  writeUsage(x.env.LG_USAGE_FILE, { at: T + 48.5 * 3_600_000 });
  run(x.env, ["tick"], { extraEnv: { LG_NOW: String(T + 48.5 * 3_600_000) } }); // a: 48시간 진척 없음 → 만료. b: 47.5시간 — 아직
  assert.equal(status(x, "gostop-fix:bench:a:r1").status, "expired");
  writeUsage(x.env.LG_USAGE_FILE, { at: T + 50 * 3_600_000 });
  run(x.env, ["tick"], { extraEnv: { LG_NOW: String(T + 50 * 3_600_000) } }); // b: 등록 49시간이지만 a 가 막고 있던 시간은 놀던 것이 아니다 — 시작(표식에 걸려 보류)
  assert.notEqual(status(x, "gostop-fix:bench:b:r1").status, "expired");
  // 같은 때 올린 묶음: 앞 스레드가 만료되는 바로 그 틱에 뒤 대기열이 따라 만료되지 않고 시작한다(재검토 B 중)
  const y = setup(t);
  fs.writeFileSync(path.join(y.repo, ".jarvis-busy"), "");
  assert.equal(run(y.env, ["start", "gostop-fix", "gostop-fix:bench:a:r1", "--sigkey=bench:a:r1", `--signal=${JSON.stringify(benchSig(y))}`], { extraEnv: { LG_NOW: String(T) } }).code, 0);
  assert.equal(run(y.env, ["start", "gostop-fix", "gostop-fix:bench:b:r1", "--sigkey=bench:b:r1", `--signal=${JSON.stringify(benchSig(y))}`, "--queue"], { extraEnv: { LG_NOW: String(T) } }).code, 0);
  writeUsage(y.env.LG_USAGE_FILE, { at: T + 48.5 * 3_600_000 });
  run(y.env, ["tick"], { extraEnv: { LG_NOW: String(T + 48.5 * 3_600_000) } });
  assert.equal(status(y, "gostop-fix:bench:a:r1").status, "expired");
  assert.notEqual(status(y, "gostop-fix:bench:b:r1").status, "expired", "앞 것과 같은 틱에 만료되지 않는다");
  assert.notEqual(status(y, "gostop-fix:bench:b:r1").status, "queued", "그 틱에 시작했다");
});

test("H3 중2·중3: 접수 때 진행 중이던 CI 는 다음 접수가 줍고, 하루 상한에 밀린 소크 신호와 접수가 없던 날의 소크도 이월된다", async (t) => {
  const run1 = { conclusion: "", headSha: "f".repeat(40), name: "Flutter CI", workflowName: "Flutter CI", url: "u", databaseId: 9, createdAt: "2026-10-05T00:30:00Z", status: "in_progress" };
  const x = setup(t, { gh: { runs: [run1], log: "FAILED: test/domain/game/a_test.dart" } });
  // 어제(10-04) 소크 폴더만 있고, 그날은 접수가 없었다 — 불일치 4개
  fs.mkdirSync(path.join(x.soak, "20261004"));
  fs.writeFileSync(path.join(x.soak, "20261004", "summary.json"), JSON.stringify(soakSummary("20261004", [11, 22, 33, 44])));
  const day1 = Date.parse("2026-10-05T09:00:00+09:00");
  assert.equal(run(x.env, ["start", "gostop-intake", "gostop-intake:2026-10-05", "--day=2026-10-05"], { extraEnv: { LG_NOW: String(day1) } }).code, 0);
  let q = listThreads(x).filter((v) => v.graph === "gostop-fix").map((v) => v.thread);
  assert.equal(q.length, 3, "어제 소크를 오늘 줍는다(상한 3)");
  assert.ok(q.every((th) => th.includes(":soak:")));
  // 다음 날: 진행 중이던 CI 가 실패로 끝났다 + 어제 밀린 소크 1건
  fs.writeFileSync(x.reg.ghCtl, JSON.stringify({ runs: [{ ...run1, conclusion: "failure", status: "completed" }], log: "FAILED: test/domain/game/a_test.dart", trace: path.join(x.sb.dir, "gh-trace.jsonl") }));
  const day2 = Date.parse("2026-10-06T09:00:00+09:00");
  assert.equal(run(x.env, ["start", "gostop-intake", "gostop-intake:2026-10-06", "--day=2026-10-06"], { extraEnv: { LG_NOW: String(day2) } }).code, 0);
  q = listThreads(x).filter((v) => v.graph === "gostop-fix").map((v) => v.thread);
  assert.ok(q.includes(`gostop-fix:ci:flutter-ci:${"f".repeat(8)}`), "진행 중이던 CI 실패를 줍는다");
  assert.ok(q.includes("gostop-fix:soak:normal:44:abc1234"), "상한에 밀렸던 소크 신호");
  assert.equal(q.length, 5);
});

test("H3 중4: 3일 지난 사본은 관문(디스크)에 걸린 틱에서도 지운다 — 끝나지 않은 스레드의 사본은 남긴다", (t) => {
  const x = setup(t, { extra: { LG_DISK_FLOOR_GIB: "100000" } });
  const old = path.join(x.sb.state, "gostop", "sandbox", "bench_old_r1");
  const keep = path.join(x.sb.state, "gostop", "sandbox", "bench_new_r1");
  for (const d of [old, keep]) { fs.mkdirSync(path.join(d, "work"), { recursive: true }); fs.writeFileSync(path.join(d, ".ready"), "x"); }
  const four = (Date.now() - 4 * 86_400_000) / 1000;
  fs.utimesSync(path.join(old, ".ready"), four, four);
  const r = run(x.env, ["tick", "--verbose"]);
  assert.match(r.out, /HOLD disk/);
  assert.ok(!fs.existsSync(old), "3일 지난 사본 정리");
  assert.ok(fs.existsSync(keep));
});

test("H3 하: 신호로 죽은 재현은 초록이 아니라 실행 실패 · 서명 없는 빨간불은 도구 오류 · '..' 경로는 허용 목록 밖", () => {
  const killed = C.readTestOutput("00:01 +3: loading", null, "SIGKILL");
  assert.equal(killed.infra, true);
  assert.equal(killed.red, false);
  const tool = C.readTestOutput("Error: No tests ran.\n", 1);
  assert.equal(tool.toolError, true);
  assert.equal(C.judgeRepro([tool, tool]), "tool_error");
  assert.equal(C.scopeOf({ files: ["lib/domain/game/../ai/ai_player.dart"], hypothesis: "" }).ai.length, 1, "펴서 본다");
  assert.equal(C.scopeOf({ files: ["lib/domain/game/../../../../etc/passwd"], hypothesis: "" }).outside.length, 1);
});

test("재검토 B: 진단 호출 오류(형식·결과 없음)는 sonnet ×≤2 에 센다 · 도구 오류 재현은 gave_up(진단 없음)", async (t) => {
  const x = setup(t, { claudeMode: "fail" });
  assert.equal(startFix(x, "bench:t1:r1", benchSig(x)).code, 0);
  assert.equal((await drive(x, "gostop-fix:bench:t1:r1")).status, "done");
  assert.equal(resultOf(x, "bench:t1:r1").status, "gave_up");
  assert.equal(x.fc.calls().filter((c) => c.input.includes("정해진 JSON")).length, 2, "sonnet 2회까지");
  const y = setup(t, { flutter: { mode: "toolerr" } });
  assert.equal(startFix(y, "bench:t1:r1", benchSig(y)).code, 0);
  assert.equal((await drive(y, "gostop-fix:bench:t1:r1")).status, "done");
  const r = resultOf(y, "bench:t1:r1");
  assert.equal(r.repro, "tool_error");
  assert.equal(r.status, "gave_up");
  assert.equal(y.fc.calls().length, 0, "도구 오류면 진단하지 않는다");
});

test("재검토 B 하: 채점 근거 — 넓은 범위는 근거가 아니다 · 파일 이름만·L줄 꼴도 받는다 · 사본 정리가 틱을 죽이지 않는다", (t) => {
  const expect = { files: ["lib/domain/game/turn_manager.dart"], lines: { "lib/domain/game/turn_manager.dart": [[1572, 1572]] } };
  const base = { hypothesis: "h", rule_gap: false, confidence: 0.5, files: ["lib/domain/game/turn_manager.dart"] };
  assert.equal(C.diagMatch(expect, { ...base, evidence: ["lib/domain/game/turn_manager.dart:1-3000 — 전부"] }).ok, false, "넓은 범위");
  assert.equal(C.diagMatch(expect, { ...base, evidence: ["turn_manager.dart:1575 — 승자"] }).ok, true, "파일 이름만");
  assert.equal(C.diagMatch(expect, { ...base, evidence: ["lib/domain/game/turn_manager.dart:L1570 — 승자"] }).ok, true, "L줄");
  // 사본 폴더 자리에 파일이 있어도(정리 대상이 이상해도) 틱은 0 으로 끝난다
  const x = setup(t, { extra: { LG_SANDBOX_KEEP_DAYS: "0" } });
  const root = path.join(x.sb.state, "gostop", "sandbox");
  fs.mkdirSync(path.join(root, "a", "work"), { recursive: true });
  fs.writeFileSync(path.join(root, "not-a-dir"), "x");
  const r = run(x.env, ["tick"]);
  assert.equal(r.code, 0, r.out + r.err);
  assert.ok(!fs.existsSync(path.join(root, "a")));
});
