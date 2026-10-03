// patch-allowlist.test.mjs — 수정 허용 목록(설계 §4①)과 승인 사유: 규칙 엔진·시험만이면 통과, 조건부 파일은 AI 판정(§4②)을 따른다,
// AI 경계(lib/domain/ai·MCTSConstants 줄 범위)·결제·외부 송출(경로·내용)·pubspec·플랫폼·자산·번역·생성 코드·골든·관문 설정·시험 삭제·고정 파일.
// 통합 diff 해석기의 함정('-- x' 를 지운 줄이 '--- x' 로 보임)도 여기서 본다.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { classifyPatch, classifyPatchText, classRange } from "../lib/sandbox/patch-allowlist.mjs";
import { parseUnifiedDiff } from "../lib/sandbox/unified-diff.mjs";

// 경로 목록 → 한 줄씩 바꾼 가짜 패치
const mod = (p, from = "a", to = "b", at = 1) => `diff -ruN a/${p} b/${p}\n--- a/${p}\n+++ b/${p}\n@@ -${at},1 +${at},1 @@\n-${from}\n+${to}\n`;
const add = (p, line = "x") => `diff -ruN a/${p} b/${p}\n--- /dev/null\n+++ b/${p}\n@@ -0,0 +1,1 @@\n+${line}\n`;
const del = (p, line = "x") => `diff -ruN a/${p} b/${p}\n--- a/${p}\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-${line}\n`;
const reasonOf = (r, p) => r.reasons.find((x) => x.path === p)?.reason ?? null;

test("규칙 엔진·시험만 바꾸면 승인 사유 없음(ok)", () => {
  const r = classifyPatchText(mod("lib/domain/game/turn_manager.dart") + mod("lib/domain/game/special_rules.dart") + add("test/repro/bug_42_test.dart"));
  assert.equal(r.ok, true, JSON.stringify(r.reasons));
  assert.deepEqual(r.allowed, ["lib/domain/game/turn_manager.dart", "lib/domain/game/special_rules.dart", "test/repro/bug_42_test.dart"]);
});

test("조건부(game_provider·bomb_handler 규칙 처리부): AI 판정 통과면 허용, 판정이 없거나 실패면 승인 사유", () => {
  const patch = mod("lib/presentation/providers/game_provider.dart") + mod("lib/presentation/providers/bomb_handler.dart");
  assert.equal(classifyPatchText(patch, { aiCheck: "pass" }).ok, true);
  const un = classifyPatchText(patch);
  assert.equal(reasonOf(un, "lib/presentation/providers/game_provider.dart"), "ai_check_unavailable");
  assert.equal(reasonOf(un, "lib/presentation/providers/bomb_handler.dart"), "ai_check_unavailable");
  // 판정 실패는 어떤 파일이든 전체 사유(같은 상태에서 결정이 바뀜 — 규칙 엔진만 바꿨어도)
  const failed = classifyPatchText(mod("lib/domain/game/turn_manager.dart"), { aiCheck: "fail" });
  assert.equal(failed.ok, false);
  assert.equal(reasonOf(failed, "*"), "ai_decision_changed");
});

test("AI 경계: lib/domain/ai/** · MCTSConstants 를 바꾸거나 쓰는 줄 · constants.dart 의 MCTSConstants 범위(내보내기로 계산)", (t) => {
  const r = classifyPatchText(mod("lib/domain/ai/ai_player.dart") + mod("lib/domain/ai/mcts/mcts_node.dart") + mod("lib/domain/game/turn_manager.dart", "x", "final n = MCTSConstants.iterations;"));
  assert.equal(reasonOf(r, "lib/domain/ai/ai_player.dart"), "ai_boundary");
  assert.equal(reasonOf(r, "lib/domain/ai/mcts/mcts_node.dart"), "ai_boundary");
  assert.equal(reasonOf(r, "lib/domain/game/turn_manager.dart"), "ai_boundary", "허용 경로라도 MCTSConstants 를 건드리면 AI 경계");
  // constants.dart: MCTSConstants 범위 안 줄이면 ai_boundary, 밖이면 그냥 목록 밖
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lg-al-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const lines = ["// c", "class GameConstants {", "  static const a = 1;", "}", "", "class MCTSConstants {", "  MCTSConstants._();", "  static const iterations = 800;", "}", ""];
  fs.mkdirSync(path.join(dir, "lib/core"), { recursive: true });
  fs.writeFileSync(path.join(dir, "lib/core/constants.dart"), lines.join("\n"));
  assert.deepEqual(classRange(lines.join("\n"), "MCTSConstants"), [6, 9]);
  const inMcts = classifyPatchText(mod("lib/core/constants.dart", "  static const iterations = 800;", "  static const iterations = 900;", 8), { clean: dir });
  assert.equal(reasonOf(inMcts, "lib/core/constants.dart"), "ai_boundary");
  const outside = classifyPatchText(mod("lib/core/constants.dart", "  static const a = 1;", "  static const a = 2;", 3), { clean: dir });
  assert.equal(reasonOf(outside, "lib/core/constants.dart"), "outside_allowlist");
  // 내보내기를 못 읽으면 넓게(AI 경계로) 본다
  assert.equal(reasonOf(classifyPatchText(mod("lib/core/constants.dart", "  static const a = 1;", "  static const a = 2;", 3)), "lib/core/constants.dart"), "ai_boundary");
});

test("경로 사유: 결제·외부 송출·pubspec·플랫폼·자산·번역·생성 코드·골든·관문 설정 — 허용 경로 안이라도 생성 코드·골든은 승인", () => {
  const cases = {
    "lib/data/services/iap_service.dart": "payment",
    "lib/domain/economy/top_up_system.dart": "payment",
    "lib/presentation/screens/skin/skin_shop_screen.dart": "payment",
    "lib/data/services/bug_report_service.dart": "external_send",
    "lib/data/services/analytics_service.dart": "external_send",
    "pubspec.yaml": "pubspec",
    "pubspec.lock": "pubspec",
    "android/app/build.gradle": "platform",
    "ios/Runner/Info.plist": "platform",
    "firebase.json": "platform",
    "assets/images/card.png": "assets",
    "lib/l10n/app_ko.arb": "l10n",
    "lib/data/models/game_state.g.dart": "generated",
    "test/domain/game/fake.mocks.dart": "generated",
    "lib/data/models/user.freezed.dart": "generated",
    "test/goldens/card_flip_animation.png": "golden",
    "integration_test/golden_images/home_screen.png": "golden",
    "analysis_options.yaml": "gate_config",
    "quality_gates.yaml": "gate_config",
    "test/flutter_test_config.dart": "gate_config",
    ".github/workflows/ci.yml": "gate_config",
    "lib/presentation/widgets/hand.dart": "outside_allowlist",
    "lib/core/enums.dart": "outside_allowlist",
  };
  const r = classifyPatchText(Object.keys(cases).map((p) => mod(p)).join(""));
  for (const [p, want] of Object.entries(cases)) assert.equal(reasonOf(r, p), want, p);
  assert.equal(r.ok, false);
  assert.deepEqual(r.byReason.golden, ["test/goldens/card_flip_animation.png", "integration_test/golden_images/home_screen.png"]);
});

test("내용 사유: 경로로 못 맞히는 결제(in_app_purchase)·송출(url_launcher·웹훅) 파일 — 패치 전·후 어느 쪽이든", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lg-al-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const clean = path.join(dir, "clean"), copy = path.join(dir, "copy");
  const put = (root, rel, body) => { fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true }); fs.writeFileSync(path.join(root, rel), body); };
  put(clean, "lib/presentation/screens/settings/settings_screen.dart", "import 'package:url_launcher/url_launcher.dart';\n");
  put(copy, "lib/presentation/widgets/coin_badge.dart", "import 'package:in_app_purchase/in_app_purchase.dart';\n");
  put(copy, "lib/domain/game/helper.dart", "const u = 'https://discord.com/api/webhooks/1/x';\n");
  const r = classifyPatchText(mod("lib/presentation/screens/settings/settings_screen.dart") + add("lib/presentation/widgets/coin_badge.dart") + add("lib/domain/game/helper.dart"), { clean, copy });
  assert.equal(reasonOf(r, "lib/presentation/screens/settings/settings_screen.dart"), "external_send");
  assert.equal(reasonOf(r, "lib/presentation/widgets/coin_badge.dart"), "payment");
  assert.equal(reasonOf(r, "lib/domain/game/helper.dart"), "external_send", "규칙 엔진 경로여도 웹훅 주소가 들어오면 송출");
});

test("기존 시험 수정은 승인 사유(회귀 시험의 expect 를 풀어 전체 초록을 만드는 길 — 독립 검토 중2), 새 시험 파일은 허용", () => {
  const r = classifyPatchText(mod("test/domain/game/self_qa_regressions_test.dart", "    expect(found, isEmpty);", "    // expect(found, isEmpty);")
    + add("test/repro/bug_42_test.dart") + mod("lib/domain/game/turn_manager.dart"));
  assert.equal(r.ok, false);
  assert.deepEqual(r.byReason, { test_modified: ["test/domain/game/self_qa_regressions_test.dart"] });
  assert.deepEqual(r.allowed, ["test/repro/bug_42_test.dart", "lib/domain/game/turn_manager.dart"]);
});

test("기존 시험 파일 삭제 · 앞 단계가 쓴 고정 파일(frozen)을 바꾸면 승인 사유", () => {
  const r = classifyPatchText(del("test/domain/game/bomb_rules_test.dart") + mod("test/repro/bug_42_test.dart"), { frozen: ["test/repro/bug_42_test.dart"] });
  assert.equal(reasonOf(r, "test/domain/game/bomb_rules_test.dart"), "test_removed");
  assert.equal(reasonOf(r, "test/repro/bug_42_test.dart"), "frozen");
  assert.equal(classifyPatchText(mod("test/repro/x/a_test.dart"), { frozen: ["test/repro/x/"] }).reasons[0].reason, "frozen");
});

test("통합 diff 해석: 덩어리 줄 수로 읽는다 — 지운 줄 '-- x' 가 '--- x' 로 보여도 새 파일로 착각하지 않는다", () => {
  const patch = "--- a/lib/domain/game/a.dart\n+++ b/lib/domain/game/a.dart\n@@ -1,3 +1,1 @@\n keep\n--- x\n-++ y\n"
    + "--- a/test/b_test.dart\n+++ b/test/b_test.dart\n@@ -5 +5,2 @@\n-old\n+new\n+more\n\\ No newline at end of file\n";
  const f = parseUnifiedDiff(patch);
  assert.deepEqual(f.map((x) => x.path), ["lib/domain/game/a.dart", "test/b_test.dart"]);
  assert.deepEqual(f[0].hunks[0].lines.map((l) => [l.t, l.s, l.oldNo, l.newNo]), [[" ", "keep", 1, 1], ["-", "-- x", 2, null], ["-", "++ y", 3, null]]);
  assert.deepEqual(f[1].hunks[0].lines.filter((l) => l.t === "+").map((l) => l.newNo), [5, 6]);
  // git diff 형식(a/ b/ 접두사, 탭 시각)도 같은 경로로
  assert.equal(parseUnifiedDiff("--- a/x.dart\t2026-10-03 10:00:00\n+++ b/x.dart\t2026-10-03 10:00:01\n@@ -1 +1 @@\n-a\n+b\n")[0].path, "x.dart");
  assert.deepEqual(classifyPatch(parseUnifiedDiff(patch)).byReason, { test_modified: ["test/b_test.dart"] });
  // 머리 줄 수가 본문보다 많은 잘못된 패치라도 다음 파일을 놓치지 않는다
  const bad = patch.replace("@@ -1,3 +1,1 @@", "@@ -1,3 +1,2 @@");
  assert.deepEqual(parseUnifiedDiff(bad).map((x) => x.path), ["lib/domain/game/a.dart", "test/b_test.dart"]);
});
