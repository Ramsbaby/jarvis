// detach-runner.mjs — 분리 실행의 바깥 껍데기. lib/detach.mjs 가 detached(새 세션)로 띄운다. 직접 부르지 않는다.
//   node detach-runner.mjs <작업 폴더>
// 하는 일: spec.json 을 읽어 명령을 띄우고(표준 입출력은 파일로), meta.json 에 pid·시작 시각·cmdId 를 남기고,
// heartbeat 를 주기마다 갱신하고, 끝나면 result.json 을 원자적으로(임시 파일 → 이름 바꾸기) 쓴다.
// 부모(틱)가 죽어도 이 프로세스는 산다(다른 세션). 이 껍데기가 SIGTERM 을 받으면 자식에게 넘기고 결과를 남긴 뒤 묶음을 정리한다(reap).
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

// 멈추라는 신호(확인이 최대 시간으로 묶음째 보낸 SIGTERM, 명령의 `kill 0` 포함)도 시간 제한처럼 다룬다: 명령에 넘기고, 끝나면 정리(reap).
// 끄는 쪽(틱)이 30초 유예 중에 죽어도 SIGTERM 을 무시한 손주가 남지 않게(0b 후속 검토 중1).
let stopping = false;
for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) process.on(sig, () => { stopping = true; try { child.kill(sig); } catch { /* 이미 끝남 */ } });

// 묶음에 이 껍데기 말고 살아 있는 것이 남았나(좀비 제외). 못 읽으면 남았다고 본다.
// 여기서 띄운 ps 자신도 이 묶음에 든다 — 빼고 센다(안 빼면 늘 '남았다'가 되어 유예를 다 채운다).
function othersLive() {
  const r = spawnSync("/bin/ps", ["-A", "-o", "pid=,pgid=,stat="], { env: { LC_ALL: "C", PATH: "/bin:/usr/bin" }, encoding: "utf8" });
  if (r.status !== 0) return true;
  return r.stdout.split("\n").some((l) => {
    const [p, g, st] = l.trim().split(/\s+/);
    return Number(g) === process.pid && Number(p) !== process.pid && Number(p) !== r.pid && !!st && !st.startsWith("Z");
  });
}
// 시간 제한·멈춤 신호로 끝났을 때: 남은 것(SIGTERM 을 받은 손주)이 스스로 정리할 시간을 주고, 비면 바로 끝난다. 유예가 지나도 남으면
// 그때 살아 있는 모든 것을 묶음째 SIGKILL(이 껍데기 포함). 명령이 끝나자마자 끄면 손주가 정리를 못 한다(0b 후속 재검토 중).
// 결과를 쓴 뒤에도 우두머리로 남아 있으므로 그동안 check 도 이 묶음이 우리 것임을 증명할 수 있다.
function reap(graceMs) {
  const end = Date.now() + graceMs;
  const step = () => {
    if (!othersLive()) process.exit(0);
    if (Date.now() >= end) {
      try { process.kill(-process.pid, "SIGKILL"); } catch { /* 우두머리가 아님(직접 띄움) */ }
      process.exit(0);
    }
    setTimeout(step, 200);
  };
  step();
}

child.on("close", (code, signal) => {
  if (finished) return;
  finished = true;
  clearInterval(hb);
  clearTimeout(timer);
  try {
    writeAtomic("result.json", { code, signal, timedOut, startedAt, endedAt: Date.now() });
  } catch { /* 작업 폴더가 지워짐(gc) — 결과는 못 남겨도 아래 정리는 한다(검토 중2) */ }
  // 유예: 멈춤 신호는 check 와 같은 30초(spec.stopGraceMs), 시간 제한은 5초(명령 SIGKILL 까지 이미 5초를 줬다)
  if (timedOut || stopping) reap(timedOut ? 5_000 : (spec.stopGraceMs ?? 30_000));
  else process.exit(0);
});
