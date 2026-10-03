#!/usr/bin/env node
// three-path-check.mjs — 재현 시험 파일에 세 경로 묶음이 다 있는지 정적으로 확인한다(설계 §5.2⑦ · L 상2).
// 엔진 · 라이브 사람 · 라이브 AI(어려움 포함). 셋 중 하나라도 없으면 ⑦ repro_test 는 통과하지 못한다.
//
//   node three-path-check.mjs <시험.dart>… [--markers <json 파일>] [--no-hard]
//   → JSON 한 줄 {ok, paths:{engine,liveHuman,liveAi}, liveAiHard, missing:[…], tests:[…]}. ok:false 면 종료 3.
//
// 기준 표식(고스톱 시험의 기존 이름 관례 — 10-03 gukjin_capture_paths_live_test.dart 등): 시험·묶음 이름에
//   '엔진:' · '라이브 사람:' · '라이브 AI:'(또는 [engine]·[live-human]·[live-ai] 꼬리표). 시험은 자기 이름이나 감싼 group 이름의 표식을 따른다.
//   '엔진과 같다'처럼 콜론·괄호 없이 쓴 말은 표식이 아니다.
// 경로마다: 건너뛰지 않은(skip 없음) test·testWidgets 가 하나 이상이고 그 안에 expect·expectLater 가 있어야 센다.
// 어려움: 라이브 AI 시험(또는 라이브 AI 묶음) 안에 AIDifficulty.hard 나 AIDifficulty.values 가 있어야 한다.
// 한계(정직): 정적 확인이다 — 이름만 붙이고 실제로 그 경로를 안 타는 시험은 못 잡는다. 그건 실행 증명(coverage-check)이 잡는다.
import fs from "node:fs";
import { fileURLToPath } from "node:url";

export const DEFAULT_MARKERS = {
  engine: String.raw`(?:^|[\s\[(|·—-])(?:엔진|engine)\s*[:：]|\[(?:엔진|engine)\]`,
  liveHuman: String.raw`(?:^|[\s\[(|·—-])(?:라이브\s*사람|live[\s_-]*human)\s*[:：]|\[(?:라이브\s*사람|live[\s_-]*human)\]`,
  liveAi: String.raw`(?:^|[\s\[(|·—-])(?:라이브\s*AI|live[\s_-]*ai)\s*[:：]|\[(?:라이브\s*AI|live[\s_-]*ai)\]`,
};
export const HARD_TOKENS = [["AIDifficulty", "hard"], ["AIDifficulty", "values"]];

// ── 간이 Dart 어휘 분석: 주석은 버리고, 문자열은 하나의 토큰(값은 따옴표 안 글자 그대로, 보간 ${…} 포함)으로.
export function lex(src) {
  const toks = [];
  let i = 0;
  const n = src.length;
  const isId = (c) => /[A-Za-z0-9_$]/.test(c);
  // 문자열 하나를 읽는다. i 는 따옴표(또는 r) 자리. 끝난 뒤 위치와 값을 돌려준다.
  const readString = (j) => {
    let raw = false;
    if (src[j] === "r") { raw = true; j++; }
    const q = src[j];
    const triple = src.startsWith(q.repeat(3), j);
    const close = triple ? q.repeat(3) : q;
    j += close.length;
    let val = "";
    while (j < n) {
      if (src.startsWith(close, j)) return { end: j + close.length, val };
      const c = src[j];
      if (!raw && c === "\\") { val += src.slice(j, j + 2); j += 2; continue; }
      if (!raw && c === "$" && src[j + 1] === "{") { // 보간: 짝 맞는 } 까지(안의 문자열·괄호 포함)
        let depth = 0, k = j + 1;
        while (k < n) {
          if (src[k] === "{") depth++;
          else if (src[k] === "}") { depth--; if (depth === 0) { k++; break; } }
          else if (src[k] === "'" || src[k] === '"') { k = readString(k).end; continue; }
          k++;
        }
        val += src.slice(j, k);
        j = k;
        continue;
      }
      if (!triple && c === "\n") return { end: j, val }; // 닫히지 않은 한 줄 문자열 — 줄 끝에서 끊는다
      val += c;
      j++;
    }
    return { end: n, val };
  };
  while (i < n) {
    const c = src[i];
    if (c === "/" && src[i + 1] === "/") { while (i < n && src[i] !== "\n") i++; continue; }
    if (c === "/" && src[i + 1] === "*") { // 중첩 주석
      let depth = 0;
      while (i < n) {
        if (src.startsWith("/*", i)) { depth++; i += 2; } else if (src.startsWith("*/", i)) { depth--; i += 2; if (!depth) break; } else i++;
      }
      continue;
    }
    if (c === "'" || c === '"' || (c === "r" && (src[i + 1] === "'" || src[i + 1] === '"') && !isId(src[i - 1] ?? " "))) {
      const s = readString(i);
      toks.push({ t: "str", v: s.val, pos: i });
      i = s.end;
      continue;
    }
    if (isId(c)) { let j = i; while (j < n && isId(src[j])) j++; toks.push({ t: "id", v: src.slice(i, j), pos: i }); i = j; continue; }
    if (/\s/.test(c)) { i++; continue; }
    toks.push({ t: "p", v: c, pos: i });
    i++;
  }
  return toks;
}

// group·test·testWidgets 호출을 찾는다: 이름(붙은 문자열 리터럴들), 인자 범위(토큰 위치), skip 여부.
export function findCalls(toks) {
  const calls = [];
  for (let k = 0; k < toks.length - 1; k++) {
    const t = toks[k];
    if (t.t !== "id" || !["group", "test", "testWidgets"].includes(t.v) || toks[k + 1].v !== "(") continue;
    if (toks[k - 1]?.v === "." || toks[k - 1]?.t === "id") continue; // x.test(…)·선언(void test(…)) 제외
    let depth = 0, end = k + 1;
    for (let j = k + 1; j < toks.length; j++) {
      const v = toks[j].v;
      if (toks[j].t === "p" && (v === "(" || v === "[" || v === "{")) depth++;
      else if (toks[j].t === "p" && (v === ")" || v === "]" || v === "}")) { depth--; if (depth === 0) { end = j; break; } }
    }
    let name = null, j = k + 2;
    while (toks[j]?.t === "str") { name = (name ?? "") + toks[j].v; j++; }
    // skip: true / skip: '이유' — 최상위 인자(괄호 깊이 1)에서만
    let skip = false, d = 0;
    for (let m = k + 1; m <= end; m++) {
      const v = toks[m].v;
      if (toks[m].t === "p" && "([{".includes(v)) d++;
      else if (toks[m].t === "p" && ")]}".includes(v)) d--;
      else if (d === 1 && toks[m].t === "id" && v === "skip" && toks[m + 1]?.v === ":") {
        const val = toks[m + 2];
        skip = !(val?.t === "id" && (val.v === "false" || val.v === "null"));
      }
    }
    calls.push({ kind: t.v, name, start: k, end, skip });
  }
  return calls;
}

const hasSeq = (toks, a, b, [x, y]) => {
  for (let i = a; i < b - 1; i++) if (toks[i].t === "id" && toks[i].v === x && toks[i + 1].v === "." && toks[i + 2]?.v === y) return true;
  return false;
};
const hasId = (toks, a, b, names) => { for (let i = a; i < b; i++) if (toks[i].t === "id" && names.includes(toks[i].v)) return true; return false; };
// expect 도우미: 같은 파일 안에 정의가 있고 그 몸통에 expect·expectLater 가 있어야 센다(H10 중7 — 이름만 _expectX 인 빈 함수로 통과 막기)
export function expectHelpers(src) {
  const text = String(src).replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
  const ok = new Set();
  for (const m of text.matchAll(/\b(_?expect[A-Z0-9_]\w*)\s*\([^()]*\)\s*(?:async\s*)?\{/g)) {
    let depth = 0, i = m.index + m[0].length - 1, end = -1;
    for (; i < text.length; i++) { if (text[i] === "{") depth++; else if (text[i] === "}" && --depth === 0) { end = i; break; } }
    if (end > 0 && /\bexpect(?:Later)?\s*\(/.test(text.slice(m.index + m[0].length, end))) ok.add(m[1]);
  }
  return ok;
}
const hasExpectHelper = (toks, a, b, helpers) => { for (let i = a; i < b - 1; i++) if (toks[i].t === "id" && helpers.has(toks[i].v) && toks[i + 1].v === "(") return true; return false; };
// 어려움 낱말: [이름] 하나면 그 식별자, [앞, 뒤] 면 '앞.뒤'
const hasHard = (toks, a, b, h) => (h.length === 1 ? hasId(toks, a, b, h) : hasSeq(toks, a, b, h));

export function checkThreePaths(sources, { markers = DEFAULT_MARKERS, requireHard = true } = {}) {
  // markers.hardTokens(선택): 어려움을 뜻하는 낱말 줄을 더한다 — 고스톱 3경로 틀(H5)의 threePathAiDifficulties(쉬움·보통·어려움 목록)
  const { hardTokens = [], ...marks } = markers;
  const HARD = [...HARD_TOKENS, ...hardTokens.map((t) => [].concat(t).map(String))];
  const re = Object.fromEntries(Object.entries(marks).map(([k, v]) => [k, new RegExp(v, "iu")]));
  const paths = { engine: [], liveHuman: [], liveAi: [] };
  const tests = [];
  let liveAiHard = false;
  for (const src of [].concat(sources)) {
    const toks = lex(src);
    const helpers = expectHelpers(src);
    const calls = findCalls(toks);
    const groups = calls.filter((c) => c.kind === "group");
    const tag = (name) => Object.keys(paths).filter((p) => name && re[p].test(name));
    for (const g of groups) {
      if (tag(g.name).includes("liveAi") && HARD.some((h) => hasHard(toks, g.start, g.end, h))) liveAiHard = true;
    }
    for (const c of calls.filter((x) => x.kind !== "group")) {
      const enclosing = groups.filter((g) => g.start < c.start && g.end > c.end);
      if (c.skip || enclosing.some((g) => g.skip)) { tests.push({ name: c.name, skipped: true }); continue; }
      const own = tag(c.name);
      const inherited = enclosing.flatMap((g) => tag(g.name));
      const pathsOf = own.length ? own : [...new Set(inherited)];
      // expect·expectLater, 또는 expect 로 시작하는 도우미 호출(_expectPuk(…) 처럼 — 고스톱 3경로 틀이 쓰는 꼴, 1b 통합 실측)
      const expects = hasId(toks, c.start, c.end, ["expect", "expectLater"]) || hasExpectHelper(toks, c.start, c.end, helpers);
      tests.push({ name: c.name, paths: pathsOf, expects });
      if (!expects) continue;
      for (const p of pathsOf) paths[p].push(c.name);
      if (pathsOf.includes("liveAi") && HARD.some((h) => hasHard(toks, c.start, c.end, h))) liveAiHard = true;
    }
  }
  const missing = Object.entries(paths).filter(([, v]) => !v.length).map(([k]) => k);
  if (requireHard && paths.liveAi.length && !liveAiHard) missing.push("liveAiHard");
  const count = Object.fromEntries(Object.entries(paths).map(([k, v]) => [k, v.length]));
  return { ok: missing.length === 0, paths: count, liveAiHard, missing, tests };
}

function main(argv) {
  const files = [];
  let markers = DEFAULT_MARKERS, requireHard = true;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--markers") markers = { ...DEFAULT_MARKERS, ...JSON.parse(fs.readFileSync(argv[++i], "utf8")) };
    else if (argv[i] === "--no-hard") requireHard = false;
    else files.push(argv[i]);
  }
  if (!files.length) { process.stderr.write("시험 파일을 하나 이상 주어야 한다\n"); process.exit(2); }
  const r = checkThreePaths(files.map((f) => fs.readFileSync(f, "utf8")), { markers, requireHard });
  process.stdout.write(`${JSON.stringify(r)}\n`);
  process.exit(r.ok ? 0 : 3);
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
