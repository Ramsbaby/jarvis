// check-interrupt.test.mjs — interrupt 노드 정적 검사기의 양성(잡아야 할 것)·음성(잡으면 안 되는 것).
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { checkSource, checkFile } from "../scripts/check-interrupt-nodes.mjs";
import { ROOT, NODE, sandbox } from "./helpers.mjs";

const HEAD = `import fs from "node:fs";\nimport { StateGraph, interrupt } from "@langchain/langgraph";\n`;
const rules = (src) => checkSource(src).problems.map((p) => `${p.node}:${p.rule}`).sort();

test("양성: interrupt 노드 안의 LLM 호출·await 를 잡는다", () => {
  const src = `${HEAD}export const build = (llm) => new StateGraph(S)
  .addNode("approve", async (s) => {
    const draft = (await llm.ask("초안")).text;
    const d = interrupt({ question: "승인?", draft });
    return { d };
  });`;
  assert.deepEqual(rules(src), ["approve:await", "approve:llm"]);
});

test("양성: 같은 파일 도우미 함수를 거친 파일 쓰기도 따라가서 잡는다", () => {
  const src = `${HEAD}function trace(n) { fs.appendFileSync("t.log", n); }
function ask(s) { trace("ask"); return interrupt({ question: "승인?" }); }
export const g = new StateGraph(S).addNode("approve", (s) => ({ decision: ask(s) }));`;
  assert.deepEqual(rules(src), ["approve:fs"]);
});

test("양성: try/catch·별칭 import·발송·다른 모듈 함수", () => {
  const src = `import { interrupt as pause } from "@langchain/langgraph";
import { postReport } from "../lib/report.mjs";
const g = x.addNode("gate", (s) => {
  try { const v = pause("승인?"); postReport(v); return { v }; } catch (e) { return {}; }
});`;
  assert.deepEqual(rules(src), ["gate:import", "gate:send", "gate:try"]);
});

test("양성: 검사할 수 없는 노드 모양과 노드 밖 interrupt 도 위반", () => {
  const src = `${HEAD}import { approveNode } from "./nodes.mjs";
const g = x.addNode("a", approveNode).addNode("b", makeNode());
export function orphan() { return interrupt("누가 부르나?"); }`;
  assert.deepEqual(rules(src), ["?:outside", "a:unanalyzable", "b:unanalyzable"]);
});

test("음성: 순수한 interrupt 노드, 문자열·주석 속 낱말, interrupt 없는 노드의 부수효과는 통과", () => {
  const src = `${HEAD}// approve 노드에서 fetch( 나 await llm.ask( 를 부르면 안 된다 — 주석은 무시
const re = /await fetch\\(/;
export const g = new StateGraph(S)
  .addNode("think", async (s) => { fs.writeFileSync("x", "y"); return { draft: (await llm.ask("q")).text }; })
  .addNode("approve", (s) => {
    const decision = interrupt({ question: "await fetch( 같은 글자는 문자열일 뿐", draft: \`초안 \${s.draft} — llm.ask(\` });
    return { decision, log: [\`approve:\${decision}\`] };
  });`;
  const r = checkSource(src);
  assert.deepEqual(r.problems, []);
  assert.deepEqual(r.interruptNodes, ["approve"]);
});

test("음성: 실제 graphs/ 폴더는 위반 0 (CLI, 종료 코드 0)", () => {
  const r = spawnSync(NODE, [path.join(ROOT, "scripts", "check-interrupt-nodes.mjs")], { cwd: ROOT, encoding: "utf8" });
  assert.equal(r.status, 0, r.stdout);
  assert.match(r.stdout, /^OK interrupt-nodes 파일 \d+개 · interrupt 노드 [1-9]\d*개 · 위반 0/);
});

test("양성: CLI 는 위반 파일에 종료 코드 1, 실행기는 그런 그래프를 시작하지 않는다", (t) => {
  const sb = sandbox(t);
  const bad = path.join(sb.dir, "bad.mjs");
  fs.writeFileSync(bad, `${HEAD}const g = x.addNode("approve", (s) => { console.log("두 번 찍힘"); return { d: interrupt("승인?") }; });\n`);
  const r = spawnSync(NODE, [path.join(ROOT, "scripts", "check-interrupt-nodes.mjs"), bad], { encoding: "utf8" });
  assert.equal(r.status, 1);
  assert.match(r.stdout, /\[approve\] console/);

  // 실행기 사본의 graphs/ 에 위반 그래프를 넣으면 start 가 거부된다
  const app = path.join(sb.dir, "app");
  for (const f of ["run.mjs", "package.json", "lib", "graphs", "scripts"]) fs.cpSync(path.join(ROOT, f), path.join(app, f), { recursive: true });
  fs.symlinkSync(path.join(ROOT, "node_modules"), path.join(app, "node_modules"));
  const smoke = fs.readFileSync(path.join(app, "graphs", "smoke.mjs"), "utf8");
  fs.writeFileSync(path.join(app, "graphs", "badsmoke.mjs"),
    smoke.replace('const decision = interrupt(', 'fs.appendFileSync("/dev/null", "x");\n      const decision = interrupt('));
  const s = spawnSync(NODE, [path.join(app, "run.mjs"), "start", "badsmoke", "b1"], { env: sb.env, encoding: "utf8" });
  assert.equal(s.status, 1);
  assert.match(s.stdout, /^ERROR b1 internal 그래프 규칙 위반/);
});

// ── 반대편 검토(10-03)가 실행으로 보인 빈틈 ─────────────────────────────
test("검토 양성: 다른 모듈에 숨긴 interrupt 는 그래프가 가져오면 위반(파일 단위 검사)", (t) => {
  const sb = sandbox(t);
  fs.mkdirSync(path.join(sb.dir, "lib"));
  fs.writeFileSync(path.join(sb.dir, "lib", "approval.mjs"), `import { interrupt } from "@langchain/langgraph";\nexport const askOwner = (q) => interrupt({ question: q });\n`);
  const g = path.join(sb.dir, "g.mjs");
  fs.writeFileSync(g, `import { askOwner } from "./lib/approval.mjs";\nconst x = y.addNode("think", async (s) => { const d = (await llm.ask("초안")).text; return { d, ok: askOwner(d) }; });\n`);
  assert.deepEqual(checkFile(g).problems.map((p) => p.rule), ["helper-interrupt"]);
  assert.deepEqual(checkSource(fs.readFileSync(g, "utf8")).problems, [], "한 파일만 보면 못 잡는다 — 그래서 파일 단위로 따라간다");
});

test("검토 양성: 노드 안 하위 그래프 invoke, 허용 목록 밖 메서드, bind 로 감춘 LLM, interrupt 별칭, 정적 중단점", () => {
  assert.deepEqual(rules(`${HEAD}const g = x.addNode("think", async (s) => { const d = (await llm.ask("q")).text; return { r: await gate.invoke({ d }) }; });`), ["think:subgraph"]);
  // 바깥 객체(io)·bind 로 감춘 함수(think)는 '바깥 값' 규칙이 먼저 잡는다
  assert.deepEqual(rules(`${HEAD}const g = x.addNode("approve", (s) => { io.save(s.draft); return { d: interrupt("승인?") }; });`), ["approve:outer"]);
  assert.deepEqual(rules(`${HEAD}const think = llm.ask.bind(llm);\nconst g = x.addNode("approve", (s) => ({ d: interrupt(think("새 초안")) }));`), ["approve:outer"]);
  assert.deepEqual(rules(`${HEAD}const g = x.addNode("approve", (s) => { const d = s.box; d.save(); return { d: interrupt("승인?") }; });`), ["approve:call"], "지역 값이어도 허용 목록 밖 메서드는 위반");
  assert.deepEqual(rules(`${HEAD}const pause = interrupt;\nconst g = x.addNode("approve", (s) => ({ d: pause("승인?") }));`), ["?:alias"]);
  assert.deepEqual(rules(`${HEAD}const g = x.addNode("publish", (s) => ({ ok: 1 })).compile({ checkpointer, interruptBefore: ["publish"] });`), ["?:breakpoint"]);
});

test("검토 음성: 허용 목록 안의 순수 계산만 하는 interrupt 노드는 통과", () => {
  const src = `${HEAD}const g = x.addNode("approve", (s) => {
    const list = s.items.map((i) => String(i).trim()).filter(Boolean).join(", ");
    const meta = JSON.stringify({ n: Math.max(1, s.items.length), at: new Date(0).toISOString() });
    const decision = interrupt({ question: \`\${list} 반영?\`, meta, keys: Object.keys(s).sort() });
    return { decision: decision?.toString?.() ?? "rejected" };
  });`;
  assert.deepEqual(checkSource(src).problems, []);
});

// ── 반대편 재검토(10-03)가 보인 우회로 ────────────────────────────────
test("재검토 양성: 다시 내보내기(barrel)로 가져온 interrupt — 노드도 interrupt 노드로 알아보고, 가져온 모듈도 위반", (t) => {
  const sb = sandbox(t);
  fs.mkdirSync(path.join(sb.dir, "lib"));
  fs.writeFileSync(path.join(sb.dir, "lib", "lg.mjs"), `export { interrupt, StateGraph } from "@langchain/langgraph";\n`);
  const g = path.join(sb.dir, "g.mjs");
  fs.writeFileSync(g, `import { interrupt } from "./lib/lg.mjs";\nconst x = y.addNode("approve", async (s) => { const d = (await llm.ask("초안")).text; return { ok: interrupt(d) }; });\n`);
  assert.deepEqual(checkFile(g).problems.map((p) => `${p.node}:${p.rule}`).sort(), ["?:helper-interrupt", "approve:await", "approve:llm"]);
});

test("재검토 양성: 이름만 넘긴 함수(map(relay)), 바깥 객체의 허용 이름 메서드(api.get), 네임스페이스 구조분해, stdio inherit", () => {
  assert.deepEqual(rules(`${HEAD}function relay(m) { notifyOwner(m); }
const g = x.addNode("approve", (s) => { [s.msg].map(relay); return { d: interrupt("승인?") }; });`), ["approve:send"]);
  assert.deepEqual(rules(`${HEAD}const api = makeClient();
const g = x.addNode("approve", (s) => { const v = api.get("/x"); return { d: interrupt(v) }; });`), ["approve:outer"]);
  assert.deepEqual(rules(`import * as lg from "@langchain/langgraph";\nconst { interrupt } = lg;\nconst g = x.addNode("approve", (s) => ({ d: interrupt("승인?") }));`).filter((r) => r.endsWith("alias")).length > 0, true);
  assert.deepEqual(rules(`${HEAD}import { execFileSync } from "node:child_process";
const g = x.addNode("test", (s) => { execFileSync("/bin/echo", ["x"], { stdio: "inherit" }); return {}; });`), ["?:stdout"]);
});

test("최종 검토 양성: 바깥 객체를 지역 변수로 옮겨 부르기, 경로 별칭 import, 모듈 상수도 interrupt 노드에선 위반", () => {
  assert.deepEqual(rules(`${HEAD}const client = makeClient();
const g = x.addNode("approve", (s) => { const c = client; c.get("/notify"); return { d: interrupt("승인?") }; });`), ["approve:outer"]);
  assert.deepEqual(rules(`${HEAD}import { askOwner } from "#lib/approval.mjs";\nconst g = x.addNode("think", (s) => ({ ok: askOwner(s) }));`), ["?:import-alias"]);
  assert.deepEqual(rules(`${HEAD}const Q = "승인?";\nconst g = x.addNode("approve", (s) => ({ d: interrupt(Q) }));`), ["approve:outer"]);
  assert.deepEqual(rules(`${HEAD}const g = x.addNode("approve", (s) => {
    if (process.env.FLAG === "1") throw new Error("고장");
    const pick = s.ok ? s.a : s.b;
    return { d: interrupt({ question: pick, n: Number(s.n) }) };
  });`), [], "환경변수 읽기·삼항·객체 열쇠·인자는 통과");
});
