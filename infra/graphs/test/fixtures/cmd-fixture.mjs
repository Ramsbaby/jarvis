// cmd-fixture.mjs — 시험용 명령(허용 목록 시험 등록부가 고정 경로로 부른다).
//   node cmd-fixture.mjs append <파일>        파일에 한 줄 더한다(부수효과가 몇 번 일어났는지 세는 용도)
//   node cmd-fixture.mjs sleep <ms> <파일>    ms 만큼 기다린 뒤 파일에 'slept' 를 쓰고 표준 출력에 'done <ms>'
//   node cmd-fixture.mjs tree <파일> [term-ignore]   손주(hang)를 띄우고 멈춰 있다 — 묶음째 끄기 시험(손주가 파일을 쓴다)
//   node cmd-fixture.mjs hang <파일> [term-ignore]   (term-ignore 면 SIGTERM 을 무시하게 한 뒤) 파일에 "부모pid 자기pid" 를 쓰고 멈춰 있다
import { spawn } from "node:child_process";
import fs from "node:fs";

const [mode, a, b] = process.argv.slice(2);
if (mode === "append") {
  fs.appendFileSync(a, `${process.pid}\n`);
} else if (mode === "sleep") {
  setTimeout(() => { if (b) fs.writeFileSync(b, "slept"); process.stdout.write(`done ${a}\n`); }, Number(a));
} else if (mode === "tree") {
  spawn(process.execPath, [process.argv[1], "hang", a, b ?? ""], { stdio: "ignore" });
  setInterval(() => {}, 1000);
} else if (mode === "hang") {
  if (b === "term-ignore") process.on("SIGTERM", () => {});
  fs.writeFileSync(`${a}.tmp`, `${process.ppid} ${process.pid}`);
  fs.renameSync(`${a}.tmp`, a);
  setInterval(() => {}, 1000);
} else {
  process.stderr.write(`모르는 모드 ${mode}\n`);
  process.exit(2);
}
