// fake-gqa.mjs — gostop-qa 그래프 시험용 가짜 일꾼(에뮬레이터·adb·ffmpeg·LLM 없음).
// FAKE_GQA_DIR 의 표식 파일로 상황을 흉내 낸다: gate-hold(관문 막힘) · die-once(첫 판 두기에서 기기 사라짐) · play-fail(판 두기 계속 실패)
// 부른 기록은 calls.jsonl — 시험이 책갈피(같은 판을 두 번 두지 않음)를 센다.
import fs from "node:fs";
import path from "node:path";

const dir = process.env.FAKE_GQA_DIR;
const [cmd, ...rest] = process.argv.slice(2);
const arg = (k) => { const i = rest.indexOf(`--${k}`); return i >= 0 ? rest[i + 1] : undefined; };
const has = (f) => fs.existsSync(path.join(dir, f));
fs.appendFileSync(path.join(dir, "calls.jsonl"), JSON.stringify({ cmd, run: arg("run"), seed: arg("seed"), games: arg("games"), stage: arg("stage"), batch: arg("batch"), runs: arg("runs") }) + "\n");
const out = (o) => process.stdout.write(`로그 한 줄\n${JSON.stringify(o)}\n`);
switch (cmd) {
  case "gate": out(has("gate-hold") ? { ok: false, reasons: ["disk: 여유 9GiB < 16GiB"] } : { ok: true, reasons: [], disk_gib: 40, load1: 2 }); break;
  case "build": out({ ok: true, apk: "/tmp/fake-qa.apk", sha: "0123456789abcdef0123456789abcdef01234567", cached: true }); break;
  case "emu-up": out({ ok: true, pid: 4242, airplane: "1" }); break;
  case "install": out({ ok: true }); break;
  case "play": {
    if (has("die-once")) { fs.rmSync(path.join(dir, "die-once")); out({ ok: false, error: "기기 없음(emu-up 먼저)" }); break; }
    if (has("play-fail")) { process.exit(3); }
    const n = Number(arg("games"));
    out({ ok: true, finished: n, outcomes: Array(n).fill("finished"), app_died: false, segments: 2 });
    break;
  }
  case "analyze": out({ ok: true, frames: 1234, confirmed: 1, candidates: 1, eye: { sheets: 3 } }); break;
  case "eye-batch-prompt": {
    const cwd = path.join(dir, "eye"); fs.mkdirSync(cwd, { recursive: true });
    out(arg("stage") === "first" ? { ok: true, prompt: "그림을 보라", cwd, files: 3 } : { ok: true, prompt: "확인하라", cwd, items: 1 });
    break;
  }
  case "eye-batch-record": out({ ok: true, stage: arg("stage"), flagged: 1, parsed: true }); break;
  case "clip": out({ ok: true, findings: 1, clips: 1 }); break;
  case "signal": out({ ok: true, new: ["visual:D1-aaaa:01234567"], orders: [{ id: "D1-aaaa", line: "- [ ] **[고스톱 QA·중] 화면 넘침** (결정적, id D1-aaaa)" }] }); break;
  case "cleanup": case "emu-down": out({ ok: true }); break;
  default: process.stderr.write(`모르는 명령 ${cmd}\n`); process.exit(2);
}
