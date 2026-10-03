// gostop-qa.mjs — 고스톱 실기 QA 반장. 사람이 하던 '수백 판 실기 QA'(녹화를 프레임 단위로 보기)를 무인으로 돌린다.
//
// 일꾼은 따로 도는 CLI 하나다: ~/.openclaw/workspace/scripts/gostop-qa/gqa.py (허용 목록 gostop.qa-*).
//   자동 대국 드라이버(앱 안, integration_test/qa_autoplay_test.dart)가 진짜 탭으로 두고 사건 JSONL 을 남기면,
//   녹화기(screenrecord 이어 찍기)·분석기(모든 프레임 결정적 검사 + 3×3 프레임 묶음)가 판정 재료를 만든다.
// 이 그래프는 순서·책갈피·LLM 눈 검사·신호 등록만 맡는다.
//
//   gate → build → emu → [play_launch → play_check → analyze → (묶음이 차면) eye_first → eye_confirm → clip → signal]* → finish
//
// 책갈피: 판 번호(next)가 체크포인트에 남는다. 에뮬레이터가 죽으면 emu 로 돌아가 같은 판부터, 게이트웨이가 재시작돼도
//         분리 실행은 살아 있고 다음 틱의 확인 노드가 잇는다. 끝난 판은 다시 두지 않는다.
// LLM: 스레드당 5회 상한이라 판마다 부르지 않는다 — 판 묶음(eyeEvery 묶음)마다 1차(haiku) 1회 + 확인(sonnet) 1회.
// 부수효과: 지시함(orders.md) 줄만 — effect 로(그림자면 '했을 일'만). 신호 파일(signals.json)은 우리 상태 파일이라 일꾼이 쓴다.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { StateGraph, Annotation, START, END } from "@langchain/langgraph";

export const meta = { name: "gostop-qa", description: "고스톱 실기 QA — 자동 대국·녹화·프레임 검사·AI 눈·신호 등록" };

const last = (a, b) => (b === undefined ? a : b);
const State = Annotation.Root({
  day: Annotation({ reducer: last }),
  base: Annotation({ reducer: last }),
  games: Annotation({ reducer: last }),
  perLaunch: Annotation({ reducer: last }),
  eyeEvery: Annotation({ reducer: last }),
  seed0: Annotation({ reducer: last }),
  diffs: Annotation({ reducer: last }),
  rev: Annotation({ reducer: last }),
  gateInfo: Annotation({ reducer: last }),
  apk: Annotation({ reducer: last }),
  sha: Annotation({ reducer: last }),
  next: Annotation({ reducer: last, default: () => 0 }), // 책갈피 — 다음에 둘 판 번호
  runs: Annotation({ reducer: last, default: () => [] }), // 끝난 판 묶음 [{run, from, n, outcomes}]
  curRun: Annotation({ reducer: last }),
  queue: Annotation({ reducer: last, default: () => [] }), // LLM 눈 검사를 기다리는 판 묶음
  eyeDone: Annotation({ reducer: last, default: () => false }),
  batchNo: Annotation({ reducer: last, default: () => 0 }),
  h: Annotation({ reducer: last, default: () => ({}) }), // 분리 실행 손잡이
  att: Annotation({ reducer: last, default: () => ({}) }), // 노드별 시도
  emuNeeded: Annotation({ reducer: last, default: () => false }),
  emuReady: Annotation({ reducer: last, default: () => false }),
  eyeRetry: Annotation({ reducer: last, default: () => false }),
  failed: Annotation({ reducer: last }),
  tokens: Annotation({ reducer: last, default: () => 0 }),
  llmCalls: Annotation({ reducer: last, default: () => 0 }),
  posted: Annotation({ reducer: last, default: () => [] }),
  result: Annotation({ reducer: last }),
  log: Annotation({ reducer: (a, b) => a.concat(b), default: () => [] }),
});

const DIFFS_RE = /^[0-2](,[0-2]){0,5}$/;
const kstDay = (ms = Date.now()) => new Date(ms + 9 * 3_600_000).toISOString().slice(0, 10);
const stateRoot = () => path.resolve(process.env.GQA_STATE || path.join(os.homedir(), ".openclaw", "workspace", "state", "gostop-play", "qa-auto"));
const ordersPath = () => path.resolve(process.env.GQA_ORDERS || path.join(os.homedir(), ".openclaw", "workspace", "state", "duty", "orders.md"));
const MAX_ATTEMPT = 3;

export function input(flags) {
  const day = /^\d{4}-\d{2}-\d{2}$/.test(String(flags.day ?? "")) ? String(flags.day) : kstDay();
  const games = Math.max(1, Math.min(200, Number(flags.games ?? 20) | 0));
  const perLaunch = Math.max(1, Math.min(10, Number(flags.per ?? 5) | 0));
  const diffs = DIFFS_RE.test(String(flags.diffs ?? "")) ? String(flags.diffs) : "0,1,2";
  const seed0 = Math.max(1, Number(flags.seed ?? Number(day.replace(/-/g, "")) % 100000 * 100) | 0);
  const rev = /^[A-Za-z0-9._/-]{1,60}$/.test(String(flags.rev ?? "")) ? String(flags.rev) : "master";
  // 묶음 수: LLM 스레드 상한(5회) 안에 들게 — 묶음 하나당 1차 + 확인 2회. 기본은 두 묶음.
  const launches = Math.ceil(games / perLaunch);
  const eyeEvery = Math.max(1, Number(flags.eyeEvery ?? Math.ceil(launches / 2)) | 0);
  const base = `qa${day.replace(/-/g, "").slice(2)}-${String(flags.tag ?? seed0).replace(/[^A-Za-z0-9]/g, "").slice(0, 12)}`;
  return { day, games, perLaunch, eyeEvery, seed0, diffs, rev, base };
}

export const summarize = (v) => String(v.result ?? `판 ${v.next ?? 0}/${v.games ?? "?"}`);

// 일꾼 출력의 마지막 JSON 줄
export function lastJson(text) {
  const lines = String(text ?? "").trim().split("\n").reverse();
  for (const l of lines) {
    const t = l.trim();
    if (t.startsWith("{")) { try { return JSON.parse(t); } catch { /* 다음 줄 */ } }
  }
  return null;
}

// 분리 실행 확인 공통: running → pending, 실패 → 다시 띄울지(시도 + 1), 성공 → JSON
function checkJob(tools, s, key, label) {
  const h = s.h[key];
  const st = tools.check(h);
  if (st.state === "running") throw tools.pending(`${label} 진행 중`);
  const failed = st.state === "dead" || st.timedOut || st.error || st.code == null || st.signal;
  if (failed) {
    const why = st.state === "dead" ? `분리 실행 ${st.reason ?? "죽음"}` : st.timedOut ? "시간 제한 초과" : `끝남 코드 ${st.code ?? st.signal}`;
    return { retry: true, why };
  }
  const j = lastJson(tools.output(h, "stdout"));
  if (!j) return { retry: true, why: `출력 JSON 없음(코드 ${st.code})` };
  return { j };
}

function bump(s, key) { return { ...s.att, [key]: (s.att[key] ?? 1) + 1 }; }

// 지시함에 하루 제목 아래로 한 줄. 이미 있으면(같은 id) 쓰지 않는다.
export function appendOrder(file, day, line, id) {
  const cur = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
  if (cur.includes(`id ${id})`)) return false;
  const head = `## 고스톱 실기 QA 자동 — ${day}`;
  let add = "";
  if (!cur.includes(head)) add += `${cur.endsWith("\n") || !cur ? "" : "\n"}\n${head}\n`;
  else if (!cur.endsWith("\n")) add += "\n";
  // 제목이 끝에 있지 않으면 끝에 같은 제목을 다시 열지 않고 그냥 끝에 붙인다(제목 아래 묶음은 사람이 읽기 좋게 유지)
  fs.appendFileSync(file, `${add}${line}\n`);
  return true;
}

export function build({ checkpointer, llm, tools }) {
  const sdir = (s, run) => path.join(stateRoot(), s.day, run);

  // ① 관문 — 에뮬레이터 비었나·디스크·부하·01:30~04:30
  async function gate(s) {
    const r = await tools.run("gostop.qa-gate", {});
    const j = lastJson(r.stdout);
    if (!j) throw new Error(`관문 출력 없음(코드 ${r.code})`);
    if (!j.ok) throw tools.hold(`관문: ${j.reasons.join("; ")}`);
    return { gateInfo: j, log: [`gate 통과 디스크 ${j.disk_gib}GiB 부하 ${j.load1}`] };
  }

  // ② 빌드(씨앗별 캐시 — 같은 커밋·같은 드라이버면 바로 끝)
  function buildLaunch(s) {
    const h = tools.launch("gostop.qa-build", { rev: s.rev }, { node: "build", attempt: s.att.build ?? 1 });
    return { h: { ...s.h, build: h }, log: [`build_launch ${s.rev}`] };
  }
  function buildCheck(s) {
    const c = checkJob(tools, s, "build", "빌드");
    if (c.retry || !c.j.ok) {
      const why = c.why ?? c.j.error;
      if ((s.att.build ?? 1) >= MAX_ATTEMPT) return { failed: `빌드 실패: ${why}`, log: [`build 실패 ${why}`] };
      return { att: bump(s, "build"), log: [`build ${why} — 다시`] };
    }
    return { apk: c.j.apk, sha: c.j.sha, log: [`build ${c.j.cached ? "캐시" : `${c.j.sec}s`} ${String(c.j.sha).slice(0, 8)}`] };
  }

  // ③ 에뮬레이터(창 없이·비행기 모드) + 설치
  function emuLaunch(s) {
    // 같은 (노드, 시도)는 한 번만 뜬다 — 다시 띄울 때마다 새 번호(기동 횟수)를 쓴다
    const n = (s.att.emuN ?? 0) + 1;
    const h = tools.launch("gostop.qa-emu-up", {}, { node: "emu", attempt: n });
    return { h: { ...s.h, emu: h }, att: { ...s.att, emuN: n }, log: [`emu_launch ${n}`] };
  }
  async function emuCheck(s) {
    const c = checkJob(tools, s, "emu", "에뮬레이터 기동");
    if (c.retry || !c.j.ok) {
      const why = c.why ?? c.j.error;
      if (/다른 작업/.test(why ?? "")) throw tools.hold(`에뮬레이터: ${why}`);
      if ((s.att.emu ?? 1) >= MAX_ATTEMPT) return { failed: `에뮬레이터 기동 실패: ${why}`, log: [`emu 실패 ${why}`] };
      return { att: bump(s, "emu"), emuReady: false, log: [`emu ${why} — 다시`] };
    }
    const r = await tools.run("gostop.qa-install", { apk: s.apk });
    const j = lastJson(r.stdout);
    if (!j?.ok) {
      if ((s.att.emu ?? 1) >= MAX_ATTEMPT) return { failed: `설치 실패: ${JSON.stringify(j?.msg ?? r.code)}`, log: ["install 실패"] };
      return { att: bump(s, "emu"), emuReady: false, log: [`install 실패 — 에뮬레이터부터 다시`] };
    }
    return { emuNeeded: false, emuReady: true, att: { ...s.att, emu: 1 }, log: [`emu 준비 pid ${c.j.pid} 비행기 ${c.j.airplane}`] };
  }

  // ④ 판 두기 + 녹화(분리 실행). 판 사이마다 관문을 다시 본다(부하·디스크·야간).
  async function playLaunch(s) {
    const r = await tools.run("gostop.qa-gate", {});
    const g = lastJson(r.stdout);
    if (g && !g.ok) throw tools.hold(`판 사이 관문: ${g.reasons.join("; ")}`);
    const n = Math.min(s.perLaunch, s.games - s.next);
    const run = `${s.base}-${s.next}`;
    const h = tools.launch("gostop.qa-play", { run, seed: String(s.seed0 + s.next), games: String(n), diffs: s.diffs, rev: s.sha },
      { node: `play_${s.next}`, attempt: s.att.play ?? 1 });
    return { h: { ...s.h, play: h }, curRun: run, log: [`play_launch 판 ${s.next}~${s.next + n - 1} (${run})`] };
  }
  function playCheck(s) {
    const c = checkJob(tools, s, "play", `판 ${s.next}`);
    if (c.retry || !c.j.ok) {
      const why = c.why ?? c.j.error ?? "?";
      const emuGone = /기기 없음|device|offline/.test(why);
      if ((s.att.play ?? 1) >= MAX_ATTEMPT) {
        // 같은 판이 세 번 실패 — 이 판은 건너뛴다(기록만). 책갈피를 넘겨 다음 판으로.
        return { next: s.next + 1, att: { ...s.att, play: 1 }, curRun: null, emuNeeded: true, emuReady: false,
          runs: [...s.runs, { run: s.curRun, from: s.next, n: 0, outcomes: ["infra_fail"], why }], log: [`play 판 ${s.next} 3회 실패(${why}) — 건너뜀`] };
      }
      const need = emuGone || /분리 실행/.test(why);
      return { att: bump(s, "play"), curRun: null, emuNeeded: need, emuReady: !need, log: [`play ${why} — 다시${emuGone ? "(에뮬레이터부터)" : ""}`] };
    }
    const j = c.j;
    const fin = Math.max(1, Number(j.finished ?? 0)); // 앱이 첫 판에서 죽어도 그 판은 친다(같은 판 무한 반복 방지)
    const runs = [...s.runs, { run: s.curRun, from: s.next, n: fin, outcomes: j.outcomes ?? [], died: !!j.app_died }];
    return { runs, next: s.next + fin, att: { ...s.att, play: 1 }, emuNeeded: false,
      log: [`play 끝 ${fin}판 ${JSON.stringify(j.outcomes ?? [])}${j.app_died ? " 앱 죽음" : ""}`] };
  }

  // ⑤ 수거·결정적 검사(+ LLM 눈 검사용 묶음)
  function analyzeLaunch(s) {
    const h = tools.launch("gostop.qa-analyze", { run: s.curRun, day: s.day }, { node: `analyze_${s.curRun}`, attempt: s.att.ana ?? 1 });
    return { h: { ...s.h, ana: h }, log: [`analyze_launch ${s.curRun}`] };
  }
  function analyzeCheck(s) {
    const c = checkJob(tools, s, "ana", "분석");
    if (c.retry || !c.j.ok) {
      if ((s.att.ana ?? 1) >= MAX_ATTEMPT) return { queue: s.queue, att: { ...s.att, ana: 1 }, log: [`analyze 실패 ${c.why ?? c.j.error} — 이 묶음 건너뜀`] };
      return { att: bump(s, "ana"), log: [`analyze ${c.why ?? c.j.error} — 다시`] };
    }
    const j = c.j;
    return { queue: [...s.queue, s.curRun], att: { ...s.att, ana: 1 },
      log: [`analyze 프레임 ${j.frames} 확정 ${j.confirmed} 후보 ${j.candidates} 묶음 ${j.eye?.sheets ?? 0}`] };
  }
  const eyeDue = (s) => s.queue.length >= s.eyeEvery || s.next >= s.games;

  // ⑥ AI 1차(haiku) — 묶음의 모든 3×3 그림을 한 번에. ⑦ AI 확인(sonnet) — 1차가 짚은 것만.
  const batchName = (s) => `${s.base}-eye${s.batchNo}`;
  async function eyeLaunch(s, stage) {
    const batch = batchName(s);
    const r = await tools.run("gostop.qa-eye-prompt", { batch, runs: s.queue.join(","), stage, day: s.day });
    const j = lastJson(r.stdout);
    if (!j?.ok) throw new Error(`눈 검사 프롬프트 실패(${stage}): ${r.stderr?.slice?.(-200) ?? r.code}`);
    if (j.skip) return { h: { ...s.h, eye: null }, log: [`eye_${stage} 건너뜀(볼 것 없음)`] };
    const model = stage === "first" ? "haiku" : "sonnet";
    const h = llm.launchAsk(j.prompt, { model, node: `eye_${stage}_${s.batchNo}`, attempt: s.att[`eye_${stage}`] ?? 1, tools: ["Read"], cwd: j.cwd,
      timeoutMs: 12 * 60_000 });
    return { h: { ...s.h, eye: h }, log: [`eye_${stage}_launch ${model} ${j.files ?? j.items}건`] };
  }
  async function eyeCheck(s, stage) {
    const h = s.h.eye;
    if (!h) return { eyeRetry: false, log: [`eye_${stage} 없음`] };
    const st = llm.checkAsk(h);
    if (st.state === "running") throw tools.pending(`AI ${stage} 진행 중`);
    if (st.state === "failed" && (st.kind === "login" || st.kind === "usage_limit")) throw tools.hold(`AI ${stage}: ${st.error}`, st.kind);
    if (st.state !== "done") {
      const key = `eye_${stage}`;
      if ((s.att[key] ?? 1) >= 2) return { h: { ...s.h, eye: null }, eyeRetry: false, log: [`eye_${stage} 실패(${st.reason ?? st.kind ?? st.state}) — AI 없이 진행`] };
      return { h: { ...s.h, eye: null }, att: bump(s, key), eyeRetry: true, log: [`eye_${stage} ${st.reason ?? st.kind ?? st.state} — 다시`] };
    }
    const batch = batchName(s);
    const dir = path.join(stateRoot(), s.day, batch);
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    fs.writeFileSync(path.join(dir, `llm-${stage}.txt`), String(st.text ?? ""), { mode: 0o600 });
    const r = await tools.run("gostop.qa-eye-record", { batch, stage, day: s.day });
    const j = lastJson(r.stdout) ?? {};
    const u = st.usage ?? {};
    const tok = (u.input_tokens ?? u.in ?? 0) + (u.output_tokens ?? u.out ?? 0) + (u.cache_creation_input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0);
    return { h: { ...s.h, eye: null }, eyeRetry: false, tokens: s.tokens + tok, llmCalls: s.llmCalls + 1,
      log: [`eye_${stage} ${j.parsed ? "" : "(답 형식 못 읽음) "}짚음 ${j.flagged ?? 0} 토큰 ${tok}`] };
  }

  // ⑧ 클립 ⑨ 신호·지시함 — 눈 검사가 끝난 묶음이면 묶음 전체, 아니면 이번 판(결정적 확정만)
  async function clip(s) {
    const due = eyeDue(s);
    const targets = due ? s.queue : [s.curRun].filter(Boolean);
    let n = 0;
    for (const run of targets) {
      const r = await tools.run("gostop.qa-clip", { run, day: s.day });
      n += lastJson(r.stdout)?.findings ?? 0;
    }
    return { eyeDone: due, log: [`clip ${targets.length}묶음 확정 ${n}`] };
  }
  async function signal(s) {
    const targets = s.eyeDone ? s.queue : [s.curRun].filter(Boolean);
    const posted = [...s.posted];
    for (const run of targets) {
      const r = await tools.run("gostop.qa-signal", { run, day: s.day });
      const j = lastJson(r.stdout) ?? {};
      for (const o of j.orders ?? []) {
        const file = ordersPath();
        const res = await tools.effect(`gostop-qa-order:${o.id}`, "orders_append",
          () => appendOrder(file, s.day, o.line, o.id),
          { verify: () => fs.existsSync(file) && fs.readFileSync(file, "utf8").includes(`id ${o.id})`) });
        if (!posted.includes(o.id)) posted.push(o.id);
        void res;
      }
    }
    // 눈 검사까지 끝난 묶음은 원본 녹화를 지운다(임시 산출물)
    if (s.eyeDone) for (const run of s.queue) await tools.run("gostop.qa-cleanup", { run });
    if (s.eyeDone) {
      for (const run of [batchName(s)]) await tools.run("gostop.qa-cleanup", { run });
    }
    return s.eyeDone
      ? { queue: [], batchNo: s.batchNo + 1, eyeDone: false, posted, att: { ...s.att, eye_first: 1, eye_confirm: 1 }, log: [`signal 지시함 후보 ${posted.length}`] }
      : { posted, log: [`signal(결정적) 누적 ${posted.length}`] };
  }

  // ⑩ 묶음 요약
  async function finish(s) {
    await tools.run("gostop.qa-emu-down", {});
    const rows = [];
    let total = 0;
    const sev = { 상: 0, 중: 0, 하: 0 };
    for (const r of s.runs) {
      const f = path.join(sdir(s, r.run), "findings.json");
      let fs_ = [];
      try { fs_ = JSON.parse(fs.readFileSync(f, "utf8")).findings ?? []; } catch { /* 없음 */ }
      total += fs_.length;
      for (const x of fs_) sev[x.severity] = (sev[x.severity] ?? 0) + 1;
      rows.push(`| ${r.run} | ${r.from}~${r.from + Math.max(0, r.n - 1)} | ${(r.outcomes ?? []).join(",")} | ${fs_.length} | ${fs_.map((x) => `${x.severity} ${x.check}`).slice(0, 6).join(" · ")} |`);
    }
    const md = [`# 고스톱 실기 QA 묶음 — ${s.base} (${s.day})`, "",
      `- 판 ${s.next}/${s.games} · 커밋 ${String(s.sha ?? "").slice(0, 8)} · 씨앗 ${s.seed0}~ · 난이도 ${s.diffs} · 모드 ${tools.mode}`,
      `- 확정 발견 ${total}건(상 ${sev.상} · 중 ${sev.중} · 하 ${sev.하}) · 지시함 후보 ${s.posted.length} · AI 호출 ${s.llmCalls}회 토큰 ${s.tokens}`,
      s.failed ? `- 실패: ${s.failed}` : "", "", "| 묶음 | 판 | 결과 | 발견 | 요지 |", "|---|---|---|---|---|", ...rows].join("\n");
    const out = path.join(stateRoot(), s.day, `${s.base}-summary.md`);
    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.writeFileSync(out, md + "\n");
    return { result: `${s.failed ? "실패 — " + s.failed + " · " : ""}판 ${s.next}/${s.games} · 발견 ${total}(상 ${sev.상}) · 지시함 ${s.posted.length} · ${out}`, log: ["finish"] };
  }

  const afterBuild = (s) => (s.failed ? "finish" : s.apk ? "emu_launch" : "build_launch");
  const afterEmu = (s) => (s.failed ? "finish" : s.emuReady ? "play_launch" : "emu_launch");
  const afterPlay = (s) => {
    if (s.curRun && s.runs.at(-1)?.run === s.curRun && s.runs.at(-1)?.n > 0) return "analyze_launch";
    if (s.next >= s.games) return "finish";
    return s.emuNeeded ? "emu_launch" : "play_launch";
  };
  const afterAnalyze = (s) => (s.queue.at(-1) === s.curRun || s.att.ana === 1 ? (eyeDue(s) ? "eye_first_launch" : "clip") : "analyze_launch");
  const afterEyeCheck = (stage) => (s) => {
    if (s.h.eye) return `eye_${stage}_check`;
    if (s.eyeRetry) return `eye_${stage}_launch`;
    return stage === "first" ? "eye_confirm_launch" : "clip";
  };
  const afterSignal = (s) => (s.next >= s.games ? (s.queue.length ? "eye_first_launch" : "finish") : "play_launch");

  return new StateGraph(State)
    .addNode("gate", gate)
    .addNode("build_launch", buildLaunch)
    .addNode("build_check", buildCheck)
    .addNode("emu_launch", emuLaunch)
    .addNode("emu_check", emuCheck)
    .addNode("play_launch", playLaunch)
    .addNode("play_check", playCheck)
    .addNode("analyze_launch", analyzeLaunch)
    .addNode("analyze_check", analyzeCheck)
    .addNode("eye_first_launch", (s) => eyeLaunch(s, "first"))
    .addNode("eye_first_check", (s) => eyeCheck(s, "first"))
    .addNode("eye_confirm_launch", (s) => eyeLaunch(s, "confirm"))
    .addNode("eye_confirm_check", (s) => eyeCheck(s, "confirm"))
    .addNode("clip", clip)
    .addNode("signal", signal)
    .addNode("finish", finish)
    .addEdge(START, "gate")
    .addEdge("gate", "build_launch")
    .addEdge("build_launch", "build_check")
    .addConditionalEdges("build_check", afterBuild, ["build_launch", "emu_launch", "finish"])
    .addEdge("emu_launch", "emu_check")
    .addConditionalEdges("emu_check", afterEmu, ["emu_launch", "play_launch", "finish"])
    .addEdge("play_launch", "play_check")
    .addConditionalEdges("play_check", afterPlay, ["analyze_launch", "play_launch", "emu_launch", "finish"])
    .addEdge("analyze_launch", "analyze_check")
    .addConditionalEdges("analyze_check", afterAnalyze, ["analyze_launch", "eye_first_launch", "clip"])
    .addConditionalEdges("eye_first_launch", (s) => (s.h.eye ? "eye_first_check" : "eye_confirm_launch"), ["eye_first_check", "eye_confirm_launch"])
    .addConditionalEdges("eye_first_check", afterEyeCheck("first"), ["eye_first_check", "eye_first_launch", "eye_confirm_launch"])
    .addConditionalEdges("eye_confirm_launch", (s) => (s.h.eye ? "eye_confirm_check" : "clip"), ["eye_confirm_check", "clip"])
    .addConditionalEdges("eye_confirm_check", afterEyeCheck("confirm"), ["eye_confirm_check", "eye_confirm_launch", "clip"])
    .addEdge("clip", "signal")
    .addConditionalEdges("signal", afterSignal, ["play_launch", "eye_first_launch", "finish"])
    .addEdge("finish", END)
    .compile({ checkpointer });
}
