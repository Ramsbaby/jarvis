// detach.mjs — 분리 실행(띄우기 → 확인). 틱 예산(8분)보다 긴 일(빌드·전체 시험·LLM 수정)을 노드 둘로 나눈다(설계 §6).
// - launch(): 작업 폴더 <jobs>/<스레드>/<노드>/<시도> 를 만들고(이것이 (thread, node, attempt) 잠금 — 폴더 만들기는 원자적이라
//   틱이 겹쳐도 한 번만 띄운다), 껍데기(detach-runner.mjs)를 detached 로 띄운다. 표준 입출력은 파일로 받는다.
// - check(): done(결과 파일 있음) · running(껍데기 pid 가 살아 있음) · dead(결과 없이 죽음) 셋 중 하나.
//   결과는 껍데기가 임시 파일 → 이름 바꾸기로 쓰니 반쯤 쓴 결과를 읽지 않는다.
// - 부모(틱)가 죽거나 게이트웨이가 재시작돼도 껍데기는 산다(새 세션). dead 를 내기 전에 남은 자식은 끈다(재시도와 겹치지 않게).
// 그래프는 이 모듈을 직접 가져오지 않는다 — 실행기가 build({ tools }) 로 넘기는 launch·check 를 쓴다(허용 목록을 거친다).
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { pidAlive, procStart } from "./store.mjs";

const RUNNER = path.join(path.dirname(fileURLToPath(import.meta.url)), "detach-runner.mjs");
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/;
const LAUNCH_GRACE_MS = 60_000; // 폴더는 있는데 meta 가 아직 없을 때 '띄우는 중'으로 볼 시간

const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch { return null; } };

export function jobDir(jobsDir, { thread, node, attempt }) {
  if (!NAME_RE.test(String(thread)) || !NAME_RE.test(String(node))) throw new Error(`분리 실행 이름이 이상하다: ${thread}/${node}`);
  if (!(Number.isInteger(attempt) && attempt >= 1 && attempt <= 99)) throw new Error(`attempt 는 1~99 정수: ${attempt}`);
  return path.join(jobsDir, thread, node, String(attempt));
}

// spec: { bin, argv, cwd, env, stdinText?, timeoutMs, heartbeatSec? }. 돌려주는 handle 은 그래프 상태에 넣을 수 있는 순수 값이다.
export function launch(jobsDir, { thread, node, attempt, cmdId }, spec) {
  const dir = jobDir(jobsDir, { thread, node, attempt });
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
    stdinFile, timeoutMs: spec.timeoutMs ?? 600_000, heartbeatSec: spec.heartbeatSec ?? 30,
  }), { mode: 0o600 });
  const child = spawn(process.execPath, [RUNNER, dir], {
    detached: true, stdio: "ignore", cwd: dir, env: { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LANG: process.env.LANG || "en_US.UTF-8" },
  });
  child.on("error", () => { /* meta 가 안 생기면 check 가 dead 로 판정한다 */ });
  child.unref();
  return handle;
}

const alive = (pid, pstart) => pidAlive(pid) && (pstart == null || procStart(pid) === pstart);

export function check(handle) {
  const dir = typeof handle === "string" ? handle : handle?.dir;
  if (!dir || !fs.existsSync(dir)) return { state: "dead", reason: "작업 폴더가 없다" };
  const done = () => {
    const r = readJson(path.join(dir, "result.json"));
    return r ? { state: "done", ...r, stdoutPath: path.join(dir, "stdout"), stderrPath: path.join(dir, "stderr") } : null;
  };
  const d1 = done();
  if (d1) return d1;
  const meta = readJson(path.join(dir, "meta.json"));
  if (!meta) {
    const born = fs.statSync(path.join(dir, "spec.json"), { throwIfNoEntry: false })?.mtimeMs ?? fs.statSync(dir).mtimeMs;
    return Date.now() - born < LAUNCH_GRACE_MS ? { state: "running", launching: true } : { state: "dead", reason: "띄우지 못함(meta 없음)" };
  }
  if (alive(meta.pid, meta.pstart)) {
    const hb = readJson(path.join(dir, "heartbeat"))?.t;
    return { state: "running", pid: meta.pid, startedAt: meta.startedAt, heartbeatAgeMs: hb ? Date.now() - hb : null };
  }
  const d2 = done(); // 두 번 읽는 사이에 끝났을 수 있다
  if (d2) return d2;
  if (meta.childPid && alive(meta.childPid, meta.childPstart)) {
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
