#!/usr/bin/env node
// check-graph-rules.mjs — 그래프 파일의 실행 규칙 정적 검사(S10·S15). interrupt 노드 검사(check-interrupt-nodes.mjs)와 함께 돈다.
// 규칙(그래프 파일 + 그 파일이 상대 경로로 가져오는 모듈 전부):
//   child-process  child_process 를 가져오거나(import·require·동적 import) process.binding 을 쓰면 위반 — 명령은 run(cmdId) 입구로만
//   cmd-unknown    run(…)·launch(…) 의 첫 인자가 허용 목록(cmd-registry.json)에 없는 cmdId 면 위반
//   cmd-literal    첫 인자가 글자값이 아니면 위반(정적으로 확인할 수 없다)
//   effect-scope   effect:true 명령(커밋·푸시 등)을 effect( … ) 인자 밖에서 부르면 위반
//   store          랭그래프 Store(자체 기억 장치)를 쓰면 위반(S15 — 기억층 겹침)
//   lib-import     실행기 내부 모듈(lib/·scripts/)을 가져오면 위반 — 도구는 build({ tools }) 로 받는다(입구 우회 방지)
//   network        fetch·http·https·net·tls·dgram·undici·WebSocket 을 쓰면 위반 — 노드는 오픈클로·밖과 직접 말하지 않는다(S15)
// 한계(정직): 정규식·괄호 짝 수준이다. 그래서 실행기 쪽에도 같은 규칙을 실행 때 한 번 더 건다(run 의 허용 목록·effect 범위 확인).
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { strip } from "./check-interrupt-nodes.mjs";
import { loadRegistry } from "../lib/run.mjs";

const HERE = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const INTERNAL = [path.join(HERE, "lib"), path.join(HERE, "scripts")];

const CLOSE = { "(": ")", "[": "]", "{": "}" };
function matchBracket(code, i) {
  const stack = [];
  for (let k = i; k < code.length; k++) {
    const ch = code[k];
    if (CLOSE[ch]) stack.push(CLOSE[ch]);
    else if (ch === ")" || ch === "]" || ch === "}") { if (stack.pop() !== ch) return -1; if (!stack.length) return k; }
  }
  return -1;
}

// 원문 src 의 i 자리부터 글자값 하나를 읽는다(따옴표·${} 없는 템플릿). 아니면 null.
function literalAt(src, i) {
  while (i < src.length && /\s/.test(src[i])) i++;
  const q = src[i];
  if (q !== '"' && q !== "'" && q !== "`") return null;
  let j = i + 1, s = "";
  while (j < src.length && src[j] !== q) {
    if (src[j] === "\\") return null;
    if (q === "`" && src[j] === "$" && src[j + 1] === "{") return null;
    s += src[j++];
  }
  return j < src.length ? s : null;
}

function specsOf(src, code) {
  const out = [];
  for (const m of src.matchAll(/import\s+([^;]*?)\s+from\s*["']([^"']+)["']|import\s*["']([^"']+)["']|export\s*(?:\{[^}]*\}|\*(?:\s*as\s+[\w$]+)?)\s*from\s*["']([^"']+)["']/g)) {
    if (code[m.index] !== "i" && code[m.index] !== "e") continue;
    out.push({ index: m.index, clause: m[1] ?? "", spec: m[2] ?? m[3] ?? m[4] });
  }
  for (const m of src.matchAll(/\bimport\s*\(\s*["']([^"']+)["']\s*\)|\brequire\s*\(\s*["']([^"']+)["']\s*\)/g)) {
    if (code[m.index] === "i" || code[m.index] === "r") out.push({ index: m.index, clause: "", spec: m[1] ?? m[2], dynamic: true });
  }
  return out;
}

const NET_MODULES = /^(node:)?(http|https|http2|net|tls|dgram|dns)$|^(undici|ws|axios|node-fetch|got)$/;

export function checkGraphSource(src, file, registry, { resolveImport } = {}) {
  const code = strip(src);
  const lineOf = (idx) => src.slice(0, idx).split("\n").length;
  const problems = [];
  const seen = new Set(); // 같은 줄의 같은 규칙은 한 번만
  const report = (idx, rule, message) => {
    const line = lineOf(idx);
    if (seen.has(`${line}:${rule}`)) return;
    seen.add(`${line}:${rule}`);
    problems.push({ file, line, node: "-", rule, message });
  };

  for (const im of specsOf(src, code)) {
    if (/^(node:)?child_process$/.test(im.spec)) report(im.index, "child-process", "child_process 직접 사용 금지 — 명령은 run(cmdId, 인자) 입구로만(허용 목록)");
    if (NET_MODULES.test(im.spec)) report(im.index, "network", `${im.spec} 금지 — 노드는 네트워크·오픈클로와 직접 말하지 않는다(S15)`);
    if (/^@langchain\//.test(im.spec) && (/store/i.test(im.spec) || /\b\w*Store\b/.test(im.clause))) {
      report(im.index, "store", "랭그래프 Store 금지(S15) — 기억은 오픈클로 메모리 한 곳");
    }
    const target = resolveImport?.(im.spec);
    if (target && INTERNAL.some((d) => target === d || target.startsWith(`${d}${path.sep}`))) {
      report(im.index, "lib-import", `실행기 내부 모듈(${path.relative(HERE, target)}) 가져오기 금지 — 도구는 build({ llm, tools }) 로 받는다`);
    }
  }
  for (const m of code.matchAll(/\bchild_process\b|\bprocess\s*\.\s*(?:binding|_linkedBinding|dlopen)\s*\(/g)) report(m.index, "child-process", "child_process·process.binding 금지");
  for (const m of code.matchAll(/\b(?:InMemoryStore|BaseStore|AsyncBatchedStore|PostgresStore|SqliteStore|MemoryStore)\b|\bgetStore\s*\(/g)) {
    report(m.index, "store", "랭그래프 Store 금지(S15)");
  }
  for (const m of code.matchAll(/\bcompile\s*\(/g)) {
    const close = matchBracket(code, m.index + m[0].length - 1);
    const inner = close > 0 ? code.slice(m.index, close) : "";
    const k = /\bstore\s*:/.exec(inner);
    if (k) report(m.index + k.index, "store", "compile({ store }) 금지(S15)");
  }
  for (const m of code.matchAll(/\bfetch\s*\(|\bWebSocket\b|\bXMLHttpRequest\b|\bEventSource\b/g)) report(m.index, "network", "네트워크 호출 금지(S15) — 필요한 것은 허용 목록 명령으로");

  // effect( … ) 인자 범위 — effect:true 명령은 이 안에서만
  const effectRanges = [];
  for (const m of code.matchAll(/(?<![\w$])effect\s*\(/g)) {
    const open = m.index + m[0].length - 1;
    const close = matchBracket(code, open);
    if (close > 0) effectRanges.push([open, close]);
  }
  for (const m of code.matchAll(/(?<![\w$])(run|launch)\s*\(/g)) {
    const open = m.index + m[0].length - 1;
    // 같은 파일에서 run·launch 라는 이름의 함수를 정의하면 검사가 흐려진다 — 정의 자리는 건너뛰지 않고 위반으로 본다
    if (/\bfunction\s*$/.test(code.slice(0, m.index))) { report(m.index, "cmd-literal", `${m[1]} 라는 이름의 함수 정의 금지 — 도구 이름과 겹친다`); continue; }
    const id = literalAt(src, open + 1);
    if (id == null) { report(m.index, "cmd-literal", `${m[1]}() 의 첫 인자는 허용 목록 cmdId 글자값이어야 한다(변수·조합 금지)`); continue; }
    const c = registry.commands[id];
    if (!c) { report(m.index, "cmd-unknown", `허용 목록에 없는 cmdId: ${id}`); continue; }
    if (c.effect && !effectRanges.some(([a, b]) => m.index > a && m.index < b)) {
      report(m.index, "effect-scope", `${id} 는 부수효과 명령 — effect(key, kind, () => run("${id}", …)) 안에서만`);
    }
  }
  return problems;
}

// 그래프 파일 하나 + 상대 경로로 가져오는 모듈(재귀). 돌려주는 값: [{file,line,node,rule,message}]
export function checkGraphFile(file, registry, label = file) {
  const problems = [];
  const seen = new Set();
  const queue = [path.resolve(file)];
  while (queue.length) {
    const f = queue.shift();
    if (seen.has(f)) continue;
    seen.add(f);
    let src;
    try { src = fs.readFileSync(f, "utf8"); } catch { continue; }
    const dir = path.dirname(f);
    const resolveImport = (spec) => {
      if (!/^\.{1,2}\//.test(spec)) return null;
      const base = path.resolve(dir, spec);
      return [base, `${base}.mjs`, `${base}.js`, path.join(base, "index.mjs")].find((p) => { try { return fs.statSync(p).isFile(); } catch { return false; } }) ?? base;
    };
    const shown = f === path.resolve(file) ? label : path.relative(path.dirname(path.resolve(file)), f);
    problems.push(...checkGraphSource(src, shown, registry, { resolveImport }));
    const code = strip(src);
    for (const im of specsOf(src, code)) {
      const t = resolveImport(im.spec);
      if (t && !INTERNAL.some((d) => t.startsWith(`${d}${path.sep}`))) queue.push(t); // 내부 모듈은 위반으로 이미 적었다 — 따라가지 않는다
    }
  }
  return problems;
}

if (process.argv[1] && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) {
  const args = process.argv.slice(2);
  const registry = loadRegistry(process.env.LG_CMD_REGISTRY || path.join(HERE, "cmd-registry.json"));
  const files = [];
  const walk = (p) => {
    const st = fs.statSync(p);
    if (st.isDirectory()) { for (const f of fs.readdirSync(p).sort()) if (f !== "node_modules") walk(path.join(p, f)); }
    else if (/\.(mjs|js)$/.test(p)) files.push(p);
  };
  (args.length ? args : [path.join(HERE, "graphs")]).forEach(walk);
  let bad = 0;
  for (const f of files) {
    for (const p of checkGraphFile(f, registry, path.relative(process.cwd(), f))) { bad++; console.log(`위반 ${p.file}:${p.line} ${p.rule} — ${p.message}`); }
  }
  if (bad) { console.log(`FAIL graph-rules 위반 ${bad}건`); process.exitCode = 1; }
  else console.log(`OK graph-rules 파일 ${files.length}개 · 명령 ${Object.keys(registry.commands).length}개 허용 · 위반 0`);
}
