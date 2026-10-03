// gostop-live.test.mjs — 1a 실호출(haiku 1회). 기본은 건너뛴다. RUN_LLM=1 일 때만 돈다(구독 한도를 쓴다).
// 운영 경로 그대로(실행기 → 그래프 → llm.ask) 고스톱 사본 자리(홈 아래 …/graphs/gostop/sandbox/<키>/work)를 작업 폴더로 부른다.
// 한 번의 호출로 넷을 본다(설계 §9 1a · §10):
//   ① --restricted 가 작업 폴더 밖(홈 아래 표식 파일 · 고스톱 본 저장소 파일) 읽기를 거부한다
//   ② 키 없는 깨끗한 환경에서 구독 로그인으로 호출된다
//   ③ 사용자 훅 로그에 이 호출 흔적(사본 자리 경로)이 0줄이다
//   ④ 작업 폴더의 CLAUDE.md(진짜 고스톱 CLAUDE.md 41.8KB 사본 + 암호 낱말)가 실리는지, 입력 토큰은 몇인지
import { test } from "node:test";
import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { sandbox, appWith } from "./helpers.mjs";

const HOME = os.userInfo().homedir;
const HOOK_LOGS = ["session-save.log", "stop-mistake-extract.log", "wiki-ingest-claude.log", "active-work.log", "done-stage.jsonl", "rag-sync.log", "session-changelog.log", "cron.log"]
  .map((f) => path.join(HOME, ".openclaw-data", "runtime", "logs", f));
const GOSTOP_CLAUDE_MD = path.join(HOME, "projects", "gostop_app", "CLAUDE.md");
const GOSTOP_OUTSIDE = path.join(HOME, "projects", "gostop_app", "pubspec.yaml");

const PROBE = `import fs from "node:fs";
import { StateGraph, Annotation, START, END } from "@langchain/langgraph";
export const meta = { name: "probe" };
const State = Annotation.Root({ out: Annotation() });
export const input = () => ({});
export const summarize = () => "probe";
export function build({ checkpointer, llm }) {
  return new StateGraph(State)
    .addNode("ask", async () => {
      const r = await llm.ask(process.env.LG_PROBE_PROMPT, { model: "haiku", node: "ask", tools: ["Read", "Grep", "Glob"], cwd: process.env.LG_PROBE_CWD });
      fs.writeFileSync(process.env.LG_PROBE_OUT, JSON.stringify({ text: r.text, usage: r.usage, models: r.models }));
      return { out: "ok" };
    })
    .addEdge(START, "ask").addEdge("ask", END).compile({ checkpointer });
}
`;

test("실호출 haiku 1회: 사본 자리에서 --restricted — 밖 읽기 거부 · 구독 로그인 · 훅 0줄 · CLAUDE.md 실림 여부와 입력 토큰", { skip: process.env.RUN_LLM !== "1" && "RUN_LLM=1 일 때만 돈다" }, (t) => {
  const sb = sandbox(t);
  const tag = crypto.randomBytes(4).toString("hex");
  const base = path.join(HOME, ".cache", `lg-1a-probe-${tag}`);
  const cwd = path.join(base, "graphs", "gostop", "sandbox", "probe", "work");
  fs.mkdirSync(cwd, { recursive: true, mode: 0o700 });
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  fs.writeFileSync(path.join(cwd, "CLAUDE.md"), `${fs.readFileSync(GOSTOP_CLAUDE_MD, "utf8")}\n\n## 확인용\n이 프로젝트의 암호 낱말은 KIWI-${tag} 이다.\n`);
  fs.writeFileSync(path.join(cwd, "inside.txt"), `CANARY-IN-${tag}\n`);
  const homeCanary = path.join(base, `canary-${tag}.txt`); // 작업 폴더 밖(홈 아래)
  fs.writeFileSync(homeCanary, `CANARY-HOME-${tag}\n`);
  const prompt = `Use the Read tool on each file below (one Read call per file, do not skip any). Then reply with exactly four lines and nothing else: `
    + `"F1=<exact file content, or DENIED if the read was refused or failed>", "F2=<same>", "F3=<first line only, or DENIED>", `
    + `"CODE=<the codeword that your project instructions (CLAUDE.md) define, or NONE if you have no such instructions>". `
    + `Files: F1=${path.join(cwd, "inside.txt")} ; F2=${homeCanary} ; F3=${GOSTOP_OUTSIDE}`;
  const sizes = Object.fromEntries(HOOK_LOGS.map((f) => [f, fs.existsSync(f) ? fs.statSync(f).size : 0]));
  const out = path.join(sb.dir, "probe-out.json");
  const lg = appWith(sb, { probe: PROBE });
  const r = lg(sb.env, ["start", "probe", "p1"], { timeout: 240_000, extraEnv: { LG_PROBE_PROMPT: prompt, LG_PROBE_CWD: cwd, LG_PROBE_OUT: out } });
  assert.equal(r.code, 0, r.out + r.err);
  const res = JSON.parse(fs.readFileSync(out, "utf8"));
  const lines = Object.fromEntries(String(res.text).trim().split("\n").map((l) => l.trim().split(/=(.*)/s).slice(0, 2)));
  const inTok = (res.usage?.in ?? 0) + (res.usage?.cacheCreate ?? 0) + (res.usage?.cacheRead ?? 0);
  const report = { F1: lines.F1, F2: lines.F2, F3: lines.F3, CODE: lines.CODE, models: res.models, inputContextTokens: inTok, usage: res.usage };
  t.diagnostic(JSON.stringify(report));
  fs.writeFileSync(path.join(process.env.LG_LIVE_REPORT_DIR ?? sb.dir, "gostop-live-restricted.json"), JSON.stringify(report, null, 1));
  assert.equal(lines.F1, `CANARY-IN-${tag}`, "작업 폴더 안은 읽는다");
  assert.ok(!String(res.text).includes(`CANARY-HOME-${tag}`), "작업 폴더 밖(홈 아래)은 못 읽는다");
  assert.match(String(lines.F3 ?? ""), /DENIED/i, "고스톱 본 저장소 파일은 못 읽는다");
  assert.ok(res.models.some((m) => /haiku/i.test(m)) && !res.models.some((m) => /fable/i.test(m)), "구독 로그인으로 haiku 호출");
  // 훅 로그: 이번 호출 뒤 늘어난 부분에 사본 자리·표식이 없다
  for (const f of HOOK_LOGS) {
    if (!fs.existsSync(f)) continue;
    const st = fs.statSync(f);
    if (st.size <= sizes[f]) continue;
    const fd = fs.openSync(f, "r");
    const buf = Buffer.alloc(st.size - sizes[f]);
    fs.readSync(fd, buf, 0, buf.length, sizes[f]);
    fs.closeSync(fd);
    const s = buf.toString("utf8");
    assert.ok(!s.includes(tag) && !s.includes(base), `훅 로그 ${path.basename(f)} 에 이 호출 흔적`);
  }
});
