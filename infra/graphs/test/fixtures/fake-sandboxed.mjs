// fake-sandboxed.mjs — 시험용 격리 실행기(1b). 시험 허용 목록이 'node fake-sandboxed.mjs <제어파일> <sandboxed-run.mjs> --copy … --tmp … [--ai-policy-dir N] [--timeout-sec S] [--canary] -- flutter …' 로 부른다.
// 진짜 sandbox-exec·flutter 는 부르지 않는다. 사본의 코드를 읽어 초록·빨강을 정한다.
// 제어 파일(JSON):
//   green: { file, contains }   — 사본의 file 에 contains 가 있으면 '고쳐졌다'(시험 초록). 기본 lib/domain/game/turn_manager.dart · 'return 6'
//   aiStillRed: true            — 재현 시험의 라이브 AI 시험은 늘 빨강(3경로 하나만 빨강)
//   violation: "<글자>"         — 인자에 이 글자가 든 실행은 종료 98(격리 위반)
//   mutate: true                — 고쳐진 사본에서 재현 시험을 돌리면 lib 파일에 한 줄을 덧붙인다(시험 코드가 사본을 바꾸는 흉내)
//   preexisting: "<시험 이름>"  — 전체 시험은 이 시험이 기준·패치 사본 모두에서 실패한다(기존 실패)
//   analyze: { errors, warnings } — 패치 사본(work)의 분석 결과(기준 사본은 0)
//   aiVerdict: same·changed·…   — AI 결정 비교 결과(compare)
//   canary: "fail"              — 격리 점검 실패
//   covMiss: true               — lcov 의 바뀐 줄 실행 횟수를 0 으로
//   crash: { match, times }     — 인자에 match 가 든 실행은 처음 times 번 시험 도구가 시작하다 죽는다(dart 예외, 종료 255, 진행 줄 없음 —
//                                 10-04~06 격리 stdio 고장 흉내). 횟수는 제어 파일 옆 crash-count 파일로 센다
//   gradeGreen: { file, contains } — 채점 사본(grade)에서만 쓰는 '고쳐졌다' 조건(숨긴 정답이 그래프 검증보다 엄할 때 흉내)
//   trace: 부를 때마다 한 줄
import fs from "node:fs";
import path from "node:path";

const [ctlFile, _script, ...argv] = process.argv.slice(2);
const ctl = JSON.parse(fs.readFileSync(ctlFile, "utf8"));
const o = { args: [] };
let i = 0;
for (; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--") { i++; break; }
  if (a === "--copy") o.copy = argv[++i];
  else if (a === "--tmp") o.tmp = argv[++i];
  else if (a === "--timeout-sec") o.timeout = argv[++i];
  else if (a === "--ai-policy-dir") o.ai = argv[++i];
  else if (a === "--canary") o.canary = true;
}
const tool = argv[i], args = argv.slice(i + 1);
if (ctl.trace) fs.appendFileSync(ctl.trace, `${JSON.stringify({ copy: o.copy, tmp: o.tmp, ai: o.ai ?? null, canary: !!o.canary, tool, args })}\n`);
const out = (s) => fs.writeSync(1, s);
if (!fs.existsSync(o.copy) || !fs.existsSync(o.tmp)) { process.stderr.write("LG-SANDBOX bad_dir: 폴더 없음\n"); process.exit(97); }
if (o.canary) {
  out(`${JSON.stringify(ctl.canary === "fail" ? { ok: false, failures: ["공인 IP: 됐다"] } : { ok: true, failures: [] })}\n`);
  process.exit(ctl.canary === "fail" ? 3 : 0);
}
if (ctl.violation && argv.join(" ").includes(ctl.violation)) { process.stderr.write("LG-SANDBOX violation: nonloopback_listen dart:1@0.0.0.0.80 — 격리 안 프로세스를 모두 껐다\n"); process.exit(98); }
if (ctl.crash && argv.join(" ").includes(ctl.crash.match)) {
  const cf = path.join(path.dirname(ctlFile), "crash-count");
  const n = Number(fs.existsSync(cf) ? fs.readFileSync(cf, "utf8") : 0) + 1;
  fs.writeFileSync(cf, String(n));
  if (n <= (ctl.crash.times ?? Infinity)) {
    process.stderr.write("Unhandled exception:\nFileSystemException: Failed to get type of stdio handle (fd 1), path = '' (OS Error: Operation not permitted, errno = 1)\n#0      _StdIOUtils._getStdioOutputStream (dart:io-patch/stdio_patch.dart:35:7)\n");
    process.exit(255);
  }
}
const read = (rel) => { try { return fs.readFileSync(path.join(o.copy, rel), "utf8"); } catch { return null; } };
const g = (path.basename(o.copy) === "grade" && ctl.gradeGreen) || ctl.green || { file: "lib/domain/game/turn_manager.dart", contains: "return 6" };
const fixed = (read(g.file) ?? "").includes(g.contains);
const isBase = path.basename(o.copy) === "base";

if (tool === "flutter" && args[0] === "analyze") {
  const a = isBase ? { errors: 0, warnings: 0 } : { errors: 0, warnings: 0, ...(ctl.analyze ?? {}) };
  const af = (ctl.analyze ?? {}).file ?? "lib/domain/game/turn_manager.dart";
  if (!a.errors && !a.warnings) { out("Analyzing work...\n   info • 정렬 • lib/main.dart:1:1 • directives_ordering\n1 issue found.\n"); process.exit(0); }
  for (let k = 0; k < a.errors; k++) out(`  error • 없는 이름 • ${af}:${k + 1}:1 • undefined_identifier\n`);
  for (let k = 0; k < a.warnings; k++) out(`warning • 안 쓰는 변수 • ${af}:${k + 1}:1 • unused_local_variable\n`);
  process.exit(1);
}
if (tool !== "flutter" || args[0] !== "test") { process.stderr.write(`LG-SANDBOX bad_args: ${tool} ${args[0]}\n`); process.exit(97); }
const file = args.find((a) => /_test\.dart$/.test(a)) ?? null;
// AI 결정 비교(고스톱 test/ai_policy)
if (o.ai) {
  const dir = path.join(o.tmp, o.ai);
  fs.mkdirSync(dir, { recursive: true });
  if (/gen_test/.test(file)) {
    fs.writeFileSync(path.join(dir, "corpus.json"), "{}"); fs.writeFileSync(path.join(dir, "baseline.json"), "{}");
    fs.writeFileSync(path.join(dir, "gen-result.json"), JSON.stringify({ verdict: "ok" }));
  } else {
    if (!fs.existsSync(path.join(dir, "baseline.json"))) { out("기준 없음\n"); process.exit(1); }
    fs.writeFileSync(path.join(dir, "compare-result.json"), JSON.stringify({ verdict: ctl.aiVerdict ?? "same" }));
  }
  out("★ ai-policy 끝\n00:03 +1: All tests passed!\n");
  process.exit(0);
}
const pass = (n = 3) => { out(`00:01 +0: loading ${file ?? "전체"}\n00:04 +${n}: All tests passed!\n`); process.exit(0); };
const fail = (names) => { out(`00:01 +0: loading ${file ?? "전체"}\n${names.map((n, k) => `00:0${k + 2} +1 -${k + 1}: ${n} [E]\n  Expected: <6>\n    Actual: <4>\n`).join("")}00:09 +1 -${names.length}: Some tests failed.\n`); process.exit(1); };
fs.mkdirSync(path.join(o.copy, "build"), { recursive: true }); // 시험이 남기는 것(패치 추출이 맨 위 build 는 뺀다)
if (file && file.startsWith("test/repro/")) {
  const src = read(file);
  if (src == null) { out("Error: No tests ran.\n"); process.exit(1); }
  if (src.includes("LOAD_FAIL")) { out(`00:01 +0 -1: loading ${file} [E]\n  Bad state: 시작하다 죽음\n00:01 +0 -1: Some tests failed.\n`); process.exit(1); }
  if (src.includes("COMPILE_ERR")) { out(`${file}:3:1: Error: Expected ';' after this.\n00:01 +0 -1: Some tests failed.\n`); process.exit(1); }
  if (fixed && ctl.mutate) fs.appendFileSync(path.join(o.copy, g.file), "// 시험이 몰래 남긴 줄\n");
  if (args.includes("--coverage")) {
    const cp = (args.find((a) => a.startsWith("--coverage-path=")) ?? `--coverage-path=${path.join(o.tmp, "coverage", "lcov.info")}`).split("=")[1];
    fs.mkdirSync(path.dirname(cp), { recursive: true });
    const recs = [];
    const walk = (d) => { for (const e of fs.readdirSync(path.join(o.copy, d), { withFileTypes: true })) { const r = `${d}/${e.name}`; if (e.isDirectory()) walk(r); else if (r.endsWith(".dart")) recs.push(r); } };
    walk("lib");
    fs.writeFileSync(cp, recs.map((r) => { const n = read(r).split("\n").length; return `SF:${path.join(o.copy, r)}\n${Array.from({ length: n }, (_, k) => `DA:${k + 1},${ctl.covMiss && r === g.file ? 0 : 1}`).join("\n")}\nend_of_record`; }).join("\n") + "\n");
  }
  if (!fixed) fail(["엔진: 같은 국면 같은 점수", "라이브 사람: 국진 쌍피", "라이브 AI [hard]: 국진 쌍피"].slice(1));
  if (ctl.aiStillRed) fail(["라이브 AI [hard]: 국진 쌍피"]);
  pass();
}
// 대상 시험·전체 시험·미니 대조
const pre = !file && ctl.preexisting ? [ctl.preexisting] : [];
if (!fixed && !isBase) fail(["라이브가 남긴 재현 파일을 엔진에 재생하면 같은 판이 나온다", ...pre]);
if (pre.length) fail(pre);
pass(file ? 2 : 40);
