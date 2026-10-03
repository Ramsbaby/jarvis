// detach.mjs — 분리 실행(띄우기 → 확인). 틱 예산(8분)보다 긴 일(빌드·전체 시험·LLM 수정)을 노드 둘로 나눈다(설계 §6).
// - launch(): 작업 폴더 <jobs>/<스레드>/<노드>/<시도> 를 만들고(이것이 (thread, node, attempt) 잠금 — 폴더 만들기는 원자적이라
//   틱이 겹쳐도 한 번만 띄운다), 껍데기(detach-runner.mjs)를 detached 로 띄운다. 표준 입출력은 파일로 받는다.
// - check(): done(결과 파일 있음) · running(껍데기 pid 가 살아 있음) · dead(결과 없이 죽음 · 최대 시간 초과) 셋 중 하나.
//   결과는 껍데기가 임시 파일 → 이름 바꾸기로 쓰니 반쯤 쓴 결과를 읽지 않는다.
// - 부모(틱)가 죽거나 게이트웨이가 재시작돼도 껍데기는 산다(새 세션). dead 를 내기 전에 남은 자식은 끈다(재시도와 겹치지 않게).
// - 최대 시간(maxMs): 오픈클로 잡 시간 상한은 분리 실행에 닿지 않는다(10-03 실측 — 잡이 끝나도, 강제 종료돼도 산다).
//   그래서 check() 가 시작 + maxMs 를 넘긴 것을 프로세스 묶음째 끄고 dead(reason "timeout")를 낸다 → 재시도 규칙(3회 → GAVE_UP).
//   껍데기는 detached 라 자기 묶음의 우두머리다(pgid = 껍데기 pid) — 그 아래 명령·손주까지 한 신호로 닿는다.
// 그래프는 이 모듈을 직접 가져오지 않는다 — 실행기가 build({ tools }) 로 넘기는 launch·check 를 쓴다(허용 목록을 거친다).
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { pidAlive, procStart } from "./store.mjs";
import { allowSpawn } from "./guard.mjs";

const RUNNER = path.join(path.dirname(fileURLToPath(import.meta.url)), "detach-runner.mjs");
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/;
const LAUNCH_GRACE_MS = 60_000; // 폴더는 있는데 meta 가 아직 없을 때 '띄우는 중'으로 볼 시간
export const KILL_GRACE_MS = 30_000; // 최대 시간 초과: SIGTERM 뒤 이만큼 기다려도 남으면 SIGKILL
// maxMs 를 안 주면 시간 제한(timeoutMs)의 1.5배 — 설계 §6 '첫 값은 알려진 상한의 1.5배'. 보통은 껍데기의 시간 제한이 먼저 걸려
// 결과(timedOut)를 남기고, 이 상한은 껍데기마저 멈췄을 때의 뒷받침이다.
export const defaultMaxMs = (timeoutMs) => Math.ceil((timeoutMs ?? 600_000) * 1.5);

const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch { return null; } };
function writeJsonAtomic(dir, name, obj) {
  const tmp = path.join(dir, `.${name}.tmp-${process.pid}`);
  fs.writeFileSync(tmp, JSON.stringify(obj), { mode: 0o600 });
  fs.renameSync(tmp, path.join(dir, name));
}
const nap = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); // check 는 동기다 — 동기로 잠깐 쉰다

export function jobDir(jobsDir, { thread, node, attempt }) {
  if (!NAME_RE.test(String(thread)) || !NAME_RE.test(String(node))) throw new Error(`분리 실행 이름이 이상하다: ${thread}/${node}`);
  if (!(Number.isInteger(attempt) && attempt >= 1 && attempt <= 99)) throw new Error(`attempt 는 1~99 정수: ${attempt}`);
  return path.join(jobsDir, thread, node, String(attempt));
}

// spec: { bin, argv, cwd, env, stdinText?, timeoutMs, maxMs?, stopGraceMs?, heartbeatSec? }. 돌려주는 handle 은 그래프 상태에 넣을 수 있는 순수 값이다.
// timeoutMs: 껍데기가 스스로 끄는 시간(결과에 timedOut). maxMs: check() 가 묶음째 끄는 시간(dead "timeout") — 둘 다 시작부터 잰다.
// stopGraceMs: 껍데기가 멈춤 신호를 받아 명령이 끝난 뒤, 남은 손주가 스스로 정리하도록 기다리는 시간(기본 30초 — check 의 유예와 같다).
export function launch(jobsDir, { thread, node, attempt, cmdId }, spec) {
  const dir = jobDir(jobsDir, { thread, node, attempt });
  const timeoutMs = spec.timeoutMs ?? 600_000;
  const maxMs = spec.maxMs ?? defaultMaxMs(timeoutMs);
  if (!(Number.isFinite(maxMs) && maxMs > 0)) throw new Error(`maxMs 는 양수: ${spec.maxMs}`);
  const handle = { dir, thread, node, attempt, cmdId };
  fs.mkdirSync(path.dirname(dir), { recursive: true, mode: 0o700 });
  try {
    fs.mkdirSync(dir, { mode: 0o700 });
  } catch (e) {
    if (e.code === "EEXIST") return { ...handle, already: true }; // 같은 (스레드, 노드, 시도)는 이미 띄웠다 — 다시 띄우지 않는다
    throw e;
  }
  let stdinFile = null;
  if (spec.stdinText != null) {
    stdinFile = path.join(dir, "stdin");
    fs.writeFileSync(stdinFile, String(spec.stdinText), { mode: 0o600 });
  }
  fs.writeFileSync(path.join(dir, "spec.json"), JSON.stringify({
    cmdId, thread, node, attempt, bin: spec.bin, argv: spec.argv ?? [], cwd: spec.cwd, env: spec.env ?? {},
    stdinFile, timeoutMs, maxMs, stopGraceMs: spec.stopGraceMs ?? KILL_GRACE_MS, heartbeatSec: spec.heartbeatSec ?? 30,
  }), { mode: 0o600 });
  const child = allowSpawn(() => spawn(process.execPath, [RUNNER, dir], {
    detached: true, stdio: "ignore", cwd: dir, env: { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LANG: process.env.LANG || "en_US.UTF-8" },
  }));
  child.on("error", () => { /* meta 가 안 생기면 check 가 dead 로 판정한다 */ });
  child.unref();
  return handle;
}

// 시작 시각을 못 읽으면(ps 실패) 살아 있다고 본다 — store 의 잠금 판정(S1)과 같다. 반대로 보면 살아 있는 일을 죽이고 다시 띄운다.
const alive = (pid, pstart) => {
  if (!pidAlive(pid)) return false;
  if (pstart == null) return true;
  const cur = procStart(pid);
  return cur == null || cur === pstart;
};

// 신호를 보내도 되는가 — 그 pid 가 기록한 바로 그 프로세스임을 시작 시각으로 증명할 때만. 못 읽거나 다르면 남의 것일 수 있다(pid 재사용).
// pid 1 이하·자기 자신은 절대 아니다(kill(-1) 은 사용자 프로세스 전부, kill(-0) 은 자기 묶음이다).
function proven(pid, pstart) {
  if (!Number.isInteger(pid) || pid <= 1 || pid === process.pid || !pstart) return false;
  return pidAlive(pid) && procStart(pid) === pstart;
}
const ownRunner = (meta) => proven(meta?.pid, meta?.pstart); // 껍데기가 우리 것이면 그 묶음(pgid = 껍데기 pid)도 우리 것이다
const PS_ENV = { LC_ALL: "C", PATH: "/bin:/usr/bin" };
function procPgid(pid) {
  const r = allowSpawn(() => spawnSync("/bin/ps", ["-o", "pgid=", "-p", String(pid)], { env: PS_ENV, encoding: "utf8" }));
  const n = Number(String(r.stdout ?? "").trim());
  return r.status === 0 && Number.isInteger(n) && n > 1 ? n : null;
}

// 묶음(pgid = 껍데기 pid)에 살아 있는 프로세스가 남았나. 좀비(끝났지만 부모가 아직 거두지 않음)는 빼고 센다 —
// 맥은 좀비만 남은 묶음에 EPERM 을 낸다(10-03 실측). 같은 프로세스가 띄운 껍데기는 이 동기 대기 중에 거둬지지 않아 좀비로 남는다.
function groupLive(pgid) {
  try { process.kill(-pgid, 0); return true; } catch (e) { if (e.code !== "EPERM") return false; }
  const r = allowSpawn(() => spawnSync("/bin/ps", ["-A", "-o", "pgid=,stat="], { env: PS_ENV, encoding: "utf8" }));
  if (r.status !== 0) return true; // 못 읽으면 남았다고 본다
  return r.stdout.split("\n").some((l) => { const [g, st] = l.trim().split(/\s+/); return Number(g) === pgid && !!st && !st.startsWith("Z"); });
}
function waitGone(pgid, ms) {
  const end = Date.now() + ms;
  for (;;) {
    if (!groupLive(pgid)) return true;
    const left = end - Date.now();
    if (!(left > 0)) return false;
    nap(Math.min(100, left));
  }
}
const signalGroup = (pgid, sig) => { try { process.kill(-pgid, sig); } catch { /* 이미 비었음 */ } }; // 우리 것임을 증명한 묶음만

const timeoutResult = (k) => ({ state: "dead", reason: "timeout", pid: k.pid, startedAt: k.startedAt, maxMs: k.maxMs, killedAt: k.at, signal: k.signal, gone: k.gone });

// 최대 시간 초과 — 묶음째 SIGTERM → killGraceMs 안에 안 비면 SIGKILL. 표식(kill.json)을 먼저 남긴다: 끄는 사이 껍데기가 쓰는
// 결과(신호로 끝남)보다 이 판정이 이기고, 같은 시도를 다시 확인해도 dead(timeout)다.
// gone: 돌려줄 때 묶음이 비었나(SIGKILL 뒤 5초까지 기다린다). false 면 커널 대기 중인 프로세스 등이 남은 것이다.
// 끄는 쪽이 유예 중에 죽어도 껍데기가 바깥 SIGTERM 을 받아 남은 것을 SIGKILL 한다(detach-runner).
// 우리 껍데기임을 증명하지 못하면(시작 시각을 못 읽음) 끄지 않고 null — 다음 확인에서 다시 본다(진척 없는 이어가기는 48시간 만료).
function killTimedOut(dir, meta, { now, maxMs, killGraceMs }) {
  if (!ownRunner(meta)) return null;
  const k = { reason: "timeout", at: now, maxMs, pid: meta.pid, startedAt: meta.startedAt, signal: "SIGTERM", gone: null };
  writeJsonAtomic(dir, "kill.json", k);
  signalGroup(meta.pid, "SIGTERM");
  k.gone = waitGone(meta.pid, killGraceMs);
  if (!k.gone) {
    k.signal = "SIGKILL";
    signalGroup(meta.pid, "SIGKILL");
    if (proven(meta.childPid, meta.childPstart)) { try { process.kill(meta.childPid, "SIGKILL"); } catch { /* 이미 끝남 */ } } // 묶음을 떠난 자식
    k.gone = waitGone(meta.pid, 5_000);
  }
  writeJsonAtomic(dir, "kill.json", k);
  return timeoutResult(k);
}

// opts.now 는 시험용 시간 주입(최대 시간 판정·heartbeat 나이). 프로세스는 실제 시간으로 돌므로 기본은 Date.now() — 그래프 시계(LG_NOW)를 쓰지 않는다.
// opts.killGraceMs 는 SIGTERM 뒤 SIGKILL 까지 기다리는 시간(기본 30초) — 이 동안 check 는 동기로 기다린다(보통은 바로 꺼진다).
export function check(handle, { now = Date.now(), killGraceMs: grace = KILL_GRACE_MS } = {}) {
  const killGraceMs = Number.isFinite(grace) && grace >= 0 ? grace : KILL_GRACE_MS; // NaN 이면 Atomics.wait 가 끝없이 잔다
  const dir = typeof handle === "string" ? handle : handle?.dir;
  if (!dir || !fs.existsSync(dir)) return { state: "dead", reason: "작업 폴더가 없다" };
  const killed = readJson(path.join(dir, "kill.json"));
  if (killed) {
    const meta = readJson(path.join(dir, "meta.json"));
    if (ownRunner(meta) && groupLive(meta.pid)) signalGroup(meta.pid, "SIGKILL"); // 처음에 못 끈 것이 남았으면 한 번 더
    return timeoutResult(killed);
  }
  const done = () => {
    const r = readJson(path.join(dir, "result.json"));
    return r ? { state: "done", ...r, stdoutPath: path.join(dir, "stdout"), stderrPath: path.join(dir, "stderr") } : null;
  };
  const d1 = done();
  if (d1) return d1;
  const meta = readJson(path.join(dir, "meta.json"));
  if (!meta) {
    const born = fs.statSync(path.join(dir, "spec.json"), { throwIfNoEntry: false })?.mtimeMs ?? fs.statSync(dir).mtimeMs;
    return now - born < LAUNCH_GRACE_MS ? { state: "running", launching: true } : { state: "dead", reason: "띄우지 못함(meta 없음)" };
  }
  if (alive(meta.pid, meta.pstart)) {
    const spec = readJson(path.join(dir, "spec.json"));
    const maxMs = spec?.maxMs ?? defaultMaxMs(spec?.timeoutMs);
    const hb = readJson(path.join(dir, "heartbeat"))?.t;
    const running = { state: "running", pid: meta.pid, startedAt: meta.startedAt, deadline: meta.startedAt + maxMs, heartbeatAgeMs: hb ? now - hb : null };
    if (!(now - meta.startedAt >= maxMs)) return running; // 시작 시각·상한을 못 읽으면(NaN) 끄지 않는다
    return done() ?? killTimedOut(dir, meta, { now, maxMs, killGraceMs }) ?? { ...running, overdue: true }; // 끄기 직전에 끝났으면 그 결과
  }
  const d2 = done(); // 두 번 읽는 사이에 끝났을 수 있다
  if (d2) return d2;
  // 껍데기 없이 명령이 살아 있다(누가 껍데기를 SIGKILL). 명령이 아직 껍데기 묶음에 있으면 그 묶음은 우리 것이다 — 손주까지 끈다.
  // 명령도 이미 끝났으면 남은 손주의 묶음이 우리 것임을 증명할 길이 없어 건드리지 않는다(pid 재사용).
  if (proven(meta.childPid, meta.childPstart)) {
    if (meta.pid > 1 && procPgid(meta.childPid) === meta.pid) signalGroup(meta.pid, "SIGKILL");
    try { process.kill(meta.childPid, "SIGKILL"); } catch { /* 이미 끝남 */ }
  }
  return { state: "dead", reason: "껍데기 프로세스가 결과 없이 끝남", pid: meta.pid, startedAt: meta.startedAt };
}

export function readOutput(handle, which = "stdout", max = 1_000_000) {
  const f = path.join(typeof handle === "string" ? handle : handle.dir, which === "stderr" ? "stderr" : "stdout");
  try {
    const fd = fs.openSync(f, "r");
    try {
      const size = fs.fstatSync(fd).size;
      const buf = Buffer.alloc(Math.min(size, max));
      fs.readSync(fd, buf, 0, buf.length, 0);
      return buf.toString("utf8");
    } finally { fs.closeSync(fd); }
  } catch { return ""; }
}
