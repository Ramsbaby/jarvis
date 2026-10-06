// gostop-fix.mjs — 고스톱 결함 하나(sigkey)를 사본에서 재현·진단하고(1a), 빨간 시험 → 수정 → 3경로 검증 → 검토까지 해(1b) '고칠 안'을 남긴다(설계 §5.2).
//   ① preflight → ② sandbox → ③ reproduce_launch ⇄ reproduce_check(2회, 흔들림 판정) → ④ diagnose_launch ⇄ diagnose_check
//   → ⑤ scope_precheck → (실제 모드 + 승인 사유) ⑥ owner_gate
//   1b: → ⑦ repro_test(sonnet ×≤2, test/repro/ 새 파일만, 3경로 틀) → ⑧ verify_red(격리 실행, 패치 전 빨간불 — 2회 실패면 no_red)
//       → ⑨ fix(opus ×1 + 재수정 ×≤2, 정본 패치는 git 없이) → [AI 결정 비교 — 고스톱 test/ai_policy 가 있을 때만] → ⑩ scope_check(허용 목록)
//       → (실제 + 사유) scope_gate → ⑪ verify(격리 실행: 대상·3경로·실행 증명·분석·전체·미니 대조 30판) → ⑫ review(sonnet, 읽기만)
//       ⑬ ⑩(재현 시험 건드림)·⑪·⑫ 실패 → ⑨ 로(수정 통틀어 3회) → (실제 전용) ⑮ merge_prep → ⑯ commit_push(effect) → ⑭ plan
//   그림자: ⑮ 는 건너뛰고 ⑯ 은 effect 가 '했을 일'만 적는다.
// 1a 단계(LG_GOSTOP_STAGE=1a)는 LLM 이 쓴 코드를 실행하지 않는다. 1b 의 LLM 코드는 lg-test.sb 격리 안(sandbox.* 명령)에서만 돈다 —
// LLM 이 사본에 쓴 뒤에는 격리 밖 시험 명령(flutter.*)을 그 사본에 쓰지 않는다.
// 본 저장소는 읽기만 한다(git 읽기 명령 · 표식 파일 확인). 사본은 상태 폴더 gostop/sandbox/<sigkey>/ 에 역사 없이 푼다(§2).
// 규칙: interrupt 가 든 노드(owner_gate)는 동기·순수다 — 상태만 읽는다(scripts/check-interrupt-nodes.mjs).
import fs from "node:fs";
import path from "node:path";
import { StateGraph, Annotation, START, END, interrupt } from "@langchain/langgraph";
import {
  repoPath, sandboxDir, runDir, gostopDir, keyDir, mkdirp, writeAtomic, dirBytes, forbiddenPresent, applyInject, busyReason, pruneHistoryDocs, leakScan,
  readTestOutput, judgeRepro, reproExcerpt, DIAG_SCHEMA, parseDiag, scopeOf, diagMatch, reproCommand, short, DIFF_TEST, SOAK_TEST,
  hasH5Frame, hasAiPolicy, sameFiles, AI_POLICY, copyTree, lastJson, judgeReproFiles, restoreFiles, analyzeCounts, failureItems, seedFor,
  REVIEW_SCHEMA, parseReview, reviewPass, reproTestPrompt, fixPrompt, reviewPrompt,
  safeTarget, readNoFollow, copyNoFollow, redQuality, aiCallsites, h5FrameUse,
} from "./gostop-common.mjs";
import crypto from "node:crypto";

const LLM_TOUCHED = ".llm-touched"; // 사본 뿌리(LLM·격리 실행이 못 닿는 곳)의 표식 — ⑦ 을 띄우기 직전에 남긴다

// 한 번에 하나(S13) — 실행기가 같은 그래프의 시작된 미완 스레드가 있으면 대기열 것을 미룬다
// llmPerThread: 1b 최악 2(진단)+2(재현 시험)+3(수정)+3(검토)+1(요약)=11, 스레드 상한 12(설계 §5.2 예산). Fable 은 claude.mjs 가 막는다.
export const meta = { name: "gostop-fix", description: "고스톱 결함 재현·진단(1a)·빨간 시험·수정·3경로 검증·검토(1b)", serial: true, llmPerThread: 12 };

const MAX_REPRO_ATTEMPTS = 3; // 분리 실행이 결과 없이 죽거나 최대 시간을 넘긴 경우의 다시 띄우기(같은 run 번호)
const MAX_DIAG_ATTEMPTS = 2; // sonnet ×≤2 (설계 §5.2④) — 답이 형식에 안 맞을 때
const MAX_DIAG_INFRA = 3; // 로그인 만료·사용량 한도로 다시 띄우는 횟수 — 이 둘은 모델 일을 쓰지 않아 시도와 따로 센다(H3 상3)
const DIAG_WAIT_MS = { login: 6 * 3_600_000, usage_limit: 3_600_000 }; // 관문(llm-hold)과 같은 쉼
const DIAG_TIMEOUT_MS = 15 * 60_000; // 분리 실행 — 최대 시간은 1.5배(22.5분)
// 1b
const MAX_RT_ATTEMPTS = 2; // ⑦ sonnet ×≤2 — 3경로 틀·파일 규칙·빨간불(⑧) 실패를 함께 센다
const MAX_FIX_ATTEMPTS = 3; // ⑨ opus ×1 + 재수정 ×≤2(⑬)
const MAX_RELAUNCH = 3; // 분리 실행이 결과 없이 죽었을 때 같은 일을 다시 띄우는 횟수
const FIX_TIMEOUT_MS = 15 * 60_000; // opus 수정 — 최대 시간 23분(설계 §6, 1.5배)
const RT_TIMEOUT_MS = 12 * 60_000;
const REVIEW_TIMEOUT_MS = 10 * 60_000;
const RW_TOOLS = ["Read", "Grep", "Glob", "Edit", "Write"]; // --restricted 가 작업 폴더(사본) 안에 가둔다. 범위는 결과(정본 패치)로 다시 본다
const modelCap = (m) => { const v = Number(process.env[m === "opus" ? "LG_GOSTOP_OPUS_CAP" : "LG_GOSTOP_SONNET_CAP"]); return Number.isFinite(v) && v > 0 ? v : (m === "opus" ? 3 : 7); };

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
  // ── 1b ──
  stage: Annotation({ reducer: last, default: () => "1b" }), // 스레드 시작 때 고정(LG_GOSTOP_STAGE)
  route: Annotation({ reducer: last, default: () => null }), // 갈림길 노드가 고른 다음 노드
  seq: Annotation({ reducer: last, default: () => 0 }), // 분리 실행 번호(LLM·명령 공통, 띄울 때마다 +1)
  calls: Annotation({ reducer: last, default: () => ({}) }), // 모델별 호출 수(진단 제외) — LG_GOSTOP_SONNET_CAP·OPUS_CAP
  llmInfra: Annotation({ reducer: last, default: () => 0 }),
  llmWaitUntil: Annotation({ reducer: last, default: () => null }),
  tmp: Annotation({ reducer: last, default: () => null }), // 격리 실행 임시 폴더(사본 옆 tmp)
  baseDir: Annotation({ reducer: last, default: () => null }), // 기준 실행용 사본(pub get 함, LLM 손 안 탐)
  redbase: Annotation({ reducer: last, default: () => null }), // 재현 시험을 쓴 직후의 사본 복제 — ⑨ 패치(fixPatch) 기준
  markers: Annotation({ reducer: last, default: () => "default" }), // default · h5(고스톱 3경로 틀)
  rtAttempt: Annotation({ reducer: last, default: () => 0 }),
  rtHandle: Annotation({ reducer: last, default: () => null }),
  rtFeedback: Annotation({ reducer: last, default: () => null }),
  rtError: Annotation({ reducer: last, default: () => null }),
  reproTest: Annotation({ reducer: last, default: () => null }),
  reproSupport: Annotation({ reducer: last, default: () => [] }),
  threePath: Annotation({ reducer: last, default: () => null }),
  redHandle: Annotation({ reducer: last, default: () => null }),
  redRelaunch: Annotation({ reducer: last, default: () => 0 }),
  redRuns: Annotation({ reducer: last, default: () => [] }),
  noRed: Annotation({ reducer: last, default: () => false }),
  fixAttempt: Annotation({ reducer: last, default: () => 0 }),
  fixHandle: Annotation({ reducer: last, default: () => null }),
  fixFeedback: Annotation({ reducer: last, default: () => null }),
  fixError: Annotation({ reducer: last, default: () => null }),
  fixPatch: Annotation({ reducer: last, default: () => null }), // { file, sha256, files } — redbase 대비(이번 수정만)
  fullPatch: Annotation({ reducer: last, default: () => null }), // clean 대비(재현 시험 + 수정 — 반영할 정본)
  aiCheck: Annotation({ reducer: last, default: () => "unavailable" }), // pass · fail · unavailable(폴백)
  aiDetail: Annotation({ reducer: last, default: () => null }),
  aiGenOk: Annotation({ reducer: last, default: () => false }),
  scopeFinal: Annotation({ reducer: last, default: () => null }),
  scopeApproval: Annotation({ reducer: last, default: () => null }),
  phase: Annotation({ reducer: last, default: () => null }), // ai · verify · merge
  stepsDone: Annotation({ reducer: last, default: () => [] }),
  stepHandle: Annotation({ reducer: last, default: () => null }),
  stepId: Annotation({ reducer: last, default: () => null }),
  stepRelaunch: Annotation({ reducer: last, default: () => 0 }),
  stepTmp: Annotation({ reducer: last, default: () => null }),
  aiGenSha: Annotation({ reducer: last, default: () => null }),
  steps: Annotation({ reducer: last, default: () => [] }), // 단계 기록(모든 시도)
  needBase: Annotation({ reducer: last, default: () => ({}) }), // 실패한 단계의 실패 항목 — 깨끗한 내보내기에서도 실패하는지 본다
  analyzeBase: Annotation({ reducer: last, default: () => null }),
  verifyOk: Annotation({ reducer: last, default: () => null }),
  verifyFail: Annotation({ reducer: last, default: () => null }),
  review: Annotation({ reducer: last, default: () => null }),
  reviewHandle: Annotation({ reducer: last, default: () => null }),
  violation: Annotation({ reducer: last, default: () => null }),
  merge: Annotation({ reducer: last, default: () => null }),
  commit: Annotation({ reducer: last, default: () => null }),
  verify_log: Annotation({ reducer: last, default: () => null }), // 판정 M2 — plan 이 끝난 상태를 뒷받침하는 확인을 적는다(fixVerifyLog)
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

// 판정 M2 — 끝난 상태(status)를 뒷받침하는 확인 기록. 고칠 안(plan.md)이 있어야 하고, 상태마다 근거가 다르다:
//   ready·would_ask(1b) 마지막 수정의 격리 검증 단계 전부 통과 + 검토 통과 · (1a) 재현됨 + 진단 · not_reproduced·flaky 재현 실행 기록
//   no_red 빨간불 확인 기록 · rule_decision 규칙 공백 진단. 포기(gave_up)·근거 없음은 null — '확인 없이 끝남'으로 센다.
export function fixVerifyLog(s, status, planPath) {
  if (!planPath || !fs.existsSync(planPath)) return null;
  const tail = ` — ${planPath}`;
  if (status === "ready" || status === "would_ask") {
    if (s.stage === "1b") {
      const v = (s.steps ?? []).filter((x) => x.phase === "verify" && x.fix === s.fixAttempt);
      if (!s.verifyOk || !s.review?.pass || !v.length || !v.every((x) => x.ok)) return null;
      return `gostop-fix ${status}: 격리 검증 ${v.map((x) => x.id).join(",")} 통과 · 검토 통과${tail}`;
    }
    return (s.repro === "reproduced" || s.repro === "skipped") && s.diag ? `gostop-fix ${status}(1a): 재현 ${s.repro} · 진단 있음${tail}` : null;
  }
  if (status === "not_reproduced" || status === "flaky") return s.reproRuns?.length ? `gostop-fix ${status}: 재현 실행 ${s.reproRuns.length}회 판정${tail}` : null;
  if (status === "no_red") return s.redRuns?.length ? `gostop-fix no_red: 패치 전 빨간불 확인 ${s.redRuns.length}회 모두 아님${tail}` : null;
  if (status === "rule_decision") return s.diag?.rule_gap ? `gostop-fix rule_decision: 규칙 공백 진단${tail}` : null;
  return null;
}

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
    const stage = process.env.LG_GOSTOP_STAGE === "1a" ? "1a" : "1b";
    return { mode: tools.mode, base, stage, log: [`preflight ${base.slice(0, 8)} ${tools.mode} ${stage}`] };
  }

  // ② 역사 없는 사본(설계 §2): git archive → work(사본)·clean(깨끗한 내보내기)에 비밀·설정을 빼고 푼다 → pub get --offline.
  async function sandbox(s) {
    const root = sandboxDir(tools.stateDir, s.sigkey);
    const work = path.join(root, "work"), clean = path.join(root, "clean"), tar = path.join(root, "src.tar"), ready = path.join(root, ".ready");
    // 1b: base = 기준 실행용 셋째 사본(pub get 함 — 분석·전체 시험·미니 대조의 기준, AI 결정 기준 생성). clean 은 패치 기준이라 손대지 않는다
    //   (clean 에 pub get·시험을 돌리면 생성 파일이 '바뀐 파일'로 패치에 섞인다 — 1b 통합 때 찾음).
    const base = path.join(root, "base");
    const dirs = s.stage === "1a" ? [work, clean] : [work, clean, base];
    const prev = fs.existsSync(ready) ? fs.readFileSync(ready, "utf8").trim() : "";
    // LLM 이 한 번이라도 쓴 사본은 다시 쓰지 않는다 — 같은 sigkey 로 다시 시작하면 ③ 이 격리 밖에서 그 코드를 돌리게 된다(H10 상2)
    const touched = fs.existsSync(path.join(root, LLM_TOUCHED));
    if (prev !== s.base || touched) { // 처음이거나, 도중에 끊긴 사본 — 처음부터 다시 만든다(상태 폴더 안 우리 사본만)
      fs.rmSync(root, { recursive: true, force: true });
      for (const d of dirs) mkdirp(d);
      const a = await tools.run("git.archive", { repo, out: tar, rev: s.base });
      if (a.code !== 0) throw new Error(`git archive 실패(코드 ${a.code}): ${short(a.stderr)}`);
      for (const dir of dirs) {
        const x = await tools.run("tar.extract-sandbox", { tar, dir });
        if (x.code !== 0) throw new Error(`tar 풀기 실패(코드 ${x.code}): ${short(x.stderr)}`);
      }
      fs.rmSync(tar, { force: true });
      for (const dir of dirs) pruneHistoryDocs(dir); // 수정 원장·작업 기록·QA 보고 — 정답이 적혀 있다(H3 상1)
      if (s.signal?.kind === "inject") for (const dir of dirs) applyInject(dir, s.signal.inject);
      const bad = dirs.flatMap((d) => forbiddenPresent(d));
      if (bad.length) throw Object.assign(new Error(`사본에 있으면 안 되는 것이 있다: ${bad.join(", ")}`), { codeDefect: true });
      // 의존성은 LLM 이 손대기 전 여기서만(격리 안 pub get 은 불가 — H4). clean 에는 하지 않는다(패치 기준).
      for (const dir of s.stage === "1a" ? [work] : [work, base]) {
        const pg = await tools.run("flutter.pub-get-offline", { dir });
        if (pg.code !== 0) throw new Error(`pub get --offline 실패(코드 ${pg.code}): ${short(pg.stdout + pg.stderr, 300)}`);
      }
      fs.writeFileSync(ready, s.base, { mode: 0o600 });
    }
    const tmp = mkdirp(path.join(root, "tmp"));
    const sizes = { work: dirBytes(work), clean: dirBytes(clean) };
    // 벤치면 정답 표지(수정 커밋 해시·정답 시험 이름 등)가 사본 글 파일에 없는지 — 있으면 이 사례는 진단하지 않는다(plan: gave_up)
    const leak = s.signal?.bench ? leakScan(work, s.signal.bench.leakTerms) : [];
    return { work, clean, baseDir: s.stage === "1a" ? null : base, tmp, sizes, markers: hasH5Frame(work) ? "h5" : "default", leak: leak.length ? leak : null, log: [`sandbox ${Math.round((sizes.work + sizes.clean) / 1e6)}MB${leak.length ? ` · 누설 ${leak.length}` : ""}`] };
  }

  // ③ 재현 — 사람이 쓴 기존 시험을 같은 조건으로 2회(흔들림 판정). 분리 실행이라 띄우기/확인 두 노드다.
  function reproduceLaunch(s) {
    // 격리 밖 시험(flutter.*)은 LLM 이 손대지 않은 사본에만(H10 상2). 표식이 있으면 코드 결함 — 사본을 새로 만들어야 한다
    if (fs.existsSync(path.join(path.dirname(s.work), LLM_TOUCHED))) throw Object.assign(new Error("LLM 이 손댄 사본에 격리 밖 재현을 돌리려 했다"), { codeDefect: true });
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
  // 1b: 규칙 공백이 아니면 ⑦ 로 간다 — 그림자는 사유가 있어도 끝까지 해 본다(물었을 것은 plan 에 남는다).
  const afterScope = (s) => {
    if (s.diag?.rule_gap) return "plan";
    if (s.mode === "live" && s.scope?.reasons?.length) return "owner_gate";
    return s.stage === "1b" ? "repro_test_launch" : "plan";
  };
  const afterOwner = (s) => (s.stage === "1b" && s.approval === "approved" ? "repro_test_launch" : "plan");

  // ⑥ 승인(순수 interrupt) — 상태만 읽고 묻는다
  function ownerGate(s) {
    const decision = interrupt({ question: `고스톱 ${s.sigkey} 수정에 승인이 필요합니다`, reason: s.scope.reasons.join(" / ") });
    return { approval: decision, log: [`owner_gate ${decision}`] };
  }

  // ════════════════ 1b — ⑦~⑬ · ⑮⑯ ════════════════
  const rdir = (s) => runDir(tools.stateDir, s.sigkey);
  const rel = (s, file) => path.relative(rdir(s), file);
  const sonnetUsed = (s) => (s.calls.sonnet ?? 0) + (s.diag || s.diagError ? s.diagAttempt : 0);
  const used = (s, m) => (m === "sonnet" ? sonnetUsed(s) : (s.calls[m] ?? 0));

  // LLM 분리 실행 띄우기 — 쉼 중이면 보류, 모델 상한이면 null(그래프가 gave_up 으로)
  function launchLlm(s, node, model, prompt, { tools: tl, jsonSchema = null, timeoutMs }) {
    if (s.llmWaitUntil && tools.now() < s.llmWaitUntil) throw tools.hold(`${node} 호출 쉼 — ${new Date(s.llmWaitUntil).toISOString()} 뒤 다시`, "llm_wait");
    if (used(s, model) >= modelCap(model)) return null;
    const seq = s.seq + 1;
    const handle = llm.launchAsk(prompt, { model, node, attempt: seq, tools: tl, cwd: s.work, jsonSchema, timeoutMs });
    return { seq, handle, llmWaitUntil: null };
  }
  // 판정: 진행 중이면 pending. done → { st, upd } · 로그인·한도 → { infra } · 그 밖 → { fail }
  function checkLlm(s, handle, model, label) {
    const st = llm.checkAsk(handle);
    if (st.state === "running") throw tools.pending(`${label} 진행 중`);
    const plus = { calls: { ...s.calls, [model]: (s.calls[model] ?? 0) + 1 } };
    if (st.state === "done") return { st, upd: { ...plus, llmInfra: 0 } };
    const why = `${st.state} ${st.reason ?? st.kind ?? ""} ${short(st.error ?? "", 120)}`.trim();
    if (st.state === "failed" && (st.kind === "login" || st.kind === "usage_limit")) {
      const n = s.llmInfra + 1;
      if (n > MAX_DIAG_INFRA) return { fatal: `${label} 실행 실패 ${MAX_DIAG_INFRA}회 — ${why}`, upd: { llmInfra: n } };
      const wait = DIAG_WAIT_MS[st.kind] ?? 0;
      return { infra: why, upd: { llmInfra: n, llmWaitUntil: wait ? tools.now() + wait : null } };
    }
    return { fail: why, upd: plus };
  }
  // 격리 실행 결과 읽기: 진행 중 pending · 결과 없이 죽음 { dead } · 그 밖 { code, raw, out, secs, timedOut }
  function checkCmd(h, label) {
    const st = tools.check(h);
    if (st.state === "running") throw tools.pending(`${label} 진행 중`);
    if (st.state === "dead" || st.error || (st.code == null && !st.timedOut)) {
      return { dead: st.state === "dead" ? `분리 실행 ${st.reason}` : st.error ? `띄우기 오류 ${short(st.error, 80)}` : `신호로 끝남(${st.signal ?? "코드 없음"})` };
    }
    const raw = tools.output(h, "stdout") + tools.output(h, "stderr");
    const code = st.timedOut ? 124 : st.code;
    return { code, raw, out: readTestOutput(raw, code, null), secs: Math.round(((st.endedAt ?? 0) - (st.startedAt ?? 0)) / 1000), timedOut: !!st.timedOut };
  }
  // 격리 실행마다 새 임시 폴더(H10 상1 — 앞 실행의 시험 코드가 심은 바로가기를 다음 실행·그래프가 밟지 않게). 격리 점검은 tmp/0.
  const freshTmp = (s, seq) => { const d = path.join(s.tmp, String(seq)); fs.rmSync(d, { recursive: true, force: true }); return mkdirp(d); };
  const saveLog = (s, name, raw) => writeAtomic(path.join(rdir(s), `${name}.log`), String(raw).slice(-200_000));
  // 격리 위반(종료 98·사본 무단 변경): 지표를 남기고 고칠 안은 gave_up
  const violate = (s, kind, detail) => { tools.sandboxViolation(kind, detail); return { violation: `${kind} — ${short(detail, 200)}`, route: "plan", log: [`격리 위반 ${kind}`] }; };
  // 격리 점검 — 이 기기에서 격리가 실제로 막는지(실패하면 시험을 돌리지 않고 보류)
  async function canary(s, dir) {
    const r = await tools.run("sandbox.canary", { dir, tmp: freshTmp(s, 0) });
    const j = lastJson(r.stdout);
    if (r.code !== 0 || !j?.ok) throw tools.hold(`격리 점검 실패(코드 ${r.code}): ${short((j?.failures ?? []).join("; ") || r.stderr, 200)}`, "sandbox_canary");
  }
  // 정본 패치(git 없이). which: fix(redbase 대비) · full(clean 대비) · 그 밖 이름
  async function extract(s, base, name) {
    const out = path.join(rdir(s), `${name}.diff`);
    mkdirp(rdir(s));
    const r = await tools.run("patch.extract", { clean: base, copy: s.work, out });
    const j = lastJson(r.stdout);
    if (!j) throw new Error(`patch.extract 출력 없음(코드 ${r.code}): ${short(r.stderr, 200)}`);
    return { ...j, file: out, files: j.files ?? [] };
  }
  // ⑬ 재수정 — 수정 통틀어 3회. 남았으면 ⑨ 로, 아니면 gave_up
  const refix = (s, feedback, upd = {}) => (s.fixAttempt < MAX_FIX_ATTEMPTS
    ? { ...upd, fixFeedback: short(feedback, 3000), route: "fix_launch", log: [`재수정으로(${s.fixAttempt + 1}/${MAX_FIX_ATTEMPTS}) — ${short(feedback, 100)}`] }
    : { ...upd, fixError: `수정 ${MAX_FIX_ATTEMPTS}회 끝 — ${short(feedback, 300)}`, route: "plan", log: [`수정 ${MAX_FIX_ATTEMPTS}회 끝`] });

  // ⑦ 재현 시험 — sonnet, 작업 폴더 = 사본, 쓰기 도구. 결과로 test/repro/ 새 파일만 남았는지 다시 본다(아래 check).
  function reproTestLaunch(s) {
    const first = s.reproRuns[0];
    const prompt = reproTestPrompt({ signal: s.signal, repro: s.repro === "skipped" ? "재현 수단 없음(제보만)" : `판정 ${s.repro}\n${reproExcerpt(first)}`,
      diag: s.diag, h5: s.markers === "h5", feedback: s.rtFeedback, existing: s.reproTest });
    if (used(s, "sonnet") >= modelCap("sonnet")) return { rtError: `sonnet 상한 ${modelCap("sonnet")}회에 닿음`, route: "plan", log: ["repro_test 상한"] };
    fs.writeFileSync(path.join(path.dirname(s.work), LLM_TOUCHED), `${s.sigkey}\n`, { mode: 0o600 }); // 이 뒤로 이 사본에 격리 밖 명령 금지
    const l = launchLlm(s, "repro_test", "sonnet", prompt, { tools: RW_TOOLS, timeoutMs: RT_TIMEOUT_MS });
    return { seq: l.seq, rtHandle: l.handle, llmWaitUntil: null, rtAttempt: s.rtAttempt + (s.rtHandle ? 0 : 1), route: "repro_test_check", log: [`repro_test_launch 시도 ${s.rtAttempt + 1} · 실행 ${l.seq}`] };
  }
  async function reproTestCheck(s) {
    const c = checkLlm(s, s.rtHandle, "sonnet", "재현 시험 작성");
    if (c.fatal) return { ...c.upd, rtHandle: null, rtError: c.fatal, route: "plan", log: [c.fatal] };
    // 로그인·한도: 시도를 세지 않고 다시 띄운다(rtHandle 을 비우되 rtAttempt 는 그대로 — launch 가 +1 하지 않게 표시)
    if (c.infra) return { ...c.upd, rtHandle: null, rtAttempt: s.rtAttempt - 1, route: "repro_test_launch", log: [`repro_test 실행 실패 — ${c.infra}`] };
    const retryOrStop = (why, extra = {}) => (s.rtAttempt < MAX_RT_ATTEMPTS
      ? { ...c.upd, ...extra, rtHandle: null, rtFeedback: short(why, 2000), route: "repro_test_launch", log: [`repro_test 다시 — ${short(why, 100)}`] }
      : { ...c.upd, ...extra, rtHandle: null, rtError: `재현 시험 ${MAX_RT_ATTEMPTS}회 실패 — ${short(why, 300)}`, route: "plan", log: [`repro_test 실패 끝 — ${short(why, 100)}`] });
    if (c.fail) return retryOrStop(`호출 실패: ${c.fail}`);
    // 바뀐 것(깨끗한 내보내기 대비)이 test/repro/ 새 파일뿐인지 — 밖은 되돌리고 실패로 센다
    const px = await extract(s, s.clean, `repro-${s.rtAttempt}`);
    if (!px.ok) return { ...c.upd, rtHandle: null, rtError: `재현 시험 뒤 패치 추출 거부(${px.reason}) — 사본을 믿을 수 없다`, route: "plan", log: [`repro_test 추출 거부 ${px.reason}`] };
    const jr = judgeReproFiles(px.files);
    if (jr.bad.length) restoreFiles(s.work, s.clean, jr.bad);
    if (!jr.ok) return retryOrStop(jr.why.join(" / "));
    const file = path.join(s.work, jr.test);
    const tp = s.markers === "h5" ? await tools.run("repro.three-path-h5", { file }) : await tools.run("repro.three-path", { file });
    const tj = lastJson(tp.stdout);
    if (!tj) throw new Error(`3경로 확인 출력 없음(코드 ${tp.code}): ${short(tp.stderr, 200)}`);
    if (!tj.ok) return retryOrStop(`3경로 시험 틀이 모자란다 — 빠진 것: ${tj.missing.join(", ")}(엔진·라이브 사람·라이브 AI 묶음마다 expect 가 있는 시험, 라이브 AI 는 어려움 포함)`, { reproTest: jr.test });
    if (s.markers === "h5") {
      const src = String(readNoFollow(file) ?? "");
      const h5 = h5FrameUse(src, jr.support.map((f) => String(readNoFollow(path.join(s.work, f)) ?? "")));
      if (!h5.ok) return retryOrStop(`고스톱 3경로 틀을 쓰지 않았다 — ${h5.why.join(", ")}`, { reproTest: jr.test });
    }
    // 빨간 기준 redbase = 깨끗한 내보내기 + 재현 시험 파일 — 이후 ⑨ 패치(이번 수정만)는 여기 대비
    const rb = copyTree(s.clean, path.join(path.dirname(s.work), "redbase"));
    for (const f of [jr.test, ...jr.support]) copyNoFollow(path.join(s.work, f), rb, f);
    return { ...c.upd, rtHandle: null, reproTest: jr.test, reproSupport: jr.support, threePath: tj.paths, redbase: rb,
      redRelaunch: 0, route: "verify_red_launch", log: [`repro_test_check ${jr.test} · 3경로 ${JSON.stringify(tj.paths)}`] };
  }

  // ⑧ 패치 전 빨간불 — 격리 실행. 띄우기 전 격리 점검.
  async function verifyRedLaunch(s) {
    await canary(s, s.work);
    const seq = s.seq + 1;
    const h = tools.launch("sandbox.flutter-test", { dir: s.work, tmp: freshTmp(s, seq), test: s.reproTest }, { node: "verify_red", attempt: seq });
    return { seq, redHandle: h, route: "verify_red_check", log: [`verify_red_launch ${s.reproTest} · 실행 ${seq}`] };
  }
  async function verifyRedCheck(s) {
    const r = checkCmd(s.redHandle, "빨간불 확인");
    if (r.dead) {
      if (s.redRelaunch + 1 >= MAX_RELAUNCH) return { redHandle: null, rtError: `빨간불 확인 실행 실패 ${MAX_RELAUNCH}회 — ${r.dead}`, route: "plan", log: [`verify_red ${r.dead} 끝`] };
      return { redHandle: null, redRelaunch: s.redRelaunch + 1, route: "verify_red_launch", log: [`verify_red ${r.dead} — 다시 띄움`] };
    }
    const logFile = saveLog(s, `red-${s.rtAttempt}`, r.raw);
    if (r.code === 98) return violate(s, "exit98", `빨간불 확인 — ${short(r.raw.split("LG-SANDBOX").pop(), 160)}`);
    if (r.code === 97) throw new Error(`격리 실행 준비 오류(97): ${short(r.raw.split("LG-SANDBOX").pop(), 200)}`);
    // 시험이 사본을 바꿨나(LLM 시험 코드가 lib 를 고쳐 놓는 길) — redbase 대비 변경이 없어야 한다
    const px = await extract(s, s.redbase, `red-check-${s.rtAttempt}`);
    if (!px.ok || px.files.length) return violate(s, "copy_changed", `빨간불 확인 중 사본이 바뀜: ${px.ok ? px.files.map((f) => f.path).join(", ") : px.reason}`);
    const out = r.out;
    const q = redQuality(out, r.raw); // 표식 붙은 경로 시험이 단언으로 실패해야 빨간불(H10 중6)
    const red = r.code === 1 && q.ok;
    const run = { attempt: s.rtAttempt, rc: r.code, red, failed: out.failed.slice(0, 20), compileError: out.compileError, secs: r.secs, log: rel(s, logFile) };
    const runs = [...s.redRuns, run];
    if (red) return { redRuns: runs, redHandle: null, route: "fix_launch", log: [`verify_red 빨간불 — 실패 ${out.failed.length}`] };
    const why = r.code === 0 ? "패치 전인데 재현 시험이 모두 통과했다 — 결함을 드러내지 못한다(국면·기대값을 다시 보라)"
      : out.compileError ? `재현 시험이 컴파일되지 않는다:\n${short(r.raw.split("\n").filter((l) => /Error:/.test(l)).slice(0, 6).join("\n"), 1200)}`
      : r.code === 124 ? "재현 시험이 시간 상한(900초)을 넘었다 — 한 국면만 직접 만들어라"
      : r.code === 1 && !q.ok ? `빨간불이 단언 실패가 아니다(${q.loading ? "파일을 싣다 죽음" : !q.assertion ? "Expected/Actual 단언 실패 없음 — 예외로 죽음" : "표식 붙은 경로 시험이 실패하지 않음"}) — 실패한 시험: ${short(out.failed.slice(0, 4).join(" | "), 400)}`
      : `시험 도구 오류(코드 ${r.code}) — 실패한 시험 이름이 없다`;
    if (s.rtAttempt < MAX_RT_ATTEMPTS) return { redRuns: runs, redHandle: null, rtFeedback: why, route: "repro_test_launch", log: [`verify_red 빨간불 아님 — 재현 시험 다시`] };
    return { redRuns: runs, redHandle: null, noRed: true, route: "plan", log: ["verify_red 2회 실패 → no_red"] };
  }

  // ⑨ 수정 — opus, 쓰기 도구, 작업 폴더 = 사본. 정본 패치는 git 없이.
  function fixLaunch(s) {
    const lastRed = s.redRuns.at(-1);
    const red = lastRed ? [`실패한 시험(${lastRed.failed.length}): ${lastRed.failed.slice(0, 8).join(" | ")}`].join("\n") : "";
    const attempt = s.fixHandle ? s.fixAttempt : s.fixAttempt + 1;
    const l = launchLlm(s, "fix", "opus", fixPrompt({ signal: s.signal, diag: s.diag, reproTest: s.reproTest, redExcerpt: red, feedback: s.fixFeedback, attempt }),
      { tools: RW_TOOLS, timeoutMs: FIX_TIMEOUT_MS });
    if (!l) return { fixError: `opus 상한 ${modelCap("opus")}회에 닿음`, route: "plan", log: ["fix 상한"] };
    return { seq: l.seq, fixHandle: l.handle, llmWaitUntil: null, fixAttempt: attempt, route: "fix_check", log: [`fix_launch 시도 ${attempt} · 실행 ${l.seq}`] };
  }
  async function fixCheck(s) {
    const c = checkLlm(s, s.fixHandle, "opus", "수정");
    if (c.fatal) return { ...c.upd, fixHandle: null, fixError: c.fatal, route: "plan", log: [c.fatal] };
    if (c.infra) return { ...c.upd, fixHandle: null, fixAttempt: s.fixAttempt - 1, route: "fix_launch", log: [`fix 실행 실패 — ${c.infra}`] };
    if (c.fail) return refix({ ...s, ...c.upd }, `수정 호출 실패: ${c.fail}`, { ...c.upd, fixHandle: null });
    const fx = await extract(s, s.redbase, `fix-${s.fixAttempt}`);
    if (!fx.ok) return { ...c.upd, fixHandle: null, fixError: `수정 패치 추출 거부(${fx.reason}) — ${short(fx.detail ?? "", 200)}`, route: "plan", log: [`fix 추출 거부 ${fx.reason}`] };
    if (!fx.files.length) return refix(s, "아무 파일도 바꾸지 않았다 — 재현 시험이 통과하도록 lib 코드를 고쳐라", { ...c.upd, fixHandle: null });
    const full = await extract(s, s.clean, `patch-${s.fixAttempt}`);
    if (!full.ok) return { ...c.upd, fixHandle: null, fixError: `전체 패치 추출 거부(${full.reason})`, route: "plan", log: [`full 추출 거부 ${full.reason}`] };
    const pick = (x) => ({ file: x.file, sha256: x.sha256, bytes: x.bytes, files: x.files.map((f) => ({ path: f.path, status: f.status, added: f.added, removed: f.removed })) });
    // AI 결정 비교(§4②): 고스톱 test/ai_policy 가 사본에 있고 lib 를 바꿨을 때만. 없으면 폴백(AI 영역·MCTSConstants 무조건 승인, 규칙 처리부는 ai_check_unavailable 승인)
    const touchesLib = fx.files.some((f) => f.path.startsWith("lib/"));
    const ai = touchesLib && hasAiPolicy(s.clean);
    return { ...c.upd, fixHandle: null, fixPatch: pick(fx), fullPatch: pick(full), aiCheck: "unavailable", aiDetail: ai ? null : (touchesLib ? "AI 결정 비교 시험 없음(폴백)" : "lib 변경 없음"),
      phase: ai ? "ai" : null, stepsDone: [], route: ai ? "steps_launch" : "scope_check",
      log: [`fix_check 파일 ${fx.files.map((f) => f.path).join(", ")} · ${fx.bytes}B`] };
  }

  // ⑩ 수정 범위 — 이번 수정(redbase 대비)을 허용 목록에 댄다. 재현 시험(test/repro/)을 건드렸으면 되돌리고 재수정.
  async function scopeCheck(s) {
    const r = await tools.run("patch.allowlist", { patch: s.fixPatch.file, clean: s.redbase, copy: s.work, ai: s.aiCheck });
    const j = lastJson(r.stdout);
    if (!j || (r.code !== 0 && r.code !== 3)) throw new Error(`patch.allowlist 실패(코드 ${r.code}): ${short(r.stderr, 200)}`);
    const frozen = j.byReason?.frozen ?? [];
    if (frozen.length) {
      restoreFiles(s.work, s.redbase, s.fixPatch.files.filter((f) => frozen.includes(f.path)));
      return refix(s, `재현 시험(test/repro/)을 바꾸지 마라 — 되돌렸다: ${frozen.join(", ")}. 시험이 아니라 lib 코드를 고쳐 통과시켜라`, { scopeFinal: j });
    }
    // AI 호출부(정적, 고스톱 callsites 와 같은 규칙): 결정 비교는 호출부 변경(새 AI 호출 추가 등)을 못 잡는다 — 비교가 같음이어도 승인 사유(H10 상4)
    const sites = aiCallsites(String(readNoFollow(s.fixPatch.file) ?? ""));
    if (sites.length) {
      j.reasons = [...(j.reasons ?? []), ...sites.map((x) => ({ path: x.file, reason: "ai_callsite", detail: `AI 호출부 ${x.hunk}` }))];
      j.byReason = { ...(j.byReason ?? {}), ai_callsite: [...new Set(sites.map((x) => x.file))] };
      j.ok = false;
    }
    const reasons = j.reasons ?? [];
    const next = s.mode === "live" && reasons.length ? "scope_gate" : "steps_launch";
    return { scopeFinal: j, phase: "verify", stepsDone: [], needBase: {}, verifyOk: null, verifyFail: null, route: next,
      log: [`scope_check 허용 ${j.allowed?.length ?? 0} · 사유 ${reasons.map((x) => `${x.path}:${x.reason}`).join(", ") || "없음"} · AI ${s.aiCheck}`] };
  }
  // 실제 모드 + 사유 — 순수 interrupt
  function scopeGate(s) {
    const decision = interrupt({ question: `고스톱 ${s.sigkey} 수정 패치에 승인이 필요합니다`, reason: s.scopeFinal.reasons.map((x) => `${x.path}: ${x.reason}`).join(" / ") });
    return { scopeApproval: decision, log: [`scope_gate ${decision}`] };
  }
  const afterScopeGate = (s) => (s.scopeApproval === "approved" ? "steps_launch" : "plan");

  // ⑪·AI 비교·⑮ 재검증 — 격리 실행 단계 목록(상태로 정해진다. 끝난 단계는 id 로 건너뛴다)
  function stepsFor(s) {
    // 임시 폴더(tmp)는 띄울 때 새로 붙인다(stepsLaunch)
    const W = s.work, CL = s.baseDir, test = s.reproTest;
    if (s.phase === "ai") {
      return [
        ...(s.aiGenOk ? [] : [{ id: "ai_gen", cmd: "sandbox.ai-policy", params: { dir: CL, out: "ai-gen", test: AI_POLICY.gen }, kind: "ai_gen" }]),
        { id: `ai_cmp_${s.fixAttempt}`, cmd: "sandbox.ai-policy", params: { dir: W, out: `ai-cmp-${s.fixAttempt}`, test: AI_POLICY.compare }, kind: "ai_cmp" },
      ];
    }
    const D = s.phase === "merge" ? s.merge.dir : W;
    const rc = reproCommand(s.signal, D);
    const target = rc ? [{ id: "target", cmd: rc.cmd === "flutter.test-defines" ? "sandbox.flutter-test-defines" : "sandbox.flutter-test", params: { ...rc.params, dir: D }, kind: "green" }] : [];
    const three = { id: "three_path", cmd: "sandbox.flutter-test", params: { dir: D, test }, kind: "green" };
    // ⑮: 최신 master 에서 결함이 아직 재현되는지(재현 시험만 얹은 상태로 빨강) → 수정 패치 적용 → 3경로·대상·전체 초록(H10 상3·중9)
    if (s.phase === "merge") return [{ ...three, id: "master_red", kind: "red" }, ...(s.merge.applied ? [three, ...target, { id: "full", cmd: "sandbox.flutter-test-all", params: { dir: D }, kind: "green" }] : [])];
    const seed = seedFor(s.sigkey);
    const heavy = [
      { id: "full", cmd: "sandbox.flutter-test-all", params: { dir: W } },
      { id: "mini_diff", cmd: "sandbox.flutter-test-defines", params: { dir: W, test: DIFF_TEST, d1: "REPLAY_GAMES=20", d2: `REPLAY_SEED_BASE=${seed}`, d3: "LG_NOOP=1" } },
      { id: "mini_hard", cmd: "sandbox.flutter-test-defines", params: { dir: W, test: SOAK_TEST, d1: "SOAK_GAMES=6", d2: `SOAK_SEED_BASE=${seed + 1}`, d3: "SOAK_DIFFICULTY=hard" } },
      { id: "mini_easy", cmd: "sandbox.flutter-test-defines", params: { dir: W, test: SOAK_TEST, d1: "SOAK_GAMES=4", d2: `SOAK_SEED_BASE=${seed + 2}`, d3: "SOAK_DIFFICULTY=easy" } },
    ].flatMap((m) => [{ ...m, kind: "green_or_base" }, ...(s.needBase[m.id] ? [{ ...m, id: `${m.id}_base`, params: { ...m.params, dir: CL }, kind: "base", of: m.id }] : [])]);
    return [
      ...target, three,
      { id: "coverage", cmd: "sandbox.flutter-cov-ai", params: { dir: W, test, name: s.markers === "h5" ? "3경로/라이브-AI" : "라이브 AI" }, kind: "coverage" },
      ...(s.analyzeBase ? [] : [{ id: "analyze_base", cmd: "sandbox.flutter-analyze", params: { dir: CL }, kind: "analyze_base" }]),
      { id: "analyze", cmd: "sandbox.flutter-analyze", params: { dir: W }, kind: "analyze" },
      ...heavy,
    ];
  }
  // cmdId 는 글자값으로만(정적 검사가 허용 목록과 대조한다) — 단계 목록의 이름을 여기서 글자값 호출로 바꾼다
  function launchStep(cmd, params, opts) {
    switch (cmd) {
      case "sandbox.flutter-test": return tools.launch("sandbox.flutter-test", params, opts);
      case "sandbox.flutter-test-defines": return tools.launch("sandbox.flutter-test-defines", params, opts);
      case "sandbox.flutter-test-all": return tools.launch("sandbox.flutter-test-all", params, opts);
      case "sandbox.flutter-analyze": return tools.launch("sandbox.flutter-analyze", params, opts);
      case "sandbox.flutter-cov-ai": return tools.launch("sandbox.flutter-cov-ai", params, opts);
      case "sandbox.ai-policy": return tools.launch("sandbox.ai-policy", params, opts);
      default: throw Object.assign(new Error(`단계 명령이 목록 밖: ${cmd}`), { codeDefect: true });
    }
  }
  const nextStep = (s) => stepsFor(s).find((x) => !s.stepsDone.includes(x.id)) ?? null;
  async function stepsLaunch(s) {
    const step = nextStep(s);
    if (!step) return { stepHandle: null, route: "steps_check" };
    if (!s.stepsDone.length && s.phase !== "ai") await canary(s, s.phase === "merge" ? s.merge.dir : s.work); // 단계 묶음 앞 격리 점검
    const seq = s.seq + 1;
    const tmp = freshTmp(s, seq); // 이 실행 전용 — 앞 실행이 쓴 것을 밟지 않는다
    if (step.kind === "ai_cmp") {
      // 비교기(시험 두 파일)가 깨끗한 쪽과 같아야 믿는다. 기준(코퍼스·기준값)은 격리 밖 runs/ 에 지문과 함께 둔 것을 새 폴더로(H10 상1)
      if (!sameFiles(s.clean, s.work, AI_POLICY.trusted)) return { aiCheck: "unavailable", aiDetail: "AI 비교기가 깨끗한 사본과 다르다 — 믿지 않음", stepsDone: [...s.stepsDone, step.id], stepHandle: null, route: "steps_check" };
      for (const f of ["corpus.json", "baseline.json"]) {
        const src = path.join(rdir(s), "ai-gen", f);
        const buf = readNoFollow(src);
        if (!buf || crypto.createHash("sha256").update(buf).digest("hex") !== s.aiGenSha?.[f]) return { aiCheck: "unavailable", aiDetail: `AI 기준 ${f} 지문 불일치`, stepsDone: [...s.stepsDone, step.id], stepHandle: null, route: "steps_check" };
        copyNoFollow(src, tmp, `ai-cmp-${s.fixAttempt}/${f}`);
      }
    }
    const h = launchStep(step.cmd, { ...step.params, tmp }, { node: `${s.phase}_${step.id}`.slice(0, 60), attempt: seq });
    return { seq, stepHandle: h, stepId: step.id, stepTmp: tmp, route: "steps_check", log: [`${s.phase}:${step.id} 띄움(${seq})`] };
  }
  // 한 단계의 판정. 돌려주는 값 { ok, detail, upd }
  async function judgeStep(s, step, r) {
    const ex = () => short([...r.out.blocks.map((b) => b[0]), ...r.out.failed].slice(0, 6).join(" | ") || r.raw.split("\n").filter((l) => /Error|error •|warning •/.test(l)).slice(0, 4).join(" | "), 400);
    switch (step.kind) {
      case "green": return { ok: r.code === 0, detail: r.code === 0 ? "초록" : `코드 ${r.code} — ${ex()}` };
      case "red": { const q = redQuality(r.out, r.raw); const ok = r.code === 1 && q.ok; return { ok, detail: ok ? `최신 master 에서도 빨강(실패 ${q.marked.length})` : `최신 master 에서 재현 시험이 빨강이 아니다(코드 ${r.code}) — 이미 고쳐졌거나 시험이 깨짐` }; }
      case "coverage": {
        if (r.code !== 0) return { ok: false, detail: `라이브 AI 시험 실패(코드 ${r.code}) — ${ex()}` };
        const cv = await tools.run("cov.check", { patch: s.fullPatch.file, lcov: path.join(s.stepTmp, "coverage", "lcov.info"), root: s.work });
        const j = lastJson(cv.stdout);
        return { ok: cv.code === 0 && !!j?.ok, detail: `실행 증명 ${j?.verdict ?? `코드 ${cv.code}`}${j?.summary ? ` — ${short(JSON.stringify(j.summary), 200)}` : ""}` };
      }
      case "analyze_base": { const n = analyzeCounts(r.raw); return { ok: true, detail: `기준 오류 ${n.errors}·경고 ${n.warnings}`, upd: { analyzeBase: n } }; }
      case "analyze": {
        const n = analyzeCounts(r.raw), b = s.analyzeBase ?? { errors: 0, warnings: 0 };
        return { ok: n.errors <= b.errors && n.warnings <= b.warnings, detail: `오류 ${n.errors}(기준 ${b.errors})·경고 ${n.warnings}(기준 ${b.warnings})` };
      }
      case "green_or_base":
        if (r.code === 0) return { ok: true, detail: "초록" };
        if (r.out.compileError || r.code === 124) return { ok: false, detail: r.code === 124 ? "시간 상한 초과" : `컴파일 오류 — ${ex()}` };
        // 실패 — 깨끗한 내보내기에서도 같은 실패인지 본다(격리 환경·기존 결함 탓을 이번 수정 탓으로 몰지 않게)
        return { ok: true, pendingBase: true, detail: `실패 ${failureItems(r.out).length} — 깨끗한 내보내기와 견줌`, upd: { needBase: { ...s.needBase, [step.id]: failureItems(r.out).slice(0, 200) } } };
      case "base": {
        const mine = s.needBase[step.of] ?? [];
        const base = new Set(failureItems(r.out));
        const fresh = mine.filter((x) => !base.has(x));
        return { ok: fresh.length === 0 && mine.length > 0, detail: fresh.length ? `이번 수정에서 새로 실패: ${short(fresh.slice(0, 5).join(" | "), 400)}` : `기존 실패 ${mine.length}건(깨끗한 내보내기도 같음)` };
      }
      case "ai_gen": {
        // 기준 사본(사람 코드)의 결과를 격리 밖 runs/ai-gen 으로 옮기고 지문을 남긴다 — 이후 비교는 그 사본만 쓴다(H10 상1)
        const dir = path.join(s.stepTmp, "ai-gen");
        const verdict = (() => { try { return JSON.parse(String(readNoFollow(path.join(dir, "gen-result.json"), 1 << 20) ?? "")).verdict; } catch { return null; } })();
        if (r.code !== 0 || verdict !== "ok") return { ok: false, detail: `기준 생성 실패(코드 ${r.code}, ${verdict ?? "결과 없음"})`, upd: { aiCheck: "unavailable", aiDetail: `AI 기준 생성 실패(코드 ${r.code}, ${verdict ?? "결과 없음"})` } };
        const sha = {};
        for (const f of ["corpus.json", "baseline.json"]) {
          const buf = readNoFollow(path.join(dir, f));
          if (!buf) return { ok: false, detail: `기준 ${f} 없음`, upd: { aiCheck: "unavailable", aiDetail: `AI 기준 ${f} 없음` } };
          sha[f] = crypto.createHash("sha256").update(buf).digest("hex");
          copyNoFollow(path.join(dir, f), rdir(s), `ai-gen/${f}`);
        }
        return { ok: true, detail: "기준 생성", upd: { aiGenOk: true, aiGenSha: sha } };
      }
      case "ai_cmp": {
        const v = (() => { try { return JSON.parse(String(readNoFollow(path.join(s.stepTmp, `ai-cmp-${s.fixAttempt}`, "compare-result.json"), 1 << 20) ?? "")).verdict; } catch { return null; } })();
        // 종료 코드와 판정이 맞아야 믿는다(같음인데 시험 실패 = 판정 불가)
        const ai = v === "same" && r.code === 0 ? "pass" : v === "changed" || v === "search-only" ? "fail" : "unavailable";
        return { ok: true, detail: `AI 결정 비교 ${v ?? "결과 없음"}(코드 ${r.code}) → ${ai}`, upd: { aiCheck: ai, aiDetail: `AI 결정 비교 ${v ?? "결과 없음"}(코드 ${r.code})` } };
      }
      default: throw new Error(`모르는 단계 종류 ${step.kind}`);
    }
  }
  async function stepsCheck(s) {
    let upd = {};
    let cur = s;
    if (s.stepHandle) {
      const step = stepsFor(s).find((x) => x.id === s.stepId);
      if (!step) throw new Error(`단계 ${s.stepId} 가 목록에 없다`);
      const r = checkCmd(s.stepHandle, `${s.phase}:${step.id}`);
      if (r.dead) {
        if (s.stepRelaunch + 1 < MAX_RELAUNCH) return { stepHandle: null, stepRelaunch: s.stepRelaunch + 1, route: "steps_launch", log: [`${s.phase}:${step.id} ${r.dead} — 다시 띄움`] };
        r.code = -1; r.raw = r.dead; r.out = readTestOutput("", 1);
      }
      const logFile = saveLog(s, `${s.phase}-${s.fixAttempt}-${step.id}`, r.raw);
      if (r.code === 98) return violate(s, "exit98", `${s.phase}:${step.id} — ${short(r.raw.split("LG-SANDBOX").pop(), 160)}`);
      if (r.code === 97) throw new Error(`격리 실행 준비 오류(97) ${step.id}: ${short(r.raw.split("LG-SANDBOX").pop(), 200)}`);
      const j = r.code === -1 ? { ok: false, detail: `실행 실패 ${MAX_RELAUNCH}회 — ${r.dead}` } : await judgeStep(s, step, r);
      const rec = { phase: s.phase, fix: s.fixAttempt, id: step.id, ok: j.ok, rc: r.code, secs: r.secs ?? null, detail: j.detail, log: rel(s, logFile) };
      upd = { ...(j.upd ?? {}), steps: [...s.steps, rec], stepsDone: [...s.stepsDone, step.id], stepHandle: null, stepRelaunch: 0, log: [`${s.phase}:${step.id} ${j.ok ? "통과" : "실패"} — ${short(j.detail, 120)}`] };
      cur = { ...s, ...upd };
      if (j.ok && s.phase === "merge" && step.id === "master_red") {
        // 재현 시험만 얹은 최신 master 가 빨강 — 이제 이번 수정(fix 패치)을 얹는다
        const ap = await tools.run("patch.apply-copy", { dir: s.merge.dir, patch: s.fixPatch.file });
        if (ap.code !== 0) return { ...upd, merge: { ...s.merge, ok: false, detail: `최신 master 에 수정이 안 맞음(코드 ${ap.code}): ${short(ap.stdout + ap.stderr, 300)}` }, route: "plan" };
        upd.merge = { ...s.merge, applied: true };
        cur = { ...cur, merge: upd.merge };
      }
      if (!j.ok) {
        if (s.phase === "ai") return { ...upd, route: "scope_check" }; // 기준 생성 실패 → 폴백
        if (s.phase === "merge") return { ...upd, merge: { ...s.merge, ok: false, detail: `${step.id}: ${j.detail}` }, route: "plan" };
        const tail = r.out ? reproExcerpt({ ...r.out, rc: r.code }) : "";
        return refix(cur, `자동 검증 '${step.id}' 실패 — ${j.detail}\n${short(tail, 1500)}`, { ...upd, verifyOk: false, verifyFail: { id: step.id, detail: j.detail } });
      }
    }
    if (nextStep(cur)) return { ...upd, route: "steps_launch" };
    if (cur.phase === "ai") return { ...upd, route: "scope_check" };
    if (cur.phase === "merge") return { ...upd, merge: { ...cur.merge, ok: true }, route: "commit_push" };
    // 검증 끝 — 검증하는 동안 사본(수정 패치)이 그대로였나(시험 코드가 lib 를 고쳐 놓는 길)
    const again = await extract(cur, cur.redbase, `fix-${cur.fixAttempt}-after`);
    if (!again.ok || again.sha256 !== cur.fixPatch.sha256) return { ...upd, ...violate(cur, "copy_changed", `검증 중 수정 패치가 바뀜(${again.ok ? "내용 다름" : again.reason})`) };
    return { ...upd, verifyOk: true, verifyFail: null, route: "review_launch" };
  }

  // ⑫ 검토 — sonnet, 새 맥락, 읽기만
  function verifySummary(s) {
    return s.steps.filter((x) => x.phase === "verify" && x.fix === s.fixAttempt).map((x) => `- ${x.id}: ${x.ok ? "통과" : "실패"} — ${x.detail}`).join("\n") || "(없음)";
  }
  function reviewLaunch(s) {
    let patch = "";
    try { patch = fs.readFileSync(s.fullPatch.file, "utf8"); } catch { /* 없으면 빈 패치로 묻는다 */ }
    const l = launchLlm(s, "review", "sonnet", reviewPrompt({ signal: s.signal, diag: s.diag, patch, verify: verifySummary(s) }),
      { tools: ["Read", "Grep", "Glob"], jsonSchema: REVIEW_SCHEMA, timeoutMs: REVIEW_TIMEOUT_MS });
    if (!l) return { fixError: `sonnet 상한 ${modelCap("sonnet")}회에 닿음(검토)`, route: "plan", log: ["review 상한"] };
    return { seq: l.seq, reviewHandle: l.handle, llmWaitUntil: null, route: "review_check", log: [`review_launch 수정 ${s.fixAttempt} · 실행 ${l.seq}`] };
  }
  function reviewCheck(s) {
    const c = checkLlm(s, s.reviewHandle, "sonnet", "검토");
    if (c.fatal) return { ...c.upd, reviewHandle: null, fixError: c.fatal, route: "plan", log: [c.fatal] };
    if (c.infra) return { ...c.upd, reviewHandle: null, route: "review_launch", log: [`review 실행 실패 — ${c.infra}`] };
    const rv = c.st ? parseReview(c.st.structured, c.st.text) : null;
    const review = rv ? { ...rv, pass: reviewPass(rv), fix: s.fixAttempt } : { pass: false, fix: s.fixAttempt, issues: [c.fail ? `검토 호출 실패: ${c.fail}` : "검토 답이 형식에 맞지 않음"], summary: "" };
    if (!review.pass) {
      const why = [`검토 반려 — 3경로 ${rv?.three_path ?? "?"} · 무관한 변경 ${rv?.unrelated_changes ?? "?"} · 규칙 일치 ${rv?.rule_match ?? "?"}`, ...(review.issues ?? []).slice(0, 8)].join("\n");
      return refix({ ...s, ...c.upd }, why, { ...c.upd, reviewHandle: null, review });
    }
    const st = statusOf({ ...s, review });
    // 벤치(정답이 이미 master 에 있는 옛 결함)는 실제 모드여도 반영·push 하지 않는다(H10 상3)
    const next = st.status !== "ready" ? "plan" : s.signal?.bench ? "plan" : s.mode === "live" ? "merge_prep" : "commit_push";
    return { ...c.upd, reviewHandle: null, review, route: next, log: [`review 통과 → ${next}`] };
  }

  // ⑮ 반영 준비(실제 전용) — 최신 master 를 git 없이 내보내 패치를 얹고 격리 재검증. 본 저장소는 읽기만.
  async function mergePrep(s) {
    const root = sandboxDir(tools.stateDir, s.sigkey);
    const dir = path.join(root, "merge"), tar = path.join(root, "src.tar");
    const h = await tools.run("git.rev-parse", { repo, rev: "master" });
    const head = h.code === 0 ? h.stdout.trim() : "";
    if (!/^[0-9a-f]{40}$/.test(head)) return { merge: { ok: false, detail: `master 를 못 찾음(코드 ${h.code})` }, route: "plan" };
    fs.rmSync(dir, { recursive: true, force: true }); mkdirp(dir);
    const a = await tools.run("git.archive", { repo, out: tar, rev: head });
    if (a.code !== 0) throw new Error(`git archive 실패(코드 ${a.code})`);
    const x = await tools.run("tar.extract-sandbox", { tar, dir });
    fs.rmSync(tar, { force: true });
    if (x.code !== 0) throw new Error(`tar 풀기 실패(코드 ${x.code})`);
    if (forbiddenPresent(dir).length) throw Object.assign(new Error("반영 사본에 있으면 안 되는 것이 있다"), { codeDefect: true });
    const pg = await tools.run("flutter.pub-get-offline", { dir }); // 패치(LLM 코드)를 얹기 전에만
    if (pg.code !== 0) throw new Error(`pub get --offline 실패(코드 ${pg.code})`);
    // 재현 시험만 먼저 얹는다 → (격리) 최신 master 에서도 빨강인지 → 그다음 수정 패치(steps_check 가 master_red 통과 뒤 적용)
    for (const f of [s.reproTest, ...s.reproSupport]) copyNoFollow(path.join(s.redbase, f), dir, f);
    return { merge: { ok: null, head, dir, applied: false }, phase: "merge", stepsDone: [], route: "steps_launch", log: [`merge_prep master ${head.slice(0, 8)} 내보냄 + 재현 시험`] };
  }

  // ⑯ 커밋·push — effect 로만. 그림자는 '했을 일'만 적힌다(fn 을 부르지 않는다).
  async function commitPush(s) {
    const key = `gostop-commit:${s.sigkey}:${String(s.fullPatch?.sha256 ?? "").slice(0, 12)}`;
    const wt = path.join(gostopDir(tools.stateDir), "release-wt", keyDir(s.sigkey));
    const title = short(String(s.diag?.hypothesis ?? s.sigkey).split(/[.。\n]/)[0], 60);
    const msg = writeAtomic(path.join(rdir(s), "commit-msg.txt"),
      `fix(rules): ${title}\n\n${short(s.review?.summary ?? "", 600)}\n\n재현 시험: ${s.reproTest}\n자동 검증: ${s.steps.filter((x) => x.phase === "verify" && x.fix === s.fixAttempt).map((x) => `${x.id}${x.ok ? "✓" : "✗"}`).join(" ")}\n\nLG-Key: ${s.sigkey}\n`);
    const headFile = path.join(rdir(s), "commit-head.txt");
    // 시작만 적히고 끝이 없을 때(틱이 push 중에 죽음): 원격 master 가 우리가 만든 커밋이면 일어난 것, 아니면 안 일어난 것(H10 중9)
    const verify = async () => {
      const mine = String(readNoFollow(headFile) ?? "").trim();
      if (!/^[0-9a-f]{40}$/.test(mine)) return false;
      const r = await tools.run("git.ls-remote-master", { repo });
      return r.code === 0 && r.stdout.split(/\s/)[0] === mine;
    };
    // 훅은 끈다(-c core.hooksPath=/dev/null · --no-verify): 본 저장소 훅이 LLM 코드를 격리 밖에서 돌린다(H10 중9).
    // 대신 ⑮ 가 격리 안에서 최신 master + 패치의 3경로·대상·전체 시험을 돌렸다. 설계 §5.2⑯ 'pre-push 관문 그대로'와 다르다 — 실제 모드 전 결정 사항.
    const res = await tools.effect(key, "git_commit_push", async () => {
      const must = (id, r) => { if (r.code !== 0) throw new Error(`${id} 실패(코드 ${r.code}): ${short(r.stderr, 200)}`); };
      if (fs.existsSync(wt)) await tools.run("git.worktree-remove", { repo, wt }); // 지난번에 죽고 남은 작업 폴더
      must("worktree-add", await tools.run("git.worktree-add", { repo, wt, rev: s.merge.head }));
      try {
        must("apply", await tools.run("git.apply-index", { wt, patch: s.fullPatch.file }));
        must("commit", await tools.run("git.commit-file", { wt, msg }));
        const h = await tools.run("git.wt-head", { wt });
        must("head", h);
        writeAtomic(headFile, h.stdout.trim());
        must("push", await tools.run("git.push-master", { wt }));
      } finally {
        await tools.run("git.worktree-remove", { repo, wt });
      }
    }, { verify });
    return { commit: { key, shadow: !!res?.shadow, ran: res?.ran !== false && !res?.shadow, dedup: !!res?.dedup }, route: "plan", log: [`commit_push ${res?.shadow ? "그림자(했을 일)" : "실행"}`] };
  }

  // 1b 상태 판정 — plan 과 검토 뒤 갈림길이 함께 쓴다
  function statusOf(s) {
    if (s.violation) return { status: "gave_up", note: `격리 위반 — ${s.violation}` };
    if (s.rtError) return { status: "gave_up", note: s.rtError };
    if (s.noRed) return { status: "no_red", note: "재현 시험이 패치 전에 빨간불을 내지 못했다(2회)" };
    if (s.fixError) return { status: "gave_up", note: s.fixError };
    if (s.mode === "live" && s.scopeFinal?.reasons?.length && s.scopeApproval && s.scopeApproval !== "approved") return { status: "gave_up", note: "주인님 반려(수정 패치)" };
    if (!s.verifyOk || !s.review?.pass) return { status: "gave_up", note: "검증·검토를 마치지 못했다" };
    const reasons = [...(s.scope?.reasons ?? []), ...(s.scopeFinal?.reasons ?? []).map((x) => `${x.path}: ${x.reason}`)];
    if (reasons.length) {
      if (s.mode !== "live") return { status: "would_ask", note: reasons.join(" / ") };
      const okPre = !(s.scope?.reasons?.length) || s.approval === "approved";
      const okFinal = !(s.scopeFinal?.reasons?.length) || s.scopeApproval === "approved";
      if (!(okPre && okFinal)) return { status: "gave_up", note: "주인님 반려" };
    }
    if (s.mode === "live" && s.merge && s.merge.ok === false) return { status: "gave_up", note: `반영 준비 실패 — ${s.merge.detail}` };
    return { status: "ready", note: s.signal?.bench ? "벤치 — 반영·커밋하지 않는다(정답은 이미 본 저장소에 있다)" : null };
  }

  // plan.md 의 1b 절 — 고칠 안을 사람이 따라갈 수 있게 경로를 다 적는다
  function plan1b(s, dir) {
    const r = (f) => (f ? path.relative(dir, f) : "-");
    const lastFix = s.steps.filter((x) => x.phase === "verify" && x.fix === s.fixAttempt);
    return [
      "", "## 빨간 시험 → 수정 → 검증(1b)",
      `- 재현 시험: ${s.reproTest ?? "-"}${s.threePath ? ` (3경로 ${JSON.stringify(s.threePath)})` : ""} · 작성 ${s.rtAttempt}회${s.rtError ? ` — ${s.rtError}` : ""}`,
      `- 시험 파일 자리: ${s.reproTest && s.work ? path.join(s.work, s.reproTest) : "-"}`,
      ...s.redRuns.map((x) => `- 빨간불 확인 ${x.attempt}: ${x.red ? "빨강" : "아님"} rc=${x.rc} ${x.secs}s 실패 ${x.failed.length}${x.compileError ? " (컴파일 오류)" : ""} · 로그 ${x.log}`),
      `- 수정: ${s.fixAttempt}회${s.fixError ? ` — ${s.fixError}` : ""} · 정본 패치 ${r(s.fullPatch?.file)} (${s.fullPatch?.files?.map((f) => `${f.path}+${f.added}-${f.removed}`).join(", ") ?? "-"})`,
      `- 이번 수정만: ${r(s.fixPatch?.file)} · AI 결정 비교: ${s.aiCheck}${s.aiDetail ? ` (${s.aiDetail})` : ""}`,
      ...(s.scopeFinal ? [`- 수정 범위: ${s.scopeFinal.reasons?.length ? s.scopeFinal.reasons.map((x) => `${s.mode === "shadow" ? "물었을 것" : "승인 사유"} ${x.path}: ${x.reason}`).join(" / ") : "승인 사유 없음"}`] : []),
      ...(lastFix.length ? ["", "| 검증 | 결과 | 시간 | 내용 | 로그 |", "|---|---|---|---|---|", ...lastFix.map((x) => `| ${x.id} | ${x.ok ? "통과" : "실패"} | ${x.secs ?? "-"}s | ${String(x.detail).replace(/\|/g, "/").slice(0, 160)} | ${x.log} |`)] : []),
      ...(s.review ? ["", `- 검토(수정 ${s.review.fix}): ${s.review.pass ? "통과" : "반려"} — ${s.review.summary ?? ""}`, ...(s.review.issues ?? []).map((x) => `  - ${x}`)] : []),
      ...(s.violation ? [`- 격리 위반: ${s.violation}`] : []),
      ...(s.merge ? [`- 반영 준비(⑮): ${s.merge.ok ? "통과" : `실패 — ${s.merge.detail ?? ""}`} master ${String(s.merge.head ?? "").slice(0, 8)}`] : []),
      ...(s.commit ? [`- 커밋·push(⑯): ${s.commit.shadow ? "그림자 — 했을 일만 기록" : s.commit.dedup ? "이미 했음" : "실행"} (${s.commit.key})`] : []),
      `- 호출: sonnet ${sonnetUsed(s)} · opus ${s.calls.opus ?? 0}`,
    ];
  }

  // ⑭ 고칠 안 — 상태를 정하고 runs/<sigkey>/plan.md 를 남긴다. 사본의 build·.dart_tool 은 지운다(사본은 3일 보관, §2).
  async function plan(s) {
    let status, note = null;
    if (s.leak) { status = "gave_up"; note = `벤치 정답 누설 — ${s.leak.map((h) => `${h.file}(${h.term})`).join(", ")}`; }
    else if (s.repro === "flaky") status = "flaky";
    else if (s.repro === "not_reproduced") status = "not_reproduced";
    else if (s.repro === "failed" || s.repro === "compile_error" || s.repro === "tool_error" || s.diagError) { status = "gave_up"; note = s.diagError ?? `재현 ${s.repro}`; }
    else if (s.diag?.rule_gap) status = "rule_decision";
    else if (s.stage === "1b") {
      if (s.mode === "live" && s.scope?.reasons?.length && s.approval !== "approved") { status = "gave_up"; note = "주인님 반려(수정 전 승인)"; }
      else ({ status, note } = statusOf(s));
    } else if (s.scope?.reasons?.length) {
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
        const facts = JSON.stringify({ sigkey: s.sigkey, status, note, repro: s.repro, diag: s.diag ? { hypothesis: s.diag.hypothesis, files: s.diag.files, rule_gap: s.diag.rule_gap, rule_gap_detail: s.diag.rule_gap_detail, confidence: s.diag.confidence } : null, scope: s.scope?.reasons ?? [],
          ...(s.stage === "1b" ? { repro_test: s.reproTest, patch_files: s.fullPatch?.files?.map((f) => f.path) ?? [], verify: s.steps.filter((x) => x.phase === "verify" && x.fix === s.fixAttempt).map((x) => `${x.id}:${x.ok ? "ok" : "fail"}`), review: s.review?.summary ?? null, approval_reasons: s.scopeFinal?.reasons?.map((x) => x.reason) ?? [] } : {}) });
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
      ...(s.stage === "1b" && (s.rtAttempt || s.reproTest) ? plan1b(s, dir) : []),
      "",
    ].join("\n");
    const planPath = writeAtomic(path.join(dir, "plan.md"), md);
    writeAtomic(path.join(dir, "result.json"), `${JSON.stringify({ sigkey: s.sigkey, status, note, leak: s.leak, repro: s.repro, runs: s.reproRuns.map(({ blocks, ...r }) => r), diag: s.diag, diagError: s.diagError, scope: s.scope, bench: bench ? { id: bench.id, match } : null, mode: s.mode, base: s.base, sizes: s.sizes,
      ...(s.stage === "1b" ? { stage: "1b", reproTest: s.reproTest, reproSupport: s.reproSupport, threePath: s.threePath, rtAttempt: s.rtAttempt, rtError: s.rtError, redRuns: s.redRuns, noRed: s.noRed,
        fixAttempt: s.fixAttempt, fixError: s.fixError, fixPatch: s.fixPatch, fullPatch: s.fullPatch, aiCheck: s.aiCheck, aiDetail: s.aiDetail, scopeFinal: s.scopeFinal,
        steps: s.steps, verifyOk: s.verifyOk, review: s.review, violation: s.violation, merge: s.merge, commit: s.commit, calls: { ...s.calls, sonnet: sonnetUsed(s) }, work: s.work } : {}) }, null, 1)}\n`);
    // 판정 M8 은 스레드당 한 번(plan 이 다시 돌아도 두 번 세지 않게 표식 파일)
    let firstBench = false;
    if (bench) { try { fs.writeFileSync(path.join(dir, "bench-recorded"), status, { flag: "wx", mode: 0o600 }); firstBench = true; } catch { /* 이미 적음 */ } }
    if (firstBench) tools.bench({ bench: bench.id, reproduced: s.repro === "skipped" ? null : s.repro === "reproduced", diag_match: match?.ok ?? null, signal: sg.kind });
    for (const d of [s.work, s.baseDir, s.merge?.dir].filter(Boolean)) for (const sub of ["build", ".dart_tool"]) fs.rmSync(path.join(d, sub), { recursive: true, force: true });
    const verify_log = fixVerifyLog(s, status, planPath);
    return { status, planPath, verify_log, log: [`plan ${status}${verify_log ? "" : " (확인 기록 없음)"}`] };
  }

  const R = (s) => s.route; // 갈림길 노드가 고른 다음 노드
  return new StateGraph(State)
    .addNode("preflight", preflight)
    .addNode("sandbox", sandbox)
    .addNode("reproduce_launch", reproduceLaunch)
    .addNode("reproduce_check", reproduceCheck)
    .addNode("diagnose_launch", diagnoseLaunch)
    .addNode("diagnose_check", diagnoseCheck)
    .addNode("scope_precheck", scopePrecheck)
    .addNode("owner_gate", ownerGate)
    .addNode("repro_test_launch", reproTestLaunch)
    .addNode("repro_test_check", reproTestCheck)
    .addNode("verify_red_launch", verifyRedLaunch)
    .addNode("verify_red_check", verifyRedCheck)
    .addNode("fix_launch", fixLaunch)
    .addNode("fix_check", fixCheck)
    .addNode("scope_check", scopeCheck)
    .addNode("scope_gate", scopeGate)
    .addNode("steps_launch", stepsLaunch)
    .addNode("steps_check", stepsCheck)
    .addNode("review_launch", reviewLaunch)
    .addNode("review_check", reviewCheck)
    .addNode("merge_prep", mergePrep)
    .addNode("commit_push", commitPush)
    .addNode("plan", plan)
    .addEdge(START, "preflight")
    .addEdge("preflight", "sandbox")
    .addConditionalEdges("sandbox", (s) => (s.leak ? "plan" : "reproduce_launch"), ["reproduce_launch", "plan"])
    .addConditionalEdges("reproduce_launch", (s) => (s.repro === "skipped" ? "diagnose_launch" : "reproduce_check"), ["reproduce_check", "diagnose_launch"])
    .addConditionalEdges("reproduce_check", afterReproCheck, ["reproduce_launch", "diagnose_launch", "plan"])
    .addEdge("diagnose_launch", "diagnose_check")
    .addConditionalEdges("diagnose_check", afterDiagCheck, ["diagnose_launch", "scope_precheck", "plan"])
    .addConditionalEdges("scope_precheck", afterScope, ["owner_gate", "repro_test_launch", "plan"])
    .addConditionalEdges("owner_gate", afterOwner, ["repro_test_launch", "plan"])
    .addConditionalEdges("repro_test_launch", R, ["repro_test_check", "plan"])
    .addConditionalEdges("repro_test_check", R, ["repro_test_launch", "verify_red_launch", "plan"])
    .addEdge("verify_red_launch", "verify_red_check")
    .addConditionalEdges("verify_red_check", R, ["verify_red_launch", "repro_test_launch", "fix_launch", "plan"])
    .addConditionalEdges("fix_launch", R, ["fix_check", "plan"])
    .addConditionalEdges("fix_check", R, ["fix_launch", "steps_launch", "scope_check", "plan"])
    .addConditionalEdges("scope_check", R, ["fix_launch", "scope_gate", "steps_launch", "plan"])
    .addConditionalEdges("scope_gate", afterScopeGate, ["steps_launch", "plan"])
    .addEdge("steps_launch", "steps_check")
    .addConditionalEdges("steps_check", R, ["steps_launch", "scope_check", "fix_launch", "review_launch", "commit_push", "plan"])
    .addConditionalEdges("review_launch", R, ["review_check", "plan"])
    .addConditionalEdges("review_check", R, ["review_launch", "fix_launch", "merge_prep", "commit_push", "plan"])
    .addConditionalEdges("merge_prep", R, ["steps_launch", "plan"])
    .addEdge("commit_push", "plan")
    .addEdge("plan", END)
    .compile({ checkpointer });
}
