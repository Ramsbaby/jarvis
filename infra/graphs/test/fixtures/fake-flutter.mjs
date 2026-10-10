// fake-flutter.mjs — 시험용 flutter(1a 고스톱 그래프). 시험 허용 목록이 'node fake-flutter.mjs <제어파일> <원래 인자…>' 로 부른다.
// 제어 파일(JSON): { mode, trace }
//   mode: mismatch(차분 대조 불일치·코드 1) · pass(통과) · flaky(홀수 회차 불일치·짝수 통과) · fail(일반 시험 실패)
//         compile(컴파일 오류) · hang(SIGTERM 무시 + 손주를 띄우고 멈춤 — 묶음째 끄기 시험)
//         mismatch-old(사본 코드를 본다 — turn_manager 가 옛 코드 'score() => 4' 면 불일치, 고쳐진 코드면 통과)
//   trace: 부를 때마다 한 줄(pid · 하위 명령 · 인자 · 작업 폴더)을 더하는 파일
import { spawn } from "node:child_process";
import fs from "node:fs";

const [ctlFile, sub, ...rest] = process.argv.slice(2);
const ctl = JSON.parse(fs.readFileSync(ctlFile, "utf8"));
if (ctl.trace) fs.appendFileSync(ctl.trace, `${JSON.stringify({ pid: process.pid, sub, args: rest, cwd: process.cwd(), repro: fs.existsSync("test/repro") })}\n`);

if (sub === "pub") {
  fs.mkdirSync(".dart_tool", { recursive: true });
  fs.writeFileSync(".dart_tool/package_config.json", "{}");
  fs.writeSync(1, "Resolving dependencies...\nGot dependencies!\n");
  process.exit(0);
}

const nTest = ctl.trace ? fs.readFileSync(ctl.trace, "utf8").split("\n").filter((l) => l.includes('"sub":"test"')).length : 1;
const seed = (rest.find((a) => /^REPLAY_SEED_BASE=/.test(a)) ?? "REPLAY_SEED_BASE=20260906").split("=")[1];
fs.mkdirSync("build/test_cache/build", { recursive: true });
fs.writeFileSync(`build/test_cache/build/fake-${seed}.dill`, "x".repeat(1024));

const mismatch = () => {
  fs.writeSync(1, `00:01 +0: loading test\n★ 라이브↔엔진 재생 대조: 1판 / 결정 18건 재생 / 불일치 1 (seedBase=${seed})\n` +
    `  ⛔ seed=${seed}: 라이브와 엔진의 끝 상태가 다르다\n    seat0 국진 쌍피: 라이브 false / 엔진 true\n    seat0 확정 점수: 라이브 4 / 엔진 6\n` +
    `    결정 18건, 완주=true, 메모: ${Date.now()}\n00:18 +0 -1: 라이브가 남긴 재현 파일을 엔진에 재생하면 같은 판이 나온다 [E]\n00:18 +0 -1: Some tests failed.\n`);
  process.exit(1);
};
const pass = () => { fs.writeSync(1, "00:01 +0: loading test\n00:05 +2: All tests passed!\n"); process.exit(0); };

switch (ctl.mode) {
  case "mismatch": mismatch(); break;
  case "pass": pass(); break;
  case "flaky": if (nTest % 2 === 1) mismatch(); else pass(); break;
  case "mismatch-old": if (fs.readFileSync("lib/domain/game/turn_manager.dart", "utf8").includes("score() => 4")) mismatch(); else pass(); break;
  case "fail":
    fs.writeSync(1, "00:01 +0: loading test\n00:02 +3 -1: 판 끝 조커 귀속 바닥 조커는 바닥에 남는다 [E]\n00:02 +3 -1: Some tests failed.\n");
    process.exit(1);
    break;
  case "toolerr": // 시험이 하나도 안 돌았다(파일 없음 등) — 불일치·실패 시험 이름 없이 코드 1
    fs.writeSync(1, "Error: No tests ran.\n");
    process.exit(1);
    break;
  case "compile":
    fs.writeSync(1, "lib/domain/game/turn_manager.dart:10:3: Error: Expected ';' after this.\n00:01 +0 -1: Some tests failed.\n");
    process.exit(1);
    break;
  case "hang":
    process.on("SIGTERM", () => {});
    spawn(process.execPath, ["-e", "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)", "lg-fake-flutter-grandchild"], { stdio: "ignore" });
    setInterval(() => {}, 1000);
    break;
  default:
    process.stderr.write(`모르는 mode ${ctl.mode}\n`);
    process.exit(2);
}
