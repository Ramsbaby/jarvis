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
// 실패한 시험 이름 앞의 절대경로(격리 사본마다 다른 …/work/·…/base/)를 저장소 기준 경로로 줄인다 — 같은 시험을 사본끼리 견줄 수 있게.
// 10-07: 전체 시험을 깨끗한 내보내기와 견줄 때 경로가 달라 기존 실패 99건이 전부 '이번 수정에서 새로 실패'로 세어져 옳은 수정이 거절됐다.
export const relTestName = (n) => String(n).replace(/^(loading )?\/\S*\/((?:test|integration_test)\/[^\s:]*\.dart)/, "$1$2");
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
    const name = m && relTestName(m[1]).slice(0, 200);
    if (name && !failed.includes(name)) failed.push(name);
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

// 시험 도구가 시험을 하나도 돌리지 못하고 끝났나 — 진행 줄('00:01 +0: …')이 하나도 없고, 종료 코드가 시험 결과(0·1)·시간 초과(124)·
// 격리 준비(97)·격리 위반(98)이 아니다(dart 의 처리 안 된 예외는 255). 시험(LLM 이 쓴 재현 시험·수정) 탓이 아니라 실행 환경 탓이다 —
// 시험을 다시 쓰게 하거나 재수정으로 보내지 않는다(10-04~06: 격리 stdio 고장의 255·0초가 'no_red' 로 끝났다).
const TEST_PROGRESS_RE = /^\s*\d{2}:\d{2} \+\d+/m;
export function toolCrash(code, raw) {
  if (code == null || [0, 1, 97, 98, 124].includes(Number(code))) return false;
  return !TEST_PROGRESS_RE.test(strip(raw).replace(/\r/g, "\n"));
}
// 도구 고장 출력의 대표 한 줄(처리 안 된 예외면 그 예외 줄)
export function crashLine(raw) {
  const lines = strip(raw).split("\n").map((l) => l.trim()).filter(Boolean);
  const i = lines.findIndex((l) => /^Unhandled exception:?$/.test(l));
  return short(i >= 0 && lines[i + 1] ? lines[i + 1] : lines[0] ?? "(출력 없음)", 200);
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
// 채점(gostop-fix grade_prep)이 읽는 벤치 파일 — 시험만 LG_BENCH_FILE 로 가짜 사례를 준다
export const benchFile = () => process.env.LG_BENCH_FILE || BENCH_FILE;

// 숨긴 정답 채점(M8) 계획 — 사례·고칠 안 상태·정본 패치로 정한다. 정답은 사본 밖(벤치 파일·본 저장소)에서 LLM 단계가 다 끝난 뒤에만 읽는다.
//   역사 사례: 수정 커밋(origin)의 시험(hiddenTests) — 본 저장소에서 꺼낸다(git.show-file)
//   회귀 주입·시험 신호: 그 변형을 잡는 기존 시험(test) — 깨끗한 내보내기의 사람 판(설계 §1 '지금 있는 시험이 정답')
// 돌려주는 값: { tests, source: "origin"|"clean", rev? } 또는 { skip, hidden_pass(false·null) }
//   hidden_pass null = 채점 대상이 아니다(규칙 결정 사례 · 누설 · 정답이 정해지지 않음). false = 고쳐야 했는데 낼 패치가 없다.
export const ANSWER_TEST_RE = /^test\/(?:[A-Za-z0-9_]+\/)*[A-Za-z0-9_]+_test\.dart$/;
export function gradeSpec(c, { status, patch, leak = null } = {}) {
  if (!c) return { skip: "벤치 사례를 찾지 못함", hidden_pass: null };
  if (leak) return { skip: "정답 누설로 진단하지 않은 사례", hidden_pass: null };
  const ruleCase = c.expect?.status === "rule_decision";
  if (ruleCase && !patch) return { skip: `규칙 결정 사례(${status}) — 사람이 규칙을 정해야 고친다(숨긴 정답은 그 결정)`, hidden_pass: null };
  if (!["ready", "would_ask"].includes(status) || !patch) return { skip: `낼 패치 없음(${status})`, hidden_pass: false };
  const tests = c.hiddenTests?.length ? c.hiddenTests : (c.kind === "inject" || c.kind === "test") && c.test ? [c.test] : [];
  if (!tests.length) return { skip: "정답 시험이 정해지지 않은 사례", hidden_pass: null };
  const bad = tests.filter((t) => !ANSWER_TEST_RE.test(t));
  if (bad.length) return { skip: `정답 시험 경로가 규칙 밖: ${bad.join(", ")}`, hidden_pass: null };
  if (c.hiddenTests?.length) {
    if (!/^[0-9a-f]{7,40}$/.test(String(c.origin ?? ""))) return { skip: `정답 커밋(origin)이 없다: ${c.origin}`, hidden_pass: null };
    return { tests, source: "origin", rev: c.origin };
  }
  return { tests, source: "clean" };
}
// 채점 결과 → hidden_pass. 대조군(패치 전)이 빨강이 아니면 그 정답으로는 채점할 수 없다(null). 실행 고장도 null.
export function gradeVerdict(g) {
  if (!g) return null;
  if (g.skipped) return g.hidden_pass ?? null;
  if (g.error || g.controlRed === false) return null;
  const patched = (g.runs ?? []).filter((r) => r.phase === "patched");
  if (!patched.length || patched.length < (g.tests ?? []).length) return null;
  return patched.every((r) => r.rc === 0);
}
// 진단이 벤치 정답과 맞나(H3 상2 — 프롬프트 낱말은 채점하지 않는다. 낱말은 '실패한 시험' 이름으로 이미 프롬프트에 있다):
//   ① 기대 파일이 진단 파일 1~2위 안에 있고 ② 근거('파일:줄')가 정답 자리(수정·주입한 줄 범위) ±NEAR 줄 안을 가리키며
//   ③ 규칙 공백 판정·최종 상태가 기대와 같을 때만 맞음. 정답 자리 = expect.lines { 파일: [[시작, 끝], …] }(벤치 준비 때 diff 로 계산).
export const NEAR = 15;
// 근거 '파일:줄' 을 뽑는다. 폴더 없이 파일 이름만 쓴 것(turn_manager.dart:1572)·'L1572' 꼴도 받고(진단 파일 목록에서 경로를 찾는다),
// 넓은 범위(40줄 넘게)는 아무 데나 맞으므로 근거로 치지 않는다(재검토 B 하2).
export const MAX_REF_SPAN = 40;
export function evidenceRefs(diag) {
  const refs = [];
  const known = (diag?.files ?? []).map(normRel);
  for (const e of [...(diag?.evidence ?? []), diag?.hypothesis ?? ""]) {
    for (const m of String(e).matchAll(/((?:(?:lib|test|docs)\/)?[A-Za-z0-9_./-]*?[A-Za-z0-9_]+\.(?:dart|md)):L?(\d+)(?:[-~]L?(\d+))?/g)) {
      let file = normRel(m[1]);
      if (!/^(lib|test|docs)\//.test(file)) file = known.find((k) => k.endsWith(`/${file}`)) ?? file;
      const from = Number(m[2]), to = Number(m[3] ?? m[2]);
      if (to < from || to - from > MAX_REF_SPAN) continue;
      refs.push({ file, from, to });
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

// ── 1b: 쓰기 루프(설계 §5.2 ⑦~⑯) ─────────────────────────────────
// 그래프가 판정·파일 정리에 쓰는 순수 도우미. 명령은 여기서 돌리지 않는다(노드가 tools.run/launch 로만).
export const REPRO_DIR = "test/repro";
export const H5_SUPPORT = "test/repro/three_path_support.dart"; // 고스톱 3경로 틀(H5) — 있으면 그 표식('3경로/엔진' 묶음)을 쓴다
export const AI_POLICY = { gen: "test/ai_policy/ai_policy_gen_test.dart", compare: "test/ai_policy/ai_policy_compare_test.dart",
  trusted: ["test/ai_policy/ai_policy_core.dart", "test/ai_policy/ai_policy_compare_test.dart"] };
export const hasH5Frame = (dir) => fs.existsSync(path.join(dir, H5_SUPPORT));
export const hasAiPolicy = (dir) => [AI_POLICY.gen, ...AI_POLICY.trusted].every((rel) => fs.existsSync(path.join(dir, rel)));
// 벤치 기준 커밋이 AI 결정 비교 시험(10-03 추가)보다 오래됐을 때 지금 저장소의 시험 코드(.dart)만 사본에 얹는다 — 오늘 루프가 쓰는
// 검증 도구로 옛 결함을 잰다(정답이 아니다). README 는 사례 이름이 적혀 있어(누설 검사에 걸림) 얹지 않는다. 얹은 파일 수를 돌려준다.
export function overlayAiPolicy(repo, dir) {
  const rel = path.dirname(AI_POLICY.gen);
  const names = fs.readdirSync(path.join(repo, rel)).filter((f) => f.endsWith(".dart")).sort();
  for (const f of names) copyNoFollow(path.join(repo, rel, f), dir, `${rel}/${f}`);
  return names.map((f) => `${rel}/${f}`);
}
// 분석 출력에서 얹은 AI 비교 시험 파일의 오류 수 — 옛 커밋의 API 와 안 맞으면(10-07 69a0144^: aiDifficulty 매개변수 없음) 도로 뺀다
export const aiPolicyErrors = (raw) => strip(raw).split("\n").filter((l) => /^\s*error • .* • (?:\S*\/)?test\/ai_policy\/[^ ]+:\d+:\d+ • /.test(l)).length;
// 벤치 M8 'AI 분기 오판' — 정본 수정이 AI 결정을 바꾸는 사례인지(expect.aiChange, 기본 false: 규칙 결함 사례는 AI 영역을 고치지 않는다)와
// 그래프의 AI 결정 비교 판정(pass=같음·fail=바뀜)이 어긋나면 true. 비교를 못 했으면(unavailable) null — '안 잼'으로 남긴다.
export function aiMisjudge(aiCheck, expect) {
  if (aiCheck !== "pass" && aiCheck !== "fail") return null;
  return (aiCheck === "fail") !== !!expect?.aiChange;
}
// 비교기(AI 결정 비교 시험)가 깨끗한 쪽과 바이트까지 같은가 — 패치가 비교기를 고쳤으면 그 비교는 믿지 않는다(ai-policy.sh 와 같은 규칙)
export function sameFiles(a, b, rels) {
  for (const rel of rels) {
    let x, y;
    try { x = fs.readFileSync(path.join(a, rel)); y = fs.readFileSync(path.join(b, rel)); } catch { return false; }
    if (!x.equals(y)) return false;
  }
  return true;
}

// 사본 복제(재현 시험을 쓴 직후의 '빨간 기준' redbase). 맨 위 build·.dart_tool 은 뺀다. 바로가기는 따라가지 않고 그대로.
export function copyTree(src, dst) {
  fs.rmSync(dst, { recursive: true, force: true });
  fs.cpSync(src, dst, { recursive: true, verbatimSymlinks: true, filter: (p) => !["build", ".dart_tool"].includes(path.relative(src, p)) });
  return dst;
}

// 명령이 낸 JSON 한 줄(표준 출력 끝 줄). 없거나 깨지면 null.
export function lastJson(stdout) {
  const lines = String(stdout ?? "").trim().split("\n").reverse();
  for (const l of lines) { try { const j = JSON.parse(l); if (j && typeof j === "object") return j; } catch { /* 다음 줄 */ } }
  return null;
}

// ⑦ 재현 시험이 바꾼 것(깨끗한 내보내기 대비): test/repro/ 아래 새 .dart 파일만. 시험 파일(_test.dart)은 정확히 하나, 도우미는 2개까지.
export const REPRO_FILE_RE = /^test\/repro\/[A-Za-z0-9_]+\.dart$/;
export function judgeReproFiles(files) {
  const bad = files.filter((f) => f.status !== "added" || !REPRO_FILE_RE.test(f.path) || f.path === H5_SUPPORT);
  const tests = files.filter((f) => !bad.includes(f) && f.path.endsWith("_test.dart")).map((f) => f.path);
  const support = files.filter((f) => !bad.includes(f) && !f.path.endsWith("_test.dart")).map((f) => f.path);
  const why = [];
  if (bad.length) why.push(`test/repro/ 밖이거나 새 파일이 아닌 변경: ${bad.map((f) => `${f.path}(${f.status})`).join(", ")}`);
  if (tests.length !== 1) why.push(`재현 시험 파일(test/repro/*_test.dart)이 ${tests.length}개 — 정확히 1개여야 한다`);
  if (support.length > 2) why.push(`도우미 파일이 ${support.length}개 — 2개까지`);
  return { ok: why.length === 0, test: tests[0] ?? null, tests, support, bad, why };
}
// 사본 안 쓰기 자리 — 격리 안 시험 코드가 사본에 바로가기를 심었을 수 있다(독립 검토 H10 상1). 조상 폴더가 바로가기면 거부하고,
// 마지막 자리가 바로가기·특수 파일이면 그 이름만 지운다(가리키는 곳은 건드리지 않는다). 돌려주는 값: 절대경로(그 자리는 비었거나 일반 파일).
export class UnsafePath extends Error { constructor(m) { super(m); this.name = "UnsafePath"; this.unsafe = true; } }
export function safeTarget(root, rel) {
  const parts = String(rel).split("/");
  if (!parts.length || parts.some((x) => !x || x === "." || x === ".." || x.toLowerCase() === ".git")) throw new UnsafePath(`경로 형식: ${rel}`);
  let cur = root;
  for (const part of parts.slice(0, -1)) {
    cur = path.join(cur, part);
    let st = null;
    try { st = fs.lstatSync(cur); } catch { /* 없음 — 만든다 */ }
    if (!st) fs.mkdirSync(cur, { mode: 0o700 });
    else if (!st.isDirectory()) throw new UnsafePath(`조상이 폴더가 아니다(바로가기 등): ${path.relative(root, cur)}`);
  }
  const dst = path.join(root, rel);
  let st = null;
  try { st = fs.lstatSync(dst); } catch { /* 없음 */ }
  if (st && !st.isFile()) { if (st.isDirectory()) throw new UnsafePath(`폴더 자리: ${rel}`); fs.unlinkSync(dst); }
  return dst;
}
// 바로가기를 따라가지 않고 일반 파일만 읽는다(크기 상한). 아니면 null.
export function readNoFollow(file, max = 64 << 20) {
  try {
    const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try { const st = fs.fstatSync(fd); if (!st.isFile() || st.size > max) return null; return fs.readFileSync(fd); } finally { fs.closeSync(fd); }
  } catch { return null; }
}
// 일반 파일 하나를 바로가기 없이 복사(읽기·쓰기 둘 다 따라가지 않는다)
export function copyNoFollow(src, root, rel) {
  const buf = readNoFollow(src);
  if (buf == null) throw new UnsafePath(`일반 파일이 아니다: ${src}`);
  const dst = safeTarget(root, rel);
  const fd = fs.openSync(dst, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_TRUNC | fs.constants.O_NOFOLLOW, 0o600);
  try { fs.writeSync(fd, buf); } finally { fs.closeSync(fd); }
  return dst;
}
// 허용 밖 변경을 되돌린다: 바뀐·지운 파일은 깨끗한 쪽에서 다시 복사, 새로 생긴 파일은 지운다(우리 사본 안만, 바로가기 따라가지 않음).
export function restoreFiles(work, clean, files) {
  for (const f of files) {
    const dst = safeTarget(work, f.path);
    if (f.status === "added") fs.rmSync(dst, { force: true });
    else copyNoFollow(path.join(clean, f.path), work, f.path);
  }
}

// flutter analyze 출력의 오류·경고·정보 수. 재현 시험(test/repro/)의 지적은 뺀다 — 기준 사본에는 그 파일이 없고 수정 단계는 그 파일을
// 고칠 수 없다(⑩ frozen). 거기 경고 하나로 수정 3회를 날리지 않게(독립 검토 H10 중5).
export function analyzeCounts(raw, { exclude = /^test\/repro\// } = {}) {
  const lines = strip(raw).split("\n");
  const n = (k) => lines.filter((l) => {
    const m = new RegExp(`^\\s*${k} • .* • ([^ ]+?):\\d+:\\d+ • `).exec(l) ?? new RegExp(`^\\s*${k} • `).exec(l);
    return m && !(m[1] && exclude.test(m[1]));
  }).length;
  return { errors: n("error"), warnings: n("warning"), infos: n("info") };
}

// ⑧ 빨간불의 질: 표식 붙은 경로 시험이 단언(Expected/Actual)으로 실패해야 한다. 파일을 싣다 죽음(loading … [E])·예외만은 빨간불이 아니다(H10 중6).
export const MARKED_TEST_RE = /(?:엔진|라이브\s*사람|라이브\s*AI|engine|live[\s_-]*(?:human|ai))\s*[:：\]]|3경로\/|\[(?:engine|live-human|live-ai)\]/i;
export function redQuality(out, raw) {
  const marked = out.failed.filter((n) => MARKED_TEST_RE.test(n));
  const loading = out.failed.some((n) => /^loading /.test(n));
  const assertion = /^\s*Expected: /m.test(strip(raw));
  return { ok: marked.length > 0 && !loading && assertion && !out.compileError, marked, loading, assertion };
}

// AI 호출부(고스톱 scripts/ai-policy.sh callsites 의 옮김 — test/ai_policy/README: 결정 비교는 호출부 변경을 못 잡는다).
// 패치 덩어리(맥락 줄 포함)에 이 글자가 있거나 lib/domain/ai/** 를 건드리면 AI 변경 의심 → 승인 사유(H10 상4).
export const AI_CALL_RE = /AIPlayer|aiPlayerProvider|aiDifficultyProvider|_getAIDifficulty|getAIDifficultyBomb|selectCard[(]|selectMatch[(]|shouldGo[(]|selectGukjinChoice|weakeningFactor|aiAdjusterProvider|getWeakeningFactor|difficultyAdjusterProvider|getRecommendedDifficulty|AIDifficultyAdjuster|AIAdjuster|MCTSEngine|MCTSConfig|MCTSConstants|soakRng|AIPersona|mctsEnabled/;
export function aiCallsites(patchText) {
  const hits = [];
  let file = "", minus = "", hunk = "";
  const rel = (p) => { const q = `/${String(p).replace(/\t.*$/, "")}`; const i = q.lastIndexOf("/lib/"); return i >= 0 ? q.slice(i + 1) : ""; };
  for (const line of String(patchText ?? "").split("\n")) {
    if (line.startsWith("--- ")) { minus = rel(line.slice(4)); continue; }
    if (line.startsWith("+++ ")) { const p = line.slice(4); file = /^\/dev\/null/.test(p) ? minus : rel(p); continue; }
    if (line.startsWith("@@")) { hunk = line; continue; }
    if (/^(diff|Only in|Binary) /.test(line) || !file) continue;
    if (file.startsWith("lib/domain/ai/")) { if (!hits.some((h) => h.file === file)) hits.push({ file, hunk: "(AI 파일)" }); continue; }
    if (AI_CALL_RE.test(line) && !hits.some((h) => h.file === file && h.hunk === hunk)) hits.push({ file, hunk });
  }
  return hits;
}

// 고스톱 3경로 틀(H5) 쓰임새 — 시험이 틀의 도우미를 실제로 부르고, LLM 도우미 파일이 틀의 이름을 다시 정의하지 않는다(H10 중7)
export function h5FrameUse(testSrc, supportSrcs = []) {
  const why = [];
  if (!/import\s+['"][^'"]*three_path_support\.dart['"]/.test(testSrc)) why.push("three_path_support.dart 를 가져오지 않는다");
  for (const [re, name] of [[/\brunEnginePath\s*\(/, "runEnginePath("], [/\.runHuman\s*\(/, ".runHuman("], [/\.runAi\s*\(/, ".runAi("]]) if (!re.test(testSrc)) why.push(`${name} 호출이 없다`);
  for (const s of supportSrcs) if (/\b(threePathAiDifficulties|runEnginePath|ThreePathHarness)\b/.test(s)) why.push("도우미 파일이 3경로 틀의 이름을 다시 정의한다");
  return { ok: why.length === 0, why };
}
// 시험 실행기(flutter_test_listener)가 자기 연결을 못 열어 싣지 못한 시험 파일(저장소 기준 경로) — 시험 코드가 돌기도 전의 실행 환경 고장이다.
// 'loading <파일> [E]' 바로 앞(40줄 안)에 그 실행기의 처리 안 된 SocketException 이 있을 때만 센다. 컴파일 오류는 여기 들지 않는다.
export function runnerLoadFlakes(raw) {
  const lines = strip(raw).replace(/\r/g, "\n").split("\n");
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const m = /^\d{2}:\d{2} \+\d+(?: ~\d+)? -\d+: loading (\S+\.dart) \[E\]\s*$/.exec(lines[i].trim());
    if (!m) continue;
    const back = lines.slice(Math.max(0, i - 40), i).join("\n");
    if (/SocketException/.test(back) && /flutter_test_listener/.test(back) && !/Compilation failed|: Error:/.test(back)) {
      const f = relTestName(m[1]);
      if (/^(?:test|integration_test)\//.test(f) && !out.includes(f)) out.push(f);
    }
  }
  return out;
}
// 실패 항목(불일치 블록 첫 줄 + 실패한 시험 이름) — 기준(깨끗한 내보내기)과 견줄 때 쓴다
export const failureItems = (out) => [...new Set([...out.blocks.map((b) => b[0]), ...out.failed.map(relTestName)])];

// 씨앗 — sigkey 로 정해진 수(같은 스레드는 같은 판)
export function seedFor(sigkey, base = 20261000) {
  let h = 2166136261;
  for (const ch of String(sigkey)) { h ^= ch.codePointAt(0); h = Math.imul(h, 16777619) >>> 0; }
  return base + (h % 900_000);
}

// ⑫ 검토 JSON
export const REVIEW_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["approve", "three_path", "unrelated_changes", "rule_match", "issues", "summary"],
  properties: {
    approve: { type: "boolean", description: "이 패치를 그대로 반영해도 되면 true" },
    three_path: { type: "boolean", description: "엔진·라이브 사람·라이브 AI 세 경로가 같은 규칙으로 고쳐졌거나 원래 맞았으면 true" },
    unrelated_changes: { type: "boolean", description: "결함과 무관한 변경(정리·이름 바꾸기·다른 기능)이 있으면 true" },
    rule_match: { type: "boolean", description: "규칙서(docs/rules)와 맞으면 true" },
    issues: { type: "array", items: { type: "string" }, maxItems: 10, description: "고쳐야 할 점 — '파일:줄 — 설명'" },
    summary: { type: "string", description: "한국어 2~4문장" },
  },
};
const Review = z.object({ approve: z.boolean(), three_path: z.boolean(), unrelated_changes: z.boolean(), rule_match: z.boolean(),
  issues: z.array(z.string().max(500)).max(10), summary: z.string().max(3000) }).strip();
export function parseReview(structured, text) {
  const cands = [];
  if (structured && typeof structured === "object") cands.push(structured);
  const s = String(text ?? "");
  const a = s.indexOf("{"), b = s.lastIndexOf("}");
  if (a >= 0 && b > a) cands.push(s.slice(a, b + 1));
  for (const c of cands) {
    try { const r = Review.safeParse(typeof c === "string" ? JSON.parse(c) : c); if (r.success) return r.data; } catch { /* 다음 */ }
  }
  return null;
}
// 검토 통과 = 승인 + 3경로 + 무관한 변경 없음 + 규칙 일치
export const reviewPass = (r) => !!r && r.approve && r.three_path && !r.unrelated_changes && r.rule_match;

// ── 1b 프롬프트(정답·수정 커밋은 사본에 없다 — §2) ───────────────────
function signalLines(sg) {
  const out = [`출처: ${sg.source ?? "?"} · 종류: ${sg.kind ?? "?"}`];
  if (sg.kind === "seed") out.push(`재현 명령: flutter test ${sg.test ?? DIFF_TEST} ${(sg.defines ?? []).map((d) => `--dart-define=${d}`).join(" ")}`);
  if (sg.kind === "test" || sg.kind === "inject") out.push(`빨간불이 난 기존 시험: ${sg.test}`);
  if (sg.report) out.push(`제보:\n${String(sg.report).slice(0, 2000)}`);
  return out;
}
function diagLines(d) {
  if (!d) return ["(진단 없음)"];
  return [`가설: ${d.hypothesis}`, `파일: ${d.files.join(", ") || "-"}`, ...d.evidence.slice(0, 8).map((e) => `근거: ${e}`)];
}
export function reproTestPrompt({ signal, repro, diag, h5, feedback, existing }) {
  const name = h5
    ? ["묶음 이름은 반드시 '3경로/엔진 — …' · '3경로/라이브-사람 — …' · '3경로/라이브-AI — …' 로 시작한다(test/repro/three_path_template.dart 를 본떠라).",
      "도우미는 test/repro/three_path_support.dart 의 것(runEnginePath·runHuman·runAi·threePathAiDifficulties)을 쓴다. 라이브 AI 묶음은 threePathAiDifficulties(어려움 포함)를 돈다.",
      "파일 첫 줄은 '// 3경로 시험 v1' 이다."]
    : ["시험(또는 그것을 감싼 group) 이름에 표식을 붙인다: '엔진: …' · '라이브 사람: …' · '라이브 AI: …'.",
      "라이브 AI 시험은 AIDifficulty.hard 를 반드시 포함한다(AIDifficulty.values 로 셋 다 돌아도 된다).",
      "엔진·라이브를 몰아 보는 법은 기존 시험에서 찾는다: Grep 으로 'GameStateNotifier'·'ProviderContainer'·'_live_test.dart'·'live_soak_core' 를 찾아 본뜬다."];
  return [
    "너는 고스톱 앱(Flutter/Dart) 저장소 사본에서 **결함을 재현하는 시험만** 쓰는 사람이다. 작업 폴더가 그 사본이다(커밋 역사 없음, 명령 실행 도구 없음).",
    "코드(lib/)는 고치지 않는다. 기존 파일도 고치지 않는다. test/repro/ 아래 **새 파일만** 만든다:",
    `- 시험 파일 정확히 1개: test/repro/<짧은_영문_이름>_three_path_test.dart${existing ? ` — 이미 있는 ${existing} 를 고쳐 쓴다(새 시험 파일을 더 만들지 않는다)` : ""}`,
    "- 필요하면 도우미 .dart 파일 2개까지(test/repro/ 아래)",
    "",
    "[신호]", ...signalLines(signal ?? {}),
    "", "[재현 결과(사람이 쓴 기존 시험)]", repro ?? "(없음)",
    "", "[진단]", ...diagLines(diag),
    "",
    "[시험 틀 — 3경로를 다 둔다(설계 §5.2⑦)]",
    "같은 국면·같은 수를 세 경로로 돌려 같은 규칙 결과가 나와야 함을 expect 로 확인한다: ① 엔진(순수 규칙) ② 라이브 사람(앱이 사람 입력을 처리하는 길) ③ 라이브 AI(AI 차례를 처리하는 길).",
    ...name,
    "- skip 을 쓰지 않는다. 각 경로 시험 안에 expect(또는 expect 로 시작하는 도우미 호출)가 있어야 한다.",
    "- **지금 코드에서는 결함 때문에 하나 이상이 실패**해야 하고, 결함을 고치면 전부 통과해야 한다. 컴파일 오류가 나면 안 된다(import·이름을 사본에서 확인).",
    "- 시간이 오래 걸리지 않게 한 국면을 직접 만든다(판 전체를 여러 번 돌리지 않는다).",
    ...(feedback ? ["", "[지난 시도에서 고칠 점]", feedback] : []),
    "", "다 쓰면 만든 파일 경로와 각 경로가 무엇을 확인하는지 한국어로 짧게 답한다.",
  ].join("\n");
}
export function fixPrompt({ signal, diag, reproTest, redExcerpt, feedback, attempt }) {
  return [
    "너는 고스톱 앱(Flutter/Dart) 저장소 사본에서 **규칙 결함을 고치는** 사람이다. 작업 폴더가 그 사본이다(커밋 역사 없음, 명령 실행 도구 없음 — 시험은 밖에서 돌린다).",
    "",
    "[신호]", ...signalLines(signal ?? {}),
    "", "[진단]", ...diagLines(diag),
    "", `[재현 시험] ${reproTest} — 지금 코드에서 실패한다(빨간불):`, redExcerpt || "(발췌 없음)",
    "",
    "[규칙]",
    "- 고칠 수 있는 곳: lib/domain/game/** · lib/presentation/providers/game_provider.dart · lib/presentation/providers/bomb_handler.dart 의 규칙 처리 부분.",
    "- 고치지 않는다: test/ 아래 모든 파일(재현 시험 포함 — 시험을 바꿔 통과시키지 않는다), lib/domain/ai/**(게임 AI 판단), MCTSConstants, pubspec, 플랫폼·자산·결제·송출 코드.",
    "- 규칙서(docs/rules/)를 따른다. 엔진·라이브 사람·라이브 AI 세 경로가 같은 규칙 결과를 내게 한다.",
    "- 결함과 무관한 정리·이름 바꾸기·서식 변경을 하지 않는다. 바꾸는 줄은 적을수록 좋다.",
    ...(feedback ? ["", `[지난 시도(${attempt - 1}회째)에서 고칠 점]`, feedback] : []),
    "", "다 고치면 무엇을 왜 바꿨는지 한국어로 짧게 답한다.",
  ].join("\n");
}
export function reviewPrompt({ signal, diag, patch, verify }) {
  return [
    "너는 고스톱 앱 저장소의 **검토자**다. 아래 패치는 이미 사본(작업 폴더)에 적용돼 있다. 도구는 Read·Grep·Glob 뿐이다. 코드를 고치지 않고 판정만 한다.",
    "",
    "[신호]", ...signalLines(signal ?? {}),
    "", "[진단]", ...diagLines(diag),
    "", "[자동 검증 결과]", verify,
    "", "[패치(정본, diff -ruN 꼴)]", "```diff", String(patch ?? "").slice(0, 60_000), "```",
    "",
    "[볼 것]",
    "1. 3경로: 엔진·라이브 사람·라이브 AI 가 같은 규칙 결과를 내는가(한 경로만 고치고 다른 경로를 놓치지 않았나). 재현 시험(test/repro/)이 세 경로를 다 확인하는가.",
    "2. 무관한 변경이 없는가(정리·이름·다른 기능·시험 약화).",
    "3. 규칙서(docs/rules/GAME_MECHANICS.md 등)와 맞는가. AI 판단 코드(lib/domain/ai/**)를 건드리지 않았나.",
    "정해진 JSON 으로만 답한다. 고칠 점이 하나라도 있으면 approve=false.",
  ].join("\n");
}
