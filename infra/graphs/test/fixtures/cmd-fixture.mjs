// cmd-fixture.mjs — 시험용 명령(허용 목록 시험 등록부가 고정 경로로 부른다).
//   node cmd-fixture.mjs append <파일>        파일에 한 줄 더한다(부수효과가 몇 번 일어났는지 세는 용도)
//   node cmd-fixture.mjs sleep <ms> <파일>    ms 만큼 기다린 뒤 파일에 'slept' 를 쓰고 표준 출력에 'done <ms>'
//   node cmd-fixture.mjs tree <파일> [term-ignore|all-ignore]   손주(hang)를 띄우고 멈춰 있다 — 묶음째 끄기 시험(손주가 파일을 쓴다).
//                                     term-ignore: 손주만 SIGTERM 무시 · all-ignore: 자기(명령)도 무시 · term-slow: 손주가 1초 정리 뒤 끝남
//   node cmd-fixture.mjs hang <파일> [term-ignore|term-slow]   (SIGTERM 처리를 건 뒤) 파일에 "부모pid 자기pid" 를 쓰고 멈춰 있다.
//                                     term-slow: SIGTERM 을 받으면 1초 뒤 '<파일>.cleaned' 를 쓰고 끝난다(정리하는 손주)
import { spawn } from "node:child_process";
import fs from "node:fs";

const [mode, a, b] = process.argv.slice(2);
if (mode === "append") {
  fs.appendFileSync(a, `${process.pid}\n`);
} else if (mode === "sleep") {
  setTimeout(() => { if (b) fs.writeFileSync(b, "slept"); process.stdout.write(`done ${a}\n`); }, Number(a));
} else if (mode === "tree") {
  if (b === "all-ignore") process.on("SIGTERM", () => {});
  spawn(process.execPath, [process.argv[1], "hang", a, b === "all-ignore" ? "term-ignore" : (b ?? "")], { stdio: "ignore" });
  setInterval(() => {}, 1000);
} else if (mode === "hang") {
  if (b === "term-ignore") process.on("SIGTERM", () => {});
  if (b === "term-slow") process.on("SIGTERM", () => setTimeout(() => { fs.writeFileSync(`${a}.cleaned`, "1"); process.exit(0); }, 1000));
  fs.writeFileSync(`${a}.tmp`, `${process.ppid} ${process.pid}`);
  fs.renameSync(`${a}.tmp`, a);
  setInterval(() => {}, 1000);
} else {
  process.stderr.write(`모르는 모드 ${mode}\n`);
  process.exit(2);
}
