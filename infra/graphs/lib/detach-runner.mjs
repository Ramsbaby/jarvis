// detach-runner.mjs — 분리 실행의 바깥 껍데기. lib/detach.mjs 가 detached(새 세션)로 띄운다. 직접 부르지 않는다.
//   node detach-runner.mjs <작업 폴더>
// 하는 일: spec.json 을 읽어 명령을 띄우고(표준 입출력은 파일로), meta.json 에 pid·시작 시각·cmdId 를 남기고,
// heartbeat 를 주기마다 갱신하고, 끝나면 result.json 을 원자적으로(임시 파일 → 이름 바꾸기) 쓴다.
// 부모(틱)가 죽어도 이 프로세스는 산다(다른 세션). 이 껍데기가 SIGTERM 을 받으면 자식에게 넘기고 결과를 남긴다.
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

process.umask(0o077);
const dir = process.argv[2];
const spec = JSON.parse(fs.readFileSync(path.join(dir, "spec.json"), "utf8"));
const startedAt = Date.now();

function writeAtomic(name, obj) {
  const tmp = path.join(dir, `.${name}.tmp-${process.pid}`);
  fs.writeFileSync(tmp, JSON.stringify(obj), { mode: 0o600 });
  fs.renameSync(tmp, path.join(dir, name));
}
const lstart = (pid) => {
  const r = spawnSync("/bin/ps", ["-o", "lstart=", "-p", String(pid)], { env: { LC_ALL: "C", TZ: "UTC", PATH: "/bin:/usr/bin" }, encoding: "utf8" });
  return r.status === 0 ? r.stdout.trim() || null : null;
};

const meta = { pid: process.pid, pstart: lstart(process.pid), startedAt, cmdId: spec.cmdId, thread: spec.thread, node: spec.node, attempt: spec.attempt, childPid: null };
writeAtomic("meta.json", meta);

const out = fs.openSync(path.join(dir, "stdout"), "a", 0o600);
const err = fs.openSync(path.join(dir, "stderr"), "a", 0o600);
const stdin = spec.stdinFile ? fs.openSync(spec.stdinFile, "r") : "ignore";
let child;
try {
  child = spawn(spec.bin, spec.argv, { cwd: spec.cwd, env: spec.env, stdio: [stdin, out, err] });
} catch (e) {
  writeAtomic("result.json", { code: null, signal: null, error: String(e.message), timedOut: false, startedAt, endedAt: Date.now() });
  process.exit(0);
}
let finished = false;
child.on("error", (e) => {
  if (finished) return;
  finished = true;
  writeAtomic("result.json", { code: null, signal: null, error: String(e.message), timedOut: false, startedAt, endedAt: Date.now() });
  process.exit(0);
});
meta.childPid = child.pid;
meta.childPstart = child.pid ? lstart(child.pid) : null;
writeAtomic("meta.json", meta);

const beat = () => { try { writeAtomic("heartbeat", { t: Date.now() }); } catch { /* 폴더가 지워짐 */ } };
beat();
const hb = setInterval(beat, Math.max(1, spec.heartbeatSec ?? 30) * 1000);

// 시간 제한: 묶음째 SIGTERM — 이 껍데기는 detached 라 묶음의 우두머리다(pgid = 자기 pid). 명령만 끄면 그 아래 손주(시험 프로세스 등)가
// 고아로 남아 재시도와 겹친다. 껍데기 자신은 아래 신호 처리기가 있어 버티고, 명령이 끝나면 결과를 쓴다.
let timedOut = false;
const timer = setTimeout(() => {
  timedOut = true;
  try { process.kill(-process.pid, "SIGTERM"); } catch { try { child.kill("SIGTERM"); } catch { /* 이미 끝남 */ } } // 묶음 우두머리가 아니면(직접 띄움) 명령만
  setTimeout(() => { try { child.kill("SIGKILL"); } catch { /* 이미 끝남 */ } }, 5000).unref();
}, spec.timeoutMs);

// 멈추라는 신호(확인이 최대 시간으로 묶음째 보낸 SIGTERM 포함)도 시간 제한처럼 다룬다: 명령에 넘기고, 끝나면 남은 것을 SIGKILL.
// 끄는 쪽(틱)이 30초 유예 중에 죽어도 SIGTERM 을 무시한 손주가 남지 않게 — 그 뒤의 확인은 껍데기가 없어 묶음을 증명하지 못한다(0b 후속 검토 중1).
let stopping = false;
for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(sig, () => { stopping = true; try { child.kill(sig); } catch { /* 이미 끝남 */ } });

child.on("close", (code, signal) => {
  if (finished) return;
  finished = true;
  clearInterval(hb);
  clearTimeout(timer);
  try {
    writeAtomic("result.json", { code, signal, timedOut, startedAt, endedAt: Date.now() });
  } finally {
    // 시간 제한·멈춤 신호로 끝났으면 묶음에 남은 것(SIGTERM 을 무시한 손주)까지 SIGKILL. 결과를 못 써도(작업 폴더가 지워짐) 한다(검토 중2).
    // 이 껍데기도 함께 끝난다 — 결과는 이미 썼다.
    if (timedOut || stopping) { try { process.kill(-process.pid, "SIGKILL"); } catch { /* 이미 비었음 */ } }
  }
  process.exit(0);
});
