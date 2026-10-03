// run.mjs(lib) — 그래프 노드가 명령을 실행하는 유일한 입구: run(cmdId, params). (맨 위 run.mjs 는 실행기 CLI 다 — 다른 파일)
// - cmdId 는 cmd-registry.json 의 허용 목록에서만 고른다. 모드(shadow·live)별로 허용이 다르다. 정규식 금지 목록은 쓰지 않는다.
// - 인자는 목록이 정한 자리({이름})에만 들어가고, 자리마다 정규식으로 검사한다. 셸을 거치지 않는다(spawn 배열).
// - effect:true 인 명령(커밋·푸시·배포 같은 부수효과)은 effect(key, kind, fn) 안에서만 돈다.
// - OpenClaw CLI·셸·인터프리터 -c 는 목록에 올릴 수 없다(S15 — 노드에서 오픈클로를 다시 부르지 않는다).
// 그래프 파일은 child_process 를 직접 쓰지 못한다(scripts/check-graph-rules.mjs 가 막는다) — 명령은 이 입구로만.
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { effectScope } from "./effects.mjs";
import { allowSpawn } from "./guard.mjs";

export class CmdNotAllowed extends Error {
  constructor(msg) { super(msg); this.name = "CmdNotAllowed"; this.codeDefect = true; }
}

const ID_RE = /^[a-z][a-z0-9-]*(\.[a-z0-9-]+)+$/;
const MODES = new Set(["shadow", "live"]);
// 목록에 올릴 수 없는 실행 파일(이름 기준): 셸·env·osascript 는 아무 명령이나 돌릴 수 있고, openclaw 는 이중 지휘다(S15).
const BANNED_BIN = /^(sh|bash|zsh|dash|ksh|fish|csh|tcsh|env|osascript|openclaw|sudo|su|launchctl|crontab)$/;
const INTERP_BIN = /^(node|python[0-9.]*|ruby|perl|php|deno|bun|osascript)$/;
const EVAL_FLAG = /^(-c|-e|--eval|-p|--print|-r|--require|--import|-m)$/;
// OpenClaw CLI 자체를 가리키는 항목(파일 이름이 openclaw·openclaw.mjs, 또는 openclaw 패키지 안의 스크립트).
// 경로에 '.openclaw' 가 든 것(작업 공간·런타임 폴더)은 막지 않는다 — 1a 명령은 그 아래 사본을 인자로 받는다.
const OPENCLAW_CLI = (a) => /^openclaw(\.[cm]?js)?$/i.test(path.basename(String(a))) || /\/node_modules\/openclaw\//i.test(String(a));
const BASE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin";

function bad(msg) { throw new Error(`cmd-registry: ${msg}`); }

// 공개 저장소에 사용자 홈 경로가 박히지 않게 bin·argv 의 '~/' 는 이 기기 홈으로 펼친다(펼친 뒤 같은 검사를 받는다).
const home = (p) => (typeof p === "string" && p.startsWith("~/") ? path.join(os.homedir(), p.slice(2)) : p);
function expandHome(c) {
  if (!c || typeof c !== "object") return c;
  return { ...c, bin: home(c.bin), ...(Array.isArray(c.argv) ? { argv: c.argv.map(home) } : {}) };
}

// 목록을 읽고 검사한다. 하나라도 어긋나면 전부 거부한다(반쯤 맞는 목록을 쓰지 않는다).
// 파일이 없으면 빈 목록(아무 명령도 허용하지 않음 — 닫힌 쪽으로 실패)이다. 깨진 파일은 오류다.
export function loadRegistry(file) {
  let j;
  try { j = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) {
    if (e.code === "ENOENT") return { version: 1, file, commands: {}, missing: true };
    bad(`읽지 못함 ${file}: ${e.message}`);
  }
  if (j?.version !== 1 || typeof j.commands !== "object" || !j.commands) bad("version 1 · commands 객체가 있어야 한다");
  const commands = {};
  for (const [id, raw] of Object.entries(j.commands)) {
    const c = expandHome(raw);
    if (!ID_RE.test(id)) bad(`cmdId 형식(영소문자.점): ${id}`);
    if (typeof c?.bin !== "string" || !path.isAbsolute(c.bin)) bad(`${id}: bin 은 절대경로`);
    const base = path.basename(c.bin);
    if (BANNED_BIN.test(base) || OPENCLAW_CLI(c.bin)) bad(`${id}: ${base} 는 목록에 올릴 수 없다(셸·env·OpenClaw CLI 금지)`);
    const argv = c.argv ?? [];
    if (!Array.isArray(argv) || !argv.every((a) => typeof a === "string")) bad(`${id}: argv 는 글자 배열`);
    if (argv.some(OPENCLAW_CLI)) bad(`${id}: argv 에 OpenClaw CLI 금지`);
    if (INTERP_BIN.test(base) && (argv.some((a) => EVAL_FLAG.test(a)) || !argv[0] || argv[0].startsWith("{") || !path.isAbsolute(argv[0]))) {
      bad(`${id}: 인터프리터는 고정된 절대경로 스크립트로만(-c·-e 같은 즉석 코드 금지)`);
    }
    const params = c.params ?? {};
    const slots = new Set();
    for (const a of [...argv, c.cwd ?? ""]) {
      const m = /^\{([a-z][a-z0-9_]*)\}$/.exec(a);
      if (m) slots.add(m[1]);
      else if (/[{}]/.test(a)) bad(`${id}: 자리 표시는 항목 전체가 {이름} 이어야 한다: ${a}`);
    }
    for (const s of slots) if (typeof params[s] !== "string") bad(`${id}: 자리 {${s}} 의 정규식(params.${s})이 없다`);
    for (const p of Object.keys(params)) if (!slots.has(p)) bad(`${id}: 쓰지 않는 params.${p}`);
    for (const [p, re] of Object.entries(params)) {
      if (!re.startsWith("^") || !re.endsWith("$")) bad(`${id}: params.${p} 정규식은 ^…$ 로 전체를 맞춰야 한다`);
      try { new RegExp(re); } catch (e) { bad(`${id}: params.${p} 정규식 오류 ${e.message}`); }
    }
    const modes = c.modes ?? [];
    if (!Array.isArray(modes) || !modes.length || !modes.every((m) => MODES.has(m))) bad(`${id}: modes 는 shadow·live 중 하나 이상`);
    if (c.effect === true && modes.includes("shadow")) bad(`${id}: effect 명령은 그림자 모드에 올리지 않는다(그림자에서는 effect 가 실행하지 않는다)`);
    const envPass = c.envPass ?? [];
    if (!Array.isArray(envPass) || envPass.some((k) => !/^[A-Z][A-Z0-9_]*$/.test(k) || /TOKEN|SECRET|KEY|PASS|AUTH|COOKIE|PAT|WEBHOOK|CRED|URL|PRIVATE|SESSION|SIGN|CERT|ANTHROPIC|CLAUDE|LANGSMITH|LANGCHAIN|OPENCLAW/.test(k))) {
      bad(`${id}: envPass 는 대문자 이름이고 비밀류(TOKEN·KEY·SECRET…)는 넘기지 않는다`);
    }
    const timeoutSec = c.timeoutSec ?? 120;
    if (!(Number.isFinite(timeoutSec) && timeoutSec > 0 && timeoutSec <= 3600)) bad(`${id}: timeoutSec 1~3600`);
    // 분리 실행 최대 시간(설계 §6). 껍데기의 시간 제한(timeoutSec)이 먼저 걸리게 그보다 커야 한다. 없으면 LG_DETACH_MAX_SEC.
    const maxSeconds = c.maxSeconds ?? null;
    if (maxSeconds !== null && !(Number.isFinite(maxSeconds) && maxSeconds > timeoutSec && maxSeconds <= 86_400)) {
      bad(`${id}: maxSeconds 는 timeoutSec(${timeoutSec})보다 크고 86400 이하`);
    }
    commands[id] = { id, bin: c.bin, argv, params, modes, effect: c.effect === true, cwd: c.cwd ?? null, envPass, timeoutSec, maxSeconds,
      detach: c.detach === true, desc: String(c.desc ?? "") };
  }
  return { version: 1, file, commands };
}

// 목록 항목 + 인자 → 실제 argv·cwd·env. 검사에 걸리면 CmdNotAllowed(코드 결함 — 재시도해도 같다).
export function resolveCommand(registry, cmdId, params = {}, { mode, inEffect = false, scratch, parentEnv = process.env } = {}) {
  const c = registry.commands[cmdId];
  if (!c) throw new CmdNotAllowed(`허용 목록에 없는 명령: ${cmdId}`);
  if (!c.modes.includes(mode)) throw new CmdNotAllowed(`${cmdId} 는 ${mode} 모드에서 허용되지 않는다(허용: ${c.modes.join(",")})`);
  if (c.effect && !inEffect) throw new CmdNotAllowed(`${cmdId} 는 부수효과 명령 — effect(key, kind, fn) 안에서만 실행한다`);
  if (params == null || typeof params !== "object" || Array.isArray(params)) throw new CmdNotAllowed(`${cmdId}: 인자는 {이름: 값} 객체`);
  for (const k of Object.keys(params)) if (!(k in c.params)) throw new CmdNotAllowed(`${cmdId}: 모르는 인자 ${k}`);
  const fill = (a) => {
    const m = /^\{([a-z][a-z0-9_]*)\}$/.exec(a);
    if (!m) return a;
    const v = params[m[1]];
    if (typeof v !== "string" && typeof v !== "number") throw new CmdNotAllowed(`${cmdId}: 인자 ${m[1]} 가 없다`);
    const s = String(v);
    if (!new RegExp(c.params[m[1]]).test(s)) throw new CmdNotAllowed(`${cmdId}: 인자 ${m[1]} 값이 형식에 맞지 않는다`);
    return s;
  };
  const argv = c.argv.map(fill);
  const cwd = c.cwd ? fill(c.cwd) : scratch;
  const env = { PATH: BASE_PATH, HOME: os.userInfo().homedir, LANG: parentEnv.LANG || "en_US.UTF-8", TMPDIR: os.tmpdir(), USER: os.userInfo().username };
  for (const k of c.envPass) if (parentEnv[k] != null) env[k] = parentEnv[k];
  return { cmd: c, bin: c.bin, argv, cwd, env, timeoutMs: c.timeoutSec * 1000, maxMs: c.maxSeconds == null ? null : c.maxSeconds * 1000 };
}

// 돌고 있는 동기 명령 자식들 — 실행기가 신호로 끝나면 함께 끈다(고아로 남아 틱 밖에서 계속 돌지 않게. 분리 실행은 제외).
const children = new Set();
export function killRunChildren() {
  for (const c of children) { try { c.kill("SIGTERM"); } catch { /* 이미 끝남 */ } }
}

// 동기 실행(끝날 때까지 기다림). 출력은 받아서 돌려준다(표준 출력에 직접 닿지 않게). 긴 명령은 launch(분리 실행)로.
function exec({ bin, argv, cwd, env, timeoutMs }) {
  return new Promise((resolve, reject) => {
    const t0 = Date.now();
    const child = allowSpawn(() => spawn(bin, argv, { cwd, env, stdio: ["ignore", "pipe", "pipe"] }));
    children.add(child);
    let out = "", err = "", timedOut = false;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (d) => { if (out.length < 1_000_000) out += d; });
    child.stderr.on("data", (d) => { if (err.length < 200_000) err += d; });
    const timer = setTimeout(() => { timedOut = true; child.kill("SIGTERM"); setTimeout(() => child.kill("SIGKILL"), 5000).unref(); }, timeoutMs);
    child.on("error", (e) => { clearTimeout(timer); children.delete(child); reject(e); });
    child.on("close", (code, signal) => { clearTimeout(timer); children.delete(child); resolve({ code, signal, stdout: out, stderr: err, timedOut, durationMs: Date.now() - t0 }); });
  });
}

// 스레드 하나에 묶인 run(). 그래프 build 에 넘긴다.
// timeLeft: 틱 안에서만 — 잡 시간 상한까지 남은 ms. 명령 시간 제한을 그 안으로 줄이고(넘으면 끈다), 30초도 못 남으면 다음 틱으로(pending).
export function createRun({ cfg, registry, thread, mode, timeLeft = null }) {
  const scratch = path.join(cfg.stateDir, "jobs", thread, "_scratch");
  return async function run(cmdId, params = {}) {
    const inEffect = !!effectScope.getStore();
    const r = resolveCommand(registry, cmdId, params, { mode, inEffect, scratch });
    const left = timeLeft?.();
    if (left != null) {
      const room = left - 20_000;
      if (room < 30_000) throw Object.assign(new Error("잡 시간 상한이 가까워 다음 틱에 실행한다"), { pending: true });
      r.timeoutMs = Math.min(r.timeoutMs, room);
    }
    if (r.cwd === scratch) fs.mkdirSync(scratch, { recursive: true, mode: 0o700 }); // 목록이 정한 작업 폴더는 만들지 않는다(있어야 한다)
    return exec(r);
  };
}
