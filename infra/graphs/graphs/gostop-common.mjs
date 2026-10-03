// gostop-common.mjs — 고스톱 접수(gostop-intake)·수정(gostop-fix) 그래프가 함께 쓰는 순수 도우미. 그래프가 아니다(build 없음).
// 명령은 여기서 돌리지 않는다 — 그래프 노드가 tools.run/launch 로만 돌린다. 여기 있는 것은 경로·파싱·판정·파일 쓰기뿐이다.
// 설계: docs/langgraph/DESIGN-gostop-loop.md v2.2 §1(신호·벤치) §2(사본) §4①(수정 허용 목록) §5.1·§5.2(1a 노드).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { z } from "zod";

// ── 경로 ─────────────────────────────────────────────────────────
// 본 저장소·소크 결과 자리. 시험은 환경변수로 가짜 저장소를 준다. 본 저장소는 읽기만 한다(git 읽기 명령·파일 존재 확인).
export const repoPath = () => path.resolve(process.env.LG_GOSTOP_REPO || path.join(os.homedir(), "projects", "gostop_app"));
export const soakRoot = () => path.resolve(process.env.LG_GOSTOP_SOAK_DIR || path.join(os.homedir(), ".openclaw", "workspace", "state", "gostop-soak"));
export const BENCH_FILE = fileURLToPath(new URL("../bench/gostop.json", import.meta.url));
export const DIFF_TEST = "test/domain/game/live_replay_differential_test.dart";
export const SOAK_TEST = "test/domain/game/live_soak_test.dart";

// sigkey(콜론 포함) → 폴더 이름. 같은 sigkey 는 늘 같은 이름이다.
export const keyDir = (sigkey) => String(sigkey).replace(/[^A-Za-z0-9._-]/g, "_").replace(/^[._-]+/, "").slice(0, 80) || "x";
export const gostopDir = (stateDir) => path.join(stateDir, "gostop");
export const sandboxRoot = (stateDir) => path.join(gostopDir(stateDir), "sandbox");
export const sandboxDir = (stateDir, sigkey) => path.join(sandboxRoot(stateDir), keyDir(sigkey));
export const runDir = (stateDir, sigkey) => path.join(stateDir, "runs", keyDir(sigkey));

export function mkdirp(dir) { fs.mkdirSync(dir, { recursive: true, mode: 0o700 }); return dir; }
// 임시 파일 → 이름 바꾸기(반쯤 쓴 파일을 남기지 않는다). 권한 600.
export function writeAtomic(file, text) {
  mkdirp(path.dirname(file));
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, text, { mode: 0o600 });
  fs.renameSync(tmp, file);
  return file;
}
export const readJson = (file, dflt = null) => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return dflt; } };

// 폴더 크기(바이트). 심볼릭 링크는 따라가지 않는다.
export function dirBytes(dir) {
  let n = 0;
  const walk = (d) => {
    let ents;
    try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.isFile()) { try { n += fs.statSync(p).size; } catch { /* 사라짐 */ } }
    }
  };
  walk(dir);
  return n;
}

// ── 사본 규칙(설계 §2) ───────────────────────────────────────────
// 사본에 있으면 안 되는 것. tar 단계에서 빼지만 한 번 더 확인한다(빠졌으면 사본을 쓰지 않는다).
export const FORBIDDEN_IN_COPY = [".git", ".claude", ".mcp.json", "android/key.properties", "android/app/google-services.json", "ios/Runner/GoogleService-Info.plist"];
export function forbiddenPresent(dir) {
  const hits = FORBIDDEN_IN_COPY.filter((rel) => fs.existsSync(path.join(dir, rel)));
  const keys = [];
  const walk = (d, depth) => {
    if (depth > 6) return;
    let ents;
    try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      if (e.isDirectory()) { if (!["build", ".dart_tool", "node_modules"].includes(e.name)) walk(path.join(d, e.name), depth + 1); }
      else if (/\.(jks|keystore|p12)$/i.test(e.name)) keys.push(path.relative(dir, path.join(d, e.name)));
    }
  };
  walk(dir, 0);
  return [...hits, ...keys];
}

// 회귀 주입(벤치): 사본 파일에서 정확히 한 곳을 바꾼다. 사람이 적은 변형이다(LLM 코드 아님). 0곳·여러 곳이면 거부.
export function applyInject(dir, inject) {
  const rel = String(inject?.file ?? "");
  if (!/^lib\/[A-Za-z0-9_/]+\.dart$/.test(rel)) throw new Error(`주입 파일 형식: ${rel}`);
  const file = path.join(dir, rel);
  const src = fs.readFileSync(file, "utf8");
  const n = src.split(inject.find).length - 1;
  if (n !== 1) throw new Error(`주입 자리가 ${n}곳(${rel}) — 정확히 1곳이어야 한다`);
  fs.writeFileSync(file, src.replace(inject.find, () => inject.replace));
}

// 사본에서 빼는 '기록' 문서(독립 검토 H3 상1): 수정 원장·작업 기록·QA 보고는 벤치 정답(무엇을 어디서 고쳤나)을 담는다.
// 남기는 문서는 규칙서(docs/rules)와 CLAUDE.md 뿐이다. 시험은 이 문서들을 읽지 않는다(10-03 확인 — test/ 에서 참조 0).
export const KEEP_DOCS = new Set(["rules"]);
export const DROP_TOP = ["context", "coverage", "qa", ".gemini", ".vscode", ".cursorrules", ".fvm.bak", "store_assets", ".cursor"];
export function pruneHistoryDocs(dir) {
  const removed = [];
  const rm = (rel) => { fs.rmSync(path.join(dir, rel), { recursive: true, force: true }); removed.push(rel); };
  const docs = path.join(dir, "docs");
  if (fs.existsSync(docs)) for (const e of fs.readdirSync(docs)) if (!KEEP_DOCS.has(e)) rm(path.join("docs", e));
  for (const t of DROP_TOP) if (fs.existsSync(path.join(dir, t))) rm(t);
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!e.isFile()) continue;
    if ((/\.(md|txt|png|jpe?g)$/i.test(e.name) && e.name !== "CLAUDE.md") || /^CHANGELOG/i.test(e.name)) rm(e.name);
  }
  return removed;
}

// 벤치 누설 검사: 코드(lib·test) 밖 글 파일에 정답 표지(수정 커밋 해시·정답 시험 이름 등)가 있으면 그 자리를 돌려준다.
// 코드 주석은 실제 회귀에서도 남아 있으므로 보지 않는다(설계 §1 '회귀 주입').
export function leakScan(dir, terms) {
  const want = (terms ?? []).map(String).filter((x) => x.length >= 5);
  const hits = [];
  if (!want.length) return hits;
  const walk = (d, rel) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const r = rel ? `${rel}/${e.name}` : e.name;
      if (e.isDirectory()) { if (!["lib", "test", "build", ".dart_tool", "assets", "android", "ios", "macos", "web", "node_modules"].includes(r)) walk(path.join(d, e.name), r); continue; }
      if (!e.isFile() || hits.length >= 20) continue;
      let buf;
      try { if (fs.statSync(path.join(d, e.name)).size > 2_000_000) continue; buf = fs.readFileSync(path.join(d, e.name)); } catch { continue; }
      if (buf.includes(0)) continue; // 바이너리
      const text = buf.toString("utf8");
      for (const t of want) if (text.includes(t)) { hits.push({ file: r, term: t }); break; }
    }
  };
  walk(dir, "");
  return hits;
}

// ── 대화 작업 표식(설계 §5.2①) ───────────────────────────────────
export const BUSY_FILE = ".jarvis-busy";
export const BUSY_RECENT_MS = 30 * 60_000;
// lastCommitSec: 본 저장소 모든 가지 중 최근 커밋 시각(초, git.last-commit-time). 표식 파일이 있거나 30분 안 커밋이면 이유를 낸다.
export function busyReason(repo, nowMs, lastCommitSec) {
  if (fs.existsSync(path.join(repo, BUSY_FILE))) return `대화 작업 표식(${BUSY_FILE})이 있다`;
  const t = Number(lastCommitSec) * 1000;
  if (Number.isFinite(t) && t > 0 && nowMs - t < BUSY_RECENT_MS && nowMs - t > -5 * 60_000) {
    return `본 저장소에 ${Math.max(0, Math.round((nowMs - t) / 60_000))}분 전 커밋이 있다(30분 안 — 대화 작업 중으로 본다)`;
  }
  return null;
}

// ── 재현 출력 판독(사람이 쓴 기존 시험의 출력) ─────────────────────
// 차분 대조: '⛔ seed=N: …' 블록(들여쓴 4칸 줄까지). 일반 시험: 실패한 시험 이름. 서명은 흔들림 판정에 쓴다.
const strip = (s) => String(s).replace(/\u001b\[[0-9;]*m/g, "");
export function readTestOutput(raw, rc, signal = null) {
  const lines = strip(raw).replace(/\r/g, "\n").split("\n");
  const blocks = [];
  for (let i = 0; i < lines.length; i++) {
    const m = /^\s*⛔ (seed=\d+: .+)$/.exec(lines[i]);
    if (!m) continue;
    const blk = [m[1].trim()];
    for (let k = i + 1; k < lines.length && /^ {4}\S/.test(lines[k]) && blk.length < 25; k++) blk.push(lines[k].trim());
    if (!blocks.some((b) => b[0] === blk[0])) blocks.push(blk);
  }
  const failed = [];
  for (const l of lines) {
    const m = /^\d{2}:\d{2} \+\d+(?: ~\d+)? -\d+: (.+?) \[E\]\s*$/.exec(l.trim());
    if (m && !failed.includes(m[1])) failed.push(m[1].slice(0, 200));
  }
  const compileError = lines.some((l) => /^(?:lib|test)\/\S+\.dart:\d+:\d+: Error:/.test(l.trim()) || /Failed to load ".*": Compilation failed/.test(l));
  const summary = lines.map((l) => l.trim()).find((l) => /^★ /.test(l)) ?? null;
  // 신호로 죽음(코드 없음)은 초록이 아니라 실행 실패다(H3 하) — 그래프가 같은 회차를 다시 띄운다
  const infra = rc == null || signal != null;
  const red = !infra && Number(rc) !== 0;
  // 서명: 불일치 블록(차분 대조) 또는 실패한 시험 이름 — 메모·시각처럼 매번 바뀌는 줄은 뺀다
  const sig = blocks.length
    ? blocks.map((b) => b.filter((x) => !/^메모:|^결정 \d+건/.test(x)).join(" | ")).join(" || ")
    : failed.join(" || ");
  // 빨간불인데 불일치·실패 시험·컴파일 오류 어느 것도 없으면 도구 오류(없는 파일·flutter 고장)다 — 재현으로 세지 않는다(H3 하)
  const toolError = red && !blocks.length && !failed.length && !compileError;
  return { red, rc: rc == null ? null : Number(rc), infra, toolError, blocks, failed, compileError, summary, sig: red ? (sig || "(실패 · 서명 없음)") : "" };
}

// 2회 결과 → 재현 판정. 둘 다 같은 서명의 빨간불 = reproduced, 둘 다 초록 = not_reproduced, 그 밖 = flaky.
export function judgeRepro(runs) {
  if (runs.length < 2) return null;
  const [a, b] = runs;
  if (a.compileError || b.compileError) return "compile_error";
  if (a.toolError || b.toolError) return "tool_error";
  if (a.red && b.red) return a.sig === b.sig ? "reproduced" : "flaky";
  if (!a.red && !b.red) return "not_reproduced";
  return "flaky";
}

// LLM 에게 보일 재현 발췌 — 불일치 블록·실패 이름·요약만(로그 통째로 넘기지 않는다).
export function reproExcerpt(r) {
  if (!r) return "(재현 없음)";
  const out = [];
  if (r.summary) out.push(r.summary);
  for (const b of r.blocks.slice(0, 3)) out.push(...b.map((x, i) => (i ? `    ${x}` : `⛔ ${x}`)));
  for (const f of r.failed.slice(0, 5)) out.push(`실패한 시험: ${f}`);
  if (!out.length) out.push(r.red ? `시험 실패(코드 ${r.rc}) — 판독할 줄 없음` : `통과(코드 ${r.rc})`);
  return out.join("\n").slice(0, 4000);
}

// ── 진단 JSON(설계 §5.2④) ─────────────────────────────────────────
export const DIAG_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["hypothesis", "files", "rule_gap", "confidence", "evidence"],
  properties: {
    hypothesis: { type: "string", description: "원인 가설(한국어, 3~8문장)" },
    files: { type: "array", items: { type: "string" }, maxItems: 10, description: "원인이 있는 파일 — 저장소 기준 상대 경로(lib/…, test/…)" },
    rule_gap: { type: "boolean", description: "규칙서에 이 상황을 정하는 조항이 없어 코드가 아니라 규칙 결정이 필요하면 true" },
    rule_gap_detail: { type: "string", description: "rule_gap 이면 무엇이 정해져 있지 않은지" },
    confidence: { type: "number", minimum: 0, maximum: 1 },
    evidence: { type: "array", items: { type: "string" }, maxItems: 10, description: "근거 — '파일:줄 — 한 줄 설명'" },
  },
};
export const Diag = z.object({
  hypothesis: z.string().min(1).max(4000),
  files: z.array(z.string().max(300)).max(10),
  rule_gap: z.boolean(),
  rule_gap_detail: z.string().max(2000).optional(),
  confidence: z.number().min(0).max(1),
  evidence: z.array(z.string().max(500)).max(10),
}).strip();

// 구조화 출력이 오면 그것을, 없으면 본문에서 첫 JSON 객체를 찾는다. 맞지 않으면 null.
export function parseDiag(structured, text) {
  const cands = [];
  if (structured && typeof structured === "object") cands.push(structured);
  const s = String(text ?? "");
  const fence = /```(?:json)?\s*(\{[\s\S]*?\})\s*```/.exec(s);
  if (fence) cands.push(fence[1]);
  const a = s.indexOf("{"), b = s.lastIndexOf("}");
  if (a >= 0 && b > a) cands.push(s.slice(a, b + 1));
  for (const c of cands) {
    try {
      const obj = typeof c === "string" ? JSON.parse(c) : c;
      const r = Diag.safeParse(obj);
      if (r.success) return { ...r.data, files: r.data.files.map(normRel).filter(Boolean) };
    } catch { /* 다음 후보 */ }
  }
  return null;
}
// 저장소 기준 상대 경로로. '..' 는 펴서 본다 — 펴도 저장소 밖(.. 로 시작·절대 경로)이면 '?' 를 앞에 붙여 허용 목록에 안 걸리게(H3 하)
export const normRel = (f) => {
  const s = String(f).trim().replace(/^\.\//, "").replace(/^[A-Za-z]:/, "").replace(/^\/.*?\/(?=(lib|test|docs)\/)/, "").replace(/:\d+(?:[-:]\d+)?$/, "");
  const n = path.posix.normalize(s);
  return n.startsWith("..") || n.startsWith("/") ? `?${n}` : n;
};

// ── 수정 범위 미리 보기(설계 §4① 허용 목록 · §4② AI 영역) ─────────────
const ALLOW = [/^lib\/domain\/game\//, /^lib\/presentation\/providers\/(game_provider|bomb_handler)\.dart$/, /^test\//];
const AI_AREA = /^lib\/domain\/ai\//;
export function scopeOf(diag) {
  const files = (diag?.files ?? []).map(normRel);
  const ai = files.filter((f) => AI_AREA.test(f));
  const outside = files.filter((f) => !AI_AREA.test(f) && !ALLOW.some((re) => re.test(f)));
  const mcts = /MCTSConstants/.test(`${diag?.hypothesis ?? ""} ${(diag?.evidence ?? []).join(" ")}`);
  const reasons = [];
  if (ai.length || mcts) reasons.push(`게임 AI 영역(${[...ai, ...(mcts ? ["MCTSConstants"] : [])].join(", ")}) — §4② 결정 비교 시험 전까지 승인 대상`);
  if (outside.length) reasons.push(`수정 허용 목록 밖(${outside.join(", ")}) — §4① 승인 대상`);
  const conditional = files.filter((f) => /^lib\/presentation\/providers\/(game_provider|bomb_handler)\.dart$|^lib\/domain\/game\/turn_manager\.dart$/.test(f));
  return { files, ai, outside, reasons, note: conditional.length ? `규칙 처리부 파일(${conditional.join(", ")}) — 1b 에서 AI 결정 비교(§4②)를 통과해야 한다` : null };
}

// ── 벤치 ─────────────────────────────────────────────────────────
export function loadBench(file = BENCH_FILE) {
  const j = readJson(file);
  if (!j || !Array.isArray(j.cases)) throw new Error(`벤치 목록을 못 읽음: ${file}`);
  return j;
}
// 진단이 벤치 정답과 맞나(H3 상2 — 프롬프트 낱말은 채점하지 않는다. 낱말은 '실패한 시험' 이름으로 이미 프롬프트에 있다):
//   ① 기대 파일이 진단 파일 1~2위 안에 있고 ② 근거('파일:줄')가 정답 자리(수정·주입한 줄 범위) ±NEAR 줄 안을 가리키며
//   ③ 규칙 공백 판정·최종 상태가 기대와 같을 때만 맞음. 정답 자리 = expect.lines { 파일: [[시작, 끝], …] }(벤치 준비 때 diff 로 계산).
export const NEAR = 15;
export function evidenceRefs(diag) {
  const refs = [];
  for (const e of [...(diag?.evidence ?? []), diag?.hypothesis ?? ""]) {
    for (const m of String(e).matchAll(/((?:lib|test|docs)\/[A-Za-z0-9_./-]+\.(?:dart|md)):(\d+)(?:[-~](\d+))?/g)) {
      refs.push({ file: normRel(m[1]), from: Number(m[2]), to: Number(m[3] ?? m[2]) });
    }
  }
  return refs;
}
export function diagMatch(expect, diag, status) {
  if (!expect) return null;
  const why = [];
  if (!diag) return { ok: false, why: ["진단 없음"] };
  const top = (diag.files ?? []).map(normRel).slice(0, 2);
  if (expect.files?.length && !expect.files.some((f) => top.includes(f))) why.push(`기대 파일이 1~2위에 없음(기대 ${expect.files.join(",")} · 진단 ${top.join(",") || "-"})`);
  if (expect.lines && Object.keys(expect.lines).length) {
    const refs = evidenceRefs(diag);
    const near = refs.some((r) => (expect.lines[r.file] ?? []).some(([a, b]) => r.to >= a - NEAR && r.from <= b + NEAR));
    if (!near) why.push(`근거 줄이 정답 자리 ±${NEAR}줄 밖(근거 ${refs.slice(0, 4).map((r) => `${r.file.split("/").pop()}:${r.from}`).join(", ") || "없음"})`);
  }
  if (typeof expect.ruleGap === "boolean" && diag.rule_gap !== expect.ruleGap) why.push(`규칙 공백 판정 ${diag.rule_gap}(기대 ${expect.ruleGap})`);
  if (expect.status && status && expect.status !== status) why.push(`상태 ${status}(기대 ${expect.status})`);
  return { ok: why.length === 0, why };
}

// ── 신호 → 재현 명령 ───────────────────────────────────────────────
// 돌려주는 값: { cmd: "flutter.test-defines"|"flutter.test-file", params } 또는 null(재현 수단 없음 — 제보만 있는 신호)
export function reproCommand(signal, dir) {
  const k = signal?.kind;
  if (k === "seed") {
    const defs = [...(signal.defines ?? [])].slice(0, 3);
    while (defs.length < 3) defs.push("LG_NOOP=1");
    return { cmd: "flutter.test-defines", params: { dir, test: signal.test ?? DIFF_TEST, d1: defs[0], d2: defs[1], d3: defs[2] } };
  }
  if ((k === "test" || k === "inject") && signal.test) return { cmd: "flutter.test-file", params: { dir, test: signal.test } };
  return null;
}

// 벤치 사례 → 수정 그래프 신호
export function benchSignal(c, round = 1) {
  const sig = { source: "bench", kind: c.kind, sigkey: `bench:${c.id}:r${round}`, rev: c.rev,
    bench: { id: c.id, expect: c.expect ?? null, leakTerms: [...new Set([c.origin, ...(c.leakTerms ?? [])].filter(Boolean))] } };
  if (c.test) sig.test = c.test;
  if (c.defines) sig.defines = c.defines;
  if (c.report) sig.report = c.report;
  if (c.inject) sig.inject = c.inject;
  return sig;
}

// ── 그 밖 ────────────────────────────────────────────────────────
export const short = (s, n = 200) => String(s ?? "").replace(/\s+/g, " ").trim().slice(0, n);
export const kstDay = (ms) => new Date(ms).toLocaleDateString("sv-SE"); // 이 기기 시간대 YYYY-MM-DD(실행기 localDay 와 같은 식)
