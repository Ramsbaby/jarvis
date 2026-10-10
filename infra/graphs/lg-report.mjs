#!/usr/bin/env node
// lg-report.mjs — 판정 집계(PLAN §2 M1~M8). 추가 전용 기록 metrics.jsonl·effects.jsonl 만 읽는다(쓰지 않는다).
//   node lg-report.mjs [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--hours N] [--json]   (--hours: 지금부터 N시간 전부터 — --since 보다 우선)
// M1·M3·M4·M6·M7 은 지금 기록으로 센다(M7 은 당직 장부 — cfg.ledgerPath). M2·M5·M8 은 그래프가 남길 필드를 정해 두고 칸만 만든다:
//   M2  done.verified   — 검증 노드 통과 기록(로그 경로). 그래프 상태에 verify_log 를 두면 실행기가 done 줄에 옮긴다
//   M5  waiting.reason  — 승인 요청 사유(USER.md 예외 낱말: game_ai·payment·iap·external_send·play_submit·repo_visibility·delete)
//   M8  bench 사건      — tools.bench({ bench, reproduced, diag_match, hidden_pass, ai_misjudge, signal })
import { loadConfig, iso } from "./lib/config.mjs";
import fs from "node:fs";
import { readJsonl } from "./lib/metrics.mjs";

const HOLD_MS = 48 * 3_600_000;
const args = process.argv.slice(2);
const flag = (k) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : undefined; };
const cfg = loadConfig();
const hours = Number(flag("hours"));
const since = Number.isFinite(hours) && hours > 0 ? Date.now() - hours * 3_600_000 : flag("since") ? Date.parse(`${flag("since")}T00:00:00`) : -Infinity;
const until = flag("until") ? Date.parse(`${flag("until")}T23:59:59.999`) : Infinity;
const inRange = (r) => Number.isFinite(r.t) && r.t >= since && r.t <= until;
const ev = readJsonl(cfg.metricsPath).filter(inRange);
const fx = readJsonl(cfg.effectsPath).filter(inRange);
const now = Date.now();
const day = (t) => new Date(t).toLocaleDateString("sv-SE");
const pct = (a, b) => (b ? `${Math.round((a / b) * 100)}%` : "—");

const byThread = new Map();
for (const r of ev) if (r.thread) { if (!byThread.has(r.thread)) byThread.set(r.thread, []); byThread.get(r.thread).push(r); }
const ENDS = new Set(["done", "expired", "gave_up"]);

// M1 끊겨도 끝까지 — 끊긴(interrupted) 스레드를 다음 틱들이 이어 갔나. '이어 감' = 끊긴 뒤 단계를 하나라도 끝냄(node_end ok).
//   그 뒤 끝남(done)·사람이 답하지 않은 승인 만료(expired approval)·다른 이유의 포기는 이어 간 것이다(끊김 탓이 아니다).
//   '버려짐' = 끊긴 뒤 한 단계도 못 끝내고 포기·보류 만료. 끝나지 않고 진척도 없는 것은 진행 중으로 분모에서 뺀다.
const m1 = { interrupted: 0, continued: 0, finished: 0, abandoned: 0, open: 0 };
for (const [, rs] of byThread) {
  const i = rs.findIndex((r) => r.ev === "interrupted");
  if (i < 0) continue;
  m1.interrupted++;
  const after = rs.slice(i + 1);
  const progressed = after.some((r) => r.ev === "node_end" && r.ok);
  const end = after.find((r) => ENDS.has(r.ev));
  if (end?.ev === "done") m1.finished++;
  if (progressed) m1.continued++;
  else if (end) m1.abandoned++;
  else m1.open++;
}
m1.rate = pct(m1.continued, m1.continued + m1.abandoned);
// 고장 주입(scripts/lg-fault.mjs, 사건 fault): 주입 뒤 그 스레드가 단계를 하나라도 끝냈나(이어 감)
const faults = ev.filter((r) => r.ev === "fault");
m1.faults = { injected: faults.length, continued: faults.filter((f) => (byThread.get(f.thread) ?? []).some((r) => r.t > f.t && r.ev === "node_end" && r.ok)).length };

// M3 중복 부수효과 0 — 실제로 낸 것(실제 모드 + 그림자의 보고성 종류 report:true)에서 같은 key 가 두 번 성공(ok)했거나,
//   시작(started)이 둘 이상인데 앞의 것이 실패가 아닌 경우. 그림자 '했을 일'(would_run)은 따로 센다.
const m3 = { live_runs: 0, report_runs: 0, keys: 0, duplicates: 0, unknown: 0, retried_after_fail: 0, shadow_would_run: {}, dup_list: [], unknown_list: [] };
const fxItem = (rs) => ({ kind: rs.at(-1).kind, key: String(rs.at(-1).key).slice(0, 80), last_ts: rs.at(-1).ts });
const keys = new Map();
for (const r of fx) {
  if (r.status === "would_run") { m3.shadow_would_run[r.kind] = (m3.shadow_would_run[r.kind] ?? 0) + 1; continue; }
  if (r.report && r.status === "started") m3.report_runs++;
  if (!keys.has(r.key)) keys.set(r.key, []);
  keys.get(r.key).push(r);
}
for (const [, rs] of keys) {
  m3.keys++;
  const starts = rs.filter((r) => r.status === "started").length;
  const oks = rs.filter((r) => r.status === "ok" && !r.recovered).length;
  m3.live_runs += starts;
  if (oks > 1) { m3.duplicates++; m3.dup_list.push(fxItem(rs)); }
  else if (starts > 1) {
    // 시작 사이에 실패 기록이 있으면 정당한 재시도, 없으면 중복 의심
    let dup = false, lastStart = false;
    for (const r of rs) {
      if (r.status === "started") { if (lastStart) dup = true; lastStart = true; }
      else if (r.status === "failed" || r.status === "cleared") lastStart = false; // cleared = verify() 가 '안 일어났다'고 확인
      else if (r.status === "ok") lastStart = true; // 성공 뒤의 시작은 중복
    }
    if (dup) { m3.duplicates++; m3.dup_list.push(fxItem(rs)); } else m3.retried_after_fail++;
  }
  if (rs.at(-1)?.status === "started") { m3.unknown++; m3.unknown_list.push(fxItem(rs)); }
}

// M4 버려진 대기·보류 0 — 끝나지 않은(done·expired·gave_up 없는) 스레드 중 마지막 기록이 48시간 넘은 것. 대기열·답 받음도 센다.
const m4 = { expired_reported: ev.filter((r) => r.ev === "expired").length, abandoned_unreported: 0, list: [] };
for (const [t, rs] of byThread) {
  if (rs.some((r) => ENDS.has(r.ev))) continue;
  const last = rs.at(-1);
  if (now - last.t > HOLD_MS) { m4.abandoned_unreported++; m4.list.push(t); }
}

// M6 비용·한도 — llm 줄(응답 usage·total_cost_usd)을 날짜별로. Fable 호출은 0 이어야 한다.
const m6days = new Map();
let fable = 0;
for (const r of ev.filter((x) => x.ev === "llm")) {
  const d = day(r.t);
  const a = m6days.get(d) ?? { calls: 0, ok: 0, in: 0, out: 0, cache_create: 0, cache_read: 0, total: 0, cost_usd: 0, models: {} };
  a.calls++; if (r.ok) a.ok++;
  for (const k of ["in", "out", "cache_create", "cache_read", "total"]) a[k] += Number(r[k] ?? 0);
  a.cost_usd += Number(r.cost_usd ?? 0);
  a.models[r.model] = (a.models[r.model] ?? 0) + 1;
  if ([r.model, ...(r.models ?? [])].some((m) => /fable/i.test(String(m)))) fable++;
  m6days.set(d, a);
}
const m6 = { days: [...m6days].map(([d, a]) => ({ day: d, ...a, cost_usd: Math.round(a.cost_usd * 1e4) / 1e4 })), fable_calls: fable };
m6.max_day_total = Math.max(0, ...m6.days.map((d) => d.total));

// M2 · M5 · M8 — 칸만(그래프가 필드를 남기면 채워진다)
const done = ev.filter((r) => r.ev === "done");
const m2 = { done: done.length, verified: done.filter((r) => r.verified).length, unverified: done.filter((r) => !r.verified).length,
  unverified_list: done.filter((r) => !r.verified).map((r) => ({ thread: r.thread, graph: r.graph, ts: r.ts })) };
const waits = ev.filter((r) => r.ev === "waiting");
const m5 = { requests: waits.length, by_reason: {}, no_reason: 0 };
for (const r of waits) { if (r.reason) m5.by_reason[r.reason] = (m5.by_reason[r.reason] ?? 0) + 1; else m5.no_reason++; }
const bench = ev.filter((r) => r.ev === "bench");
const m8 = { runs: bench.length, reproduced: bench.filter((r) => r.reproduced === true).length, diag_match: bench.filter((r) => r.diag_match === true).length,
  hidden_pass: bench.filter((r) => r.hidden_pass === true).length, ai_misjudge: bench.filter((r) => r.ai_misjudge === true).length };
// PLAN M8 ① 그림자 기준: 재현 80%↑ · 숨긴 정답 통과 50%↑ · AI 분기 오판 0. 비율은 값이 적힌(null 아닌) 실행만 분모로.
const rate = (k) => { const n = bench.filter((r) => typeof r[k] === "boolean").length; return n ? Math.round((bench.filter((r) => r[k] === true).length / n) * 100) : null; };
m8.criteria = { reproduced_min: 80, hidden_pass_min: 50, ai_misjudge_max: 0 };
m8.rates = { reproduced: rate("reproduced"), hidden_pass: rate("hidden_pass"), diag_match: rate("diag_match") };
m8.below = [...(m8.rates.reproduced != null && m8.rates.reproduced < 80 ? ["reproduced"] : []), ...(m8.rates.hidden_pass != null && m8.rates.hidden_pass < 50 ? ["hidden_pass"] : []),
  ...(m8.ai_misjudge > 0 ? ["ai_misjudge"] : [])];
// 벤치는 돌았는데 기준 칸이 한 번도 값(true·false)을 받지 못함 — '0'이 아니라 '안 잼'이다(10-06: hidden_pass 는 아무도 적지 않았다)
m8.unmeasured = m8.runs ? ["reproduced", "hidden_pass", "ai_misjudge"].filter((k) => !bench.some((r) => typeof r[k] === "boolean")) : [];

// D0 당직 그림자(PLAN §13.3) — 합격: 7일간 당직 판정과 100% 일치 + 게이트웨이 재시작 생존 실측 3회 이상
//   verify: 재시작 뒤 확인 판정 · compare: 다음 당직 장부 판정과 일치(true·false·none·n/a) · 생존: 재시작을 건넌 스레드·분리 실행이 이어 갔나
const dvv = ev.filter((r) => r.ev === "lg.duty.verify" && r.phase === "verify");
const dvc = ev.filter((r) => r.ev === "lg.duty.verify" && r.phase === "compare");
const hbs = ev.filter((r) => r.ev === "lg.restart.heartbeat");
const d0 = { verified: dvv.length, verdicts: {}, compared: dvc.length, agreement: {}, kinds: {}, heartbeats: hbs.length,
  gw_changes: hbs.filter((r, i) => i > 0 && r.gw_pid && hbs[i - 1].gw_pid && r.gw_pid !== hbs[i - 1].gw_pid).length,
  survival: { measured: 0, with_load: 0, open: 0, progressed: 0, waiting: 0, stalled: 0, jobs: 0, jobs_survived: 0, jobs_killed: 0 } };
for (const r of dvv) d0.verdicts[r.verdict] = (d0.verdicts[r.verdict] ?? 0) + 1;
for (const r of dvc) {
  d0.agreement[String(r.agreement)] = (d0.agreement[String(r.agreement)] ?? 0) + 1;
  d0.kinds[r.kind] = (d0.kinds[r.kind] ?? 0) + 1;
  const s = r.survival ?? {};
  if (!s.measured) continue;
  d0.survival.measured++;
  if ((s.open ?? 0) + (s.jobs ?? 0) > 0) d0.survival.with_load++; // 재시작을 실제로 건넌 일이 있었던 재시작만 '생존 실측'으로 센다
  for (const k of ["open", "progressed", "waiting", "stalled", "jobs", "jobs_survived", "jobs_killed"]) d0.survival[k] += s[k] ?? 0;
}
const agreeN = d0.agreement.true ?? 0, judged = agreeN + (d0.agreement.false ?? 0);
d0.agreement_rate = pct(agreeN, judged);

// M7 주인님이 먼저 찾은 루프 고장 — 당직 장부에서 key 가 lg.·graphs. 로 시작하고 found_by:"owner" 인 줄(10-05: 손으로 세던 정의가
//   graphs.* 를 빠뜨렸다). 같은 key·같은 날은 한 사건으로 묶는다(원인 규명 줄을 덧붙여도 한 건).
const m7 = { lines: 0, incidents: [] };
try {
  const seen = new Set();
  for (const line of fs.readFileSync(cfg.ledgerPath, "utf8").split("\n")) {
    let d; try { d = JSON.parse(line); } catch { continue; }
    const k = String(d.key ?? ""), t = Date.parse(d.ts ?? "");
    if (d.found_by !== "owner" || !(k.startsWith("lg.") || k.startsWith("graphs.")) || !(t >= since && t <= until)) continue;
    m7.lines++;
    const id = `${day(t)} ${k}`;
    if (!seen.has(id)) { seen.add(id); m7.incidents.push({ day: day(t), key: k, item: String(d.item ?? "").slice(0, 80) }); }
  }
} catch (e) { m7.error = `장부를 못 읽음: ${e.code ?? e.message}`; }

const held = {};
for (const r of ev.filter((x) => x.ev === "held")) for (const g of r.reasons ?? []) held[g] = (held[g] ?? 0) + 1;
const ticks = ev.filter((r) => r.ev === "tick");
// 같은 사유로 연달아 보류된 틱 — 사유별 가장 긴 연속과 지금 이어지는 연속(틱 단위 보류만, 보류 아닌 틱이 끊는다).
// LLM 예산 관문(scope llm, 10-10)은 틱을 세우지 않으므로 그 관문이 걸린 채 돈 틱(tick 줄의 llm_gates)은 그 사유의 연속을 끊지 않는다.
const held_streak = {};
{
  const run = {};
  for (const r of ev) {
    if (r.ev === "held" && (r.scope === "tick" || r.scope === "llm")) {
      const rs = new Set(r.reasons ?? []);
      for (const k of Object.keys(run)) if (!rs.has(k)) run[k] = 0;
      for (const k of rs) {
        run[k] = (run[k] ?? 0) + 1;
        const h = (held_streak[k] ??= { max: 0, current: 0, max_since: null, last: null });
        if (run[k] > h.max) { h.max = run[k]; h.max_since = r.ts; }
        h.last = r.ts;
      }
    } else if (r.ev === "tick" && r.outcome !== "hold") { const on = new Set(r.llm_gates ?? []); for (const k of Object.keys(run)) if (!on.has(k)) run[k] = 0; }
  }
  for (const k of Object.keys(held_streak)) held_streak[k].current = run[k] ?? 0;
}

const last_tick = ticks.at(-1)?.ts ?? null;
const report = { range: { since: Number.isFinite(since) ? iso(since) : null, until: flag("until") ?? null, hours: Number.isFinite(hours) && hours > 0 ? hours : null }, now: iso(now),
  events: ev.length, effects: fx.length, ticks: ticks.length, last_tick, held, held_streak, m1, m2, m3, m4, m5, m6, m7, m8, d0 };
if (args.includes("--json")) { process.stdout.write(`${JSON.stringify(report, null, 1)}\n`); process.exit(0); }

const L = [];
L.push(`# 랭그래프 판정 집계 — ${iso(now)}`, "", `기록 ${ev.length}줄 · 부수효과 원장 ${fx.length}줄 · 틱 ${ticks.length}회 · 범위 ${flag("since") ?? "처음"} ~ ${flag("until") ?? "지금"}`, "");
L.push("## M1 끊겨도 끝까지 (기준 100%)", "", "| 끊긴 스레드 | 이어 감 | 그중 끝냄 | 버려짐 | 진행 중 | 비율(이어 감) |", "|---|---|---|---|---|---|",
  `| ${m1.interrupted} | ${m1.continued} | ${m1.finished} | ${m1.abandoned} | ${m1.open} | ${m1.rate} |`, "",
  `고장 주입 ${m1.faults.injected}회 · 그 뒤 이어 감 ${m1.faults.continued}회`, "");
L.push("## M3 중복 부수효과 (기준 0)", "", "| 실제 실행(그중 그림자 보고성) | key 수 | 중복 | 결과 모름 | 실패 뒤 재시도 | 그림자 '했을 일' |", "|---|---|---|---|---|---|",
  `| ${m3.live_runs}(${m3.report_runs}) | ${m3.keys} | ${m3.duplicates} | ${m3.unknown} | ${m3.retried_after_fail} | ${Object.entries(m3.shadow_would_run).map(([k, n]) => `${k} ${n}`).join(" · ") || 0} |`, "");
L.push("## M4 버려진 대기·보류 (기준 0)", "", "| 만료 보고 | 48시간 넘게 보고 없이 남음 |", "|---|---|", `| ${m4.expired_reported} | ${m4.abandoned_unreported}${m4.list.length ? ` (${m4.list.slice(0, 5).join(", ")})` : ""} |`, "");
L.push("## M6 비용·한도 (추가 돈 0원 · Fable 0)", "", "| 날짜 | 호출(성공) | 입력 | 출력 | 캐시 생성 | 캐시 읽기 | 합계 토큰 | 비용 환산(USD) |", "|---|---|---|---|---|---|---|---|");
for (const d of m6.days) L.push(`| ${d.day} | ${d.calls}(${d.ok}) | ${d.in} | ${d.out} | ${d.cache_create} | ${d.cache_read} | ${d.total} | ${d.cost_usd} |`);
if (!m6.days.length) L.push("| — | 0 | 0 | 0 | 0 | 0 | 0 | 0 |");
L.push("", `Fable 호출 ${m6.fable_calls} · 하루 최댓값 ${m6.max_day_total} 토큰(10-28 상한 = 그림자 ② 하루 최댓값 × 1.5)`, "");
L.push("## M7 주인님이 먼저 찾은 루프 고장 (기준 0) — 당직 장부 key lg.·graphs. · found_by owner", "", "| 사건 | 장부 줄 | 목록 |", "|---|---|---|",
  `| ${m7.error ? "?" : m7.incidents.length} | ${m7.lines} | ${m7.error ?? (m7.incidents.map((x) => `${x.day} ${x.key}`).join(" · ") || "—")} |`, "");
L.push("## M2 검증 없는 완료 (기준 0) — 필드 done.verified", "", "| 완료 | 검증 기록 있음 | 없음 | 없는 것(최근 5) |", "|---|---|---|---|",
  `| ${m2.done} | ${m2.verified} | ${m2.unverified} | ${m2.unverified_list.slice(-5).map((x) => x.thread).join(", ") || "—"} |`, "");
L.push("## M5 승인 요청 사유 — 필드 waiting.reason", "", "| 요청 | 사유별 | 사유 없음 |", "|---|---|---|",
  `| ${m5.requests} | ${Object.entries(m5.by_reason).map(([k, n]) => `${k} ${n}`).join(" · ") || "—"} | ${m5.no_reason} |`, "");
L.push("## M8 값을 했나 — 사건 bench", "", "| 벤치 실행 | 재현 | 원인 일치 | 숨긴 정답 통과 | AI 분기 오판 |", "|---|---|---|---|---|",
  `| ${m8.runs} | ${m8.reproduced}(${m8.rates.reproduced ?? "—"}%) | ${m8.diag_match}(${m8.rates.diag_match ?? "—"}%) | ${m8.hidden_pass}(${m8.rates.hidden_pass ?? "—"}%) | ${m8.ai_misjudge} |`, "",
  `기준(그림자 ①): 재현 80%↑ · 숨긴 정답 통과 50%↑ · AI 분기 오판 0 — ${m8.below.length ? `미달 ${m8.below.join(", ")}` : m8.runs ? (m8.unmeasured.length ? "잰 칸은 충족" : "충족") : "실행 없음"}${m8.unmeasured.length ? ` · 한 번도 안 잰 칸 ${m8.unmeasured.join(", ")}` : ""}`, "");
L.push("## D0 당직 그림자 — 게이트웨이 재시작 뒤 확인 (합격: 7일 당직 판정 100% 일치 + 생존 실측 3회 이상)", "",
  "| 확인 | 판정별 | 대조 | 일치(true·false) | 그 밖 | 일치율 |", "|---|---|---|---|---|---|",
  `| ${d0.verified} | ${Object.entries(d0.verdicts).map(([k, n]) => `${k} ${n}`).join(" · ") || "—"} | ${d0.compared} | ${agreeN}·${d0.agreement.false ?? 0} | ${Object.entries(d0.agreement).filter(([k]) => k !== "true" && k !== "false").map(([k, n]) => `${k} ${n}`).join(" · ") || "—"} | ${d0.agreement_rate} |`, "",
  "| heartbeat | 게이트웨이 바뀜 | 생존 실측(건넌 일 있음) | 열린 스레드 → 이어 감·대기·멈춤 | 분리 실행 → 살아남음·죽음 |", "|---|---|---|---|---|",
  `| ${d0.heartbeats} | ${d0.gw_changes} | ${d0.survival.measured}(${d0.survival.with_load}) | ${d0.survival.open} → ${d0.survival.progressed}·${d0.survival.waiting}·${d0.survival.stalled} | ${d0.survival.jobs} → ${d0.survival.jobs_survived}·${d0.survival.jobs_killed} |`, "");
L.push(`보류 사유 횟수: ${Object.entries(held).map(([k, n]) => `${k} ${n}`).join(" · ") || "없음"}`);
L.push(`보류 연속(틱): ${Object.entries(held_streak).map(([k, h]) => `${k} 최장 ${h.max} · 지금 ${h.current}`).join(" · ") || "없음"} · 마지막 틱 ${last_tick ?? "없음"}`);
process.stdout.write(`${L.join("\n")}\n`);
