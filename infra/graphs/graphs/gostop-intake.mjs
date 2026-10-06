// gostop-intake.mjs — 고스톱 신호 접수(하루 1회, LLM 0회). 설계 §5.1.
//   preflight → collect(어젯밤 소크 summary.json · 직전 접수 뒤 CI 실패 · 없으면 벤치 1건) → dedupe → enqueue(gostop-fix 대기열, 하루 3건 이하)
// 한 번에 하나는 gostop-fix 의 meta.serial 로 실행기가 지킨다(S13). 실행기 틱이 04:30 뒤 첫 틱에 'gostop-intake:<날짜>' 를 올린다(LG_DAILY).
// 명령은 읽기 전용 cmdId(gh.run-list · gh.run-log-failed)만 쓴다. 본 저장소·소크 결과는 읽기만 한다.
import fs from "node:fs";
import path from "node:path";
import { StateGraph, Annotation, START, END } from "@langchain/langgraph";
import { repoPath, soakRoot, gostopDir, runDir, writeAtomic, readJson, loadBench, benchSignal, short, DIFF_TEST, kstDay } from "./gostop-common.mjs";

export const meta = { name: "gostop-intake", description: "고스톱 신호 접수(소크·CI·벤치) → 수정 스레드 대기열" };

export const DAY_CAP = 3; // 하루 3건 이하(S13)
// 거슬러 보는 길이(H3 중2·중3): 기준 시각을 앞으로 미는 대신 늘 이만큼 다시 보고, 이미 접수한 sigkey 는 장부(seen)로 뺀다.
// 그래서 접수 때 진행 중이던 CI·하루 상한에 밀린 신호·관문 때문에 접수가 없던 날의 소크도 다음 접수가 줍는다.
const CI_LOOKBACK_MS = 7 * 86_400_000;
const SOAK_LOOKBACK_DAYS = 3;
const CI_LOG_MAX = 48 * 1024; // 실패 로그 발췌 상한(바이트)

const last = (a, b) => (b === undefined ? a : b);
const State = Annotation.Root({
  day: Annotation(),
  signals: Annotation({ reducer: last, default: () => [] }),
  reportOnly: Annotation({ reducer: last, default: () => [] }), // 재현 수단이 없어 수정 스레드로 보내지 않은 신호(기록만)
  ciError: Annotation({ reducer: last, default: () => null }),
  fresh: Annotation({ reducer: last, default: () => [] }),
  enqueued: Annotation({ reducer: last, default: () => [] }),
  skipped: Annotation({ reducer: last, default: () => [] }),
  verify_log: Annotation({ reducer: last, default: () => null }), // 판정 M2 — enqueue 가 장부를 다시 읽어 확인한 것
  log: Annotation({ reducer: (a, b) => a.concat(b), default: () => [] }),
});

export function input(flags) {
  const day = String(flags.day ?? kstDay(Date.now()));
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error(`--day 는 YYYY-MM-DD: ${day}`);
  return { day };
}
export const summarize = (v) => `신호 ${v.signals?.length ?? 0} · 새것 ${v.fresh?.length ?? 0} · 올림 ${v.enqueued?.length ?? 0}${v.reportOnly?.length ? ` · 기록만 ${v.reportOnly.length}` : ""}${v.ciError ? ` · CI 못 읽음` : ""}`;

// 접수 장부(상태 폴더 gostop/intake-state.json): 본 sigkey(60일) · 벤치 회차 · 날짜별 올린 것
const ledgerPath = (stateDir) => path.join(gostopDir(stateDir), "intake-state.json");
const readLedger = (stateDir) => ({ seen: {}, benchRounds: {}, daily: {}, ...(readJson(ledgerPath(stateDir), {}) ?? {}) });

// 소크 summary.json → { signals, reportOnly }. 수정 스레드로 보내는 것은 씨앗이 있는 불일치(⛔ seed=…)뿐이다(H3 중5):
// 씨앗 없는 문제(멈춤·코치 위반·요약 전 종료)는 사본에서 재현할 길이 없어 근거 없는 진단이 되므로 기록만 한다.
// 미커밋 상태(dirty)로 돈 소크는 커밋에서 재현되지 않으니 통째로 기록만 한다.
export function soakSignals(summary) {
  const signals = [], reportOnly = [];
  if (!summary || typeof summary !== "object") return { signals, reportOnly };
  const head = String(summary.head ?? "").slice(0, 8);
  const dirty = Number(summary.dirty ?? 0) > 0;
  for (const blk of summary.mismatch_details ?? []) {
    const m = /^seed=(\d+):/.exec(String(blk));
    if (!m) continue;
    const sg = { source: "soak", kind: "seed", sigkey: `soak:normal:${m[1]}:${head}`, rev: head || "HEAD", test: DIFF_TEST,
      defines: ["REPLAY_GAMES=1", `REPLAY_SEED_BASE=${m[1]}`], report: short(blk, 1500) };
    if (dirty) reportOnly.push({ sigkey: sg.sigkey, why: "미커밋 상태로 돈 소크(dirty)", report: sg.report });
    else signals.push(sg);
  }
  for (const p of summary.problems ?? []) reportOnly.push({ sigkey: `soak:problem:${summary.day}:${head}`, why: "씨앗 없는 문제 — 재현 수단 없음", report: short(p, 600) });
  return { signals, reportOnly };
}

// gh run list JSON → 워크플로마다 가장 최근 완료 실행이 실패이고 거슬러 보는 길이 안에 만들어진 것(이미 본 것은 dedupe 가 뺀다)
export function ciFailures(runs, sinceMs) {
  const latest = new Map();
  for (const r of runs ?? []) {
    if (r?.status && r.status !== "completed") continue;
    const wf = String(r.workflowName ?? r.name ?? "?");
    const t = Date.parse(r.createdAt);
    if (!latest.has(wf) || t > latest.get(wf).t) latest.set(wf, { r, t });
  }
  const out = [];
  for (const [wf, { r, t }] of latest) {
    if (r.conclusion !== "failure" || !(t > sinceMs)) continue;
    const slug = wf.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 30) || "wf";
    out.push({ source: "ci", kind: "report", sigkey: `ci:${slug}:${String(r.headSha).slice(0, 8)}`, rev: String(r.headSha).slice(0, 40),
      ciRunId: String(r.databaseId), url: String(r.url ?? ""), workflow: wf, createdAt: r.createdAt });
  }
  return out;
}
// 실패 로그 발췌: 실패를 가리키는 줄(최대 200줄) + 끝부분 — 전체(수백 KB)는 남기지 않는다. 상한 CI_LOG_MAX.
export function ciExcerpt(text) {
  const all = String(text ?? "");
  const hits = all.split("\n").filter((l) => /error|fail|expected|actual|exception|⛔|\[E\]/i.test(l)).slice(-200).join("\n");
  const out = Buffer.from(`${hits}\n--- 끝부분 ---\n${all.slice(-16_384)}`, "utf8");
  // 바이트로 자른다(한글은 3바이트). 잘린 첫 글자 조각은 버린다.
  return out.length > CI_LOG_MAX ? out.subarray(out.length - CI_LOG_MAX).toString("utf8").replace(/^\uFFFD+/, "") : out.toString("utf8");
}
// 실패 로그에서 고스톱 시험 파일을 찾으면 그 시험으로 재현한다(없으면 제보만)
export function ciTestOf(logText) {
  const m = /\b(test\/(?:[A-Za-z0-9_]+\/)*[A-Za-z0-9_]+_test\.dart)\b/.exec(String(logText ?? ""));
  return m ? m[1] : null;
}

export function build({ checkpointer, tools }) {
  const repo = repoPath();

  // 야간 소크가 도는 중이면 보류(잠금 폴더의 pid 가 살아 있음). 3일 지난 사본 정리는 실행기가 관문 앞에서 한다(H3 중4).
  function preflight(s) {
    const lock = path.join(soakRoot(), ".lock.d");
    if (fs.existsSync(lock)) {
      let pid = NaN;
      try { pid = Number(fs.readFileSync(path.join(lock, "pid"), "utf8").trim()); } catch { /* pid 파일 없음 — 소크가 막 시작했거나 끝나는 중 */ }
      let alive = !Number.isFinite(pid); // pid 를 모르면 도는 중으로 본다(다음 틱에 다시)
      try { if (pid > 1) { process.kill(pid, 0); alive = true; } } catch (e) { alive = e?.code === "EPERM"; }
      if (alive) throw tools.hold(`야간 소크 진행 중(pid ${pid}) — 끝난 뒤 접수`, "soak");
    }
    return { log: ["preflight"] };
  }

  async function collect(s) {
    const L = readLedger(tools.stateDir);
    const signals = [], reportOnly = [];
    // ① 소크 — 오늘부터 3일 치 폴더(소크는 02:00 에 그날 날짜로 쓴다). 이미 접수한 것은 dedupe 가 장부로 뺀다.
    for (let k = 0; k < SOAK_LOOKBACK_DAYS; k++) {
      const d = kstDay(Date.parse(`${s.day}T12:00:00+09:00`) - k * 86_400_000).replaceAll("-", "");
      const r = soakSignals(readJson(path.join(soakRoot(), d, "summary.json")));
      signals.push(...r.signals);
      reportOnly.push(...r.reportOnly);
    }
    // ② CI 실패(읽기 전용 gh) — 지난 7일 안에서 지금도 빨간 워크플로. 못 읽으면 적고 넘어간다(접수는 계속).
    let ciError = null;
    const since = tools.now() - CI_LOOKBACK_MS;
    const r = await tools.run("gh.run-list", { repo });
    let runs = null;
    if (r.code === 0) { try { runs = JSON.parse(r.stdout); } catch { ciError = "gh 출력이 JSON 이 아니다"; } }
    else ciError = `gh run list 실패(코드 ${r.code}): ${short(r.stderr, 160)}`;
    if (runs) {
      for (const f of ciFailures(runs, since)) {
        const lg = await tools.run("gh.run-log-failed", { repo, run_id: f.ciRunId });
        const text = lg.code === 0 ? ciExcerpt(lg.stdout) : `(실패 로그를 못 읽음: 코드 ${lg.code})`;
        const logFile = writeAtomic(path.join(runDir(tools.stateDir, f.sigkey), "ci-log.txt"), text);
        const test = ciTestOf(text);
        signals.push({ ...f, kind: test ? "test" : "report", ...(test ? { test } : {}), ciLog: text.slice(-4000), ciLogFile: logFile,
          report: `CI '${f.workflow}' 실패 — ${f.url}` });
      }
    }
    return { signals, reportOnly, ciError, log: [`collect 신호 ${signals.length}${reportOnly.length ? ` · 기록만 ${reportOnly.length}` : ""}${ciError ? " · CI 못 읽음" : ""}`] };
  }

  // 이미 본 sigkey·같은 묶음 안 중복을 뺀다. 새 신호가 없으면 벤치 1건 — 가장 덜 돌린 사례부터(같으면 목록 순서)
  function dedupe(s) {
    const L = readLedger(tools.stateDir);
    const seen = new Set(Object.keys(L.seen));
    const fresh = [], skipped = [];
    for (const sg of s.signals) {
      if (seen.has(sg.sigkey)) { skipped.push({ sigkey: sg.sigkey, why: "이미 접수" }); continue; }
      seen.add(sg.sigkey);
      fresh.push(sg);
    }
    if (!fresh.length) {
      const pick = [...loadBench().cases].sort((a, b) => (L.benchRounds[a.id] ?? 0) - (L.benchRounds[b.id] ?? 0))[0];
      if (pick) fresh.push(benchSignal(pick, (L.benchRounds[pick.id] ?? 0) + 1));
    }
    return { fresh, skipped, log: [`dedupe 새것 ${fresh.length} · 뺌 ${skipped.length}`] };
  }

  // 대기열에 올린다 — 하루 3건 이하. 이미 있는 스레드는 실행기가 거절한다(멱등). 장부는 끝에 한 번 쓴다.
  // 끝나기 전에 장부를 다시 읽어 확인한다(판정 M2): 올린 것이 모두 '본 것'에 적혔고, 전날까지 본 것을 다시 올리지 않았고, 하루 상한 안.
  function enqueue(s) {
    const L = readLedger(tools.stateDir);
    const seenBefore = { ...L.seen };
    const today = L.daily[s.day] ?? [];
    const room = Math.max(0, DAY_CAP - today.length);
    const enqueued = [], skipped = [...s.skipped];
    for (const sg of s.fresh) {
      if (enqueued.length >= room) { skipped.push({ sigkey: sg.sigkey, why: `하루 ${DAY_CAP}건 상한` }); continue; }
      const thread = `gostop-fix:${sg.sigkey}`.slice(0, 100);
      const r = tools.enqueue("gostop-fix", thread, { sigkey: sg.sigkey, signal: sg });
      if (r.ok || r.kind === "exists") enqueued.push({ sigkey: sg.sigkey, thread, mode: r.mode ?? null, existed: !r.ok });
      L.seen[sg.sigkey] = s.day;
      if (sg.source === "bench" && sg.bench?.id) L.benchRounds[sg.bench.id] = (L.benchRounds[sg.bench.id] ?? 0) + 1;
    }
    L.daily[s.day] = [...today, ...enqueued.filter((e) => !e.existed).map((e) => e.sigkey)];
    const cut = kstDay(tools.now() - 60 * 86_400_000);
    for (const d of Object.keys(L.daily)) if (d < cut) delete L.daily[d];
    for (const [k, d] of Object.entries(L.seen)) if (d < cut) delete L.seen[k];
    const file = writeAtomic(ledgerPath(tools.stateDir), `${JSON.stringify(L, null, 1)}\n`);
    const back = readLedger(tools.stateDir);
    const fresh = enqueued.filter((e) => !e.existed);
    const unseen = enqueued.filter((e) => !back.seen[e.sigkey]).map((e) => e.sigkey);
    const again = fresh.filter((e) => seenBefore[e.sigkey] && seenBefore[e.sigkey] !== s.day).map((e) => e.sigkey);
    const todayN = (back.daily[s.day] ?? []).length;
    const problems = [...(unseen.length ? [`장부에 안 적힘 ${unseen.join(",")}`] : []), ...(again.length ? [`전에 본 것을 다시 올림 ${again.join(",")}`] : []),
      ...(todayN > DAY_CAP ? [`하루 ${todayN}건 > ${DAY_CAP}`] : [])];
    const verify_log = problems.length ? null : `gostop-intake 올림 ${fresh.length}(이미 있음 ${enqueued.length - fresh.length}) · 장부 확인(다시 올림 0 · 오늘 ${todayN}/${DAY_CAP}) — ${file}`;
    return { enqueued, skipped, verify_log, log: [`enqueue ${enqueued.length}${skipped.length ? ` · 미룸·뺌 ${skipped.length}` : ""}${problems.length ? ` · 확인 실패: ${problems.join("; ")}` : ""}`] };
  }

  return new StateGraph(State)
    .addNode("preflight", preflight)
    .addNode("collect", collect)
    .addNode("dedupe", dedupe)
    .addNode("enqueue", enqueue)
    .addEdge(START, "preflight")
    .addEdge("preflight", "collect")
    .addEdge("collect", "dedupe")
    .addEdge("dedupe", "enqueue")
    .addEdge("enqueue", END)
    .compile({ checkpointer });
}
