// three-path-check.test.mjs — 3경로 시험 틀(설계 §5.2⑦): 엔진·라이브 사람·라이브 AI(어려움 포함) 묶음이 다 있어야 통과.
// 이름 표식(고스톱 기존 관례 '엔진:'·'라이브 사람:'·'라이브 AI:' / [engine] 꼬리표), group 상속, skip·expect 없는 시험은 안 셈,
// 주석·문자열 속 가짜 표식, 보간 문자열, AIDifficulty.values, 표식 바꾸기.
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkThreePaths, lex, findCalls } from "../lib/sandbox/three-path-check.mjs";

const FULL = `
import 'package:flutter_test/flutter_test.dart';
void main() {
  group('버그 #42 — 뻑 3번 후 점수', () {
    test('엔진: 같은 씨앗에서 3뻑이면 7점', () {
      final e = GameEngine(seed: 42);
      expect(e.score, 7);
    });
    testWidgets('라이브 사람: 같은 판을 사람이 두면 7점', (tester) async {
      expect(await playHuman(42), 7);
    });
    group('라이브 AI:', () {
      for (final d in [AIDifficulty.easy, AIDifficulty.hard]) {
        test('난이도 \${d.name} 에서 AI 가 둬도 7점', () async {
          expect(await playAi(42, d), 7);
        });
      }
    });
  });
}
`;

test("세 경로 + 어려움이 다 있으면 통과 — 라이브 AI 는 group 이름 표식을 시험이 물려받는다", () => {
  const r = checkThreePaths(FULL);
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.deepEqual(r.paths, { engine: 1, liveHuman: 1, liveAi: 1 });
  assert.equal(r.liveAiHard, true);
});

test("한 경로라도 빠지면 그 이름을 missing 에 낸다 · 라이브 AI 에 어려움이 없으면 liveAiHard", () => {
  const noHuman = FULL.replace("라이브 사람:", "사람 쪽");
  assert.deepEqual(checkThreePaths(noHuman).missing, ["liveHuman"]);
  const noHard = FULL.replace("AIDifficulty.easy, AIDifficulty.hard", "AIDifficulty.easy, AIDifficulty.normal");
  const r = checkThreePaths(noHard);
  assert.equal(r.ok, false);
  assert.deepEqual(r.missing, ["liveAiHard"]);
  assert.equal(checkThreePaths(noHard, { requireHard: false }).ok, true);
  // AIDifficulty.values 로 돌면 어려움 포함
  assert.equal(checkThreePaths(noHard.replace("[AIDifficulty.easy, AIDifficulty.normal]", "AIDifficulty.values")).ok, true);
});

test("skip 된 시험·expect 없는 시험은 세지 않는다(skip: false 는 센다)", () => {
  const skipped = FULL.replace("test('엔진: 같은 씨앗에서 3뻑이면 7점', () {", "test('엔진: 같은 씨앗에서 3뻑이면 7점', skip: '나중에', () {");
  assert.deepEqual(checkThreePaths(skipped).missing, ["engine"]);
  const skipFalse = FULL.replace("test('엔진: 같은 씨앗에서 3뻑이면 7점', () {", "test('엔진: 같은 씨앗에서 3뻑이면 7점', skip: false, () {");
  assert.equal(checkThreePaths(skipFalse).ok, true);
  const noExpect = FULL.replace("expect(e.score, 7);", "print(e.score);");
  assert.deepEqual(checkThreePaths(noExpect).missing, ["engine"]);
  // group 이 skip 이면 안의 시험도 안 센다
  const groupSkip = FULL.replace("group('라이브 AI:', () {", "group('라이브 AI:', skip: true, () {");
  assert.ok(checkThreePaths(groupSkip).missing.includes("liveAi"));
});

test("주석·다른 문자열 속 표식은 세지 않고, '엔진과 같다'처럼 콜론 없는 말은 표식이 아니다", () => {
  const src = `
void main() {
  // test('엔진: 주석 속 가짜', () { expect(1, 1); });
  /* test('라이브 사람: 블록 주석 /* 중첩 */ 속', () { expect(1, 1); }); */
  test('AI 가 뒤집어 +1점이면 즉시 우승 — 엔진과 같다', () { expect(1, 1); });
  test('평범한 시험', () { final s = "엔진: 이건 문자열 값"; expect(s, isNotEmpty); });
}`;
  const r = checkThreePaths(src);
  assert.deepEqual(r.paths, { engine: 0, liveHuman: 0, liveAi: 0 });
});

test("어휘 분석: 보간·원시 문자열·세 따옴표, 붙은 문자열 리터럴 이름, x.test(…)·선언은 호출이 아니다", () => {
  const src = `
void main() {
  final w = r'raw \\ no \${interp}';
  test('라이브 AI: ' 'seed \${seeds.map((s) => "\$s").join(",")} 어려움', () {
    expect(play(AIDifficulty.hard), isTrue);
  });
  test("""엔진: 세 따옴표
  여러 줄""", () { expect(1, 1); });
  obj.test('라이브 사람: 메서드 호출', () { expect(1, 1); });
}
void test(String n, Function f) {}
`;
  const calls = findCalls(lex(src));
  assert.deepEqual(calls.map((c) => c.name?.split("\n")[0]), ["라이브 AI: seed ${seeds.map((s) => \"$s\").join(\",\")} 어려움", "엔진: 세 따옴표"]);
  const r = checkThreePaths(src);
  assert.deepEqual(r.paths, { engine: 1, liveHuman: 0, liveAi: 1 });
  assert.equal(r.liveAiHard, true);
});

test("[engine]·[live-human]·[live-ai] 꼬리표도 받고, 표식은 바꿔 끼울 수 있다(고스톱 쪽 틀과 맞출 때)", () => {
  const src = `
void main() {
  test('[engine] a', () { expect(1, 1); });
  test('[live-human] b', () { expect(1, 1); });
  test('[live-ai] c', () { expect(play(AIDifficulty.hard), 1); });
}`;
  assert.equal(checkThreePaths(src).ok, true);
  const custom = { engine: "^E:", liveHuman: "^H:", liveAi: "^A:" };
  const src2 = "void main(){ test('E: a', () { expect(1,1); }); test('H: b', () { expect(1,1); }); test('A: c', () { expect(AIDifficulty.hard, 1); }); }";
  assert.equal(checkThreePaths(src2, { markers: custom }).ok, true);
  assert.equal(checkThreePaths(src2).ok, false);
});

test("여러 파일로 나뉘어 있어도 합쳐서 본다", () => {
  const a = "void main(){ test('엔진: a', () { expect(1,1); }); }";
  const b = "void main(){ test('라이브 사람: b', () { expect(1,1); }); test('라이브 AI: c', () { expect(AIDifficulty.hard, 1); }); }";
  assert.equal(checkThreePaths([a, b]).ok, true);
  assert.equal(checkThreePaths([a]).ok, false);
});
