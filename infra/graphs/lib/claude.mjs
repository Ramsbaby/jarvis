// claude.mjs — 그래프 노드가 Claude 를 부르는 유일한 길.
// - 이 맥의 로그인(키체인)을 그대로 쓴다. API 키·토큰을 넘기거나 만들거나 출력하지 않는다.
// - 사용자 훅·MCP·세션 기록이 돌지 않게 project 설정만 읽고(--setting-sources project), 빈 폴더에서, 깨끗한 환경변수로 부른다(위험 7·8).
//   --bare 는 훅을 끄지만 로그인 인증을 못 쓴다(API 키 전용) — 그래서 쓰지 않는다.
// - 스레드당·하루당 호출 상한을 넘으면 LlmBudgetHeld 를 던진다 → 실행기가 그 스레드를 '보류'로 둔다(retry 로 이어감).
// - Fable(최상위) 모델은 막는다 — 한도를 가장 빨리 쓴다. 허용은 haiku·sonnet·opus 계열뿐.
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// held = true 인 오류는 실행기가 '보류'(HELD, 종료 0)로 처리한다. 다른 노드도 같은 표시로 보류할 수 있다(예: 디스크 부족).
export class LlmBudgetHeld extends Error {
  constructor(msg) { super(msg); this.name = "LlmBudgetHeld"; this.held = true; }
}
export class LlmModelBlocked extends Error {
  constructor(msg) { super(msg); this.name = "LlmModelBlocked"; }
}

const ALLOWED_MODEL = /^(haiku|sonnet|opus)$|^claude-(haiku|sonnet|opus)-[0-9a-z.-]+$/;

export function checkModel(model) {
  const m = String(model ?? "").trim().toLowerCase();
  if (!m || /fable/.test(m) || !ALLOWED_MODEL.test(m)) {
    throw new LlmModelBlocked(`모델 차단: ${model || "(빈 값)"} — haiku·sonnet·opus 계열만 쓴다(Fable 금지)`);
  }
  return m;
}

export function claudeArgs(model, tools = []) {
  return [
    "-p", "--setting-sources", "project", "--strict-mcp-config", "--no-session-persistence",
    "--output-format", "json", "--model", model, "--disable-slash-commands",
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

// 돌고 있는 claude 자식들. 실행기가 시간 초과 신호로 끝나도 자식이 고아로 남아 한도를 쓰지 않게 함께 끈다.
const children = new Set();
export function killActiveChildren() {
  for (const c of children) { try { c.kill("SIGTERM"); } catch { /* 이미 끝남 */ } }
}

function run(bin, args, { env, cwd, input, timeoutMs }) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { env, cwd, stdio: ["pipe", "pipe", "pipe"] });
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

// 스레드 하나에 묶인 호출기. 실행기가 그래프를 만들 때 넘긴다.
export function createClaude({ store, cfg, now, thread }) {
  return {
    async ask(prompt, { model = cfg.llm.defaultModel, node = "?", tools = [], timeoutMs = cfg.llm.timeoutMs } = {}) {
      const m = checkModel(model);
      const r = store.reserveLlmCall({ thread, node, model: m, now: now(), perThread: cfg.llm.perThread, perDay: cfg.llm.perDay });
      if (!r.ok) throw new LlmBudgetHeld(r.reason);
      const bin = resolveClaudeBin(cfg.llm.bin);
      const cwd = path.join(cfg.stateDir, "claude-cwd"); // 빈 폴더 — project 설정·훅이 없다
      fs.mkdirSync(cwd, { recursive: true, mode: 0o700 });
      const res = await run(bin, claudeArgs(m, tools), { env: cleanEnv(bin), cwd, input: String(prompt), timeoutMs });
      if (res.timedOut) throw new Error(`claude 시간 초과(${Math.round(timeoutMs / 1000)}초)`);
      let j;
      try { j = JSON.parse(res.out); } catch {
        throw new Error(`claude 출력이 JSON 이 아니다(코드 ${res.code ?? res.signal}): ${(res.err || res.out).trim().split("\n")[0].slice(0, 160)}`);
      }
      const used = Object.keys(j.modelUsage ?? {});
      if (used.some((k) => /fable/i.test(k))) throw new LlmModelBlocked(`응답 모델이 Fable 이다: ${used.join(",")}`);
      if (j.is_error || j.subtype !== "success") throw new Error(`claude 오류(${j.subtype ?? "?"}): ${String(j.result ?? "").slice(0, 160)}`);
      return { text: String(j.result ?? ""), models: used, costUsd: j.total_cost_usd ?? null, durationMs: j.duration_ms ?? null };
    },
  };
}
