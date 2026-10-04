// fake-gw.mjs — 시험용 가짜 게이트웨이 확인 명령(lsof·ps·curl 자리). 진짜 게이트웨이·OpenClaw 를 건드리지 않는다.
//   LG_TEST_GW_FILE 의 JSON { up, pid, start_ms, health } 로 답한다. ps 의 나이(etime)는 실행기 시계 LG_NOW 기준.
//   부를 때마다 LG_TEST_GW_FILE.calls 에 한 줄 남긴다(시험이 '진짜 명령 대신 이것이 불렸다'를 확인).
import fs from "node:fs";

const [, , cmd, arg] = process.argv;
const file = process.env.LG_TEST_GW_FILE;
fs.appendFileSync(`${file}.calls`, `${cmd} ${arg ?? ""}\n`);
const s = JSON.parse(fs.readFileSync(file, "utf8"));
const now = Number(process.env.LG_NOW) || Date.now();
const etime = (sec) => {
  const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60), x = sec % 60;
  const p = (n) => String(n).padStart(2, "0");
  return `${d ? `${d}-` : ""}${d || h ? `${p(h)}:` : ""}${p(m)}:${p(x)}`;
};
if (cmd === "lsof") {
  if (!s.up) process.exit(1);
  process.stdout.write(`${s.pid}\n`);
  process.exit(0);
}
if (cmd === "ps") {
  if (!s.up || String(s.pid) !== arg || s.psFail) process.exit(1);
  process.stdout.write(`${s.pid} ${etime(Math.max(0, Math.floor((now - s.start_ms) / 1000)))}\n`);
  process.exit(0);
}
if (cmd === "curl") {
  if (!s.up || s.health === false) process.exit(7);
  process.stdout.write('{"ok":true,"status":"live"}');
  process.exit(0);
}
process.exit(2);
