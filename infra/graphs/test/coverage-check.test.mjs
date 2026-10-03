// coverage-check.test.mjs — 실행 증명(설계 §5.2⑪⑤): 바뀐 lib 줄이 AI 경로 시험에서 실행됐나.
// 덩어리 기준(기본)·전부·하나라도, 파일이 안 실림, 지우기만 한 덩어리(경계 줄), 주석만 바뀜, lib 변경 없음, lcov 없음, SF 경로 맞추기,
// 출처 닻(이 lcov 가 라이브 AI 경로 시험에서 나왔나 — 독립 검토 중3).
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { checkCoverage, parseLcov, normalizeSf, changedNewLines, functionRange, DEFAULT_ANCHORS } from "../lib/sandbox/coverage-check.mjs";
import { parseUnifiedDiff } from "../lib/sandbox/unified-diff.mjs";

const cc = (o) => checkCoverage({ anchors: [], ...o }); // 줄 판정만 보는 시험은 닻을 끈다(닻은 아래 따로)

// lib/domain/game/rule.dart: 10~12줄을 바꿈(+2줄), 30줄 근처는 지우기만
const PATCH = [
  "diff -ruN a/lib/domain/game/rule.dart b/lib/domain/game/rule.dart",
  "--- a/lib/domain/game/rule.dart",
  "+++ b/lib/domain/game/rule.dart",
  "@@ -9,3 +9,4 @@",
  " int keep() {",
  "-  return 1;",
  "+  final x = compute();",
  "+  return x;",
  " }",
  "@@ -29,3 +30,2 @@",
  " void a() {}",
  "-void removed() {}",
  " void b() {}",
  "diff -ruN a/test/rule_test.dart b/test/rule_test.dart",
  "--- a/test/rule_test.dart",
  "+++ b/test/rule_test.dart",
  "@@ -1 +1 @@",
  "-old",
  "+new",
  "",
].join("\n");
const lcov = (das, sf = "lib/domain/game/rule.dart") => `SF:${sf}\n${das.map(([l, c]) => `DA:${l},${c}`).join("\n")}\nend_of_record\n`;

test("바뀐 줄 고르기: '+' 줄(새 파일 번호) · 지우기만 한 덩어리는 지운 자리 앞뒤 줄", () => {
  const [f] = parseUnifiedDiff(PATCH);
  assert.deepEqual(changedNewLines(f.hunks[0]).lines, [10, 11]);
  assert.deepEqual(changedNewLines(f.hunks[1]).lines, [30, 31]);
  assert.equal(changedNewLines(f.hunks[1]).deletionOnly, true);
});

test("덩어리마다 하나 이상 실행되면 executed(기본) · 한 덩어리라도 안 지나면 not_executed", () => {
  const good = cc({ patch: PATCH, lcov: lcov([[10, 3], [11, 0], [30, 1], [31, 0], [50, 0]]) });
  assert.equal(good.ok, true, good.summary);
  assert.equal(good.verdict, "executed");
  const bad = cc({ patch: PATCH, lcov: lcov([[10, 3], [11, 1], [30, 0], [31, 0]]) });
  assert.equal(bad.ok, false);
  assert.equal(bad.verdict, "not_executed");
  assert.match(bad.summary, /rule\.dart:30/);
});

test("policy all 은 실행 가능한 바뀐 줄 전부 · any 는 하나라도", () => {
  const cov = lcov([[10, 3], [11, 0], [30, 1], [31, 1]]);
  assert.equal(cc({ patch: PATCH, lcov: cov, policy: "all" }).ok, false);
  assert.equal(cc({ patch: PATCH, lcov: lcov([[10, 1], [11, 1], [30, 1], [31, 1]]), policy: "all" }).ok, true);
  assert.equal(cc({ patch: PATCH, lcov: lcov([[10, 0], [11, 0], [30, 0], [31, 1]]), policy: "any" }).ok, true);
  assert.throws(() => cc({ patch: PATCH, lcov: cov, policy: "most" }), /policy/);
});

test("DA 기록이 없는 줄(주석·선언)은 판정에서 빠지고, 바뀐 lib 파일이 lcov 에 아예 없으면 실패(시험이 그 파일을 싣지도 않음)", () => {
  const onlyOther = lcov([[1, 1]], "lib/domain/game/other.dart");
  const r = cc({ patch: PATCH, lcov: onlyOther });
  assert.equal(r.ok, false);
  assert.equal(r.files[0].loaded, false);
  assert.match(r.summary, /파일 안 실림/);
  // 바뀐 줄이 전부 주석이면 안 실려도 중립
  const commentOnly = "--- a/lib/domain/game/c.dart\n+++ b/lib/domain/game/c.dart\n@@ -1,1 +1,2 @@\n x\n+// 설명만 더함\n";
  const c = cc({ patch: commentOnly, lcov: onlyOther });
  assert.equal(c.ok, true);
  assert.equal(c.verdict, "no_executable_change");
});

test("lib 변경 없음 → no_lib_change(통과로 두되 표시) · lcov 비면 lcov_missing(실패) · 지운 lib 파일은 판정 밖", () => {
  const testOnly = "--- a/test/x_test.dart\n+++ b/test/x_test.dart\n@@ -1 +1 @@\n-a\n+b\n";
  assert.equal(cc({ patch: testOnly, lcov: "" }).verdict, "no_lib_change");
  assert.equal(cc({ patch: PATCH, lcov: "" }).verdict, "lcov_missing");
  assert.equal(cc({ patch: PATCH, lcov: "  \n" }).ok, false);
  const delLib = "--- a/lib/domain/game/gone.dart\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n";
  assert.equal(cc({ patch: delLib, lcov: lcov([[1, 1]]) }).verdict, "no_lib_change");
});

test("lcov 해석: 같은 파일 기록은 더하고, SF 절대경로는 사본 기준으로(/tmp ↔ /private/tmp 같은 곳)", () => {
  const m = parseLcov("SF:lib/a.dart\nDA:1,2\nDA:2,0\nend_of_record\nSF:lib/a.dart\nDA:1,3\nDA:3,1,abcd\nend_of_record\n");
  assert.deepEqual([...m.get("lib/a.dart")], [[1, 5], [2, 0], [3, 1]]);
  assert.equal(normalizeSf("/private/tmp/x/copy/lib/a.dart", ["/tmp/x/copy"]), "lib/a.dart");
  assert.equal(normalizeSf("/tmp/x/copy/lib/a.dart", ["/private/tmp/x/copy"]), "lib/a.dart");
  assert.equal(normalizeSf("./lib/a.dart"), "lib/a.dart");
  assert.equal(normalizeSf("/elsewhere/lib/a.dart", ["/tmp/x/copy"]), "/elsewhere/lib/a.dart", "다른 곳(pub 캐시 등)은 lib/ 로 착각하지 않는다");
  const abs = lcov([[10, 1], [30, 1]], "/private/tmp/x/copy/lib/domain/game/rule.dart");
  assert.equal(cc({ patch: PATCH, lcov: abs, root: "/tmp/x/copy" }).ok, true);
});

test("출처 닻: 엔진 시험만 돌린 lcov 는 바뀐 줄을 지났어도 not_ai_path — 라이브 AI 핵심(ai_player · game_provider.processAITurns 안)이 실행돼야 통과", (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "lg-cc-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const gp = ["class GameNotifier {", "  Future<void> other() async {", "    await processAITurns();", "  }", "", "  Future<void> processAITurns() async {",
    "    final p = pick();", "    if (p) {", "      play();", "    }", "  }", "}", ""].join("\n");
  fs.mkdirSync(path.join(root, "lib/presentation/providers"), { recursive: true });
  fs.writeFileSync(path.join(root, "lib/presentation/providers/game_provider.dart"), gp);
  assert.deepEqual(functionRange(gp, "processAITurns"), [6, 11], "호출(await processAITurns();)이 아니라 선언을 찾는다");
  assert.equal(functionRange(gp, "nope"), null);
  const rule = lcov([[10, 3], [11, 1], [30, 1], [31, 1]]);
  const engineOnly = checkCoverage({ patch: PATCH, lcov: rule, root });
  assert.equal(engineOnly.ok, false);
  assert.equal(engineOnly.verdict, "not_ai_path");
  assert.match(engineOnly.summary, /ai_player\.dart\(안 실림\)/);
  const ai = lcov([[5, 2]], "lib/domain/ai/ai_player.dart");
  // game_provider 가 실렸어도 processAITurns 밖(other)만 지났으면 실패
  const outside = checkCoverage({ patch: PATCH, lcov: rule + ai + lcov([[3, 1], [7, 0]], "lib/presentation/providers/game_provider.dart"), root });
  assert.equal(outside.verdict, "not_ai_path");
  assert.match(outside.summary, /processAITurns/);
  const inside = checkCoverage({ patch: PATCH, lcov: rule + ai + lcov([[3, 1], [7, 4]], "lib/presentation/providers/game_provider.dart"), root });
  assert.equal(inside.ok, true, inside.summary);
  assert.equal(inside.verdict, "executed");
  assert.deepEqual(DEFAULT_ANCHORS.map((a) => a.file), ["lib/domain/ai/ai_player.dart", "lib/presentation/providers/game_provider.dart"]);
});
