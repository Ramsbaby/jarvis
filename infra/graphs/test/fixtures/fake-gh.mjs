// fake-gh.mjs — 시험용 gh(읽기 전용 두 명령만). 시험 허용 목록이 'node fake-gh.mjs <제어파일> <원래 인자…>' 로 부른다.
// 제어 파일(JSON): { rc, runs: [...], log: "…", trace }  — rc 가 0 이 아니면 인증 실패 흉내(stderr)
import fs from "node:fs";

const [ctlFile, ...args] = process.argv.slice(2);
const ctl = JSON.parse(fs.readFileSync(ctlFile, "utf8"));
if (ctl.trace) fs.appendFileSync(ctl.trace, `${JSON.stringify({ args, cwd: process.cwd() })}\n`);
if (ctl.rc) { process.stderr.write("To get started with GitHub CLI, please run:  gh auth login\n"); process.exit(ctl.rc); }
if (args[0] === "run" && args[1] === "list") { fs.writeSync(1, JSON.stringify(ctl.runs ?? [])); process.exit(0); }
if (args[0] === "run" && args[1] === "view" && args.includes("--log-failed")) { fs.writeSync(1, String(ctl.log ?? "")); process.exit(0); }
process.stderr.write(`허용하지 않은 gh 인자: ${args.join(" ")}\n`);
process.exit(2);
