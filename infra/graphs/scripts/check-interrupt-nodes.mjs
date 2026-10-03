#!/usr/bin/env node
// check-interrupt-nodes.mjs — interrupt(사람 답 대기)가 든 노드에 LLM 호출·부수효과가 없는지 보는 정적 검사(안전장치 2, 위험 5).
// 왜: 재개하면 interrupt 가 든 노드는 처음부터 다시 돈다. 그 안의 LLM 호출은 새 초안을 만들어 승인 안 받은 내용이 나가고,
//     발송·파일 쓰기는 두 번 일어난다. 규칙: interrupt 노드는 동기·순수 — 상태를 읽고, interrupt 를 부르고, 값을 돌려줄 뿐.
// 한계(정직): 정규식과 괄호 짝 맞추기 수준이다. 같은 파일의 함수는 따라 들어가고, 다른 모듈의 함수는 못 따라가므로
//     interrupt 노드에서 가져온(import) 함수를 부르는 것 자체를 위반으로 본다. 노드는 addNode(이름, 함수) 형식이어야 한다.
// 사용: node scripts/check-interrupt-nodes.mjs [파일|폴더 ...]   (기본: graphs/)  → 위반이 있으면 종료 코드 1
import fs from "node:fs";
import { isBuiltin } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const REGEX_AFTER = new Set(["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await"]);

// 주석·문자열·정규식 내용을 공백으로 지운 사본(길이·줄바꿈 보존). 템플릿의 ${…} 안은 코드라 남긴다.
export function strip(src) {
  const out = src.split("");
  const n = src.length;
  const blank = (a, b) => { for (let k = a; k < b && k < n; k++) if (out[k] !== "\n") out[k] = " "; };
  const tplDepths = [];
  let depth = 0, prev = "", word = "", i = 0;
  const regexOk = () => prev === "" || (prev === "w" ? REGEX_AFTER.has(word) : !/[)\]}`'"]/.test(prev));
  const tpl = (j) => { // 템플릿 본문을 지우다가 ` 또는 ${ 에서 멈춘다
    const s = j;
    while (j < n) {
      if (src[j] === "\\") { j += 2; continue; }
      if (src[j] === "`") { blank(s, j); prev = "`"; return j + 1; }
      if (src[j] === "$" && src[j + 1] === "{") { blank(s, j); tplDepths.push(depth); depth++; prev = "{"; return j + 2; }
      j++;
    }
    blank(s, n);
    return n;
  };
  while (i < n) {
    const c = src[i], d = src[i + 1];
    if (c === "/" && d === "/") { let e = src.indexOf("\n", i); if (e < 0) e = n; blank(i, e); i = e; continue; }
    if (c === "/" && d === "*") { let e = src.indexOf("*/", i + 2); e = e < 0 ? n : e + 2; blank(i, e); i = e; continue; }
    if (c === "'" || c === '"') {
      let j = i + 1;
      while (j < n && src[j] !== c && src[j] !== "\n") j += src[j] === "\\" ? 2 : 1;
      blank(i + 1, j); i = j + 1; prev = c; continue;
    }
    if (c === "`") { i = tpl(i + 1); continue; }
    if (c === "/" && regexOk()) {
      let j = i + 1, cls = false;
      while (j < n && src[j] !== "\n") {
        if (src[j] === "\\") { j += 2; continue; }
        if (src[j] === "[") cls = true; else if (src[j] === "]") cls = false; else if (src[j] === "/" && !cls) break;
        j++;
      }
      blank(i + 1, j); i = j + 1;
      while (i < n && /[a-z]/i.test(src[i])) i++;
      prev = ")"; continue;
    }
    if (c === "{") { depth++; prev = c; i++; continue; }
    if (c === "}") {
      if (tplDepths.length && tplDepths[tplDepths.length - 1] === depth - 1) { tplDepths.pop(); depth--; i = tpl(i + 1); continue; }
      depth--; prev = c; i++; continue;
    }
    if (/\s/.test(c)) { i++; continue; }
    if (/[\w$]/.test(c)) { let j = i; while (j < n && /[\w$]/.test(src[j])) j++; word = src.slice(i, j); prev = "w"; i = j; continue; }
    prev = c; i++;
  }
  return out.join("");
}

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
function topCommas(code, a, b) {
  const out = [];
  for (let k = a, dep = 0; k < b; k++) {
    const ch = code[k];
    if (CLOSE[ch]) dep++; else if (ch === ")" || ch === "]" || ch === "}") dep--; else if (ch === "," && dep === 0) out.push(k);
  }
  return out;
}
// 함수식 하나의 끝(배타). 블록 본문이면 그 } 다음, 식 본문이면 깊이 0 의 ; , 닫는 괄호 또는 이어지지 않는 줄바꿈.
function fnEnd(code, s) {
  for (let k = s, dep = 0; k < code.length; k++) {
    const ch = code[k];
    if (CLOSE[ch]) {
      if (ch === "{" && dep === 0 && /(=>|\))\s*$/.test(code.slice(s, k))) { const e = matchBracket(code, k); return e < 0 ? code.length : e + 1; }
      dep++;
    } else if (ch === ")" || ch === "]" || ch === "}") { if (--dep < 0) return k; }
    else if (dep === 0 && (ch === ";" || ch === ",")) return k;
    else if (dep === 0 && ch === "\n") {
      const before = code.slice(s, k).trimEnd().slice(-1);
      const after = code.slice(k).trimStart()[0] ?? "";
      if (!/[=>([{,.?:+\-*/%&|!<]/.test(before) && !/[.?:+\-*/%&|=<>,)\]}]/.test(after)) return k;
    }
  }
  return code.length;
}
function localFunctions(code) {
  const fns = new Map();
  for (const m of code.matchAll(/\b(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(/g)) {
    const p = matchBracket(code, m.index + m[0].length - 1); if (p < 0) continue;
    const b = code.indexOf("{", p); const e = b < 0 ? -1 : matchBracket(code, b); if (e < 0) continue;
    fns.set(m[1], [m.index, e + 1]);
  }
  for (const m of code.matchAll(/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?=(?:async\b\s*)?(?:function\b|\(|[A-Za-z_$][\w$]*\s*=>))/g)) {
    fns.set(m[1], [m.index, fnEnd(code, m.index + m[0].length)]);
  }
  return fns;
}
const esc = (s) => s.replace(/[$]/g, "\\$");
const IDENT = /[A-Za-z_$][\w$]*/g;

const RULES = [
  ["await", /\bawait\b|\basync\b/, "비동기 작업(await) — interrupt 노드는 동기·순수여야 한다"],
  ["try", /\btry\s*\{/, "try/catch — interrupt 신호를 삼킬 수 있다"],
  ["llm", /\bllm\b|\bclaude\w*\s*\(|\bask\w*\s*\(|\bquery\s*\(|\.invoke\s*\(|\.stream\s*\(|\bchat\w*\s*\(|\bcomplet\w*\s*\(|\bgenerate\w*\s*\(/, "LLM 호출 — 재개 때 다시 불려 승인 안 받은 새 내용이 나온다"],
  ["fs", /\bfs\w*\s*\.|\b(?:write|append|rm|unlink|rename|mkdir|copy|truncate)\w*\s*\(|createWriteStream/, "파일 쓰기 — 재개 때 두 번 일어난다"],
  ["process", /\bchild_process\b|\b(?:exec|execFile|spawn|fork)(?:Sync)?\s*\(|\bprocess\s*\.\s*(?:exit|kill)\b/, "프로세스 실행·종료"],
  ["network", /\bfetch\s*\(|\bhttps?\s*\.|\bXMLHttpRequest\b|\bWebSocket\b|\bnet\s*\./, "네트워크 — 재개 때 두 번 나간다"],
  ["send", /\b(?:send|post|notify|publish|emit|announce|deliver)\w*\s*\(/i, "발송 — 재개 때 두 번 나간다"],
  ["db", /\b(?:db|store|saver|checkpointer)\s*\.|\.(?:run|prepare)\s*\(/, "저장소 쓰기"],
  ["console", /\bconsole\s*\./, "로그 출력 — 재개 때 두 번 찍힌다"],
];
// interrupt 노드 안에서 허용하는 호출(순수 계산)만. 위 규칙에 안 걸린 나머지 호출은 'call' 위반이다 — 허용 목록 방식.
// 메서드는 이름이 허용 목록에 있어도, 받는 쪽의 뿌리가 노드 인자·지역 값·글자값·안전한 내장일 때만 통과한다(api.get 같은 것을 막으려고).
const KEYWORDS = new Set(["if", "for", "while", "switch", "catch", "function", "return", "typeof", "void", "delete", "await", "async", "new", "in", "of", "do", "else", "case", "throw", "yield", "super", "import", "with", "const", "let", "var", "this", "true", "false", "null", "undefined"]);
const SAFE_GLOBAL = new Set(["String", "Number", "Boolean", "Array", "Object", "parseInt", "parseFloat", "isNaN", "isFinite", "encodeURIComponent", "decodeURIComponent", "structuredClone", "Symbol", "BigInt"]);
const SAFE_NS = new Set(["Math", "JSON", "Object", "Array", "Number", "String", "Date", "Intl", "Symbol"]);
const SAFE_NEW = new Set(["Map", "Set", "Date", "Error", "Array", "URL", "RegExp"]);
const SAFE_METHOD = new Set(["map", "filter", "join", "slice", "includes", "some", "every", "find", "findIndex", "findLast", "concat", "trim", "trimStart", "trimEnd", "toLowerCase", "toUpperCase", "split", "replace", "replaceAll", "padStart", "padEnd", "toFixed", "toString", "toISOString", "at", "flat", "flatMap", "reduce", "indexOf", "lastIndexOf", "startsWith", "endsWith", "charAt", "codePointAt", "localeCompare", "normalize", "repeat", "substring", "sort", "reverse", "push", "keys", "values", "entries", "has", "get", "toLocaleString", "getTime", "valueOf"]);

// 범위 안에서 선언된 이름(인자·지역 변수·안쪽 화살표 인자)
function scopeNames(text) {
  const names = new Set();
  const add = (t) => { for (const m of String(t).matchAll(IDENT)) if (!KEYWORDS.has(m[0])) names.add(m[0]); };
  for (const m of text.matchAll(/\(([^()]*)\)\s*=>/g)) add(m[1]);
  for (const m of text.matchAll(/\b([A-Za-z_$][\w$]*)\s*=>/g)) add(m[1]);
  for (const m of text.matchAll(/\bfunction\b[^(]*\(([^()]*)\)/g)) add(m[1]);
  for (const m of text.matchAll(/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)/g)) names.add(m[1]);
  for (const m of text.matchAll(/\b(?:const|let|var)\s*[{[]([^}\]=]*)/g)) add(m[1]);
  return names;
}
function openOf(body, i) { // 닫는 괄호 body[i] 의 짝(뒤로)
  const want = { ")": "(", "]": "[", "}": "{" };
  const stack = [];
  for (let k = i; k >= 0; k--) {
    const ch = body[k];
    if (want[ch]) stack.push(want[ch]);
    else if (ch === "(" || ch === "[" || ch === "{") { if (stack.pop() !== ch) return -1; if (!stack.length) return k; }
  }
  return -1;
}
// x.y(…).z 처럼 이어진 호출의 뿌리 이름. 글자값이면 "<lit>", 알 수 없으면 null.
function chainRoot(body, i) {
  for (let guard = 0; guard < 500; guard++) {
    while (i >= 0 && /\s/.test(body[i])) i--;
    if (i < 0) return null;
    const c = body[i];
    if (c === ")" || c === "]") {
      const o = openOf(body, i);
      if (o < 0) return null;
      let j = o - 1;
      while (j >= 0 && /\s/.test(body[j])) j--;
      if (j >= 0 && (/[\w$]/.test(body[j]) || body[j] === ")" || body[j] === "]")) { i = j; continue; }
      return c === "]" ? "<lit>" : null;
    }
    if (c === "'" || c === '"' || c === "`") return "<lit>";
    if (/[\w$]/.test(c)) {
      let j = i;
      while (j >= 0 && /[\w$]/.test(body[j])) j--;
      const name = body.slice(j + 1, i + 1);
      let k = j;
      while (k >= 0 && /\s/.test(body[k])) k--;
      if (k >= 0 && body[k] === ".") { i = k - 1; if (body[i] === "?") i--; continue; }
      return /^\d/.test(name) ? "<lit>" : name;
    }
    return null;
  }
  return null;
}
function unsafeCall(body, roots) {
  for (const m of body.matchAll(/([A-Za-z_$][\w$]*)\s*(?:\?\.)?\(/g)) {
    const name = m[1];
    if (KEYWORDS.has(name)) continue;
    const before = body.slice(0, m.index).trimEnd();
    if (before.endsWith(".")) { // 메서드 호출
      let dot = before.length - 1;
      const root = chainRoot(body, before[dot - 1] === "?" ? dot - 2 : dot - 1);
      if (root && SAFE_NS.has(root) && (before.slice(0, dot).trimEnd().endsWith(root))) continue; // Math.max(…) 같은 내장 함수
      if (SAFE_METHOD.has(name) && root && (root === "<lit>" || roots.has(root) || SAFE_NS.has(root) || SAFE_GLOBAL.has(root))) continue;
      return { index: m.index, name: `${root ?? "?"}….${name}` };
    }
    if (/\bnew$/.test(before) ? SAFE_NEW.has(name) : SAFE_GLOBAL.has(name)) continue;
    return { index: m.index, name };
  }
  return null;
}

// interrupt 노드 본문이 바깥(모듈 수준) 이름을 쓰는 첫 자리. 객체 열쇠·속성 이름·process.env 읽기는 뺀다.
// 바깥 객체를 지역 변수로 옮겨(const c = client) 허용 이름 메서드를 부르는 우회를 막는다.
const SAFE_VALUE = new Set(["undefined", "NaN", "Infinity"]);
function outerRef(body, known) {
  for (const m of body.matchAll(/(?<![.\w$])([A-Za-z_$][\w$]*)(?![\w$])/g)) {
    const id = m[1];
    if (KEYWORDS.has(id) || known.has(id) || SAFE_GLOBAL.has(id) || SAFE_NS.has(id) || SAFE_NEW.has(id) || SAFE_VALUE.has(id)) continue;
    const after = body.slice(m.index + id.length);
    if (id === "$" && after.startsWith("{")) continue; // 템플릿 글자 안의 ${ 표시
    if (/^\s*:/.test(after) && /[{,]\s*$/.test(body.slice(0, m.index))) continue; // 객체 열쇠
    if (id === "process" && /^\s*\.\s*env\b/.test(after)) continue; // 환경변수 읽기
    return { index: m.index, id };
  }
  return null;
}

const LG_SPEC = /^@langchain\/langgraph(\/|$)/;
function importsOf(src, code) { // [{index, end, clause, spec}] — 주석 처리된 import 는 뺀다
  const out = [];
  for (const m of src.matchAll(/import\s+([^;]*?)\s+from\s*["']([^"']+)["']\s*;?|import\s*["']([^"']+)["']\s*;?/g)) {
    if (code[m.index] !== "i") continue;
    out.push({ index: m.index, end: m.index + m[0].length, clause: m[1] ?? "", spec: m[2] ?? m[3] });
  }
  for (const m of src.matchAll(/\bimport\s*\(\s*["']([^"']+)["']\s*\)/g)) if (code[m.index] === "i") out.push({ index: m.index, end: m.index + m[0].length, clause: "", spec: m[1] });
  return out;
}
// interrupt 의 이 파일 안 이름. 어느 모듈에서 가져왔든 원래 이름이 interrupt 면 interrupt 로 본다(다시 내보내기 대비).
function interruptNames(imports) {
  const names = new Set(), spaces = new Set();
  for (const im of imports) {
    const named = /\{([^}]*)\}/.exec(im.clause)?.[1] ?? "";
    for (const part of named.split(",").map((x) => x.trim()).filter(Boolean)) {
      const [orig, local = orig] = part.split(/\s+as\s+/).map((x) => x.trim());
      if (orig === "interrupt") names.add(local);
    }
    const ns = /\*\s*as\s+([\w$]+)/.exec(im.clause)?.[1];
    if (ns && LG_SPEC.test(im.spec)) spaces.add(ns);
  }
  return { names, spaces };
}
// 노드 안 자식 프로세스·직접 쓰기가 표준 출력에 바로 닿는 곳 — 실행기의 '첫 줄이 결과' 규약을 깬다
function stdoutHazards(src, code) {
  const out = [];
  for (const m of src.matchAll(/\bstdio\s*:\s*(?:\[[^\]]*["']inherit["'][^\]]*\]|["']inherit["'])/g)) if (code[m.index] === "s") out.push(m.index);
  for (const m of code.matchAll(/\bstdio\s*:\s*\[[^\]]*\b[12]\b[^\]]*\]|\bwriteSync\s*\(\s*[12]\s*[,)]|\bprocess\s*\.\s*(?:stdout|stderr)\s*\.\s*fd\b/g)) out.push(m.index);
  return out;
}

// src 한 파일을 검사한다. 돌려주는 값: { problems: [{file,line,node,rule,message}], interruptNodes: [이름] }
export function checkSource(src, file = "<src>") {
  const code = strip(src);
  const lineOf = (idx) => src.slice(0, idx).split("\n").length;
  const problems = [];
  const report = (idx, node, rule, message) => problems.push({ file, line: lineOf(idx), node, rule, message });

  const imports = importsOf(src, code);
  const inImport = (i) => imports.some((im) => i >= im.index && i < im.end);
  const { names, spaces } = interruptNames(imports);
  const imported = new Set(); // 다른 모듈에서 가져온 이름(interrupt 노드에서 쓰면 검사할 수 없다). node:fs 등 내장은 이름 규칙이 잡는다
  for (const im of imports) {
    if (LG_SPEC.test(im.spec) || isBuiltin(im.spec) || !im.clause) continue;
    const named = /\{([^}]*)\}/.exec(im.clause)?.[1] ?? "";
    for (const part of named.split(",").map((x) => x.trim()).filter(Boolean)) {
      const local = part.split(/\s+as\s+/).pop().trim();
      if (!names.has(local)) imported.add(local);
    }
    const ns = /\*\s*as\s+([\w$]+)/.exec(im.clause)?.[1];
    if (ns) imported.add(ns);
    const dflt = /^([\w$]+)\s*(,|$)/.exec(im.clause.trim())?.[1];
    if (dflt) imported.add(dflt);
  }
  const callAlts = [...[...names].map((x) => `(?<![.\\w$])${esc(x)}\\s*\\(`), ...[...spaces].map((x) => `\\b${esc(x)}\\s*\\.\\s*interrupt\\s*\\(`)];
  const calls = callAlts.length ? [...code.matchAll(new RegExp(callAlts.join("|"), "g"))].map((m) => m.index) : [];

  // interrupt 는 직접 부르기만 — 별칭·구조분해·인자로 넘기기는 검사가 못 따라간다
  for (const nm of new Set([...names, "interrupt"])) {
    for (const m of code.matchAll(new RegExp(`(?<![\\w$])${esc(nm)}(?![\\w$])`, "g"))) {
      if (inImport(m.index)) continue;
      const after = code.slice(m.index + nm.length);
      const dotted = /\.\s*$/.test(code.slice(0, m.index));
      if (/^\s*\(/.test(after) && (names.has(nm) || dotted)) continue; // 직접 호출(이름 또는 네임스페이스.interrupt)
      if (dotted && !/^\s*\(/.test(after) && nm === "interrupt") {
        const ns = /([\w$]+)\s*\.\s*$/.exec(code.slice(0, m.index))?.[1];
        if (!spaces.has(ns)) continue; // 다른 객체의 interrupt 속성 — 랭그래프 것이 아니다
      }
      if (dotted && nm === "interrupt" && /^\s*\(/.test(after)) continue;
      report(m.index, "?", "alias", "interrupt 는 직접 불러야 한다 — 별칭·구조분해·인자로 넘기면 검사가 못 따라간다");
    }
  }
  // 정적 중단점은 interrupt 없이 멈춰 retry 가 승인 없이 지나갈 수 있다
  for (const m of code.matchAll(/\binterrupt(?:Before|After)\b/g)) report(m.index, "?", "breakpoint", "정적 중단점(interruptBefore/After)은 쓰지 않는다 — interrupt() 노드로");
  for (const i of stdoutHazards(src, code)) report(i, "?", "stdout", "자식 출력·직접 쓰기가 표준 출력에 닿는다(stdio inherit·fd 1) — 출력은 받아서 넘긴다");
  for (const im of imports) if (im.spec.startsWith("#")) report(im.index, "?", "import-alias", `경로 별칭(${im.spec})은 검사가 따라가지 못한다 — 같은 꾸러미 모듈은 상대 경로로 가져온다`);

  const fns = localFunctions(code);
  const nodes = [];
  for (const m of code.matchAll(/\.addNode\s*\(/g)) {
    const open = m.index + m[0].length - 1;
    const close = matchBracket(code, open);
    if (close < 0) { report(m.index, "?", "parse", "addNode 괄호 짝을 찾지 못함"); continue; }
    const commas = topCommas(code, open + 1, close);
    const name = src.slice(open + 1, commas[0] ?? close).trim().replace(/^["'`]|["'`]$/g, "");
    if (commas[0] === undefined) { report(m.index, name, "unanalyzable", "addNode(이름, 함수) 형식만 검사할 수 있다"); continue; }
    const fnRange = [commas[0] + 1, commas[1] ?? close];
    const fnText = code.slice(...fnRange).trim();
    if (/^[A-Za-z_$][\w$]*$/.test(fnText)) {
      if (fns.has(fnText)) nodes.push({ name, range: fns.get(fnText) });
      else report(fnRange[0], name, "unanalyzable", `노드 함수 ${fnText} 가 이 파일에 없다 — (s) => ${fnText}(s) 처럼 감싸야 검사할 수 있다`);
    } else if (/^(?:async\b|function\b|\(|[A-Za-z_$][\w$]*\s*=>)/.test(fnText)) {
      nodes.push({ name, range: fnRange });
    } else {
      report(fnRange[0], name, "unanalyzable", "노드 함수는 이 파일 안의 함수여야 한다(공장 함수 호출 금지)");
    }
  }

  const within = (r, i) => i >= r[0] && i < r[1];
  const reachable = (range) => { // 노드 본문 + 거기서 부르거나 넘기는 같은 파일 함수들(재귀). 이름만 넘겨도(map(relay)) 따라간다
    const out = [range], seen = new Set();
    for (let q = 0; q < out.length; q++) {
      for (const m of code.slice(...out[q]).matchAll(/(?<![.\w$])([A-Za-z_$][\w$]*)(?![\w$])/g)) {
        if (fns.has(m[1]) && !seen.has(m[1])) { seen.add(m[1]); out.push(fns.get(m[1])); }
      }
    }
    return out;
  };
  const neutral = new RegExp(`(?<![.\\w$])(?:${[...names, ...fns.keys()].map(esc).join("|") || "(?!)"})\\s*(?=\\()`, "g");
  const importRe = imported.size ? new RegExp(`(?<![.\\w$])(?:${[...imported].map(esc).join("|")})(?![\\w$])`) : null;
  const subgraphRe = /\.\s*(?:invoke|stream|streamEvents|batch)\s*\(/;
  const covered = new Set();
  const interruptNodes = [];
  for (const node of nodes) {
    const ranges = reachable(node.range);
    // 어느 노드든: 그래프·모델을 안에서 invoke/stream 하면 하위 그래프의 interrupt 가 부모 노드 전체를 재개 때 다시 돌린다
    for (const r of ranges) {
      const m = subgraphRe.exec(code.slice(...r));
      if (m) { report(r[0] + m.index, node.name, "subgraph", "노드 안에서 그래프·모델을 invoke/stream 하지 않는다 — 하위 그래프는 addNode 로 잇는다(2단계)"); break; }
    }
    const mine = calls.filter((i) => ranges.some((r) => within(r, i)));
    if (!mine.length) continue;
    mine.forEach((i) => covered.add(i));
    interruptNodes.push(node.name);
    const hit = new Set();
    let firstUnsafe = null, firstOuter = null;
    for (const r of ranges) {
      const text = code.slice(...r);
      const own = scopeNames(text);
      const roots = new Set([...own, ...fns.keys()]);
      const body = text.replace(neutral, (x) => " ".repeat(x.length)); // interrupt·같은 파일 함수 이름은 따로 따라간다
      if (!firstOuter) { const o = outerRef(body, new Set([...own, ...fns.keys(), ...names, ...imported])); if (o) firstOuter = { index: r[0] + o.index, id: o.id }; }
      for (const [rule, re, message] of [...RULES, ...(importRe ? [["import", importRe, "다른 모듈에서 가져온 것을 쓴다 — 검사할 수 없으니 interrupt 노드 밖으로"]] : [])]) {
        if (hit.has(rule)) continue;
        const m = re.exec(body);
        if (m) { hit.add(rule); report(r[0] + m.index, node.name, rule, message); }
      }
      const u = unsafeCall(body, roots);
      if (u && !firstUnsafe) firstUnsafe = { index: r[0] + u.index, name: u.name };
    }
    if (!hit.size && firstOuter) report(firstOuter.index, node.name, "outer", `바깥 값 ${firstOuter.id} 를 쓴다 — interrupt 노드는 자기 인자·지역 값·안전한 내장만(필요한 값은 앞 노드에서 상태로)`);
    else if (!hit.size && firstUnsafe) report(firstUnsafe.index, node.name, "call", `허용 목록 밖 호출 ${firstUnsafe.name}() — interrupt 노드는 상태 읽기·순수 계산·interrupt 만`);
  }
  for (const i of calls) if (!covered.has(i)) report(i, "?", "outside", "interrupt 가 검사한 노드 밖에 있다(공장 함수·다른 모듈?) — addNode(이름, 함수) 안으로");
  return { problems, interruptNodes };
}

// 그래프 파일 하나 + 그 파일이 상대 경로로 가져오는 모듈(재귀)을 검사한다.
// 가져온 모듈 안의 interrupt(가져오기·다시 내보내기)·정적 중단점·표준 출력 직접 쓰기는 위반이다.
export function checkFile(file, label = file) {
  const src = fs.readFileSync(file, "utf8");
  const res = checkSource(src, label);
  const seen = new Set([path.resolve(file)]);
  const queue = relativeImports(src, file);
  while (queue.length) {
    const f = queue.shift();
    if (seen.has(f)) continue;
    seen.add(f);
    let s2;
    try { s2 = fs.readFileSync(f, "utf8"); } catch { continue; }
    const code = strip(s2);
    const imports = importsOf(s2, code);
    const { names, spaces } = interruptNames(imports);
    const shown = path.relative(path.dirname(path.resolve(file)), f);
    const lineOf = (idx) => s2.slice(0, idx).split("\n").length;
    const push = (idx, rule, message) => res.problems.push({ file: shown, line: lineOf(idx), node: "?", rule, message });
    const lgImport = imports.find((im) => LG_SPEC.test(im.spec) && (names.size || spaces.size));
    if (lgImport) push(lgImport.index, "helper-interrupt", `interrupt 는 그래프 파일 안에서만 — ${label} 가 가져오는 모듈에 있으면 검사가 못 본다`);
    for (const m of s2.matchAll(/export\s*(?:\{[^}]*\binterrupt\b[^}]*\}|\*(?:\s*as\s+[\w$]+)?)\s*from\s*["']@langchain\/langgraph(?:\/[\w-]+)?["']/g)) {
      if (code[m.index] === "e") push(m.index, "helper-interrupt", "interrupt 를 다시 내보낸다 — 그래프 파일이 랭그래프에서 직접 가져와야 검사된다");
    }
    for (const m of code.matchAll(/\binterrupt(?:Before|After)\b/g)) push(m.index, "breakpoint", "정적 중단점(interruptBefore/After)은 쓰지 않는다");
    for (const i of stdoutHazards(s2, code)) push(i, "stdout", "자식 출력·직접 쓰기가 표준 출력에 닿는다(stdio inherit·fd 1) — 출력은 받아서 넘긴다");
    for (const im of imports) if (im.spec.startsWith("#")) push(im.index, "import-alias", `경로 별칭(${im.spec})은 검사가 따라가지 못한다 — 상대 경로로`);
    queue.push(...relativeImports(s2, f));
  }
  return res;
}
function relativeImports(src, file) {
  const code = strip(src);
  const dir = path.dirname(path.resolve(file));
  const out = [];
  const specs = importsOf(src, code).map((im) => im.spec);
  for (const m of src.matchAll(/export\s*(?:\{[^}]*\}|\*(?:\s*as\s+[\w$]+)?)\s*from\s*["']([^"']+)["']/g)) if (code[m.index] === "e") specs.push(m[1]);
  for (const spec of specs) {
    if (!/^\.{1,2}\//.test(spec)) continue;
    const base = path.resolve(dir, spec);
    const hit = [base, `${base}.mjs`, `${base}.js`, path.join(base, "index.mjs")].find((p) => { try { return fs.statSync(p).isFile(); } catch { return false; } });
    if (hit) out.push(hit);
  }
  return out;
}

function collectFiles(paths) {
  const out = [];
  const walk = (p) => {
    const st = fs.statSync(p);
    if (st.isDirectory()) { for (const f of fs.readdirSync(p).sort()) if (f !== "node_modules") walk(path.join(p, f)); }
    else if (/\.(mjs|js)$/.test(p)) out.push(p);
  };
  paths.forEach(walk);
  return out;
}

if (process.argv[1] && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href) {
  const here = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
  const args = process.argv.slice(2);
  const files = collectFiles(args.length ? args : [path.join(here, "graphs")]);
  let bad = 0, inodes = 0;
  for (const f of files) {
    const { problems, interruptNodes } = checkFile(f, path.relative(process.cwd(), f));
    inodes += interruptNodes.length;
    for (const p of problems) { bad++; console.log(`위반 ${p.file}:${p.line} [${p.node}] ${p.rule} — ${p.message}`); }
  }
  if (bad) { console.log(`FAIL interrupt-nodes 위반 ${bad}건`); process.exitCode = 1; }
  else console.log(`OK interrupt-nodes 파일 ${files.length}개 · interrupt 노드 ${inodes}개 · 위반 0`);
}
