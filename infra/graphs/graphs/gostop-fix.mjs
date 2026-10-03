// gostop-fix.mjs — 고스톱 결함 하나(sigkey)를 사본에서 재현하고 진단해 '고칠 안'을 남긴다. 1a판: ①~⑥ + ⑭ (설계 §5.2).
//   ① preflight → ② sandbox → ③ reproduce_launch ⇄ reproduce_check(2회, 흔들림 판정) → ④ diagnose_launch ⇄ diagnose_check
//   → ⑤ scope_precheck → (실제 모드 + 승인 사유) ⑥ owner_gate → ⑭ plan
// 1a 는 LLM 이 쓴 코드를 실행하지 않는다. 사본에서 도는 것은 사람이 쓴 기존 시험뿐이다(벤치 회귀 주입도 사람이 적은 변형).
// 본 저장소는 읽기만 한다(git 읽기 명령 · 표식 파일 확인). 사본은 상태 폴더 gostop/sandbox/<sigkey>/ 에 역사 없이 푼다(§2).
// 규칙: interrupt 가 든 노드(owner_gate)는 동기·순수다 — 상태만 읽는다(scripts/check-interrupt-nodes.mjs).
import fs from "node:fs";
import path from "node:path";
import { StateGraph, Annotation, START, END, interrupt } from "@langchain/langgraph";
import {
  repoPath, sandboxDir, runDir, mkdirp, writeAtomic, dirBytes, forbiddenPresent, applyInject, busyReason, pruneHistoryDocs, leakScan,
  readTestOutput, judgeRepro, reproExcerpt, DIAG_SCHEMA, parseDiag, scopeOf, diagMatch, reproCommand, short, DIFF_TEST,
} from "./gostop-common.mjs";

// 한 번에 하나(S13) — 실행기가 같은 그래프의 시작된 미완 스레드가 있으면 대기열 것을 미룬다
export const meta = { name: "gostop-fix", description: "고스톱 결함 재현·진단(1a 읽기 전용)", serial: true };

const MAX_REPRO_ATTEMPTS = 3; // 분리 실행이 결과 없이 죽거나 최대 시간을 넘긴 경우의 다시 띄우기(같은 run 번호)
const MAX_DIAG_ATTEMPTS = 2; // sonnet ×≤2 (설계 §5.2④) — 답이 형식에 안 맞을 때
const MAX_DIAG_INFRA = 3; // 로그인 만료·사용량 한도로 다시 띄우는 횟수 — 이 둘은 모델 일을 쓰지 않아 시도와 따로 센다(H3 상3)
const DIAG_WAIT_MS = { login: 6 * 3_600_000, usage_limit: 3_600_000 }; // 관문(llm-hold)과 같은 쉼
const DIAG_TIMEOUT_MS = 15 * 60_000; // 분리 실행 — 최대 시간은 1.5배(22.5분)

const last = (a, b) => (b === undefined ? a : b);
const State = Annotation.Root({
  sigkey: Annotation(),
  signal: Annotation(),
  mode: Annotation({ reducer: last, default: () => "shadow" }),
  base: Annotation({ reducer: last, default: () => null }), // 대상 커밋 전체 해시
  work: Annotation({ reducer: last, default: () => null }), // 사본(LLM 작업 폴더·시험 실행)
  clean: Annotation({ reducer: last, default: () => null }), // 깨끗한 내보내기(1b 패치 추출 기준)
  sizes: Annotation({ reducer: last, default: () => null }),
  reproRuns: Annotation({ reducer: last, default: () => [] }),
  reproHandle: Annotation({ reducer: last, default: () => null }),
  reproAttempt: Annotation({ reducer: last, default: () => 1 }),
  repro: Annotation({ reducer: last, default: () => null }), // reproduced · not_reproduced · flaky · skipped · compile_error · failed
  diagHandle: Annotation({ reducer: last, default: () => null }),
  diagAttempt: Annotation({ reducer: last, default: () => 1 }),
  diagJob: Annotation({ reducer: last, default: () => 1 }), // 분리 실행 시도 번호(다시 띄울 때마다 +1 — 같은 번호는 같은 결과 파일)
  diagInfra: Annotation({ reducer: last, default: () => 0 }),
  diagWaitUntil: Annotation({ reducer: last, default: () => null }),
  leak: Annotation({ reducer: last, default: () => null }), // 벤치 정답 누설(사본 안 글 파일)
  pruned: Annotation({ reducer: last, default: () => 0 }),
  diag: Annotation({ reducer: last, default: () => null }),
  diagError: Annotation({ reducer: last, default: () => null }),
  scope: Annotation({ reducer: last, default: () => null }),
  approval: Annotation({ reducer: last, default: () => null }),
  status: Annotation({ reducer: last, default: () => null }),
  planPath: Annotation({ reducer: last, default: () => null }),
  log: Annotation({ reducer: (a, b) => a.concat(b), default: () => [] }),
});

// start 인자: --sigkey=… --signal='{"source":…}' (손으로 돌릴 때). 대기열은 접수 그래프가 { sigkey, signal } 으로 넣는다.
export function input(flags) {
  const signal = typeof flags.signal === "string" ? JSON.parse(flags.signal) : flags.signal ?? null;
  const sigkey = String(flags.sigkey ?? signal?.sigkey ?? "");
  if (!sigkey || !signal) throw new Error("gostop-fix 시작에는 --sigkey 와 --signal(JSON)이 필요하다");
  return { sigkey, signal: { ...signal, sigkey } };
}
export const summarize = (v) => `${v.status ?? "?"}${v.repro ? ` · 재현 ${v.repro}` : ""}${v.planPath ? ` · ${v.planPath}` : ""}`;

export function build({ checkpointer, llm, tools }) {
  const repo = repoPath();

  // ① 관문·대화 작업 표식 — 표식이 있으면 HOLD(다음 틱에 다시 본다). 대상 커밋을 전체 해시로 고정한다.
  async function preflight(s) {
    const lc = await tools.run("git.last-commit-time", { repo });
    const busy = busyReason(repo, tools.now(), lc.code === 0 ? lc.stdout.trim() : null);
    if (busy) throw tools.hold(`${busy} — 대화 작업과 겹치지 않게 보류`, "busy");
    const rev = String(s.signal?.rev ?? "HEAD");
    const r = await tools.run("git.rev-parse", { repo, rev });
    const base = r.code === 0 ? r.stdout.trim() : "";
    if (!/^[0-9a-f]{40}$/.test(base)) throw new Error(`대상 커밋을 찾지 못함: ${rev}(코드 ${r.code})`);
    return { mode: tools.mode, base, log: [`preflight ${base.slice(0, 8)} ${tools.mode}`] };
  }

  // ② 역사 없는 사본(설계 §2): git archive → work(사본)·clean(깨끗한 내보내기)에 비밀·설정을 빼고 푼다 → pub get --offline.
  async function sandbox(s) {
    const root = sandboxDir(tools.stateDir, s.sigkey);
    const work = path.join(root, "work"), clean = path.join(root, "clean"), tar = path.join(root, "src.tar"), ready = path.join(root, ".ready");
    const prev = fs.existsSync(ready) ? fs.readFileSync(ready, "utf8").trim() : "";
    if (prev !== s.base) { // 처음이거나, 도중에 끊긴 사본 — 처음부터 다시 만든다(상태 폴더 안 우리 사본만)
      fs.rmSync(root, { recursive: true, force: true });
      mkdirp(work); mkdirp(clean);
      const a = await tools.run("git.archive", { repo, out: tar, rev: s.base });
      if (a.code !== 0) throw new Error(`git archive 실패(코드 ${a.code}): ${short(a.stderr)}`);
      for (const dir of [work, clean]) {
        const x = await tools.run("tar.extract-sandbox", { tar, dir });
        if (x.code !== 0) throw new Error(`tar 풀기 실패(코드 ${x.code}): ${short(x.stderr)}`);
      }
      fs.rmSync(tar, { force: true });
      for (const dir of [work, clean]) pruneHistoryDocs(dir); // 수정 원장·작업 기록·QA 보고 — 정답이 적혀 있다(H3 상1)
      if (s.signal?.kind === "inject") { applyInject(work, s.signal.inject); applyInject(clean, s.signal.inject); }
      const bad = [...forbiddenPresent(work), ...forbiddenPresent(clean)];
      if (bad.length) throw Object.assign(new Error(`사본에 있으면 안 되는 것이 있다: ${bad.join(", ")}`), { codeDefect: true });
      const pg = await tools.run("flutter.pub-get-offline", { dir: work });
      if (pg.code !== 0) throw new Error(`pub get --offline 실패(코드 ${pg.code}): ${short(pg.stdout + pg.stderr, 300)}`);
      fs.writeFileSync(ready, s.base, { mode: 0o600 });
    }
    const sizes = { work: dirBytes(work), clean: dirBytes(clean) };
    // 벤치면 정답 표지(수정 커밋 해시·정답 시험 이름 등)가 사본 글 파일에 없는지 — 있으면 이 사례는 진단하지 않는다(plan: gave_up)
    const leak = s.signal?.bench ? leakScan(work, s.signal.bench.leakTerms) : [];
    return { work, clean, sizes, leak: leak.length ? leak : null, log: [`sandbox ${Math.round((sizes.work + sizes.clean) / 1e6)}MB${leak.length ? ` · 누설 ${leak.length}` : ""}`] };
  }

  // ③ 재현 — 사람이 쓴 기존 시험을 같은 조건으로 2회(흔들림 판정). 분리 실행이라 띄우기/확인 두 노드다.
  function reproduceLaunch(s) {
    const rc = reproCommand(s.signal, s.work);
    if (!rc) return { repro: "skipped", log: ["reproduce 재현 수단 없음(제보만) — 본문으로 진단"] };
    const n = s.reproRuns.length + 1;
    const opts = { node: `reproduce_${n}`, attempt: s.reproAttempt };
    const h = rc.cmd === "flutter.test-defines" ? tools.launch("flutter.test-defines", rc.params, opts) : tools.launch("flutter.test-file", rc.params, opts);
    return { reproHandle: h, log: [`reproduce_launch ${n}/2 시도 ${s.reproAttempt}`] };
  }
  function reproduceCheck(s) {
    const h = s.reproHandle;
    const st = tools.check(h);
    if (st.state === "running") throw tools.pending(`재현 ${s.reproRuns.length + 1}/2 진행 중`);
    // 결과 없이 죽음·최대 시간 초과(dead) · 시간 제한에 걸림(timedOut) · 띄우지 못함(error) — 재현이 아니라 실행 실패다.
    // 같은 회차를 다시 띄운다(통틀어 3회). 끝내 안 되면 failed → plan(gave_up).
    if (st.state === "dead" || st.timedOut || st.error || st.code == null || st.signal) {
      const why = st.state === "dead" ? `분리 실행 ${st.reason}` : st.timedOut ? "시간 제한 초과" : st.error ? `띄우기 오류 ${short(st.error, 80)}` : `신호로 끝남(${st.signal ?? "코드 없음"})`;
      const attempt = s.reproAttempt + 1;
      if (attempt > MAX_REPRO_ATTEMPTS) return { reproHandle: null, repro: "failed", log: [`reproduce ${why} — ${MAX_REPRO_ATTEMPTS}회 끝`] };
      return { reproHandle: null, reproAttempt: attempt, log: [`reproduce ${why} — 다시 띄움(${attempt})`] };
    }
    const raw = tools.output(h, "stdout") + tools.output(h, "stderr");
    const out = readTestOutput(raw, st.code, st.signal ?? null);
    const n = s.reproRuns.length + 1;
    const logFile = writeAtomic(path.join(runDir(tools.stateDir, s.sigkey), `repro-${n}.log`), raw.slice(-200_000));
    const run = { n, rc: out.rc, red: out.red, sig: out.sig, blocks: out.blocks, failed: out.failed, summary: out.summary,
      compileError: out.compileError, toolError: out.toolError, secs: Math.round(((st.endedAt ?? 0) - (st.startedAt ?? 0)) / 1000), log: logFile };
    const runs = [...s.reproRuns, run];
    const verdict = judgeRepro(runs);
    return { reproRuns: runs, reproHandle: null, reproAttempt: 1, repro: verdict, log: [`reproduce_check ${n}/2 rc=${run.rc} ${run.secs}s${verdict ? ` → ${verdict}` : ""}`] };
  }
  const afterReproCheck = (s) => {
    if (s.repro === "failed" || s.repro === "compile_error" || s.repro === "tool_error") return "plan";
    if (!s.repro) return "reproduce_launch"; // 다시 띄우기 또는 2회째
    // 차분 대조·시험 신호는 재현이 돼야 진단한다. 재현 안 됨·흔들림은 고칠 안으로 끝(설계 §5.2 간선)
    return s.repro === "reproduced" ? "diagnose_launch" : "plan";
  };

  // ④ 진단 — sonnet, --restricted, 읽기 도구만, 작업 폴더 = 사본, JSON 스키마(설계 §5.2④). 긴 호출이라 분리 실행.
  function diagPrompt(s) {
    const sg = s.signal ?? {};
    const first = s.reproRuns[0];
    const lines = [
      "너는 고스톱 앱(Flutter/Dart) 저장소 사본에서 결함의 원인을 찾는 진단가다. 지금 작업 폴더가 그 사본이다(커밋 역사는 없다).",
      "도구는 Read·Grep·Glob 뿐이다. 코드를 고치지 말고 원인 가설만 낸다. 작업 폴더 밖은 읽을 수 없다.",
      "",
      "[신호]",
      `출처: ${sg.source ?? "?"} · 종류: ${sg.kind ?? "?"}`,
    ];
    if (sg.kind === "seed") lines.push(`재현 명령: flutter test ${sg.test ?? DIFF_TEST} ${(sg.defines ?? []).map((d) => `--dart-define=${d}`).join(" ")}`);
    if (sg.kind === "test" || sg.kind === "inject") lines.push(`빨간불이 난 기존 시험: ${sg.test}`);
    if (sg.report) lines.push(`제보:\n${String(sg.report).slice(0, 3000)}`);
    if (sg.ciLog) lines.push(`CI 실패 로그 발췌:\n${String(sg.ciLog).slice(-4000)}`);
    lines.push("", "[재현 결과] 사람이 쓴 기존 시험을 같은 조건으로 2회 돌렸다.");
    lines.push(s.repro === "skipped" ? "재현 수단이 없는 신호다(제보만) — 제보 내용으로 진단한다." : `판정: ${s.repro}\n${reproExcerpt(first)}`);
    lines.push(
      "",
      "[할 일]",
      "1. 규칙서(docs/rules/GAME_MECHANICS.md 등)에서 이 상황을 정하는 조항을 찾는다. 조항이 없거나 이 상황의 결과를 정하지 않으면 rule_gap=true 다(코드 결함이 아니라 규칙 결정이 필요한 공백).",
      "2. 엔진(lib/domain/game/**)·라이브(lib/presentation/providers/game_provider.dart 등)·AI 경로 중 이 동작을 만드는 코드를 찾는다. 큰 파일은 Grep 으로 자리를 좁힌 뒤 필요한 줄만 Read 한다.",
      "3. 원인 가설(한국어), 원인이 있는 파일(저장소 기준 상대 경로), 근거('파일:줄 — 설명'), 확신도(0~1)를 정해진 JSON 으로만 답한다.",
    );
    return lines.join("\n");
  }
  function diagnoseLaunch(s) {
    // 로그인 만료·사용량 한도 뒤에는 관문과 같은 시간을 쉰다(그사이 틱 관문도 llm-hold 로 쉰다). 쉬는 동안은 보류 — 다음 틱에 다시 본다.
    if (s.diagWaitUntil && tools.now() < s.diagWaitUntil) throw tools.hold(`진단 호출 쉼 — ${new Date(s.diagWaitUntil).toISOString()} 뒤 다시`, "llm_wait");
    const h = llm.launchAsk(diagPrompt(s), { model: "sonnet", node: "diagnose", attempt: s.diagJob, tools: ["Read", "Grep", "Glob"], cwd: s.work,
      jsonSchema: DIAG_SCHEMA, timeoutMs: DIAG_TIMEOUT_MS });
    return { diagHandle: h, diagWaitUntil: null, log: [`diagnose_launch 시도 ${s.diagAttempt} · 실행 ${s.diagJob}`] };
  }
  function diagnoseCheck(s) {
    const st = llm.checkAsk(s.diagHandle);
    if (st.state === "running") throw tools.pending("진단 진행 중");
    if (st.state === "done") {
      const d = parseDiag(st.structured, st.text);
      if (d) return { diag: d, diagHandle: null, log: [`diagnose_check 확신도 ${d.confidence} · 파일 ${d.files.length} · 규칙 공백 ${d.rule_gap}`] };
    }
    // 로그인 만료·사용량 한도는 모델 시도로 세지 않고, 쉰 뒤 새 실행 번호로 다시 띄운다(H3 상3 — 같은 번호는 같은 결과 파일을 다시 읽는다).
    // 그 밖의 실패(결과 없이 죽음·시간 초과·호출 오류·형식 불일치)는 모델 일을 쓴 것이라 sonnet ×≤2 시도에 센다(재검토 B 중 — 설계 §5.2④).
    const infraFail = st.state === "failed" && (st.kind === "login" || st.kind === "usage_limit");
    if (infraFail) {
      const n = s.diagInfra + 1;
      const why = `${st.state} ${st.reason ?? st.kind ?? ""} ${short(st.error ?? "", 120)}`.trim();
      if (n > MAX_DIAG_INFRA) return { diagHandle: null, diagError: `진단 실행 실패 ${MAX_DIAG_INFRA}회 — ${why}`, log: [`diagnose 실행 실패 끝 — ${why}`] };
      const wait = DIAG_WAIT_MS[st.kind] ?? 0;
      return { diagHandle: null, diagJob: s.diagJob + 1, diagInfra: n, diagWaitUntil: wait ? tools.now() + wait : null, log: [`diagnose 실행 실패(${n}) — ${why}`] };
    }
    const why = st.state === "done" ? "진단 JSON 이 형식에 맞지 않음" : `${st.state} ${st.reason ?? st.kind ?? ""} ${short(st.error ?? "", 120)}`.trim();
    const attempt = s.diagAttempt + 1;
    if (attempt > MAX_DIAG_ATTEMPTS) return { diagHandle: null, diagError: why, log: [`diagnose 실패 ${MAX_DIAG_ATTEMPTS}회 — ${why}`] };
    return { diagHandle: null, diagAttempt: attempt, diagJob: s.diagJob + 1, log: [`diagnose 다시(${attempt}) — ${why}`] };
  }
  const afterDiagCheck = (s) => (s.diag ? "scope_precheck" : s.diagError ? "plan" : "diagnose_launch");

  // ⑤ 수정 범위 미리 보기 — 진단이 짚은 파일이 §4① 허용 목록 밖이거나 AI 영역이면 '승인 필요 예상'
  function scopePrecheck(s) {
    const scope = scopeOf(s.diag);
    return { scope, log: [`scope_precheck 사유 ${scope.reasons.length}`] };
  }
  // 실제 모드이고 사유가 있을 때만 사람에게 묻는다. 그림자는 묻지 않고 plan 이 '물었을 것'(would_ask)으로 적는다.
  const afterScope = (s) => (s.mode === "live" && !s.diag?.rule_gap && s.scope?.reasons?.length ? "owner_gate" : "plan");

  // ⑥ 승인(순수 interrupt) — 상태만 읽고 묻는다
  function ownerGate(s) {
    const decision = interrupt({ question: `고스톱 ${s.sigkey} 수정에 승인이 필요합니다`, reason: s.scope.reasons.join(" / ") });
    return { approval: decision, log: [`owner_gate ${decision}`] };
  }

  // ⑭ 고칠 안 — 상태를 정하고 runs/<sigkey>/plan.md 를 남긴다. 사본의 build·.dart_tool 은 지운다(사본은 3일 보관, §2).
  async function plan(s) {
    let status, note = null;
    if (s.leak) { status = "gave_up"; note = `벤치 정답 누설 — ${s.leak.map((h) => `${h.file}(${h.term})`).join(", ")}`; }
    else if (s.repro === "flaky") status = "flaky";
    else if (s.repro === "not_reproduced") status = "not_reproduced";
    else if (s.repro === "failed" || s.repro === "compile_error" || s.repro === "tool_error" || s.diagError) { status = "gave_up"; note = s.diagError ?? `재현 ${s.repro}`; }
    else if (s.diag?.rule_gap) status = "rule_decision";
    else if (s.scope?.reasons?.length) {
      if (s.mode !== "live") status = "would_ask";
      else if (s.approval === "approved") status = "ready";
      else { status = "gave_up"; note = "주인님 반려"; }
    } else status = "ready";
    const bench = s.signal?.bench ?? null;
    // 누설로 진단을 안 한 사례는 채점하지 않는다(분모에서 뺀다 — 진단 실패와 다르다, 재검토 B 하4)
    const match = bench && !s.leak ? diagMatch(bench.expect, s.diag, status) : null;
    let summary = null;
    if (s.diag || status === "flaky" || status === "not_reproduced") {
      // 주인님용 요약 — haiku 1회(설계 ⑭). 덤이다: 실패·상한 보류·시간 부족이어도 고칠 안은 남기고 넘어간다(H3 하 — 요약 때문에 대기열을 묶지 않는다)
      try {
        const facts = JSON.stringify({ sigkey: s.sigkey, status, repro: s.repro, diag: s.diag ? { hypothesis: s.diag.hypothesis, files: s.diag.files, rule_gap: s.diag.rule_gap, rule_gap_detail: s.diag.rule_gap_detail, confidence: s.diag.confidence } : null, scope: s.scope?.reasons ?? [] });
        const r = await llm.ask(`아래 고스톱 결함 진단 결과를 비개발자가 읽을 한국어 3줄로 요약하라. 무엇이 잘못됐는지, 왜인지, 다음에 무엇을 해야 하는지. 요약문만 답하라.\n${facts}`,
          { model: "haiku", node: "plan" });
        summary = short(r.text, 1200);
      } catch (e) {
        summary = `(요약 없음: ${short(e?.message, 120)})`;
      }
    }
    const dir = runDir(tools.stateDir, s.sigkey);
    const sg = s.signal ?? {};
    const md = [
      `# 고칠 안 — ${s.sigkey}`,
      "",
      `- 상태: **${status}**${s.mode === "shadow" ? " (그림자)" : ""}${note ? ` — ${note}` : ""}`,
      `- 신호: ${sg.source ?? "?"} · ${sg.kind ?? "?"} · 대상 ${String(s.base ?? sg.rev ?? "").slice(0, 12)}`,
      `- 재현: ${s.repro ?? "-"}${s.reproRuns.length ? ` (${s.reproRuns.map((r) => `rc=${r.rc} ${r.secs}s`).join(" / ")})` : ""}`,
      `- 사본: ${s.work ?? "-"} (${s.sizes ? `${Math.round(s.sizes.work / 1e6)}MB + 깨끗한 내보내기 ${Math.round(s.sizes.clean / 1e6)}MB` : "-"})`,
      ...(summary ? ["", "## 요약", summary] : []),
      ...(s.reproRuns.length ? ["", "## 재현 발췌", "```", reproExcerpt(s.reproRuns[0]), "```"] : []),
      ...(s.diag ? ["", "## 진단", `- 가설: ${s.diag.hypothesis}`, `- 파일: ${s.diag.files.join(", ") || "-"}`,
        `- 규칙 공백: ${s.diag.rule_gap}${s.diag.rule_gap_detail ? ` — ${s.diag.rule_gap_detail}` : ""}`, `- 확신도: ${s.diag.confidence}`,
        ...s.diag.evidence.map((e) => `- 근거: ${e}`)] : []),
      ...(s.diagError ? ["", `## 진단 실패`, s.diagError] : []),
      ...(s.scope ? ["", "## 수정 범위 미리 보기", ...(s.scope.reasons.length ? s.scope.reasons.map((r) => `- ${s.mode === "shadow" ? "물었을 것" : "승인 사유"}: ${r}`) : ["- 승인 사유 없음"]),
        ...(s.scope.note ? [`- 참고: ${s.scope.note}`] : [])] : []),
      ...(match ? ["", "## 벤치 대조", `- 사례: ${bench.id} · 진단 일치: ${match.ok}${match.why.length ? ` (${match.why.join("; ")})` : ""}`] : []),
      "",
    ].join("\n");
    const planPath = writeAtomic(path.join(dir, "plan.md"), md);
    writeAtomic(path.join(dir, "result.json"), `${JSON.stringify({ sigkey: s.sigkey, status, note, leak: s.leak, repro: s.repro, runs: s.reproRuns.map(({ blocks, ...r }) => r), diag: s.diag, diagError: s.diagError, scope: s.scope, bench: bench ? { id: bench.id, match } : null, mode: s.mode, base: s.base, sizes: s.sizes }, null, 1)}\n`);
    // 판정 M8 은 스레드당 한 번(plan 이 다시 돌아도 두 번 세지 않게 표식 파일)
    let firstBench = false;
    if (bench) { try { fs.writeFileSync(path.join(dir, "bench-recorded"), status, { flag: "wx", mode: 0o600 }); firstBench = true; } catch { /* 이미 적음 */ } }
    if (firstBench) tools.bench({ bench: bench.id, reproduced: s.repro === "skipped" ? null : s.repro === "reproduced", diag_match: match?.ok ?? null, signal: sg.kind });
    for (const sub of ["build", ".dart_tool"]) if (s.work) fs.rmSync(path.join(s.work, sub), { recursive: true, force: true });
    return { status, planPath, log: [`plan ${status}`] };
  }

  return new StateGraph(State)
    .addNode("preflight", preflight)
    .addNode("sandbox", sandbox)
    .addNode("reproduce_launch", reproduceLaunch)
    .addNode("reproduce_check", reproduceCheck)
    .addNode("diagnose_launch", diagnoseLaunch)
    .addNode("diagnose_check", diagnoseCheck)
    .addNode("scope_precheck", scopePrecheck)
    .addNode("owner_gate", ownerGate)
    .addNode("plan", plan)
    .addEdge(START, "preflight")
    .addEdge("preflight", "sandbox")
    .addConditionalEdges("sandbox", (s) => (s.leak ? "plan" : "reproduce_launch"), ["reproduce_launch", "plan"])
    .addConditionalEdges("reproduce_launch", (s) => (s.repro === "skipped" ? "diagnose_launch" : "reproduce_check"), ["reproduce_check", "diagnose_launch"])
    .addConditionalEdges("reproduce_check", afterReproCheck, ["reproduce_launch", "diagnose_launch", "plan"])
    .addEdge("diagnose_launch", "diagnose_check")
    .addConditionalEdges("diagnose_check", afterDiagCheck, ["diagnose_launch", "scope_precheck", "plan"])
    .addConditionalEdges("scope_precheck", afterScope, ["owner_gate", "plan"])
    .addEdge("owner_gate", "plan")
    .addEdge("plan", END)
    .compile({ checkpointer });
}
