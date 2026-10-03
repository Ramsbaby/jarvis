#!/usr/bin/env node
// sandboxed-run.mjs — LLM 이 쓴 시험·분석 코드를 lg-test.sb 격리 안에서 돌리는 입구(설계 §3 · 1b 전제 조건).
// 그래프는 이 파일을 직접 가져오지 않는다(실행기 내부 가져오기 금지) — cmd-registry 의 cmdId 로 별도 프로세스로 부른다.
//
//   node sandboxed-run.mjs --copy <사본> --tmp <임시> [--timeout-sec N] -- flutter test test/x_test.dart
//   node sandboxed-run.mjs --copy <사본> --tmp <임시> --canary        # 격리가 실제로 막는지 1초 점검(JSON 한 줄)
//   --ai-policy-dir <이름>: 고스톱 AI 결정 비교 시험의 출력 자리(AI_POLICY_DIR = <임시>/<이름>, 1b 통합)
//
// 하는 일
// - 프로필 틀(lg-test.sb)에 경로 변수(-D)를 실제 경로로 채우고, 지금 열려 있는 로컬 포트를 막는 줄을 덧붙여 sandbox-exec 로 띄운다.
// - flutter 는 셸 진입점(bin/flutter — git rev-parse 를 부른다)을 거치지 않고 dart + flutter_tools 스냅숏으로 바로 부른다.
//   SDK 잠금 파일·버전 확인·분석 전송을 끈다(FLUTTER_ALREADY_LOCKED·--no-version-check·--suppress-analytics) — 격리 안에서 SDK 에 쓰지 않게.
// - 환경변수는 허용 목록만 새로 만든다(토큰류 0). HOME·TMPDIR 는 임시 폴더 아래로 돌린다.
// - 사본·임시 폴더 경로를 검사한다: 정해진 뿌리 아래 · 홈·SDK·pub 캐시를 품지 않음 · 서로 겹치지 않음(겹치면 .git 보호가 풀린다).
// - 도는 동안 0.5초마다 격리 안 프로세스의 리슨 소켓을 본다. 루프백이 아닌 주소(0.0.0.0·LAN)에 리슨하면 바로 모두 끈다 —
//   격리 규칙만으로는 이것을 막을 수 없다(아래 nonLoopbackListeners 주석, 10-03 실측).
// - 출력은 그대로 흘려보내고 종료 코드도 그대로 낸다. 시간 초과는 124, 준비 오류는 97, 격리 위반 시도는 98(stderr 'LG-SANDBOX …').
// 맥 전용이다(sandbox-exec). 다른 OS 에서는 97(not_darwin)로 닫힌 쪽 실패.
import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const PROFILE = path.join(HERE, "lg-test.sb");
export const PROBE = path.join(HERE, "probe.dart");
export const SANDBOX_EXEC = "/usr/bin/sandbox-exec";
// 늘 막는 로컬 서비스 포트(설계 §3) — 프로필 틀에 박혀 있다. 여기 값은 덧붙일 때 중복을 빼고 시험·보고에 쓴다.
export const FIXED_DENY_PORTS = [18789, 9222, 5037, 11434, 3100];
export const EXIT_SETUP = 97;
export const EXIT_VIOLATION = 98; // 격리 위반 시도(루프백 아닌 주소에 리슨) — 그래프는 보류 + 지표 '격리 위반 시도'
export const EXIT_TIMEOUT = 124;
// flutter 하위 명령 허용 목록. pub 은 뺐다 — 끝에 xcodebuild 를 부르다 막히고(실측), 의존성 준비는 LLM 이 손대기 전 사본 단계(1a)에서 한다.
export const FLUTTER_SUBCOMMANDS = new Set(["test", "analyze"]);

export class SandboxError extends Error {
  constructor(code, msg) { super(msg); this.name = "SandboxError"; this.code = code; }
}

// 계정의 진짜 홈. $HOME 은 바꿀 수 있으니 쓰지 않는다(시험이 임시 HOME 으로 돌아도 프로필은 진짜 홈 기준이어야 한다).
export const realHome = () => os.userInfo().homedir;
const real = (p) => fs.realpathSync(p);
export const inside = (child, parent) => child === parent || child.startsWith(parent.endsWith("/") ? parent : `${parent}/`);

// 사본·임시 폴더가 놓일 수 있는 뿌리. 런타임 그래프 상태 폴더(1a 사본 자리)와 시스템 임시 폴더뿐이다.
// 환경변수(TMPDIR 등)에서 뿌리를 받지 않는다 — 홈을 뿌리로 넘기면 본 저장소가 쓰기 대상이 될 수 있다.
export function defaultRoots(home = realHome()) {
  const roots = ["/private/tmp", "/private/var/folders"];
  const state = path.join(home, ".openclaw-data", "runtime", "state", "graphs");
  try { roots.push(real(state)); } catch { /* 아직 없음 */ }
  return roots;
}

export function locateFlutter({ flutterRoot, env = process.env } = {}) {
  let root = flutterRoot || env.LG_FLUTTER_ROOT || null;
  if (!root) {
    for (const cand of ["/opt/homebrew/bin/flutter", "/usr/local/bin/flutter"]) {
      try { root = path.dirname(path.dirname(real(cand))); break; } catch { /* 없음 */ }
    }
  }
  if (!root) throw new SandboxError("no_flutter", "flutter SDK 를 찾지 못했다(LG_FLUTTER_ROOT)");
  try { root = real(root); } catch { throw new SandboxError("no_flutter", `flutter SDK 경로가 없다: ${root}`); }
  const f = {
    root,
    dart: path.join(root, "bin/cache/dart-sdk/bin/dart"),
    snapshot: path.join(root, "bin/cache/flutter_tools.snapshot"),
    packages: path.join(root, "packages/flutter_tools/.dart_tool/package_config.json"),
  };
  for (const p of [f.dart, f.snapshot, f.packages]) if (!fs.existsSync(p)) throw new SandboxError("no_flutter", `flutter SDK 가 덜 깔렸다: ${p}`);
  return f;
}

export function checkDirs({ copy, tmp, home, flutterRoot, pubCache, roots }) {
  const out = {};
  for (const [name, d0] of [["copy", copy], ["tmp", tmp]]) {
    if (typeof d0 !== "string" || !path.isAbsolute(d0)) throw new SandboxError("bad_dir", `${name} 는 절대경로여야 한다`);
    let d;
    try { d = real(d0); } catch { throw new SandboxError("bad_dir", `${name} 폴더가 없다: ${d0}`); }
    if (!fs.statSync(d).isDirectory()) throw new SandboxError("bad_dir", `${name} 는 폴더여야 한다: ${d}`);
    if (!roots.some((r) => inside(d, r) && d !== r)) throw new SandboxError("bad_dir", `${name} 는 정해진 뿌리 아래여야 한다(${roots.join(" · ")}): ${d}`);
    for (const [label, p] of [["홈", home], ["flutter SDK", flutterRoot], ["pub 캐시", pubCache]]) {
      if (inside(p, d)) throw new SandboxError("bad_dir", `${name} 가 ${label}을(를) 품는다 — 통째로 쓰기 대상이 된다: ${d}`);
      if (label !== "홈" && inside(d, p)) throw new SandboxError("bad_dir", `${name} 가 ${label} 안에 있다: ${d}`);
    }
    out[name] = d;
  }
  if (inside(out.copy, out.tmp) || inside(out.tmp, out.copy)) {
    throw new SandboxError("bad_dir", "사본과 임시 폴더가 겹친다 — 임시 폴더 쓰기 허용이 사본 .git 보호를 덮는다");
  }
  let st = null;
  try { st = fs.lstatSync(path.join(out.copy, ".git")); } catch { /* .git 없는 사본도 된다 */ }
  if (st && !st.isDirectory()) throw new SandboxError("bad_dir", "사본의 .git 이 폴더가 아니다(바로가기·파일) — 막는 규칙이 엉뚱한 곳을 가리킨다");
  return out;
}

// 지금 열려 있는 TCP 수신 포트와 UDP 바인드 포트(루프백·전체 주소). 이 포트로는 격리 안에서 연결하지 못하게 덧붙인다.
// flutter 시험 자신의 포트는 실행 뒤에 새로 열리므로 여기 들지 않는다. 읽기에 실패하면 고정 목록만으로 간다(빈 배열).
export function listeningPorts() {
  const ports = new Set();
  for (const proto of ["tcp", "udp"]) {
    const r = spawnSync("/usr/sbin/netstat", ["-an", "-p", proto], { encoding: "utf8", timeout: 10_000 });
    if (r.status !== 0) continue;
    for (const line of r.stdout.split("\n")) {
      const f = line.trim().split(/\s+/);
      if (!/^(tcp|udp)(4|6|46)$/.test(f[0] ?? "")) continue;
      if (proto === "tcp" && f[f.length - 1] !== "LISTEN") continue;
      if (proto === "udp" && f[4] !== "*.*") continue;
      const m = /[.:](\d{1,5})$/.exec(f[3] ?? "");
      const n = m ? Number(m[1]) : 0;
      if (n > 0 && n < 65536) ports.add(n);
    }
  }
  return [...ports].sort((a, b) => a - b);
}

// 홈 아래에서 메타데이터(stat — 있는지·크기·시각)를 열어 둘 폴더: 허용 경로(사본·임시·pub 캐시·SDK) 중 홈 아래 것의 조상들.
// 경로를 따라 내려가려면 조상마다 stat 이 필요하다. 그 밖의 홈 아래는 있는지조차 안 보이게 한다(본 저장소 파일 이름 짐작 막기).
export function homeAncestors(home, paths) {
  const out = new Set();
  for (const p of paths) {
    if (!inside(p, home)) continue;
    for (let cur = p; ; cur = path.dirname(cur)) { out.add(cur); if (cur === home || cur === path.dirname(cur)) break; }
  }
  return [...out].sort();
}

// ancestors 는 변수(-D ANC0…)로 넘긴다 — 경로를 프로필 글자에 박지 않으니 따옴표·역슬래시 걱정이 없다.
export function buildProfile({ template = PROFILE, ports = [], ancestors = 0 } = {}) {
  let text = fs.readFileSync(template, "utf8");
  const anc = Array.from({ length: ancestors }, (_, i) => `\n  (literal (param "ANC${i}"))`).join("");
  text += `\n;; 홈 아래 메타데이터도 허용 목록(sandboxed-run.mjs 가 덧붙임). bsd.sb 의 전역 허용을 같은 동작 이름으로 덮고, 허용 경로와 그 조상만 다시 연다.
(deny file-read-metadata (subpath (param "HOME_DIR")))
(allow file-read-metadata${anc}
  (subpath (param "COPY")) (subpath (param "TMP")) (subpath (param "PUB_CACHE")) (subpath (param "FLUTTER_ROOT")))\n`;
  const extra = [...new Set(ports)].filter((p) => Number.isInteger(p) && p > 0 && p < 65536 && !FIXED_DENY_PORTS.includes(p)).sort((a, b) => a - b);
  if (extra.length) {
    // 나가는 연결과 함께 그 포트에 대신 리슨하기(가로채기)도 막는다
    text += `\n;; 실행 직전에 열려 있던 포트 ${extra.length}개(sandboxed-run.mjs 가 덧붙임) — 연결·가로채기 둘 다\n(deny network-outbound\n${extra.map((p) => `  (remote ip "localhost:${p}")`).join("\n")})\n`;
    for (const op of ["network-bind", "network-inbound"]) text += `(deny ${op}\n${extra.map((p) => `  (local ip "localhost:${p}")`).join("\n")})\n`;
  }
  return text;
}

export function toolArgv(tool, args, flutter, dirs) {
  if (!Array.isArray(args) || !args.every((a) => typeof a === "string")) throw new SandboxError("bad_args", "인자는 글자 배열");
  if (tool === "dart") return [flutter.dart, ...args];
  if (tool !== "flutter") throw new SandboxError("bad_args", `도구는 flutter·dart 만: ${tool}`);
  const a = [...args];
  if (!FLUTTER_SUBCOMMANDS.has(a[0])) throw new SandboxError("bad_args", `flutter ${a[0] ?? "(없음)"} 는 격리 실행 허용 목록 밖(${[...FLUTTER_SUBCOMMANDS].join("·")})`);
  if (!a.includes("--no-pub")) a.splice(1, 0, "--no-pub");
  // 커버리지 기본 자리(coverage/lcov.info)는 고스톱에서 추적되는 파일이다 — 사본에 쓰면 패치에 섞인다. 임시 폴더로 돌린다.
  if (a[0] === "test" && a.includes("--coverage") && !a.some((x) => x.startsWith("--coverage-path"))) {
    a.push(`--coverage-path=${path.join(dirs.tmp, "coverage", "lcov.info")}`);
  }
  return [flutter.dart, `--packages=${flutter.packages}`, flutter.snapshot, "--suppress-analytics", "--no-version-check", ...a];
}

function sandboxEnv({ tmp, flutter, pubCache, env, aiPolicyDir = null }) {
  const lang = /^[A-Za-z0-9_.@-]{1,40}$/.test(env.LANG ?? "") ? env.LANG : "en_US.UTF-8";
  return {
    ...(aiPolicyDir ? { AI_POLICY_DIR: aiPolicyDir } : {}), // 고스톱 AI 결정 비교(§4②) 출력 자리 — 임시 폴더 안만(아래 검사)
    HOME: path.join(tmp, "home"),
    TMPDIR: `${path.join(tmp, "t")}/`,
    PATH: "/usr/bin:/bin", // flutter 도구가 which 로 찾는다(aapt). 찾아도 실행은 프로필이 막는다
    LANG: lang,
    FLUTTER_ROOT: flutter.root,
    PUB_CACHE: pubCache,
    FLUTTER_SUPPRESS_ANALYTICS: "true",
    FLUTTER_ALREADY_LOCKED: "true", // SDK bin/cache/lockfile 에 쓰지 않는다(격리에서 SDK 는 읽기 전용)
  };
}

// 격리 실행 명세를 만든다(아직 띄우지 않는다). 시험은 이것으로 argv·env·프로필을 확인한다.
export function sandboxCommand({ copy, tmp, tool = "flutter", args = [], flutterRoot, pubCache, home = realHome(), roots, ports, env = process.env, aiPolicyDir = null } = {}) {
  if (process.platform !== "darwin") throw new SandboxError("not_darwin", "sandbox-exec 는 맥 전용이다");
  if (!fs.existsSync(SANDBOX_EXEC)) throw new SandboxError("no_sandbox_exec", `${SANDBOX_EXEC} 가 없다`);
  const flutter = locateFlutter({ flutterRoot, env });
  let pc = pubCache || env.PUB_CACHE || path.join(home, ".pub-cache");
  try { pc = real(pc); } catch { throw new SandboxError("no_pub_cache", `pub 캐시가 없다: ${pc}`); }
  const h = real(home);
  const dirs = checkDirs({ copy, tmp, home: h, flutterRoot: flutter.root, pubCache: pc, roots: roots ?? defaultRoots(home) });
  for (const d of ["home", "t"]) fs.mkdirSync(path.join(dirs.tmp, d), { recursive: true, mode: 0o700 });
  // AI 결정 비교 출력 자리: 임시 폴더 아래의 이름 하나(만들어 준다). 사본·홈 쪽을 가리키지 못하게 이름만 받는다.
  let aiDir = null;
  if (aiPolicyDir != null) {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,40}$/.test(String(aiPolicyDir))) throw new SandboxError("bad_args", `--ai-policy-dir 는 임시 폴더 아래 이름 하나: ${aiPolicyDir}`);
    aiDir = path.join(dirs.tmp, String(aiPolicyDir));
    fs.mkdirSync(aiDir, { recursive: true, mode: 0o700 });
  }
  const anc = homeAncestors(h, [dirs.copy, dirs.tmp, pc, flutter.root]);
  const profile = buildProfile({ ports: ports ?? listeningPorts(), ancestors: anc.length });
  const argv = [
    "-p", profile,
    "-D", `COPY=${dirs.copy}`, "-D", `TMP=${dirs.tmp}`, "-D", `FLUTTER_ROOT=${flutter.root}`, "-D", `PUB_CACHE=${pc}`, "-D", `HOME_DIR=${h}`,
    ...anc.flatMap((a, i) => ["-D", `ANC${i}=${a}`]),
    ...toolArgv(tool, args, flutter, dirs),
  ];
  return { bin: SANDBOX_EXEC, argv, cwd: dirs.copy, env: sandboxEnv({ tmp: dirs.tmp, flutter, pubCache: pc, env, aiPolicyDir: aiDir }), profile, dirs, flutter, pubCache: pc };
}

// pid 아래 자손 전부(ps 한 번으로 나무를 만든다). 격리 안 프로세스는 우리 자식의 자손뿐이다.
function descendants(pid) {
  const r = spawnSync("/bin/ps", ["-A", "-o", "pid=,ppid="], { encoding: "utf8" });
  const kids = new Map();
  for (const line of (r.stdout ?? "").split("\n")) {
    const [c, p] = line.trim().split(/\s+/).map(Number);
    if (!c) continue;
    if (!kids.has(p)) kids.set(p, []);
    kids.get(p).push(c);
  }
  const out = [];
  const stack = [pid];
  while (stack.length) for (const c of kids.get(stack.pop()) ?? []) { out.push(c); stack.push(c); }
  return out;
}
// 루프백이 아닌 주소(0.0.0.0·::·LAN·Tailscale)로 리슨하는 TCP 소켓 중 pids 의 것. netstat -anv 의 process:pid 칸으로 고른다.
// 왜 감시가 필요한가(10-03 실측): 격리 규칙의 network-bind·inbound 는 주소 자리에 * 나 localhost 만 받고, 0.0.0.0 을 localhost 로 친다.
// 들어오는 연결은 리슨할 때 한 번만 보고 연결마다 상대 주소를 보지 않는다 — 그래서 0.0.0.0 에 리슨하면 LAN 에서 붙어 사본(비공개 소스)을 받아 갈 수 있다.
const isLoopbackAddr = (a) => /^127\.\d+\.\d+\.\d+\.\d+$/.test(a) || /^::1\.\d+$/.test(a) || /%lo0\.\d+$/.test(a);
export function nonLoopbackListeners(pids) {
  const want = new Set(pids);
  const out = [];
  // TCP 는 LISTEN 만, UDP 는 바인드된 것 전부(받기만 해도 LAN 에서 들어온다). 열 차례: 주소 · 상대 · (TCP 상태) · 바이트 4칸 · 프로세스:pid
  const RE = { tcp: /^(tcp\S*)\s+\d+\s+\d+\s+(\S+)\s+\S+\s+LISTEN\s+\d+\s+\d+\s+\d+\s+\d+\s+(.*?):(\d+)\s/, udp: /^(udp\S*)\s+\d+\s+\d+\s+(\S+)\s+\S+\s+\d+\s+\d+\s+\d+\s+\d+\s+(.*?):(\d+)\s/ };
  for (const proto of ["tcp", "udp"]) {
    const r = spawnSync("/usr/sbin/netstat", ["-anv", "-p", proto], { encoding: "utf8", timeout: 5000 });
    for (const line of (r.stdout ?? "").split("\n")) {
      const m = RE[proto].exec(line.trim());
      if (m && want.has(Number(m[4])) && !isLoopbackAddr(m[2])) out.push({ proto, addr: m[2], proc: m[3], pid: Number(m[4]) });
    }
  }
  return out;
}

export function killTree(pid) {
  for (let i = 0; i < 2; i++) { // 끄는 사이 새로 뜬 손주까지 두 번 훑는다
    for (const p of [...descendants(pid).reverse(), pid]) { try { process.kill(p, "SIGKILL"); } catch { /* 이미 끝남 */ } }
  }
}

// 띄워서 끝날 때까지 기다린다. 자식은 우리 프로세스 묶음에 둔다 — 분리 실행 껍데기가 묶음째 끄면 격리 안까지 함께 꺼진다.
// 감시(watchMs 마다): 격리 안 프로세스가 루프백 아닌 주소로 리슨하면 바로 나무째 끄고 violation 을 남긴다(CLI 종료 코드 98).
export function runSandboxed(cmd, { timeoutMs = 30 * 60_000, stdio = "pipe", maxCapture = 4_000_000, watchMs = 500 } = {}) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    const child = spawn(cmd.bin, cmd.argv, { cwd: cmd.cwd, env: cmd.env, stdio: stdio === "inherit" ? ["ignore", "inherit", "inherit"] : ["ignore", "pipe", "pipe"] });
    let out = "", err = "", timedOut = false, violation = null, closed = false;
    const watch = watchMs > 0 ? setInterval(() => {
      if (closed || violation) return;
      const bad = nonLoopbackListeners([child.pid, ...descendants(child.pid)]);
      if (bad.length) { violation = `nonloopback_listen ${bad.map((b) => `${b.proc}:${b.pid}@${b.addr}`).join(",")}`; killTree(child.pid); }
    }, watchMs) : null;
    if (stdio !== "inherit") {
      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      child.stdout.on("data", (d) => { if (out.length < maxCapture) out += d; });
      child.stderr.on("data", (d) => { if (err.length < maxCapture) err += d; });
    }
    const timer = setTimeout(() => { timedOut = true; killTree(child.pid); }, timeoutMs);
    const onSig = (sig) => () => { killTree(child.pid); process.exit(128 + os.constants.signals[sig]); };
    const handlers = ["SIGTERM", "SIGINT", "SIGHUP"].map((s) => [s, onSig(s)]);
    for (const [s, h] of handlers) process.on(s, h);
    const done = (code, signal) => {
      closed = true;
      clearTimeout(timer);
      if (watch) clearInterval(watch);
      for (const [s, h] of handlers) process.off(s, h);
      resolve({ code, signal, stdout: out, stderr: err, timedOut, violation, ms: Date.now() - t0 });
    };
    child.on("error", (e) => { err += `\nLG-SANDBOX spawn: ${e.message}`; done(EXIT_SETUP, null); });
    child.on("close", done);
  });
}

// 탐침을 격리 안에서 돌린다(사본·임시 폴더는 실제 실행과 같은 것). ops: [{op, a:[…]}] → [{op, a, ok, err}]
export async function runProbes(opts, ops, { timeoutMs = 60_000 } = {}) {
  const probeDir = path.join(opts.tmp, ".lg-probe");
  fs.mkdirSync(probeDir, { recursive: true, mode: 0o700 });
  const probe = path.join(probeDir, "probe.dart");
  fs.copyFileSync(PROBE, probe); // 격리 안에서는 저장소(홈 아래)를 못 읽는다 — 임시 폴더로 옮겨 둔다
  const cmd = sandboxCommand({ ...opts, tool: "dart", args: [probe, JSON.stringify(ops)] });
  const r = await runSandboxed(cmd, { timeoutMs });
  const line = r.stdout.trim().split("\n").pop() ?? "";
  try { return JSON.parse(line); } catch {
    throw new SandboxError("probe_failed", `탐침 출력이 JSON 이 아니다(code ${r.code}): ${(r.stderr || r.stdout).slice(0, 300)}`);
  }
}

// 운영 점검: 격리가 이 기기·이 OS 판에서 실제로 막는지 1초 안팎으로 확인한다(OS 갱신으로 규칙 뜻이 바뀌면 닫힌 쪽으로 멈추게).
// 막혀야 할 것이 하나라도 되면 ok:false. 그래프는 ok:false 면 시험을 돌리지 않고 보류한다.
export async function canary(opts) {
  const home = opts.home ?? realHome();
  const tag = crypto.randomBytes(4).toString("hex");
  const tmp = real(opts.tmp);
  const must = [
    { op: "net", a: ["1.1.1.1", "443"], why: "공인 IP" },
    { op: "net", a: ["127.0.0.1", "18789"], why: "게이트웨이 포트" },
    { op: "write", a: [path.join(home, `.lg-canary-${tag}`)], why: "홈 쓰기" },
    // .git 이 없는 사본(1a·1b 사본은 역사가 없다)은 '.git' 이름 자체를 만들어 본다 — 같은 규칙(subpath …/.git)이 막아야 한다(1b 통합 실측: 없던 폴더 아래 쓰기는 ENOENT 라 판정 불가였다)
    { op: "write", a: [fs.existsSync(path.join(real(opts.copy), ".git")) ? path.join(real(opts.copy), ".git", `lg-canary-${tag}`) : path.join(real(opts.copy), ".git")], why: ".git 쓰기" },
    { op: "read", a: [home], why: "홈 목록 읽기" },
    { op: "exec", a: ["/usr/bin/git", "--version"], why: "git 실행" },
  ];
  const ok = [{ op: "write", a: [path.join(tmp, "t", `lg-canary-${tag}`)], why: "임시 폴더 쓰기(대조군)" }];
  const res = await runProbes(opts, [...must, ...ok].map(({ op, a }) => ({ op, a })));
  const failures = [];
  must.forEach((m, i) => {
    const r = res[i];
    // 막힘은 '권한 없음'이어야 한다 — '연결 거부'는 격리가 아니라 그 포트에 아무도 없어서다(그것도 실패로 본다, 판정을 못 하니까).
    if (!r || r.ok || !/not permitted/i.test(r.err ?? "")) failures.push(`${m.why}: ${r?.ok ? "됐다" : r?.err ?? "결과 없음"}`);
  });
  ok.forEach((m, i) => { const r = res[must.length + i]; if (!r?.ok) failures.push(`${m.why}: 안 됐다(${r?.err ?? "결과 없음"})`); });
  for (const f of [path.join(home, `.lg-canary-${tag}`), path.join(tmp, "t", `lg-canary-${tag}`)]) { try { fs.unlinkSync(f); } catch { /* 없음 */ } }
  // 막혀야 할 '.git' 만들기가 됐다면(격리 고장) 그 파일은 치운다 — 폴더(진짜 .git)는 건드리지 않는다
  try { const g = path.join(real(opts.copy), ".git"); if (fs.lstatSync(g).isFile()) fs.unlinkSync(g); } catch { /* 없음 */ }
  return { ok: failures.length === 0, failures, results: res };
}

function parseCli(argv) {
  const o = { args: [], timeoutSec: 1800, canary: false };
  let i = 0;
  for (; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--") { i++; break; }
    if (a === "--copy") o.copy = argv[++i];
    else if (a === "--tmp") o.tmp = argv[++i];
    else if (a === "--timeout-sec") o.timeoutSec = Number(argv[++i]);
    else if (a === "--canary") o.canary = true;
    else if (a === "--ai-policy-dir") o.aiPolicyDir = argv[++i];
    else throw new SandboxError("bad_args", `모르는 인자: ${a}`);
  }
  if (!o.copy || !o.tmp) throw new SandboxError("bad_args", "--copy·--tmp 가 있어야 한다");
  if (!(o.timeoutSec > 0 && o.timeoutSec <= 86_400)) throw new SandboxError("bad_args", "--timeout-sec 1~86400");
  if (!o.canary) { o.tool = argv[i]; o.args = argv.slice(i + 1); }
  return o;
}

async function main() {
  let o;
  try {
    o = parseCli(process.argv.slice(2));
    if (o.canary) {
      const r = await canary({ copy: o.copy, tmp: o.tmp });
      process.stdout.write(`${JSON.stringify({ ok: r.ok, failures: r.failures })}\n`);
      process.exit(r.ok ? 0 : 3);
    }
    const cmd = sandboxCommand({ copy: o.copy, tmp: o.tmp, tool: o.tool, args: o.args, aiPolicyDir: o.aiPolicyDir ?? null });
    const r = await runSandboxed(cmd, { timeoutMs: o.timeoutSec * 1000, stdio: "inherit" });
    if (r.violation) { process.stderr.write(`LG-SANDBOX violation: ${r.violation} — 격리 안 프로세스를 모두 껐다\n`); process.exit(EXIT_VIOLATION); }
    if (r.timedOut) { process.stderr.write(`LG-SANDBOX timeout: ${o.timeoutSec}초를 넘겨 격리 안 프로세스를 모두 껐다\n`); process.exit(EXIT_TIMEOUT); }
    process.exit(r.code ?? (r.signal ? 128 + (os.constants.signals[r.signal] ?? 0) : EXIT_SETUP));
  } catch (e) {
    process.stderr.write(`LG-SANDBOX ${e.code ?? "error"}: ${e.message}\n`);
    process.exit(EXIT_SETUP);
  }
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main();
