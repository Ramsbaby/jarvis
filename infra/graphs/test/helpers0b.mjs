// helpers0b.mjs — 0b 시험 공용(틱·관문·허용 목록·시험 그래프). 0a helpers.mjs 위에 얹는다. 전부 임시 HOME·임시 상태 폴더.
import fs from "node:fs";
import path from "node:path";
import { NODE, FIXTURES } from "./helpers.mjs";
import { readJsonl } from "../lib/metrics.mjs";

export const CMD_FIXTURE = path.join(FIXTURES, "cmd-fixture.mjs");

// KST 스냅샷 머리 시각
const kst = (ms) => new Date(ms + 9 * 3_600_000).toISOString().slice(0, 16).replace("T", " ");

// 감지기 스냅샷(latest.md) 모양 그대로 쓴다 — 관문이 읽는 출처
export function writeUsage(file, { at = Date.now(), week = 50, extra = "", row = true } = {}) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const usage = row ? `| 클로드 사용량 | session 12% · week (all models) ${week}% · week (Fable) 100% |\n` : "";
  fs.writeFileSync(file, `# 자비스 오케스트레이터 스냅샷 — ${kst(at)} KST\n\n| 축 | 값 |\n|---|---|\n| 디스크 | 92% 사용 · 여유 15.4GiB (/System/Volumes/Data) |\n${usage}${extra}`);
  return file;
}

// 관문을 통과하는 틱 환경(디스크 기준 0, 사용량 50%·방금, 야간 금지 끔). over 로 하나씩 바꿔 관문 시험을 한다.
export function tickEnv(sb, { now = Date.now(), usage = {}, over = {} } = {}) {
  const usageFile = path.join(sb.dir, "latest.md");
  writeUsage(usageFile, { at: now, ...usage });
  return {
    ...sb.env, LG_USAGE_FILE: usageFile, LG_DISK_FLOOR_GIB: "0", LG_COPY_EST_GIB: "0", LG_DISK_MARGIN_GIB: "0", LG_QUIET: "",
    LG_HOOK_LOGS: "", ...over,
  };
}

// 시험용 허용 목록(LG_CMD_REGISTRY — 시험 모드에서만 먹는다)
export function writeRegistry(sb, extra = {}) {
  const file = path.join(sb.dir, "cmd-registry.json");
  const commands = {
    "test.append": { bin: NODE, argv: [CMD_FIXTURE, "append", "{file}"], params: { file: "^/[A-Za-z0-9._/-]+$" }, modes: ["live"], effect: true, timeoutSec: 30 },
    "test.sleep": { bin: NODE, argv: [CMD_FIXTURE, "sleep", "{ms}", "{file}"], params: { ms: "^[0-9]{1,6}$", file: "^/[A-Za-z0-9._/-]+$" }, modes: ["shadow", "live"], timeoutSec: 120 },
    "test.echo": { bin: "/bin/echo", argv: ["{word}"], params: { word: "^[a-z]{1,20}$" }, modes: ["shadow", "live"], timeoutSec: 10 },
    "test.liveonly": { bin: "/usr/bin/true", argv: [], modes: ["live"], timeoutSec: 10 },
    ...extra,
  };
  fs.writeFileSync(file, JSON.stringify({ version: 1, commands }, null, 1));
  return file;
}

export const metrics = (sb) => readJsonl(path.join(sb.state, "metrics.jsonl"));
export const effects = (sb) => readJsonl(path.join(sb.state, "effects.jsonl"));
export const lineCount = (f) => (fs.existsSync(f) ? fs.readFileSync(f, "utf8").split("\n").filter(Boolean).length : 0);

const LG = `import fs from "node:fs";\nimport { StateGraph, Annotation, START, END, interrupt } from "@langchain/langgraph";\n`;
const TRACE = `const trace = (n) => { const f = process.env.LG_TEST_MODE === "1" && process.env.LG_SMOKE_TRACE; if (f) fs.appendFileSync(f, \`\${process.pid} \${n}\\n\`); };
const nap = () => new Promise((r) => setTimeout(r, Number(process.env.LG_TEST_STEP_MS ?? 0)));\n`;

// a → b → c → d, 노드마다 LG_TEST_STEP_MS 만큼 쉰다(틱 예산 시험)
export const STEPS = `${LG}${TRACE}
const State = Annotation.Root({ log: Annotation({ reducer: (a, b) => a.concat(b), default: () => [] }) });
export const input = () => ({});
export const summarize = (v) => v.log.join(">");
export function build({ checkpointer }) {
  return new StateGraph(State)
    .addNode("a", async () => { trace("a"); await nap(); return { log: ["a"] }; })
    .addNode("b", async () => { trace("b"); await nap(); return { log: ["b"] }; })
    .addNode("c", async () => { trace("c"); await nap(); return { log: ["c"] }; })
    .addNode("d", async () => { trace("d"); await nap(); return { log: ["d"] }; })
    .addEdge(START, "a").addEdge("a", "b").addEdge("b", "c").addEdge("c", "d").addEdge("d", END)
    .compile({ checkpointer });
}
`;

// 부수효과: act 가 effect("commit:<key>") 안에서 test.append 를 부른다. LG_TEST_FAIL_AFTER_EFFECT=1 이면 effect 뒤에 실패(재실행 유도)
export const FX = `${LG}${TRACE}
const State = Annotation.Root({ key: Annotation(), file: Annotation(), out: Annotation() });
export const input = (f) => ({ key: String(f.topic ?? "k1"), file: String(process.env.LG_TEST_FX_FILE ?? "") });
export const summarize = (v) => String(v.out);
export function build({ checkpointer, tools }) {
  return new StateGraph(State)
    .addNode("act", async (s) => {
      trace("act");
      const r = await tools.effect(\`commit:\${s.key}\`, "commit", () => tools.run("test.append", { file: s.file }));
      if (process.env.LG_TEST_FAIL_AFTER_EFFECT === "1") throw new Error("effect 뒤 일시 오류 흉내");
      return { out: \`\${tools.mode}:\${r.ran ? "ran" : r.shadow ? "shadow" : r.dedup ? "dedup" : "?"}\` };
    })
    .addEdge(START, "act").addEdge("act", END)
    .compile({ checkpointer });
}
`;

// 분리 실행: start_job → wait(진행 중이면 pending) → END
export const DETACHED = `${LG}${TRACE}
const State = Annotation.Root({ ms: Annotation(), file: Annotation(), job: Annotation(), out: Annotation() });
export const input = (f) => ({ ms: String(f.topic ?? "1500"), file: String(process.env.LG_TEST_DONE_FILE ?? "") });
export const summarize = (v) => String(v.out).trim();
export function build({ checkpointer, tools }) {
  return new StateGraph(State)
    .addNode("start_job", (s) => { trace("start_job"); return { job: tools.launch("test.sleep", { ms: s.ms, file: s.file }, { node: "work", attempt: 1 }) }; })
    .addNode("wait", (s) => {
      trace("wait");
      const st = tools.check(s.job);
      if (st.state === "running") throw tools.pending("작업 진행 중");
      if (st.state === "dead") throw new Error("작업이 결과 없이 죽음");
      return { out: \`code=\${st.code} \${tools.output(s.job)}\` };
    })
    .addEdge(START, "start_job").addEdge("start_job", "wait").addEdge("wait", END)
    .compile({ checkpointer });
}
`;

// 실패 흉내: LG_TEST_FAIL = transient(같은 오류) · type(코드 결함) · held(노드 보류) · 없음(성공)
export const FLAKY = `${LG}${TRACE}
const State = Annotation.Root({ out: Annotation() });
export const input = () => ({});
export const summarize = (v) => String(v.out);
export function build({ checkpointer, tools }) {
  return new StateGraph(State)
    .addNode("work", (s) => {
      trace("work");
      const m = process.env.LG_TEST_FAIL;
      if (m === "transient") throw new Error("일시 오류 흉내 #" + process.pid);
      if (m === "type") { const x = undefined; return { out: x.boom }; }
      if (m === "held") throw tools.hold("디스크 부족 흉내", "node");
      return { out: "ok" };
    })
    .addEdge(START, "work").addEdge("work", END)
    .compile({ checkpointer });
}
`;
