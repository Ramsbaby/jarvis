// gostop-1b.test.mjs — 1b 통합 시험(설계 §9 1b + 그래프 분기): ⑦ 재현 시험 → ⑧ 빨간불 → ⑨ 수정 → ⑩ 범위 → ⑪ 격리 검증 → ⑫ 검토 → ⑬ 재수정 → ⑮⑯(실제 전용).
// 전부 임시 HOME·임시 상태 폴더·가짜 고스톱 저장소. git·tar·patch·패치 추출·허용 목록·3경로 확인·실행 증명 판정은 진짜(운영 목록 그대로),
// flutter(1a)·격리 실행(sandbox.*)·claude 는 가짜다. 진짜 sandbox-exec 는 sandbox.test.mjs, 실호출은 gostop-bench-live.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { sandbox, run, fakeClaude, ROOT, NODE, FIXTURES } from "./helpers.mjs";
import { tickEnv, metrics } from "./helpers0b.mjs";
import * as C from "../graphs/gostop-common.mjs";
import { loadRegistry, resolveCommand } from "../lib/run.mjs";

const FAKE_FLUTTER = path.join(FIXTURES, "fake-flutter.mjs");
const FAKE_SB = path.join(FIXTURES, "fake-sandboxed.mjs");
const FAKE_KEYTOOL = path.join(FIXTURES, "fake-keytool.mjs");
const PROD = JSON.parse(fs.readFileSync(path.join(ROOT, "cmd-registry.json"), "utf8"));
const OLD = "2026-01-01T09:00:00+09:00";

function git(repo, args, date = OLD) {
  const env = { PATH: "/usr/bin:/bin", HOME: path.dirname(repo), GIT_CONFIG_NOSYSTEM: "1", GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@example.invalid",
    GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@example.invalid", GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date };
  const r = spawnSync("/usr/bin/git", ["-C", repo, ...args], { encoding: "utf8", env });
  assert.equal(r.status, 0, `git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.trim();
}
const put = (root, rel, text) => { fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true }); fs.writeFileSync(path.join(root, rel), text); };

const TM_BUG = "class TurnManager {\n  int score() {\n    return 4;\n  }\n}\n";
const TM_FIX = "class TurnManager {\n  int score() {\n    return 6;\n  }\n}\n";
const GP = "class GameProvider {\n  void processAITurns() {\n    final x = 1;\n    print(x);\n  }\n}\n";
// 가짜 고스톱: base(사본 대상) → answer(정답 — 사본에 안 보여야). origin = 맨 저장소(가짜 원격). aiPolicy: 고스톱 AI 결정 비교 시험 파일을 둔다
function fakeRepo(sb, { aiPolicy = false } = {}) {
  const repo = path.join(sb.dir, "gostop_app");
  const remote = path.join(sb.dir, "remote.git");
  fs.mkdirSync(repo);
  spawnSync("/usr/bin/git", ["init", "-q", "--bare", "-b", "master", remote]);
  git(repo, ["init", "-q", "-b", "master"]);
  git(repo, ["config", "user.name", "t"]); git(repo, ["config", "user.email", "t@example.invalid"]);
  put(repo, "pubspec.yaml", "name: gostop_app\n");
  put(repo, "CLAUDE.md", "# 고스톱 프로젝트 규칙\n");
  put(repo, "docs/rules/GAME_MECHANICS.md", "# 규칙\n## 4.2 9월 국진 선택\n");
  put(repo, "lib/domain/game/turn_manager.dart", TM_BUG);
  put(repo, "lib/domain/ai/ai_player.dart", "class AIPlayer {\n  int pick() {\n    return 1;\n  }\n}\n");
  put(repo, "lib/presentation/providers/game_provider.dart", GP);
  put(repo, "lib/data/services/iap_service.dart", "class IapService {}\n");
  put(repo, "test/domain/game/live_replay_differential_test.dart", "void main() {}\n");
  put(repo, "test/domain/game/live_soak_test.dart", "void main() {}\n");
  put(repo, "test/domain/game/old_rule_test.dart", "void main() { /* expect(score, 4) */ }\n");
  if (aiPolicy) for (const f of [C.AI_POLICY.gen, ...C.AI_POLICY.trusted]) put(repo, f, `// ${f}\nvoid main() {}\n`);
  git(repo, ["add", "-A"]);
  git(repo, ["commit", "-q", "-m", "base"]);
  const base = git(repo, ["rev-parse", "HEAD"]);
  put(repo, "test/presentation/providers/gukjin_answer_test.dart", "// ANSWER-MARKER-7f3a\nvoid main() {}\n");
  put(repo, "lib/domain/game/turn_manager.dart", TM_FIX.replace("}\n}\n", "}\n} // ANSWER-MARKER-7f3a\n"));
  git(repo, ["add", "-A"]);
  git(repo, ["commit", "-q", "-m", "fix: 국진 ANSWER-MARKER-7f3a"]);
  const answer = git(repo, ["rev-parse", "HEAD"]);
  git(repo, ["reset", "-q", "--hard", base]); // master = base(정답은 고칠 대상이 아니라 숨긴 미래) — 실제 모드 ⑮ 가 master 에 얹는다
  git(repo, ["remote", "add", "origin", remote]);
  git(repo, ["push", "-q", "origin", "master"]);
  return { repo, remote, base, answer };
}
const repoState = (repo) => ({ head: git(repo, ["rev-parse", "HEAD"]), status: git(repo, ["status", "--porcelain", "--untracked-files=all"]) });

// 시험 목록 = 운영 목록 + flutter(1a)·sandbox.*·keytool·firebase 만 가짜(인자 모양·자리·정규식은 운영과 같다)
function registry(sb, sbCtl = {}) {
  const flCtl = path.join(sb.dir, "fake-flutter.json"), sbFile = path.join(sb.dir, "fake-sandboxed.json"), ktCtl = path.join(sb.dir, "fake-keytool.json");
  fs.writeFileSync(flCtl, JSON.stringify({ mode: "mismatch", trace: path.join(sb.dir, "flutter-trace.jsonl") }));
  fs.writeFileSync(sbFile, JSON.stringify({ trace: path.join(sb.dir, "sb-trace.jsonl"), ...sbCtl }));
  const commands = {};
  for (const [id, c] of Object.entries(PROD.commands)) {
    if (id.startsWith("flutter.")) commands[id] = { ...c, bin: NODE, argv: [FAKE_FLUTTER, flCtl, ...c.argv] };
    else if (id.startsWith("sandbox.")) commands[id] = { ...c, bin: NODE, argv: [FAKE_SB, sbFile, ...c.argv] };
    else if (id === "apk.cert-fingerprint") commands[id] = { ...c, bin: NODE, argv: [FAKE_KEYTOOL, ktCtl, ...c.argv] };
    else if (id === "fad.distribute") commands[id] = { ...c, bin: NODE, argv: [FAKE_KEYTOOL, ktCtl, ...c.argv] };
    else commands[id] = c;
  }
  const file = path.join(sb.dir, "cmd-registry.json");
  fs.writeFileSync(file, JSON.stringify({ version: 1, commands }, null, 1));
  return { file, sbFile, ktCtl };
}
const traceOf = (sb, name) => { const f = path.join(sb.dir, name); return fs.existsSync(f) ? fs.readFileSync(f, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []; };

// 3경로 재현 시험(기본 표식) — 바르게 쓴 것
const REPRO_OK = `import 'package:flutter_test/flutter_test.dart';
void main() {
  group('엔진: 국진 획득', () {
    test('엔진: 같은 국면 같은 점수', () { expect(1, 1); });
  });
  test('라이브 사람: 국진 쌍피', () { expect(2, 2); });
  test('라이브 AI: 국진 쌍피(어려움)', () { for (final d in [AIDifficulty.hard]) { expect(d, d); } });
}
`;
const REPRO_NO_AI = REPRO_OK.replace(/ {2}test\('라이브 AI[^\n]*\n/, "");
const RT = "test/repro/gukjin_three_path_test.dart";
const DIAG = { hypothesis: "턴 관리자가 국진 점수를 4 로 센다.", files: ["lib/domain/game/turn_manager.dart"], rule_gap: false, confidence: 0.8,
  evidence: ["lib/domain/game/turn_manager.dart:3 — return 4"] };
const REVIEW_OK = { approve: true, three_path: true, unrelated_changes: false, rule_match: true, issues: [], summary: "세 경로 모두 같은 규칙으로 고쳤다." };
const REVIEW_NO = { approve: false, three_path: true, unrelated_changes: true, rule_match: true, issues: ["lib/domain/game/turn_manager.dart:1 — 무관한 변경"], summary: "반려" };

function setup(t, { script = {}, sbCtl = {}, aiPolicy = false, live = false, extra = {} } = {}) {
  const sb = sandbox(t);
  const fr = fakeRepo(sb, { aiPolicy });
  const reg = registry(sb, sbCtl);
  const fc = fakeClaude(sb, "script");
  fs.writeFileSync(`${fc.log}.script.json`, JSON.stringify({
    diag: DIAG, repro: [{ files: { [RT]: REPRO_OK } }], fix: [{ files: { "lib/domain/game/turn_manager.dart": TM_FIX } }], review: [REVIEW_OK], ...script }));
  const soak = path.join(sb.dir, "soak");
  fs.mkdirSync(soak);
  fs.mkdirSync(sb.state, { recursive: true });
  if (live) fs.writeFileSync(path.join(sb.state, "LIVE"), "");
  const env = tickEnv(sb, { over: { LG_CMD_REGISTRY: reg.file, LG_CLAUDE_BIN: fc.bin, LG_GOSTOP_REPO: fr.repo, LG_GOSTOP_SOAK_DIR: soak, LG_TICK_BUDGET_SEC: "60", ...extra } });
  return { sb, ...fr, reg, fc, soak, env };
}
const signal = (x) => ({ source: "bench", kind: "seed", rev: `${x.answer.slice(0, 12)}^`, test: C.DIFF_TEST,
  defines: ["REPLAY_GAMES=1", "REPLAY_SEED_BASE=202656775"], bench: { id: "t1", expect: { files: ["lib/domain/game/turn_manager.dart"], ruleGap: false } } });
const SIG = "bench:t1:r1", THREAD = `gostop-fix:${SIG}`;
const start = (x, sig = signal(x)) => run(x.env, ["start", "gostop-fix", THREAD, `--sigkey=${SIG}`, `--signal=${JSON.stringify(sig)}`]);
const status = (x) => JSON.parse(run(x.env, ["status", THREAD, "--json"]).out);
async function drive(x, { max = 150, until = ["done", "waiting", "gave_up", "expired"] } = {}) {
  for (let i = 0; i < max; i++) {
    const st = status(x);
    if (until.includes(st.status)) return st;
    run(x.env, ["tick"]);
    await new Promise((r) => setTimeout(r, 120));
  }
  return status(x);
}
const result = (x) => JSON.parse(fs.readFileSync(path.join(C.runDir(x.sb.state, SIG), "result.json"), "utf8"));
const work = (x) => path.join(C.sandboxDir(x.sb.state, SIG), "work");
const calls = (x, kind) => x.fc.calls().filter((c) => c.kind === kind);
const effects = (x) => { const f = path.join(x.sb.state, "effects.jsonl"); return fs.existsSync(f) ? fs.readFileSync(f, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []; };
async function runFix(t, opts = {}) {
  const x = setup(t, opts);
  const before = repoState(x.repo);
  const r = start(x);
  assert.equal(r.code, 0, r.out + r.err);
  const st = await drive(x);
  return { x, st, before };
}

// ── 끝까지 ─────────────────────────────────────────────────────────
test("1b 끝까지(그림자, CI 신호): 3경로 재현 시험 → 패치 전 빨간불 → 수정 → 격리 검증 9단계 → 검토 → ready · ⑯ 은 would_run 만 · 본 저장소·가짜 원격·소크 결과 불변", async (t) => {
  const x = setup(t);
  const before = repoState(x.repo);
  const { bench, ...ci } = signal(x);
  assert.equal(start(x, { ...ci, source: "ci", rev: x.base }).code, 0);
  const st = await drive(x);
  assert.equal(st.status, "done", JSON.stringify(st));
  const res = result(x);
  assert.equal(res.status, "ready", JSON.stringify({ note: res.note, steps: res.steps }));
  assert.equal(res.reproTest, RT);
  assert.deepEqual(res.threePath, { engine: 1, liveHuman: 1, liveAi: 1 });
  assert.equal(res.redRuns.length, 1);
  assert.equal(res.redRuns[0].red, true);
  assert.equal(res.fixAttempt, 1);
  assert.deepEqual(res.fullPatch.files.map((f) => f.path).sort(), ["lib/domain/game/turn_manager.dart", RT].sort(), "정본 패치 = 재현 시험 + 수정");
  assert.deepEqual(res.fixPatch.files.map((f) => f.path), ["lib/domain/game/turn_manager.dart"], "이번 수정만(redbase 대비)");
  const ids = res.steps.filter((s) => s.phase === "verify").map((s) => s.id);
  assert.deepEqual(ids, ["target", "three_path", "coverage", "analyze_base", "analyze", "full", "mini_diff", "mini_hard", "mini_easy"]);
  assert.ok(res.steps.every((s) => s.ok), JSON.stringify(res.steps));
  assert.match(res.steps.find((s) => s.id === "coverage").detail, /executed/);
  assert.equal(res.review.pass, true);
  assert.equal(res.aiCheck, "unavailable", "AI 결정 비교 시험이 없으면 폴백");
  assert.deepEqual(res.scopeFinal.reasons, [], "lib/domain/game 수정은 사유 없음");
  // 격리 실행: 사본(work·base)·사본 옆 tmp 에서만. 미니 대조 30판 = 차분 20 + 소크 어려움 6 + 쉬움 4. nightly-soak.sh 없음
  const sbt = traceOf(x.sb, "sb-trace.jsonl");
  const root = C.sandboxDir(x.sb.state, SIG);
  assert.ok(sbt.length >= 10 && sbt.every((c) => c.copy.startsWith(root) && c.tmp.startsWith(path.join(root, "tmp") + "/")), JSON.stringify(sbt.slice(0, 2)));
  const flat = sbt.map((c) => c.args.join(" "));
  assert.ok(flat.some((a) => a.includes("REPLAY_GAMES=20")) && flat.some((a) => a.includes("SOAK_DIFFICULTY=hard") && a.includes("SOAK_GAMES=6")) && flat.some((a) => a.includes("SOAK_DIFFICULTY=easy") && a.includes("SOAK_GAMES=4")));
  assert.ok(sbt.some((c) => c.copy.endsWith("/base") && c.args[0] === "analyze"), "분석 기준은 기준 사본(base)");
  // 미니 대조 전용 출력: 소크 결과 자리(LG_GOSTOP_SOAK_DIR)를 가리키는 인자가 없고, 모든 격리 실행은 그 실행 전용 임시 폴더(tmp/<번호>)
  assert.ok(sbt.every((c) => !JSON.stringify(c).includes(x.soak)), "소크 결과 자리를 쓰지 않는다");
  assert.equal(new Set(sbt.filter((c) => !c.canary).map((c) => c.tmp)).size, sbt.filter((c) => !c.canary).length, "실행마다 새 임시 폴더");
  // LLM 이 쓴 뒤 격리 밖 시험(1a flutter.*)은 사본에 안 돈다: 가짜 flutter 는 재현 2회 + pub get 2회(work·base)뿐
  const fl = traceOf(x.sb, "flutter-trace.jsonl");
  assert.deepEqual(fl.map((c) => c.sub).sort(), ["pub", "pub", "test", "test"]);
  // LLM: ⑦ sonnet(쓰기 도구, 작업 폴더 = 사본) · ⑨ opus · ⑫ sonnet(읽기만, JSON 스키마) · --restricted
  const [rt] = calls(x, "repro"), [fx] = calls(x, "fix"), [rv] = calls(x, "review");
  for (const c of [rt, fx, rv]) { assert.ok(c.args.includes("--restricted")); assert.equal(fs.realpathSync(c.cwd), fs.realpathSync(work(x))); }
  assert.equal(rt.args[rt.args.indexOf("--model") + 1], "sonnet");
  assert.equal(fx.args[fx.args.indexOf("--model") + 1], "opus");
  assert.deepEqual(rt.args.slice(rt.args.indexOf("--tools") + 1), ["Read", "Grep", "Glob", "Edit", "Write"]);
  assert.deepEqual(rv.args.slice(rv.args.indexOf("--tools") + 1), ["Read", "Grep", "Glob"]);
  // 쓰기 노드만 acceptEdits(-p 에서 쓰기 허락을 물을 사람이 없다 — 10-03 실호출에서 거부됨), 읽기 노드는 없음. bypassPermissions 는 어디에도 없다
  for (const c of [rt, fx]) assert.equal(c.args[c.args.indexOf("--permission-mode") + 1], "acceptEdits");
  for (const c of [rv, ...calls(x, "diag")]) assert.ok(!c.args.includes("--permission-mode"));
  assert.ok(!x.fc.calls().some((c) => c.args.includes("bypassPermissions")));
  assert.ok(rv.args.includes("--json-schema"));
  assert.match(rv.input, /\+\+\+ b\/lib\/domain\/game\/turn_manager\.dart/, "검토는 정본 패치를 본다");
  assert.doesNotMatch(rt.input + fx.input + rv.input, /ANSWER-MARKER-7f3a/, "정답이 프롬프트에 없다");
  // ⑯ 그림자: effect 는 했을 일만, 가짜 원격·본 저장소 그대로
  const ef = effects(x);
  assert.equal(ef.length, 1);
  assert.equal(ef[0].kind, "git_commit_push");
  assert.equal(ef[0].status, "would_run");
  assert.equal(git(x.remote, ["rev-parse", "master"]), x.base, "가짜 원격 불변");
  assert.deepEqual(repoState(x.repo), before, "본 저장소 HEAD·status 불변");
  const plan = fs.readFileSync(path.join(C.runDir(x.sb.state, SIG), "plan.md"), "utf8");
  assert.match(plan, /## 빨간 시험 → 수정 → 검증\(1b\)/);
  assert.match(plan, /\| mini_hard \| 통과 \|/);
  assert.match(plan, /그림자 — 했을 일만 기록/);
  assert.ok(fs.existsSync(path.join(C.runDir(x.sb.state, SIG), "patch-1.diff")));
});

test("빨간불 없으면 fix 금지: 패치 전에 재현 시험이 초록 → ⑦ 한 번 더(피드백) → 또 초록 → no_red · opus 0회", async (t) => {
  const { x, st } = await runFix(t, { sbCtl: { green: { file: "lib/domain/game/turn_manager.dart", contains: "return 4" } } });
  assert.equal(st.status, "done");
  const res = result(x);
  assert.equal(res.status, "no_red");
  assert.equal(res.rtAttempt, 2);
  assert.equal(res.redRuns.length, 2);
  assert.ok(res.redRuns.every((r) => !r.red && r.rc === 0));
  assert.equal(calls(x, "fix").length, 0, "opus 를 부르지 않는다");
  assert.match(calls(x, "repro")[1].input, /패치 전인데 재현 시험이 모두 통과했다/);
  assert.match(calls(x, "repro")[1].input, new RegExp(`이미 있는 ${RT.replace(/\//g, "\\/")}`), "두 번째는 같은 파일을 고쳐 쓰라고");
});

test("3경로 틀 강제: 라이브 AI(어려움) 묶음이 없으면 ⑦ 다시, 두 번 다 없으면 gave_up — 빨간불 확인도 돌지 않는다", async (t) => {
  const { x, st } = await runFix(t, { script: { repro: [{ files: { [RT]: REPRO_NO_AI } }] } });
  assert.equal(st.status, "done");
  const res = result(x);
  assert.equal(res.status, "gave_up");
  assert.match(res.rtError, /3경로 시험 틀이 모자란다 — 빠진 것: liveAi/);
  assert.equal(calls(x, "repro").length, 2);
  assert.equal(traceOf(x.sb, "sb-trace.jsonl").filter((c) => c.args.includes(RT)).length, 0, "LLM 시험을 한 번도 돌리지 않았다");
});

test("⑦ 범위: 재현 시험 단계가 lib 를 고치면 되돌리고 다시 — 두 번째(시험만)로 이어 가 ready", async (t) => {
  const { x, st } = await runFix(t, { script: { repro: [{ files: { [RT]: REPRO_OK, "lib/domain/game/turn_manager.dart": TM_FIX } }, { files: { [RT]: REPRO_OK } }] } });
  assert.equal(st.status, "done");
  const res = result(x);
  assert.equal(res.status, "ready", res.note);
  assert.equal(res.rtAttempt, 2);
  assert.match(calls(x, "repro")[1].input, /test\/repro\/ 밖이거나 새 파일이 아닌 변경: lib\/domain\/game\/turn_manager\.dart\(modified\)/);
  assert.equal(res.redRuns[0].red, true, "되돌린 뒤라 빨간불");
});

test("허용 목록 밖·기존 시험 수정 → 승인 사유: 그림자는 끝까지 검증하고 would_ask, 실제 모드는 ⑩ scope_gate(순수 interrupt)에서 묻는다", async (t) => {
  const fix = [{ files: { "lib/domain/game/turn_manager.dart": TM_FIX, "lib/data/services/iap_service.dart": "class IapService { int x = 1; }\n", "test/domain/game/old_rule_test.dart": "void main() { /* expect(score, 6) */ }\n" } }];
  const { x, st } = await runFix(t, { script: { fix } });
  assert.equal(st.status, "done");
  const res = result(x);
  assert.equal(res.status, "would_ask");
  assert.deepEqual(Object.keys(res.scopeFinal.byReason).sort(), ["payment", "test_modified"]);
  assert.ok(res.verifyOk && res.review.pass, "그림자는 묻지 않고 끝까지 본다");
  assert.equal(effects(x).length, 0, "물어야 할 패치는 커밋 effect 도 내지 않는다");
  // 실제 모드: ⑩ 뒤에서 멈추고 묻는다(검증 전)
  const y = setup(t, { script: { fix }, live: true });
  assert.equal(start(y).code, 0);
  const st2 = await drive(y);
  assert.equal(st2.status, "waiting", JSON.stringify(st2));
  assert.match(String(st2.question ?? JSON.stringify(st2)), /수정 패치에 승인이 필요합니다/);
  assert.equal(traceOf(y.sb, "sb-trace.jsonl").filter((c) => c.args.includes("--reporter")).length, 0, "묻기 전에는 전체 시험을 돌리지 않는다");
});

test("3경로 하나라도 빨강이면 완료 금지: 라이브 AI 만 계속 빨강 → 재수정 3회(opus 3) 끝 gave_up · 검토는 부르지 않는다", async (t) => {
  const { x, st } = await runFix(t, { sbCtl: { aiStillRed: true } });
  assert.equal(st.status, "done");
  const res = result(x);
  assert.equal(res.status, "gave_up");
  assert.match(res.fixError, /수정 3회 끝/);
  assert.equal(calls(x, "fix").length, 3);
  assert.equal(calls(x, "review").length, 0);
  assert.deepEqual(res.steps.filter((s) => !s.ok).map((s) => s.id), ["three_path", "three_path", "three_path"]);
  assert.match(calls(x, "fix")[1].input, /자동 검증 'three_path' 실패/, "재수정에 실패 내용을 준다");
  assert.equal(effects(x).length, 0);
});

test("재수정 3회 상한(검토 반려 3번) → gave_up · LLM 은 스레드 상한 12 안(기본 5 를 넘어 진행) · 마지막 재수정에 반려 사유", async (t) => {
  const { x, st } = await runFix(t, { script: { review: [REVIEW_NO] } });
  assert.equal(st.status, "done");
  const res = result(x);
  assert.equal(res.status, "gave_up");
  assert.equal(calls(x, "fix").length, 3);
  assert.equal(calls(x, "review").length, 3);
  assert.match(calls(x, "fix")[2].input, /검토 반려 — .*무관한 변경 true/);
  assert.equal(x.fc.calls().length, 1 + 1 + 3 + 3 + 1, "진단 1 + 재현 1 + 수정 3 + 검토 3 + 요약 1 = 9");
  assert.equal(res.calls.sonnet, 5);
  assert.equal(res.calls.opus, 3);
});

test("⑩ 재현 시험(test/repro/)을 수정 단계가 바꾸면 되돌리고 재수정 — 두 번째 수정으로 ready", async (t) => {
  const fix = [{ files: { "lib/domain/game/turn_manager.dart": TM_FIX, [RT]: REPRO_OK.replace("expect(1, 1)", "expect(true, isTrue)") } }, { files: { "lib/domain/game/turn_manager.dart": TM_FIX } }];
  const { x, st } = await runFix(t, { script: { fix } });
  assert.equal(st.status, "done");
  const res = result(x);
  assert.equal(res.status, "ready", res.note);
  assert.equal(res.fixAttempt, 2);
  assert.match(calls(x, "fix")[1].input, /재현 시험\(test\/repro\/\)을 바꾸지 마라 — 되돌렸다/);
  assert.equal(fs.readFileSync(path.join(work(x), RT), "utf8"), REPRO_OK, "재현 시험은 ⑦ 이 쓴 그대로");
});

test("격리 위반(종료 98) → gave_up + 지표 sandbox_violation · 수정하지 않는다", async (t) => {
  const { x, st } = await runFix(t, { sbCtl: { violation: RT } });
  assert.equal(st.status, "done");
  const res = result(x);
  assert.equal(res.status, "gave_up");
  assert.match(res.violation, /exit98/);
  assert.ok(metrics(x.sb).some((m) => m.ev === "sandbox_violation" && m.kind === "exit98"), JSON.stringify(metrics(x.sb).map((m) => m.ev)));
  assert.equal(calls(x, "fix").length, 0);
});

test("검증 중 시험 코드가 사본(lib)을 바꾸면 격리 위반(copy_changed) — 검토·커밋으로 가지 않는다", async (t) => {
  const { x, st } = await runFix(t, { sbCtl: { mutate: true } });
  assert.equal(st.status, "done");
  const res = result(x);
  assert.equal(res.status, "gave_up");
  assert.match(res.violation, /copy_changed/);
  assert.equal(calls(x, "review").length, 0);
  assert.equal(effects(x).length, 0);
});

test("전체 시험의 기존 실패는 기준 사본(base)과 견줘 이번 수정 탓이 아니면 통과 · 분석 경고가 늘면 재수정", async (t) => {
  const { x, st } = await runFix(t, { sbCtl: { preexisting: "옛날부터 깨진 시험" } });
  assert.equal(st.status, "done");
  const res = result(x);
  assert.equal(res.status, "ready", res.note);
  const full = res.steps.find((s) => s.id === "full_base");
  assert.ok(full?.ok && /기존 실패 1건/.test(full.detail), JSON.stringify(res.steps));
  const { x: y } = await runFix(t, { sbCtl: { analyze: { warnings: 2 } } });
  const r2 = result(y);
  assert.equal(r2.status, "gave_up");
  assert.ok(r2.steps.filter((s) => s.id === "analyze" && !s.ok).length === 3);
});

test("AI 결정 비교(§4②): 사본에 test/ai_policy 가 있으면 기준 사본에서 gen·패치 사본에서 compare — 같음이면 규칙 처리부(game_provider) 허용, 다름이면 ai_decision_changed, AI 파일은 늘 사유", async (t) => {
  const gpFix = { files: { "lib/presentation/providers/game_provider.dart": GP.replace("final x = 1;", "final x = 2;"), "lib/domain/game/turn_manager.dart": TM_FIX } };
  const { x } = await runFix(t, { aiPolicy: true, script: { fix: [gpFix] }, sbCtl: { aiVerdict: "same" } });
  const res = result(x);
  assert.equal(res.aiCheck, "pass");
  assert.equal(res.status, "ready", JSON.stringify(res.scopeFinal));
  const sbt = traceOf(x.sb, "sb-trace.jsonl").filter((c) => c.ai);
  assert.deepEqual(sbt.map((c) => [path.basename(c.copy), c.ai]), [["base", "ai-gen"], ["work", "ai-cmp-1"]]);
  const { x: y } = await runFix(t, { aiPolicy: true, script: { fix: [gpFix] }, sbCtl: { aiVerdict: "changed" } });
  const r2 = result(y);
  assert.equal(r2.aiCheck, "fail");
  assert.equal(r2.status, "would_ask");
  assert.ok(r2.scopeFinal.byReason.ai_decision_changed);
  // AI 결정 비교 시험이 없으면(폴백) 규칙 처리부도 승인 사유
  const { x: z } = await runFix(t, { script: { fix: [gpFix] } });
  assert.deepEqual(Object.keys(result(z).scopeFinal.byReason), ["ai_check_unavailable"]);
  const { x: w } = await runFix(t, { aiPolicy: true, script: { fix: [{ files: { "lib/domain/ai/ai_player.dart": "class AIPlayer {\n  int pick() {\n    return 2;\n  }\n}\n", "lib/domain/game/turn_manager.dart": TM_FIX } }] }, sbCtl: { aiVerdict: "same" } });
  assert.ok(result(w).scopeFinal.byReason.ai_boundary, "AI 파일은 비교가 같아도 승인");
});

test("실제 모드(가짜 원격, CI 신호): ⑮ 최신 master 에 재현 시험만 얹어 빨강 확인 → 수정 적용 → 격리 재검증 → ⑯ effect 로 커밋(LG-Key)·push(훅 끔) · 본 저장소 작업 트리 불변", async (t) => {
  const x = setup(t, { live: true });
  const before = repoState(x.repo);
  const { bench, ...ci } = signal(x);
  assert.equal(start(x, { ...ci, source: "ci", rev: x.base }).code, 0);
  const st = await drive(x);
  assert.equal(st.status, "done", JSON.stringify(st));
  const res = result(x);
  assert.equal(res.status, "ready", res.note);
  assert.equal(res.merge.ok, true);
  assert.deepEqual(res.steps.filter((s) => s.phase === "merge").map((s) => s.id), ["master_red", "three_path", "target", "full"]);
  const pushes = traceOf(x.sb, "sb-trace.jsonl").filter((c) => c.copy.endsWith("/merge"));
  assert.ok(pushes.length >= 4, "반영 사본에서 격리 실행");
  const head = git(x.remote, ["rev-parse", "master"]);
  assert.notEqual(head, x.base, "가짜 원격에 커밋이 올라갔다");
  const msg = git(x.remote, ["log", "-1", "--format=%B", "master"]);
  assert.match(msg, /LG-Key: bench:t1:r1/);
  assert.equal(git(x.remote, ["show", "master:lib/domain/game/turn_manager.dart"]), TM_FIX.trim());
  assert.ok(git(x.remote, ["show", "--stat", "--format=", "master"]).includes("test/repro/gukjin_three_path_test.dart"));
  const ef = effects(x).filter((e) => e.kind === "git_commit_push");
  assert.deepEqual(ef.map((e) => e.status), ["started", "ok"]);
  const after = repoState(x.repo);
  assert.equal(after.status, before.status, "본 저장소 작업 트리 불변(출시 작업 폴더에서만)");
  assert.equal(git(x.repo, ["worktree", "list"]).split("\n").length, 1, "출시 작업 폴더 정리");
});

test("실제 모드 벤치: 검증·검토를 통과해도 반영·push 하지 않는다(정답이 이미 master 에 있는 옛 결함) — ready + 메모", async (t) => {
  const { x, st } = await runFix(t, { live: true });
  assert.equal(st.status, "done", JSON.stringify(st));
  const res = result(x);
  assert.equal(res.status, "ready");
  assert.match(res.note, /벤치 — 반영·커밋하지 않는다/);
  assert.equal(res.merge, null);
  assert.equal(effects(x).length, 0);
  assert.equal(git(x.remote, ["rev-parse", "master"]), x.base);
});

test("같은 sigkey 로 다시 시작: LLM 이 손댄 사본은 버리고 새로 만든다 — ③ 재현(격리 밖)은 깨끗한 사본에서만", async (t) => {
  const { x } = await runFix(t);
  assert.equal(result(x).status, "ready");
  assert.ok(fs.existsSync(path.join(work(x), RT)), "앞 스레드가 남긴 재현 시험");
  const n0 = traceOf(x.sb, "flutter-trace.jsonl").length;
  const r = run(x.env, ["start", "gostop-fix", "gostop-fix:again", `--sigkey=${SIG}`, `--signal=${JSON.stringify(signal(x))}`]);
  assert.equal(r.code, 0, r.out + r.err);
  for (let i = 0; i < 150 && !["done", "gave_up"].includes(JSON.parse(run(x.env, ["status", "gostop-fix:again", "--json"]).out).status); i++) { run(x.env, ["tick"]); await new Promise((q) => setTimeout(q, 120)); }
  const again = traceOf(x.sb, "flutter-trace.jsonl").slice(n0).filter((c) => c.sub === "test");
  assert.equal(again.length, 2);
  assert.ok(again.every((c) => c.repro === false), "재현은 test/repro 가 없는(새로 만든) 사본에서");
});

test("AI 호출부(callsites): 수정이 규칙 처리부에 AI 호출을 더하면 결정 비교가 같아도 승인 사유 ai_callsite", async (t) => {
  const fix = [{ files: { "lib/domain/game/turn_manager.dart": TM_FIX, "lib/presentation/providers/game_provider.dart": GP.replace("print(x);", "print(x);\n    AIPlayer().pick();") } }];
  const { x } = await runFix(t, { aiPolicy: true, script: { fix }, sbCtl: { aiVerdict: "same" } });
  const res = result(x);
  assert.equal(res.aiCheck, "pass");
  assert.equal(res.status, "would_ask");
  assert.deepEqual(res.scopeFinal.byReason.ai_callsite, ["lib/presentation/providers/game_provider.dart"]);
});

test("빨간불의 질: 파일을 싣다 죽은 재현 시험(loading [E])은 빨간불이 아니다 → 두 번이면 no_red · opus 0", async (t) => {
  const { x, st } = await runFix(t, { script: { repro: [{ files: { [RT]: `${REPRO_OK}// LOAD_FAIL\n` } }] } });
  assert.equal(st.status, "done");
  const res = result(x);
  assert.equal(res.status, "no_red");
  assert.match(calls(x, "repro")[1].input, /파일을 싣다 죽음/);
  assert.equal(calls(x, "fix").length, 0);
});

test("컴파일 안 되는 재현 시험도 빨간불이 아니다 · 격리 점검 실패면 시험 없이 보류(sandbox_canary)", async (t) => {
  const { x } = await runFix(t, { script: { repro: [{ files: { [RT]: `${REPRO_OK}// COMPILE_ERR\n` } }] } });
  assert.equal(result(x).status, "no_red");
  assert.match(calls(x, "repro")[1].input, /컴파일되지 않는다/);
  const y = setup(t, { sbCtl: { canary: "fail" } });
  assert.equal(start(y).code, 0);
  const st = await drive(y, { until: ["done", "gave_up", "held"] });
  assert.equal(st.status, "held", JSON.stringify(st));
  assert.equal(st.hold, "sandbox_canary");
  assert.equal(traceOf(y.sb, "sb-trace.jsonl").filter((c) => !c.canary).length, 0, "격리 점검이 실패하면 LLM 시험을 돌리지 않는다");
});

test("실행 증명: 바뀐 lib 줄을 라이브 AI 시험이 안 지나면(lcov 0) 재수정 → 3회 끝 gave_up · 재현 시험의 분석 경고는 세지 않는다", async (t) => {
  const { x } = await runFix(t, { sbCtl: { covMiss: true, analyze: { warnings: 3, file: RT } } });
  const res = result(x);
  assert.equal(res.status, "gave_up");
  assert.deepEqual(res.steps.filter((s) => !s.ok).map((s) => s.id), ["coverage", "coverage", "coverage"]);
  assert.match(res.steps.find((s) => s.id === "coverage").detail, /not_executed/);
  assert.equal(calls(x, "review").length, 0);
});

test("실제 모드 ⑩ 승인: 반려면 gave_up(반려), 승인이면 검증으로 이어 간다", async (t) => {
  const fix = [{ files: { "lib/domain/game/turn_manager.dart": TM_FIX, "lib/data/services/iap_service.dart": "class IapService { int x = 1; }\n" } }];
  for (const [ans, want] of [["rejected", "gave_up"], ["approved", "would_ask_live"]]) {
    const y = setup(t, { script: { fix }, live: true });
    assert.equal(start(y).code, 0);
    assert.equal((await drive(y)).status, "waiting");
    const a = run(y.env, ["answer", THREAD, ans]);
    assert.equal(a.code, 0, a.out + a.err);
    const st = await drive(y, { until: ["done", "gave_up", "expired"] });
    assert.equal(st.status, "done", JSON.stringify(st));
    const res = result(y);
    if (want === "gave_up") { assert.equal(res.status, "gave_up"); assert.match(res.note, /반려\(수정 패치\)/); assert.equal(res.verifyOk, null); }
    else { assert.equal(res.status, "ready", res.note); assert.equal(res.verifyOk, true); assert.equal(res.merge, null, "벤치라 반영 안 함"); }
  }
});

test("사본 쓰기 안전: 조상 폴더가 바로가기면 거부, 마지막 자리가 바로가기면 그 이름만 지우고 쓴다(가리키는 곳 불변)", (t) => {
  const sb = sandbox(t);
  const root = path.join(sb.dir, "work"), outside = path.join(sb.dir, "outside");
  fs.mkdirSync(path.join(root, "lib"), { recursive: true }); fs.mkdirSync(outside);
  fs.writeFileSync(path.join(outside, "secret.txt"), "SECRET");
  fs.symlinkSync(outside, path.join(root, "evil"));
  assert.throws(() => C.safeTarget(root, "evil/x.dart"), /조상이 폴더가 아니다/);
  fs.symlinkSync(path.join(outside, "secret.txt"), path.join(root, "lib", "a.dart"));
  const src = path.join(sb.dir, "clean.dart");
  fs.writeFileSync(src, "clean");
  C.copyNoFollow(src, root, "lib/a.dart");
  assert.equal(fs.readFileSync(path.join(outside, "secret.txt"), "utf8"), "SECRET");
  assert.equal(fs.lstatSync(path.join(root, "lib", "a.dart")).isFile(), true);
  fs.symlinkSync(path.join(outside, "secret.txt"), path.join(root, "lib", "b.dart"));
  assert.equal(C.readNoFollow(path.join(root, "lib", "b.dart")), null, "읽기도 따라가지 않는다");
});

// ── 허용 목록·도구 ─────────────────────────────────────────────────
test("cmd-registry 1b: @node·@graphs/ 자리 표시(홈 경로 안 박음) · '..' 거부 · 부수효과 명령은 실제 전용 · LLM 이 쓴 사본에 격리 밖 시험 명령 불가", () => {
  const reg = loadRegistry(path.join(ROOT, "cmd-registry.json"));
  const raw = fs.readFileSync(path.join(ROOT, "cmd-registry.json"), "utf8");
  assert.doesNotMatch(raw, /\/Users\/|\/home\//, "공개 저장소 — 홈 경로 없음");
  const c = reg.commands["sandbox.flutter-test"];
  assert.equal(c.bin, process.execPath);
  assert.equal(c.argv[0], path.join(ROOT, "lib", "sandbox", "sandboxed-run.mjs"));
  for (const id of ["git.worktree-add", "git.apply-index", "git.commit-file", "git.push-master", "git.worktree-remove", "fad.distribute"]) {
    assert.equal(reg.commands[id].effect, true, id);
    assert.deepEqual(reg.commands[id].modes, ["live"], id);
  }
  const sbx = "/x/state/graphs/gostop/sandbox/bench_t1_r1";
  assert.throws(() => resolveCommand(reg, "flutter.test-file", { dir: `${sbx}/merge`, test: "test/a_test.dart" }, { mode: "shadow" }), /형식/, "1a 시험 명령은 반영 사본(merge)에 못 쓴다");
  assert.throws(() => resolveCommand(reg, "sandbox.flutter-test", { dir: `${sbx}/clean`, tmp: `${sbx}/tmp`, test: "test/a_test.dart" }, { mode: "shadow" }), /형식/, "패치 기준(clean)에서는 시험을 돌리지 않는다");
  assert.throws(() => resolveCommand(reg, "sandbox.flutter-test", { dir: `${sbx}/work`, tmp: "/tmp/x", test: "test/a_test.dart" }, { mode: "shadow" }), /형식/);
  assert.throws(() => resolveCommand(reg, "git.push-master", { wt: "/x/state/graphs/gostop/release-wt/k" }, { mode: "live" }), /effect/);
  const bad = path.join(fs.mkdtempSync(path.join(process.env.TMPDIR ?? "/tmp", "lg-reg-")), "r.json");
  fs.writeFileSync(bad, JSON.stringify({ version: 1, commands: { "x.y": { bin: "@node", argv: ["@graphs/../run.mjs"], modes: ["shadow"] } } }));
  assert.throws(() => loadRegistry(bad), /@graphs\/ 경로 형식/);
});

test("3경로 확인: 고스톱 틀(H5) 표식 — '3경로/…' 묶음 + 도우미 expect(_expectX) + threePathAiDifficulties 를 어려움으로 센다", async () => {
  const { checkThreePaths, DEFAULT_MARKERS } = await import("../lib/sandbox/three-path-check.mjs");
  const mk = JSON.parse(fs.readFileSync(path.join(ROOT, "lib", "sandbox", "markers-h5.json"), "utf8"));
  const src = `// 3경로 시험 v1
void _expectPuk(r) { expect(r, 1); }
void main() {
  group('3경로/엔진 — 뻑', () { test('엔진: 뻑', () { _expectPuk(1); }); });
  group('3경로/라이브-사람 — 뻑', () { test('사람', () async { _expectPuk(1); }); });
  group('3경로/라이브-AI — 뻑', () { for (final d in threePathAiDifficulties) { test('AI', () async { _expectPuk(d); }); } });
}`;
  const r = checkThreePaths(src, { markers: { ...DEFAULT_MARKERS, ...mk } });
  assert.equal(r.ok, true, JSON.stringify(r));
  const noHard = checkThreePaths(src.replace("threePathAiDifficulties", "[AIDifficulty.easy]"), { markers: { ...DEFAULT_MARKERS, ...mk } });
  assert.deepEqual(noHard.missing, ["liveAiHard"]);
  const empty = checkThreePaths(src.replace("void _expectPuk(r) { expect(r, 1); }", "void _expectPuk(r) {}"), { markers: { ...DEFAULT_MARKERS, ...mk } });
  assert.deepEqual(empty.missing.sort(), ["engine", "liveAi", "liveHuman"], "빈 _expectX 도우미는 단언이 아니다");
  const helperless = checkThreePaths(src.replace(/_expectPuk\(1\);/g, "print(1);"), { markers: { ...DEFAULT_MARKERS, ...mk } });
  assert.ok(helperless.missing.includes("engine"), "expect 가 없으면 세지 않는다");
  const use = C.h5FrameUse("import 'three_path_support.dart';\nrunEnginePath(a); h.runHuman(a); h.runAi(a, d);", ["const threePathAiDifficulties = [AIDifficulty.easy];"]);
  assert.equal(use.ok, false);
  assert.match(use.why.join(), /다시 정의/);
});

// ── release: 서명 지문 ─────────────────────────────────────────────
test("release(실제 전용): 서명 지문이 기대값과 다르면(가짜 키) 배포 effect 없이 멈춘다 · 맞으면 배포 · 그림자는 했을 일만", async (t) => {
  const GOOD = "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99";
  const BAD = GOOD.replace(/^AA/, "0F");
  const go = async (live, fp) => {
    const sb = sandbox(t);
    const reg = registry(sb);
    fs.writeFileSync(reg.ktCtl, JSON.stringify({ sha256: fp, fadTrace: path.join(sb.dir, "fad-trace.txt") }));
    fs.mkdirSync(sb.state, { recursive: true });
    if (live) fs.writeFileSync(path.join(sb.state, "LIVE"), "");
    const apk = path.join(sb.dir, "app-release.apk");
    fs.writeFileSync(apk, "PK fake");
    const env = tickEnv(sb, { over: { LG_CMD_REGISTRY: reg.file, LG_RELEASE_CERT_SHA256: GOOD, LG_FAD_APP_ID: "1:123456789:android:abcdef12", LG_TICK_BUDGET_SEC: "60" } });
    const thread = "gostop-release:72";
    const r = run(env, ["start", "gostop-release", thread, `--apk=${apk}`, "--version=72"]);
    for (let i = 0; i < 20 && !["done", "gave_up"].includes(JSON.parse(run(env, ["status", thread, "--json"]).out).status); i++) run(env, ["tick"]);
    const st = JSON.parse(run(env, ["status", thread, "--json"]).out);
    const ef = fs.existsSync(path.join(sb.state, "effects.jsonl")) ? fs.readFileSync(path.join(sb.state, "effects.jsonl"), "utf8") : "";
    return { r, st, ef, fad: fs.existsSync(path.join(sb.dir, "fad-trace.txt")) };
  };
  const bad = await go(true, BAD);
  assert.equal(bad.st.status, "done", JSON.stringify(bad.st));
  assert.match(bad.st.result ?? JSON.stringify(bad.st), /signing_mismatch/);
  assert.equal(bad.fad, false, "지문이 다르면 배포 명령을 부르지 않는다");
  assert.doesNotMatch(bad.ef, /fad_distribute/);
  const good = await go(true, GOOD);
  assert.match(good.st.result ?? JSON.stringify(good.st), /distributed/);
  assert.equal(good.fad, true);
  const shadow = await go(false, GOOD);
  assert.match(shadow.st.result ?? JSON.stringify(shadow.st), /shadow/);
  assert.equal(shadow.fad, false);
});

// ── 실행 환경 고장은 LLM 탓이 아니다(10-04~06 실측: 격리 stdio 고장의 255·0초가 벤치 4건을 no_red 로 끝냈다) ─────────
test("빨간불 확인에서 시험 도구가 시작하다 죽으면(255·진행 줄 없음) 같은 시험을 다시 띄운다 — 재현 시험을 다시 쓰게 하지 않고 ready", async (t) => {
  const { x, st } = await runFix(t, { sbCtl: { crash: { match: RT, times: 1 } } });
  assert.equal(st.status, "done", JSON.stringify(st));
  const res = result(x);
  assert.equal(res.status, "ready", res.note);
  assert.equal(calls(x, "repro").length, 1, "재현 시험 작성 1회");
  assert.equal(res.rtAttempt, 1);
  assert.deepEqual(res.redRuns.map((r) => [r.rc, !!r.toolCrash, r.red]), [[255, true, false], [1, false, true]]);
  assert.match(fs.readFileSync(path.join(C.runDir(x.sb.state, SIG), "plan.md"), "utf8"), /시험 도구 고장 — 다시 띄움/);
});

test("빨간불 확인 도구 고장이 3회 이어지면 gave_up(실행 환경 고장) — no_red 가 아니다 · 재현 시험 작성 1회 · opus 0회", async (t) => {
  const { x, st } = await runFix(t, { sbCtl: { crash: { match: RT, times: 99 } } });
  assert.equal(st.status, "done", JSON.stringify(st));
  const res = result(x);
  assert.equal(res.status, "gave_up");
  assert.equal(res.noRed, false);
  assert.match(res.note, /실행 환경 고장/);
  assert.match(res.note, /Failed to get type of stdio handle/);
  assert.equal(res.redRuns.filter((r) => r.toolCrash).length, 3);
  assert.equal(calls(x, "repro").length, 1);
  assert.equal(calls(x, "fix").length, 0);
});

test("검증 단계(전체 시험)의 도구 고장은 재수정(opus)으로 보내지 않는다 — 3회 다시 띄운 뒤 gave_up", async (t) => {
  const { x, st } = await runFix(t, { sbCtl: { crash: { match: "--reporter", times: 99 } } });
  assert.equal(st.status, "done", JSON.stringify(st));
  const res = result(x);
  assert.equal(res.status, "gave_up");
  assert.match(res.fixError, /검증 'full' 실행 환경 고장 3회/);
  assert.equal(calls(x, "fix").length, 1, "재수정 없음");
  assert.equal(calls(x, "review").length, 0);
  const full = res.steps.filter((s) => s.id === "full");
  assert.equal(full.length, 1);
  assert.equal(full[0].ok, false);
});

// ── 벤치 숨긴 정답 채점(M8) ─────────────────────────────────────────
const ANSWER_TEST = "test/presentation/providers/gukjin_answer_test.dart";
function benchFor(x, over = {}) {
  const f = path.join(x.sb.dir, "bench.json");
  fs.writeFileSync(f, JSON.stringify({ version: 2, cases: [{ id: "t1", kind: "seed", origin: x.answer.slice(0, 12), rev: `${x.answer.slice(0, 12)}^`, test: C.DIFF_TEST,
    defines: ["REPLAY_GAMES=1", "REPLAY_SEED_BASE=202656775"], hiddenTests: [ANSWER_TEST], expect: { status: "ready", ruleGap: false, files: ["lib/domain/game/turn_manager.dart"] }, ...over }] }));
  x.env.LG_BENCH_FILE = f;
}
const benchEv = (x) => metrics(x.sb).filter((m) => m.ev === "bench");

test("숨긴 정답 채점(M8): ready 뒤 수정 커밋의 정답 시험을 채점 사본에서 — 대조군 빨강 → 패치 뒤 초록 → hidden_pass true · 정답은 LLM 사본·프롬프트에 없다", async (t) => {
  const x = setup(t);
  benchFor(x);
  assert.equal(start(x).code, 0);
  const st = await drive(x);
  assert.equal(st.status, "done", JSON.stringify(st));
  const res = result(x);
  assert.equal(res.status, "ready", res.note);
  assert.equal(res.grade.hidden_pass, true, JSON.stringify(res.grade));
  assert.equal(res.grade.source, "origin");
  assert.deepEqual(res.grade.runs.map((r) => [r.phase, r.test, r.rc]), [["control", ANSWER_TEST, 1], ["patched", ANSWER_TEST, 0]]);
  const b = benchEv(x);
  assert.equal(b.length, 1);
  assert.equal(b[0].hidden_pass, true);
  assert.equal(b[0].diag_match, true);
  // 정답은 plan 뒤 채점 사본(grade)에만 — LLM 이 일한 사본(work)·프롬프트에는 없다
  assert.ok(!fs.existsSync(path.join(work(x), ANSWER_TEST)));
  assert.match(fs.readFileSync(path.join(C.sandboxDir(x.sb.state, SIG), "grade", ANSWER_TEST), "utf8"), /ANSWER-MARKER-7f3a/);
  for (const c of x.fc.calls()) assert.doesNotMatch(c.input, /ANSWER-MARKER-7f3a|gukjin_answer_test/);
  assert.match(fs.readFileSync(path.join(C.runDir(x.sb.state, SIG), "plan.md"), "utf8"), /## 숨긴 정답 채점[\s\S]*결과: \*\*통과\*\*/);
  const gr = traceOf(x.sb, "sb-trace.jsonl").filter((c) => c.copy.endsWith("/grade") && !c.canary);
  assert.deepEqual(gr.map((c) => c.args.at(-1)), [ANSWER_TEST, ANSWER_TEST], "채점 격리 실행 = 대조군 1 + 패치 뒤 1");
});

test("숨긴 정답이 그래프 검증보다 엄하면 hidden_pass false — 그래프가 ready 여도 채점은 실패로 적는다", async (t) => {
  const x = setup(t, { sbCtl: { gradeGreen: { file: "lib/domain/game/turn_manager.dart", contains: "return 7" } } });
  benchFor(x);
  assert.equal(start(x).code, 0);
  assert.equal((await drive(x)).status, "done");
  const res = result(x);
  assert.equal(res.status, "ready");
  assert.equal(res.grade.hidden_pass, false);
  assert.deepEqual(res.grade.runs.map((r) => [r.phase, r.rc]), [["control", 1], ["patched", 1]]);
  assert.equal(benchEv(x)[0].hidden_pass, false);
});

test("채점 대상: 낼 패치가 없으면(no_red) false · 규칙 결정 사례는 null(사람이 규칙을 정해야 한다) — 채점 실행 0", async (t) => {
  const a = setup(t, { sbCtl: { green: { file: "lib/domain/game/turn_manager.dart", contains: "return 4" } } });
  benchFor(a);
  assert.equal(start(a).code, 0);
  assert.equal((await drive(a)).status, "done");
  assert.equal(result(a).status, "no_red");
  assert.equal(result(a).grade.hidden_pass, false);
  assert.match(result(a).grade.skipped, /낼 패치 없음\(no_red\)/);
  assert.equal(benchEv(a)[0].hidden_pass, false);
  const b = setup(t, { script: { diag: { ...DIAG, rule_gap: true, rule_gap_detail: "규칙서에 조항 없음" } } });
  benchFor(b, { expect: { status: "rule_decision", ruleGap: true, files: ["lib/domain/game/turn_manager.dart"] } });
  assert.equal(start(b).code, 0);
  assert.equal((await drive(b)).status, "done");
  assert.equal(result(b).status, "rule_decision");
  assert.equal(result(b).grade.hidden_pass, null);
  assert.equal(benchEv(b)[0].hidden_pass, null);
  for (const y of [a, b]) assert.equal(traceOf(y.sb, "sb-trace.jsonl").filter((c) => c.copy.endsWith("/grade")).length, 0);
});

// 10-10 재개 확인(수정 앞): 재현 시험까지 쓴 뒤라도, opus 수정을 띄우기 전에 master 가 움직였으면 지금 master 에서 재현을 다시 본다 —
// 이미 고쳐졌으면 가장 비싼 호출(10-09 한 번에 402만 토큰)을 하지 않고 not_reproduced 로 끝낸다. 시험은 판정을 믿는 시간을 0 으로 둔다.
test("재개 확인(수정 앞): 재현 시험을 쓴 뒤 master 에서 고쳐졌으면 opus 0회로 not_reproduced — 지금 master 를 따로 내보내 두 번 통과 확인", async (t) => {
  const x = setup(t, { extra: { LG_GOSTOP_FRESH_MIN: "0" } });
  const key = "soak:normal:777:abc1234", th = `gostop-fix:${key}`;
  const sig = { source: "soak", kind: "seed", rev: x.base.slice(0, 7), test: C.DIFF_TEST, defines: ["REPLAY_GAMES=1", "REPLAY_SEED_BASE=777"] };
  assert.equal(run(x.env, ["start", "gostop-fix", th, `--sigkey=${key}`, `--signal=${JSON.stringify(sig)}`]).code, 0);
  const st = () => JSON.parse(run(x.env, ["status", th, "--json"]).out);
  let moved = false;
  for (let i = 0; i < 150 && !["done", "gave_up", "expired"].includes(st().status); i++) {
    run(x.env, ["tick"]);
    await new Promise((r) => setTimeout(r, 120));
    // 빨간불 확인(재현 시험 격리 실행)을 띄운 틱 뒤 — 다음 틱이 수정(opus)을 띄우기 전에 누가 master 에 고쳐 넣는다
    if (!moved && traceOf(x.sb, "sb-trace.jsonl").some((c) => c.args.includes(RT))) {
      put(x.repo, "lib/domain/game/turn_manager.dart", TM_FIX);
      git(x.repo, ["add", "-A"]);
      git(x.repo, ["commit", "-q", "-m", "fix: 사람이 먼저 고침"]);
      fs.writeFileSync(path.join(x.sb.dir, "fake-flutter.json"), JSON.stringify({ mode: "pass", trace: path.join(x.sb.dir, "flutter-trace.jsonl") }));
      moved = true;
    }
  }
  assert.ok(moved, "재현 시험·빨간불 확인까지는 갔다");
  assert.equal(st().status, "done");
  const res = JSON.parse(fs.readFileSync(path.join(C.runDir(x.sb.state, key), "result.json"), "utf8"));
  assert.equal(res.status, "not_reproduced");
  assert.equal(res.gone.head, git(x.repo, ["rev-parse", "master"]));
  assert.equal(calls(x, "fix").length, 0, "수정(opus)을 부르지 않았다");
  assert.equal(calls(x, "repro").length, 1, "재현 시험까지는 썼다");
  assert.equal(x.fc.calls().length, 2, "진단 1 + 재현 시험 1 — 요약(haiku)도 부르지 않는다");
  const rc = traceOf(x.sb, "flutter-trace.jsonl").filter((r) => r.sub === "test").slice(2);
  assert.equal(rc.length, 2, "재개 확인 2회");
  assert.ok(rc.every((r) => /\/gostop\/sandbox\/rc-[^/]+\/work$/.test(r.cwd) && !r.repro), "LLM 이 손대지 않은 새 내보내기에서 돈다(재현 시험 파일 없음)");
  assert.match(fs.readFileSync(path.join(C.runDir(x.sb.state, key), "plan.md"), "utf8"), /재개 확인: 지금 master [0-9a-f]{12} 에서 통과/);
});
