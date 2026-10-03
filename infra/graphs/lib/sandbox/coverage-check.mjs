#!/usr/bin/env node
// coverage-check.mjs — 실행 증명(설계 §5.2⑪⑤ · L2 부분 2): AI 경로 시험을 --coverage 로 돌린 lcov 를 읽어,
// 패치가 바꾼 lib 줄이 그 시험에서 실제로 실행됐는지 판정한다. '3경로 시험 틀은 있는데 정작 바뀐 줄을 안 지난다'를 잡는다.
//
//   node coverage-check.mjs --patch <패치 파일> --lcov <lcov.info> [--root <사본>] [--policy hunk|all|any]
//   → JSON 한 줄 {ok, verdict, files:[…], summary}. ok:false 면 종료 3, 사용 오류 2.
//
// 판정
//   · 바뀐 줄 = 새 파일 기준 '+' 줄. 지우기만 한 덩어리는 지운 자리 앞뒤 줄(새 파일 기준)로 본다 — 그 경계를 지났으면 지운 효과도 지난 것.
//   · 실행 가능한 줄 = lcov 의 DA 기록이 있는 줄. 주석·빈 줄·선언은 DA 가 없어 판정에서 빠진다.
//   · policy hunk(기본): 실행 가능한 바뀐 줄이 있는 덩어리마다 하나 이상 실행. all: 전부 실행. any: 패치 통틀어 하나라도.
//   · 바뀐 lib 파일이 lcov 에 아예 없으면(시험이 그 파일을 싣지도 않음) 그 파일은 실패 — 단 바뀐 줄이 전부 주석·빈 줄이면 중립.
//   · verdict: executed(통과) · not_executed · lcov_missing · no_lib_change(lib 변경 없음 — 통과로 두되 그래프가 판단) ·
//     no_executable_change(lib 변경이 주석·선언뿐 — 통과로 두되 표시).
// 주의: flutter test --coverage 의 기본 출력(coverage/lcov.info)은 고스톱에서 추적되는 파일이다 — 사본 밖(--coverage-path)에 쓴다.
// sandboxed-run.mjs 가 --coverage 를 보면 임시 폴더로 돌려 준다.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseUnifiedDiff } from "./unified-diff.mjs";

// lcov → Map<경로, Map<줄, 실행 횟수>>. 같은 파일 기록이 여러 번이면 더한다.
export function parseLcov(text) {
  const out = new Map();
  let cur = null;
  for (const raw of String(text ?? "").split("\n")) {
    const l = raw.trim();
    if (l.startsWith("SF:")) { const f = l.slice(3); cur = out.get(f) ?? new Map(); out.set(f, cur); }
    else if (l.startsWith("DA:") && cur) {
      const [ln, cnt] = l.slice(3).split(",");
      const n = Number(ln), c = Number(cnt);
      if (Number.isInteger(n) && Number.isFinite(c)) cur.set(n, (cur.get(n) ?? 0) + c);
    } else if (l === "end_of_record") cur = null;
  }
  return out;
}

// lcov 의 SF(절대·상대)를 사본 기준 상대 경로로. /tmp ↔ /private/tmp 처럼 같은 곳의 다른 이름도 맞춘다.
export function normalizeSf(sf, roots = []) {
  let s = sf.replace(/\\/g, "/");
  if (!path.isAbsolute(s)) return s.replace(/^\.\//, "");
  const variants = (r) => [r, r.startsWith("/private/") ? r.slice(8) : `/private${r}`];
  for (const r of roots.flatMap(variants)) if (s.startsWith(`${r}/`)) return s.slice(r.length + 1);
  return s;
}

const trivial = (s) => { const t = s.trim(); return t === "" || t.startsWith("//") || t.startsWith("*") || t.startsWith("/*") || t === "}" || t === "{"; };

// 덩어리 하나에서 '바뀐 줄'(새 파일 줄 번호) 목록
export function changedNewLines(h) {
  const plus = h.lines.filter((l) => l.t === "+");
  if (plus.length) return { lines: plus.map((l) => l.newNo), texts: plus.map((l) => l.s), deletionOnly: false };
  const out = new Set();
  h.lines.forEach((l, i) => {
    if (l.t !== "-") return;
    for (let j = i - 1; j >= 0; j--) if (h.lines[j].t === " ") { out.add(h.lines[j].newNo); break; }
    for (let j = i + 1; j < h.lines.length; j++) if (h.lines[j].t === " ") { out.add(h.lines[j].newNo); break; }
  });
  return { lines: [...out].sort((a, b) => a - b), texts: [], deletionOnly: true };
}

export function checkCoverage({ patch, lcov, root, roots = [], policy = "hunk", isTarget = (p) => p.startsWith("lib/") && p.endsWith(".dart") } = {}) {
  if (!["hunk", "all", "any"].includes(policy)) throw new Error(`policy 는 hunk·all·any: ${policy}`);
  const files = parseUnifiedDiff(patch).filter((f) => isTarget(f.path) && f.status !== "deleted");
  if (!files.length) return { ok: true, verdict: "no_lib_change", files: [], summary: "패치에 바뀐 lib 파일이 없다" };
  if (!lcov || !String(lcov).trim()) return { ok: false, verdict: "lcov_missing", files: [], summary: "lcov 가 비었다(시험이 안 돌았거나 --coverage 가 빠짐)" };
  const cov = new Map();
  for (const [sf, m] of parseLcov(lcov)) cov.set(normalizeSf(sf, [root, ...roots].filter(Boolean)), m);
  const outFiles = [];
  let anyHit = false, anyExec = false;
  for (const f of files) {
    const m = cov.get(f.path);
    const hunks = f.hunks.map((h) => {
      const c = changedNewLines(h);
      if (!m) {
        const allTrivial = !c.deletionOnly && c.texts.every(trivial);
        return { newStart: h.newStart, changed: c.lines, executable: [], hit: [], state: allTrivial ? "neutral" : "not_loaded" };
      }
      const executable = c.lines.filter((n) => m.has(n));
      const hit = executable.filter((n) => m.get(n) > 0);
      if (executable.length) anyExec = true;
      if (hit.length) anyHit = true;
      const state = !executable.length ? "neutral" : (policy === "all" ? hit.length === executable.length : hit.length > 0) ? "executed" : "not_executed";
      return { newStart: h.newStart, changed: c.lines, executable, hit, state };
    });
    const bad = hunks.filter((h) => h.state === "not_executed" || h.state === "not_loaded");
    if (hunks.some((h) => h.state === "not_loaded")) anyExec = true;
    outFiles.push({ path: f.path, loaded: !!m, ok: bad.length === 0, hunks });
  }
  if (!anyExec) return { ok: true, verdict: "no_executable_change", files: outFiles, summary: "바뀐 lib 줄이 모두 실행 대상이 아니다(주석·선언)" };
  const ok = policy === "any" ? anyHit : outFiles.every((f) => f.ok);
  const missed = outFiles.flatMap((f) => f.hunks.filter((h) => h.state === "not_executed" || h.state === "not_loaded").map((h) => `${f.path}:${h.newStart}${h.state === "not_loaded" ? "(파일 안 실림)" : ""}`));
  return { ok, verdict: ok ? "executed" : "not_executed", files: outFiles, summary: ok ? "바뀐 lib 줄이 AI 경로 시험에서 실행됐다" : `실행 안 된 덩어리: ${missed.slice(0, 10).join(", ")}` };
}

function main(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (["--patch", "--lcov", "--root", "--policy"].includes(k)) o[k.slice(2)] = argv[++i];
    else { process.stderr.write(`모르는 인자: ${k}\n`); process.exit(2); }
  }
  if (!o.patch || !o.lcov) { process.stderr.write("--patch·--lcov 가 있어야 한다\n"); process.exit(2); }
  let lcov = "";
  try { lcov = fs.readFileSync(o.lcov, "utf8"); } catch { /* 없음 → lcov_missing */ }
  const root = o.root ? (() => { try { return fs.realpathSync(o.root); } catch { return o.root; } })() : undefined;
  const r = checkCoverage({ patch: fs.readFileSync(o.patch, "utf8"), lcov, root, roots: o.root ? [o.root] : [], policy: o.policy ?? "hunk" });
  process.stdout.write(`${JSON.stringify(r)}\n`);
  process.exit(r.ok ? 0 : 3);
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
