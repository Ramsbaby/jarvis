// claude.mjs — 그래프 노드가 Claude 를 부르는 유일한 길.
// - 이 맥의 로그인(키체인)을 그대로 쓴다. API 키·토큰을 넘기거나 만들거나 출력하지 않는다.
// - 격리(0b 실측, 10-03 haiku 4회): `--restricted` 로 부른다. 사용자·프로젝트 설정 파일과 그 안의 훅, 사용자 규칙(~/.claude/rules)·
//   ~/CLAUDE.md 가 실리지 않고(입력 9,161 → 3,695 토큰, 홈 아래 작업 폴더에서도 3,700), 명령 실행 도구가 빠지며, 파일 도구는
//   작업 폴더 밖을 읽지 못한다(홈·/etc 읽기 거부 확인). 구독 로그인으로 호출된다. 옛 `--setting-sources project` 는 규칙이 실렸다(0a 위험 1).
//   작업 폴더 기본값은 홈 밖 임시 폴더(빈 폴더, /var/folders/…) — 앞으로 CLI 가 바뀌어 상위 폴더 CLAUDE.md 를 다시 찾더라도 홈 것을 줍지 않게.
//   --bare 는 훅을 끄지만 로그인 인증을 못 쓴다(API 키 전용) — 그래서 쓰지 않는다.
// - 스레드당·하루당 호출 상한, 하루 토큰 상한을 넘으면 LlmBudgetHeld → 실행기가 그 스레드를 '보류'로 둔다.
// - 로그인 만료·사용량 한도는 오류 문구로 판정해 보류하고 표식(llm-hold.json)을 남긴다 → 다음 틱 관문이 쉰다. 재시도로 세지 않는다.
// - 응답의 usage(입력·출력·캐시 토큰)와 total_cost_usd 를 장부(하루 상한)와 metrics.jsonl(판정 M6)에 남긴다.
// - Fable(최상위) 모델은 막는다 — 한도를 가장 빨리 쓴다. 허용은 haiku·sonnet·opus 계열뿐.
// - 긴 호출(opus 수정 등)은 launchAsk → checkAsk 두 노드로 분리 실행한다(lib/detach.mjs).
import { spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import * as detach from "./detach.mjs";
import { allowSpawn } from "./guard.mjs";

// held = true 인 오류는 실행기가 '보류'(HELD, 종료 0)로 처리한다. holdReason 은 보류 까닭(관문·재시도 판단에 쓴다).
// holdRef: 이 값이 그대로인 동안 틱은 그 스레드를 다시 돌리지 않는다(하루 상한 = 날짜, 스레드 상한 = 상한 값) — 노드 앞부분을 틱마다 되풀이하지 않게
export class LlmBudgetHeld extends Error {
  constructor(msg, reason = "llm_day", ref = null) { super(msg); this.name = "LlmBudgetHeld"; this.held = true; this.holdReason = reason; this.holdRef = ref; }
}
export class LlmAuthHeld extends Error {
  constructor(msg) { super(msg); this.name = "LlmAuthHeld"; this.held = true; this.holdReason = "login"; }
}
export class LlmLimitHeld extends Error {
  constructor(msg) { super(msg); this.name = "LlmLimitHeld"; this.held = true; this.holdReason = "usage_limit"; }
}
export class LlmModelBlocked extends Error {
  constructor(msg) { super(msg); this.name = "LlmModelBlocked"; this.codeDefect = true; }
}

const ALLOWED_MODEL = /^(haiku|sonnet|opus)$|^claude-(haiku|sonnet|opus)-[0-9a-z.-]+$/;
const ALLOWED_TOOLS = new Set(["Read", "Grep", "Glob", "Edit", "Write"]); // --restricted 가 이들도 작업 폴더 안에 가둔다

// 로그인 만료 — 감지기(orchestrator-scan.py LLM_AUTH_FAIL)와 같은 문구에 CLI 가 내는 몇 가지를 더했다.
export const LOGIN_FAIL = /Failed to authenticate|authentication_failed|authentication_error|OAuth session expired|OAuth (?:access )?token has expired|could not be refreshed|oauth_not_allowed|Invalid API key|Please run \/login|Not logged in/i;
// 사용량 한도(429) — 로그인 고장이 아니다(09-30 감지기 오판 전례). 쉬었다가 다시 한다.
export const LIMIT_FAIL = /usage limit|rate_limit_error|rate limit|\b429\b|limit reached|out of extra usage/i;

export function classifyLlmFailure(text) {
  const s = String(text ?? "");
  if (LOGIN_FAIL.test(s)) return "login";
  if (LIMIT_FAIL.test(s)) return "usage_limit";
  return null;
}

export function checkModel(model) {
  const m = String(model ?? "").trim().toLowerCase();
  if (!m || /fable/.test(m) || !ALLOWED_MODEL.test(m)) {
    throw new LlmModelBlocked(`모델 차단: ${model || "(빈 값)"} — haiku·sonnet·opus 계열만 쓴다(Fable 금지)`);
  }
  return m;
}
export function checkTools(tools) {
  if (!Array.isArray(tools)) throw new LlmModelBlocked("tools 는 배열");
  for (const t of tools) if (!ALLOWED_TOOLS.has(t)) throw new LlmModelBlocked(`도구 차단: ${t} — Read·Grep·Glob(·Edit·Write)만, 명령 실행·웹 도구 금지`);
  return tools;
}

// jsonSchema: 구조화 출력(--json-schema). 객체를 받아 JSON 글자로 넘긴다. --tools 는 값을 여러 개 받으므로 맨 뒤에 둔다.
export function claudeArgs(model, tools = [], { jsonSchema = null } = {}) {
  return [
    "-p", "--restricted", "--strict-mcp-config", "--no-session-persistence",
    "--output-format", "json", "--model", model, "--disable-slash-commands",
    ...(jsonSchema ? ["--json-schema", typeof jsonSchema === "string" ? jsonSchema : JSON.stringify(jsonSchema)] : []),
    "--tools", ...(tools.length ? tools : [""]), // 기본은 도구 없음. 프롬프트는 표준 입력으로 준다
  ];
}

// 자식에게 줄 환경변수: 로그인 조회에 필요한 최소한만. ANTHROPIC_*·CLAUDE*·LANGSMITH_*·LANGCHAIN_*·프록시·NODE_OPTIONS 는 넘기지 않는다.
const PASS = ["USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ"];
export function cleanEnv(bin, parent = process.env) {
  const env = { HOME: os.userInfo().homedir }; // 진짜 홈 — 로그인은 여기에 묶여 있다(HOME 을 바꾼 시험 환경에서도)
  for (const k of PASS) if (parent[k]) env[k] = parent[k];
  env.USER ??= os.userInfo().username;
  env.PATH = [...new Set([path.dirname(bin), path.dirname(process.execPath), "/usr/bin", "/bin", "/usr/sbin", "/sbin"])].join(":");
  return env;
}

export function resolveClaudeBin(explicit, parent = process.env) {
  const candidates = explicit ? [explicit] : [
    ...String(parent.PATH ?? "").split(":").filter(Boolean).map((d) => path.join(d, "claude")),
    path.join(os.userInfo().homedir, ".local", "bin", "claude"),
  ];
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); if (fs.statSync(c).isFile()) return c; } catch { /* 다음 후보 */ }
  }
  throw new Error(explicit ? `LG_CLAUDE_BIN 실행 불가: ${explicit}` : "claude 실행 파일을 찾지 못함 — LG_CLAUDE_BIN 으로 지정");
}

// 홈 밖 임시 폴더. TMPDIR 은 쓰지 않는다 — OpenClaw 는 TMPDIR 을 홈 아래(~/.openclaw/tmp)로 잡는다(0b 시험이 잡음).
// 맥의 사용자 전용 임시 폴더(getconf DARWIN_USER_TEMP_DIR, /var/folders/…/T)가 정본, 없으면 /private/tmp.
let tempBase = null;
function outsideHomeTemp() {
  if (tempBase) return tempBase;
  const home = fs.realpathSync(os.userInfo().homedir);
  const r = allowSpawn(() => spawnSync("/usr/bin/getconf", ["DARWIN_USER_TEMP_DIR"], { encoding: "utf8", env: { PATH: "/usr/bin:/bin" } }));
  for (const c of [r.status === 0 ? r.stdout.trim() : "", "/private/tmp", "/tmp"].filter(Boolean)) {
    try { const real = fs.realpathSync(c); if (real !== home && !real.startsWith(`${home}/`)) return (tempBase = real); } catch { /* 다음 후보 */ }
  }
  throw new Error("홈 밖 임시 폴더를 찾지 못함");
}
// 빈 폴더(700, 내 것, 심볼릭 링크 아님). 비어 있지 않거나 모양이 이상하면 새 빈 폴더를 만든다.
export function defaultClaudeCwd() {
  const base = outsideHomeTemp();
  const dir = path.join(base, `lg-claude-cwd-${process.getuid()}`);
  try { fs.mkdirSync(dir, { mode: 0o700 }); } catch (e) { if (e.code !== "EEXIST") throw e; }
  const st = fs.lstatSync(dir);
  if (!st.isDirectory() || st.uid !== process.getuid() || (st.mode & 0o077) || fs.readdirSync(dir).length) {
    return fs.mkdtempSync(path.join(base, "lg-claude-cwd-"));
  }
  return dir;
}

// 돌고 있는 claude 자식들. 실행기가 시간 초과 신호로 끝나도 자식이 고아로 남아 한도를 쓰지 않게 함께 끈다(분리 실행은 제외).
const children = new Set();
export function killActiveChildren() {
  for (const c of children) { try { c.kill("SIGTERM"); } catch { /* 이미 끝남 */ } }
}

function run(bin, args, { env, cwd, input, timeoutMs }) {
  return new Promise((resolve, reject) => {
    const child = allowSpawn(() => spawn(bin, args, { env, cwd, stdio: ["pipe", "pipe", "pipe"] }));
    children.add(child);
    let out = "", err = "", timedOut = false;
    child.stdout.setEncoding("utf8"); // 조각 경계에 걸린 한글 바이트를 깨지 않게(문자열 디코더가 이어 붙인다)
    child.stderr.setEncoding("utf8");
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      setTimeout(() => child.kill("SIGKILL"), 5000).unref();
    }, timeoutMs);
    child.stdout.on("data", (d) => { if (out.length < 10_000_000) out += d; });
    child.stderr.on("data", (d) => { if (err.length < 65_536) err += d; });
    child.on("error", (e) => { clearTimeout(timer); children.delete(child); reject(e); });
    child.on("close", (code, signal) => { clearTimeout(timer); children.delete(child); resolve({ code, signal, out, err, timedOut }); });
    child.stdin.on("error", () => { /* 자식이 먼저 끝나면 EPIPE — close 에서 판정한다 */ });
    child.stdin.end(input);
  });
}

// 응답 JSON 의 토큰·비용. 모델별(modelUsage)이 있으면 모두 더한다(보조 모델 호출까지), 없으면 usage.
export function usageOf(j) {
  const mu = j?.modelUsage && typeof j.modelUsage === "object" ? Object.values(j.modelUsage) : [];
  const n = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);
  if (mu.length && mu.some((m) => m && ("inputTokens" in m || "outputTokens" in m))) {
    const s = { in: 0, out: 0, cacheCreate: 0, cacheRead: 0 };
    for (const m of mu) { s.in += n(m.inputTokens); s.out += n(m.outputTokens); s.cacheCreate += n(m.cacheCreationInputTokens); s.cacheRead += n(m.cacheReadInputTokens); }
    return { ...s, costUsd: j.total_cost_usd ?? null };
  }
  const u = j?.usage ?? {};
  return { in: n(u.input_tokens), out: n(u.output_tokens), cacheCreate: n(u.cache_creation_input_tokens), cacheRead: n(u.cache_read_input_tokens), costUsd: j?.total_cost_usd ?? null };
}

// 출력 판정: { ok, text, models, usage, kind?, msg? }. kind = login · usage_limit · fable · error
export function judge(res) {
  if (res.timedOut) return { ok: false, kind: "error", msg: `claude 시간 초과(${Math.round(res.timeoutMs / 1000)}초)` };
  let j;
  try { j = JSON.parse(res.out); } catch {
    const head = (res.err || res.out || "").trim().split("\n")[0].slice(0, 160);
    const kind = classifyLlmFailure(`${res.err}\n${res.out}`) ?? "error";
    return { ok: false, kind, msg: `claude 출력이 JSON 이 아니다(코드 ${res.code ?? res.signal}): ${head}` };
  }
  const models = Object.keys(j.modelUsage ?? {});
  const usage = usageOf(j);
  if (models.some((k) => /fable/i.test(k))) return { ok: false, kind: "fable", msg: `응답 모델이 Fable 이다: ${models.join(",")}`, models, usage };
  if (j.is_error || j.subtype !== "success") {
    const text = String(j.result ?? "");
    return { ok: false, kind: classifyLlmFailure(text) ?? "error", msg: `claude 오류(${j.subtype ?? "?"}): ${text.slice(0, 160)}`, models, usage };
  }
  // --json-schema 를 준 호출은 structured_output 에 검증된 객체가 온다(없으면 null — 그래프가 본문에서 다시 찾는다)
  const structured = j.structured_output && typeof j.structured_output === "object" ? j.structured_output : null;
  return { ok: true, text: String(j.result ?? ""), structured, models, usage, costUsd: j.total_cost_usd ?? null, durationMs: j.duration_ms ?? null };
}

// 스레드 하나에 묶인 호출기. 실행기가 그래프를 만들 때 넘긴다.
// timeLeft: 틱 안에서만 — 잡 시간 상한까지 남은 ms. 호출 시간 제한을 그 안으로 줄이고, 30초도 못 남으면 다음 틱으로 미룬다(pending).
//   틱 끝 무렵 시작한 호출이 잡 상한(600초)에 걸려 통째로 죽고 토큰만 쓰는 것을 막는다(R12). 긴 호출은 launchAsk 로.
export const fitTimeout = (timeoutMs, timeLeft) => {
  const left = timeLeft?.();
  if (left == null) return timeoutMs;
  const room = left - 20_000;
  if (room < 30_000) throw Object.assign(new Error("잡 시간 상한이 가까워 다음 틱에 부른다"), { pending: true });
  return Math.min(timeoutMs, room);
};

export function createClaude({ store, cfg, now, thread, metric = () => {}, timeLeft = null }) {
  const setHold = (reason, msg) => {
    try { fs.writeFileSync(cfg.llmHoldPath, JSON.stringify({ reason, at: now(), detail: String(msg).slice(0, 200) }), { mode: 0o600 }); } catch { /* 관문은 다음 실패 때 다시 */ }
  };
  const clearHold = () => { try { fs.rmSync(cfg.llmHoldPath, { force: true }); } catch { /* 없음 */ } };
  const reserve = ({ model, node }) => {
    const r = store.reserveLlmCall({ thread, node, model, now: now(), perThread: cfg.llm.perThread, perDay: cfg.llm.perDay, dayTokenCap: cfg.llm.dayTokenCap });
    if (!r.ok) throw new LlmBudgetHeld(r.reason, r.kind, r.ref);
    return r.id;
  };
  const record = (callId, { node, model, v, ms, detached = false }) => {
    if (v.usage) store.recordLlmUsage(callId, v.usage);
    const u = v.usage ?? {};
    metric("llm", {
      thread, node, model, models: v.models ?? [], ok: v.ok, kind: v.ok ? undefined : v.kind, detached, ms,
      in: u.in ?? 0, out: u.out ?? 0, cache_create: u.cacheCreate ?? 0, cache_read: u.cacheRead ?? 0,
      total: (u.in ?? 0) + (u.out ?? 0) + (u.cacheCreate ?? 0) + (u.cacheRead ?? 0), cost_usd: u.costUsd ?? null,
    });
    if (v.ok) clearHold();
    else if (v.kind === "login" || v.kind === "usage_limit") setHold(v.kind, v.msg);
  };
  const prep = ({ model, tools, cwd, jsonSchema }) => {
    const m = checkModel(model);
    checkTools(tools);
    if (jsonSchema != null && (typeof jsonSchema !== "object" || Array.isArray(jsonSchema) || JSON.stringify(jsonSchema).length > 16_384)) {
      throw new LlmModelBlocked("jsonSchema 는 16KB 이하의 JSON Schema 객체");
    }
    if (!cwd && tools.some((t) => t === "Edit" || t === "Write")) throw new LlmModelBlocked("쓰기 도구(Edit·Write)는 작업 폴더(cwd — 사본)를 직접 줘야 한다 — 공용 빈 폴더에 쓰지 않는다");
    const bin = resolveClaudeBin(cfg.llm.bin);
    const dir = cwd ?? defaultClaudeCwd();
    if (!path.isAbsolute(dir) || !fs.statSync(dir, { throwIfNoEntry: false })?.isDirectory()) throw new LlmModelBlocked(`작업 폴더가 없다: ${dir}`);
    return { m, bin, dir };
  };
  return {
    // 동기 호출 — 틱 예산 안에 끝나는 짧은 호출(haiku 분류·요약). 긴 것은 launchAsk/checkAsk.
    async ask(prompt, { model = cfg.llm.defaultModel, node = "?", tools = [], timeoutMs = cfg.llm.timeoutMs, cwd, jsonSchema = null } = {}) {
      const { m, bin, dir } = prep({ model, tools, cwd, jsonSchema });
      const tmo = fitTimeout(timeoutMs, timeLeft);
      const callId = reserve({ model: m, node });
      const t0 = Date.now();
      const res = await run(bin, claudeArgs(m, tools, { jsonSchema }), { env: cleanEnv(bin), cwd: dir, input: String(prompt), timeoutMs: tmo });
      const v = judge({ ...res, timeoutMs: tmo });
      record(callId, { node, model: m, v, ms: Date.now() - t0 });
      if (v.ok) return { text: v.text, structured: v.structured, models: v.models, costUsd: v.costUsd, durationMs: v.durationMs, usage: v.usage };
      if (v.kind === "fable") throw new LlmModelBlocked(v.msg);
      if (v.kind === "login") throw new LlmAuthHeld(`클로드 로그인 만료로 보인다 — ${v.msg}`);
      if (v.kind === "usage_limit") throw new LlmLimitHeld(`클로드 사용량 한도 — ${v.msg}`);
      throw new Error(v.msg);
    },
    // 분리 실행: 같은 (노드, 시도)는 한 번만 띄운다. 돌려주는 handle 을 상태에 넣고 다음 노드에서 check 한다.
    // 최대 시간(maxMs)은 기본 시간 제한의 1.5배(15분 → 22.5분, 설계 §6) — 넘기면 checkAsk 가 묶음째 끄고 dead(timeout).
    launchAsk(prompt, { model = cfg.llm.defaultModel, node, attempt = 1, tools = [], timeoutMs = 15 * 60_000, maxMs = detach.defaultMaxMs(timeoutMs), cwd, jsonSchema = null } = {}) {
      const { m, bin, dir } = prep({ model, tools, cwd, jsonSchema });
      const ids = { thread, node, attempt, cmdId: "claude.ask" };
      if (fs.existsSync(detach.jobDir(cfg.jobsDir, ids))) return { dir: detach.jobDir(cfg.jobsDir, ids), ...ids, already: true };
      const callId = reserve({ model: m, node });
      const h = detach.launch(cfg.jobsDir, ids, { bin, argv: claudeArgs(m, tools, { jsonSchema }), cwd: dir, env: cleanEnv(bin), stdinText: String(prompt), timeoutMs, maxMs });
      if (!h.already) fs.writeFileSync(path.join(h.dir, "llm.json"), JSON.stringify({ callId, model: m, node }), { mode: 0o600 });
      return h;
    },
    // done 이면 { state:"done", text, … } · 실패면 { state:"failed", kind, error } · 그 밖은 running · dead. 던지지 않는다 —
    // 다시 띄울지(시도 + 1)는 그래프가 정한다. 로그인·한도 실패는 표식을 남겨 다음 틱 관문이 쉰다. 토큰은 한 번만 적는다.
    checkAsk(handle) {
      const st = detach.check(handle);
      if (st.state !== "done") return st;
      const info = JSON.parse(fs.readFileSync(path.join(handle.dir, "llm.json"), "utf8"));
      const res = { code: st.code, signal: st.signal, timedOut: st.timedOut, timeoutMs: 0, out: detach.readOutput(handle, "stdout", 10_000_000), err: detach.readOutput(handle, "stderr", 65_536) };
      const v = judge(res);
      let first = false;
      try { fs.writeFileSync(path.join(handle.dir, "recorded"), "1", { flag: "wx", mode: 0o600 }); first = true; } catch { /* 이미 적음 */ }
      if (first) record(info.callId, { node: info.node, model: info.model, v, ms: (st.endedAt ?? 0) - (st.startedAt ?? 0), detached: true });
      if (v.ok) return { state: "done", text: v.text, structured: v.structured, models: v.models, costUsd: v.costUsd, usage: v.usage };
      return { state: "failed", kind: v.kind, error: v.msg };
    },
  };
}
