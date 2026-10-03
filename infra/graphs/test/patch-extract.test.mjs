// patch-extract.test.mjs — git 없이 정본 패치 뽑기(설계 §5.2⑨): 상태 3종·적용하면 사본과 같아짐, 생성물 무시 규칙,
// 맨 위만 빼기(깊은 build/ 는 보고), 바로가기(밖 비밀 유출 경로)·특수 파일·하드링크·이진·크기·경로 거부, 얼리기(남은 프로세스 감지).
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { extractPatch, scanTree, badPath } from "../lib/sandbox/patch-extract.mjs";
import { parseUnifiedDiff } from "../lib/sandbox/unified-diff.mjs";

function trees(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lg-px-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const clean = path.join(dir, "clean"), copy = path.join(dir, "copy");
  const put = (root, rel, body) => { const p = path.join(root, rel); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, body); };
  const base = {
    "lib/domain/game/rule.dart": "int a() => 1;\nint b() => 2;\n",
    "lib/main.dart": "void main() {}\n",
    "test/rule_test.dart": "void main() {}\n",
    "coverage/lcov.info": "SF:lib/main.dart\nend_of_record\n",
  };
  for (const [rel, body] of Object.entries(base)) { put(clean, rel, body); put(copy, rel, body); }
  return { dir, clean, copy, put };
}

test("수정·추가·삭제가 diff -ruN 형식으로 나오고, 깨끗한 내보내기에 적용하면 사본과 같아진다(git 없이 patch -p1)", (t) => {
  const { dir, clean, copy, put } = trees(t);
  put(copy, "lib/domain/game/rule.dart", "int a() => 1;\nint b() => 3;\n");
  put(copy, "lib/domain/game/new_rule.dart", "int c() => 4;\n");
  fs.unlinkSync(path.join(copy, "test/rule_test.dart"));
  const r = extractPatch({ clean, copy });
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.deepEqual(r.files.map((f) => [f.path, f.status, f.added, f.removed]), [
    ["lib/domain/game/new_rule.dart", "added", 1, 0],
    ["lib/domain/game/rule.dart", "modified", 1, 1],
    ["test/rule_test.dart", "deleted", 0, 1],
  ]);
  assert.match(r.patch, /^diff -ruN a\/lib\/domain\/game\/new_rule\.dart b\/lib\/domain\/game\/new_rule\.dart\n--- \/dev\/null\n\+\+\+ b\/lib\/domain\/game\/new_rule\.dart\n/m);
  assert.match(r.patch, /^--- a\/test\/rule_test\.dart\n\+\+\+ \/dev\/null$/m);
  assert.match(r.sha256, /^[0-9a-f]{64}$/);
  // 적용 검증: 깨끗한 내보내기 복제에 patch -p1 → 사본과 파일 단위로 같다
  const apply = path.join(dir, "apply");
  fs.cpSync(clean, apply, { recursive: true });
  const p = spawnSync("/usr/bin/patch", ["-p1", "-s", "-E", "-d", apply], { input: r.patch, encoding: "utf8" }); // -E: 지운 파일을 빈 파일로 남기지 않음
  assert.equal(p.status, 0, p.stderr + p.stdout);
  const again = extractPatch({ clean: apply, copy });
  assert.equal(again.ok, true, JSON.stringify(again));
  assert.deepEqual(again.files, [], "적용한 결과가 사본과 같아야 한다");
  // 해석기와 짝이 맞는다
  assert.deepEqual(parseUnifiedDiff(r.patch).map((f) => [f.path, f.status]), r.files.map((f) => [f.path, f.status]));
});

test("빈 파일의 추가·삭제는 통합 diff 로 못 나타내니 패치에 담지 않고 메모로 남긴다", (t) => {
  const { clean, copy, put } = trees(t);
  put(copy, "lib/domain/game/empty.dart", "");
  put(clean, "test/empty_test.dart", "");
  const r = extractPatch({ clean, copy });
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.deepEqual(r.files, []);
  assert.equal(r.notes.length, 2);
});

test("바뀐 것이 없으면 빈 패치(ok) — 맨 위 .git·build·.dart_tool 은 양쪽 다 무시", (t) => {
  const { clean, copy, put } = trees(t);
  put(copy, ".git/config", "[core]\n\tfsmonitor = /tmp/x\n");
  put(copy, "build/unit_test_assets/x.bin", "\u0000\u0001");
  put(copy, ".dart_tool/package_config.json", "{}");
  const r = extractPatch({ clean, copy });
  assert.equal(r.ok, true);
  assert.deepEqual(r.files, []);
  assert.equal(r.patch, "");
});

test("flutter 생성물은 내보내기에 없을 때만 무시 — 추적되는 coverage/lcov.info 가 바뀌면 보고한다", (t) => {
  const { clean, copy, put } = trees(t);
  put(copy, ".flutter-plugins-dependencies", "{}");
  put(copy, "android/local.properties", "sdk.dir=/x\n");
  put(copy, "ios/Flutter/ephemeral/flutter_lldbinit", "x\n");
  put(copy, "macos/Flutter/ephemeral/Flutter-Generated.xcconfig", "x\n");
  put(copy, "coverage/new.info", "x\n");
  put(copy, "test/goldens/failures/card_masterImage.png", "\u0000PNG");
  let r = extractPatch({ clean, copy });
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.deepEqual(r.files, []);
  put(copy, "coverage/lcov.info", "SF:lib/main.dart\nDA:1,1\nend_of_record\n");
  r = extractPatch({ clean, copy });
  assert.deepEqual(r.files.map((f) => f.path), ["coverage/lcov.info"]);
});

test("깊은 곳의 build·.dart_tool 이름은 빼지 않는다(diff -x 처럼 변경을 숨기지 않게)", (t) => {
  const { clean, copy, put } = trees(t);
  put(copy, "lib/domain/game/build/helper.dart", "int h() => 1;\n");
  const r = extractPatch({ clean, copy });
  assert.deepEqual(r.files.map((f) => f.path), ["lib/domain/game/build/helper.dart"]);
});

test("바로가기: 밖 비밀을 가리키는 새 바로가기는 거부하고 비밀 내용은 어디에도 안 나온다 · 원래 있던 같은 바로가기는 통과 · 바뀌면 거부", (t) => {
  const { dir, clean, copy } = trees(t);
  const secret = path.join(dir, "id_rsa");
  fs.writeFileSync(secret, "SECRET-KEY-MATERIAL-123\n");
  fs.symlinkSync(secret, path.join(copy, "lib/domain/game/leak.dart"));
  let r = extractPatch({ clean, copy });
  assert.equal(r.ok, false);
  assert.equal(r.reason, "symlink");
  assert.doesNotMatch(JSON.stringify(r), /SECRET-KEY-MATERIAL/);
  // 폴더 바로가기(밖 폴더 통째)도 같다
  fs.unlinkSync(path.join(copy, "lib/domain/game/leak.dart"));
  fs.symlinkSync(dir, path.join(copy, "lib/outside"));
  r = extractPatch({ clean, copy });
  assert.equal(r.reason, "symlink");
  assert.doesNotMatch(JSON.stringify(r), /SECRET-KEY-MATERIAL/);
  fs.unlinkSync(path.join(copy, "lib/outside"));
  // 내보내기에 원래 있던 바로가기(고스톱 .fvm.bak/flutter_sdk → /Users/…/fvm) — 같은 대상이면 건너뛴다
  fs.mkdirSync(path.join(clean, ".fvm.bak")); fs.mkdirSync(path.join(copy, ".fvm.bak"));
  fs.symlinkSync("/nonexistent/fvm/versions/3.38.6", path.join(clean, ".fvm.bak/flutter_sdk"));
  fs.symlinkSync("/nonexistent/fvm/versions/3.38.6", path.join(copy, ".fvm.bak/flutter_sdk"));
  r = extractPatch({ clean, copy });
  assert.equal(r.ok, true, JSON.stringify(r));
  fs.unlinkSync(path.join(copy, ".fvm.bak/flutter_sdk"));
  fs.symlinkSync(secret, path.join(copy, ".fvm.bak/flutter_sdk"));
  assert.equal(extractPatch({ clean, copy }).reason, "symlink");
});

test("특수 파일(FIFO)·하드링크·이진·크기·파일 수 상한은 거부한다", (t) => {
  const { dir, clean, copy, put } = trees(t);
  const fifo = path.join(copy, "lib/pipe");
  assert.equal(spawnSync("/usr/bin/mkfifo", [fifo]).status, 0);
  assert.equal(extractPatch({ clean, copy }).reason, "special_file"); // diff 가 FIFO 를 읽다 멈추지 않는다
  fs.unlinkSync(fifo);
  const outside = path.join(dir, "outside.txt");
  fs.writeFileSync(outside, "x\n");
  fs.linkSync(outside, path.join(copy, "lib/hl.dart"));
  assert.equal(extractPatch({ clean, copy }).reason, "hardlink");
  fs.unlinkSync(path.join(copy, "lib/hl.dart"));
  put(copy, "lib/domain/game/blob.dart", "abc\u0000def");
  assert.equal(extractPatch({ clean, copy }).reason, "binary");
  fs.unlinkSync(path.join(copy, "lib/domain/game/blob.dart"));
  put(copy, "lib/domain/game/big.dart", "x".repeat(2000) + "\n");
  assert.equal(extractPatch({ clean, copy, limits: { maxFileBytes: 1000 } }).reason, "too_large");
  assert.equal(extractPatch({ clean, copy, limits: { maxPatchBytes: 500 } }).reason, "too_large");
  for (let i = 0; i < 5; i++) put(copy, `test/many_${i}_test.dart`, `// ${i}\n`);
  const r = extractPatch({ clean, copy, limits: { maxFiles: 3 } });
  assert.equal(r.reason, "too_many_files");
  assert.equal(r.count, 6);
});

test("경로 거부: 깊은 .git(대소문자 무관)·줄바꿈·제어 문자·역슬래시", (t) => {
  assert.equal(badPath("lib/.git/hooks/pre-commit"), true);
  assert.equal(badPath("lib/.GIT/config"), true);
  assert.equal(badPath("lib/a\nb.dart"), true);
  assert.equal(badPath("lib/a\\b.dart"), true);
  assert.equal(badPath("lib/domain/game/a.git.dart"), false);
  const { clean, copy, put } = trees(t);
  put(copy, "lib/domain/game/.Git/config", "[core]\n");
  assert.equal(extractPatch({ clean, copy }).reason, "bad_path");
});

test("얼리기: 추출 동안 사본 자리가 비고 끝나면 되돌린다 — 그 사이 옛 자리에 폴더가 생기면 lingering_writer 로 거부", (t) => {
  const { clean, copy, put } = trees(t);
  put(copy, "lib/domain/game/rule.dart", "int a() => 9;\n");
  let sawEmpty = null;
  const r = extractPatch({ clean, copy, onFrozen: () => { sawEmpty = !fs.existsSync(copy); } });
  assert.equal(r.ok, true);
  assert.equal(sawEmpty, true, "추출 중에는 원래 경로가 없어야 한다(격리 규칙이 경로 기준이라 남은 프로세스가 못 쓴다)");
  assert.equal(fs.existsSync(path.join(copy, "lib/domain/game/rule.dart")), true, "끝나면 제자리");
  const bad = extractPatch({ clean, copy, onFrozen: () => fs.mkdirSync(copy) });
  assert.equal(bad.ok, false);
  assert.equal(bad.reason, "lingering_writer");
  assert.equal(fs.readFileSync(path.join(copy, "lib/domain/game/rule.dart"), "utf8"), "int a() => 9;\n", "진짜 사본이 제자리로 돌아온다");
  const intruders = fs.readdirSync(path.dirname(copy)).filter((n) => n.startsWith("copy.lg-intruder-"));
  assert.equal(intruders.length, 1);
  // 얼리는 도중 예외가 나도 되돌린다
  assert.throws(() => extractPatch({ clean, copy, onFrozen: () => { throw new Error("boom"); } }), /boom/);
  assert.equal(fs.existsSync(path.join(copy, "lib/main.dart")), true);
});

test("겹치는 폴더·없는 폴더는 거부", (t) => {
  const { dir, clean, copy } = trees(t);
  assert.equal(extractPatch({ clean, copy: clean }).reason, "bad_dir");
  assert.equal(extractPatch({ clean: dir, copy }).reason, "bad_dir");
  assert.equal(extractPatch({ clean, copy: path.join(dir, "nope") }).reason, "bad_dir");
});

test("훑기는 바로가기를 따라가지 않는다(폴더 바로가기 안을 들여다보지 않음)", (t) => {
  const { dir, copy } = trees(t);
  fs.mkdirSync(path.join(dir, "secretdir"));
  fs.writeFileSync(path.join(dir, "secretdir/k"), "x");
  fs.symlinkSync(path.join(dir, "secretdir"), path.join(copy, "lib/sd"));
  const m = scanTree(copy);
  assert.equal(m.get("lib/sd").type, "symlink");
  assert.equal([...m.keys()].some((k) => k.startsWith("lib/sd/")), false);
});
