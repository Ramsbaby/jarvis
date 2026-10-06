// duty-verify.mjs — 당직 D0 그림자(PLAN §13.3): 게이트웨이 재시작 하나를 틱이 기다렸다가 도구 경로를 확인하고 결과를 lg. 기록에만 남긴다.
//   wait     재시작 + 3분 전이면 CONTINUE(다음 틱이 다시 본다 — 틱 안에서 자지 않는다)
//   verify   결정적(LLM 0): 게이트웨이 포트 주인·프로세스 시작 시각(새 pid)·HTTP /health · 재시작 뒤 대화 기록의 오픈클로 도구
//            '권한 끊김' 0건(감지기와 같은 판별) · 게이트웨이 로그의 같은 문구 0건 → ok | broken | unknown + 근거
//   record   기록 lg.duty.verify(phase verify) + 장부 한 줄은 그림자 effect('했을 일')로만 — fn 은 일부러 장부를 쓰지 않는다(D1 결재 뒤)
//   compare  재시작 뒤 첫 당직 장부 gateway.tool_authority 판정(읽기만)과 일치 여부 + 재시작 생존 실측 → lg.duty.verify(phase compare).
//            판정 줄이 아직 없으면 14시간까지 CONTINUE, 지나면 none 으로 끝
// 스레드는 실행기 틱 고리(lib/duty-intake.mjs)가 재시작마다 하나('dv-<재시작 초>', 그림자 고정)를 대기열에 올린다.
// 끝(DONE)은 알리지 않는다(meta.quietDone) — 결과는 lg. 기록에만. 장부·감지기·절차서는 읽기만 한다.
import { StateGraph, Annotation, START, END } from "@langchain/langgraph";
import { LEDGER_KEY, waitMs, compareWindowMs, START_TOL_MS, gatewayPort, paths, isoLocal, probeGateway, healthOk,
  scanTranscripts, scanGatewayLogs, nextDutyJudgement, measureSurvival } from "./duty-verify-common.mjs";
import fs from "node:fs";

export const meta = { name: "duty-verify", description: "당직 D0 그림자 — 게이트웨이 재시작 뒤 도구 경로 확인(lg. 기록만)", quietDone: true };

const last = (a, b) => (b === undefined ? a : b);
const State = Annotation.Root({
  restart_ms: Annotation(),
  restart: Annotation(),
  source: Annotation({ reducer: last, default: () => "manual" }),
  trigger: Annotation({ reducer: last, default: () => null }),
  outcome: Annotation({ reducer: last, default: () => null }),
  pid_before: Annotation({ reducer: last, default: () => null }),
  pid_seen: Annotation({ reducer: last, default: () => null }),
  start_seen_ms: Annotation({ reducer: last, default: () => null }),
  verdict: Annotation({ reducer: last, default: () => null }),
  check: Annotation({ reducer: last, default: () => null }),
  verified_at: Annotation({ reducer: last, default: () => null }),
  shadow_effect: Annotation({ reducer: last, default: () => null }),
  cmp: Annotation({ reducer: last, default: () => null }),
  survival: Annotation({ reducer: last, default: () => null }),
  verify_log: Annotation({ reducer: last, default: () => null }), // 판정 M2 — compare 가 남긴 확인 요지(판정이 unknown 이면 비워 둔다)
  log: Annotation({ reducer: (a, b) => a.concat(b), default: () => [] }),
});

// 시작 입력. 틱 고리가 등록부에 넣은 입력({restart_ms, …})이 그대로 오거나, 손으로 start 할 때 --topic <재시작 시각(ISO·epoch)>.
export function input(flags) {
  const raw = flags.restart_ms ?? flags.topic;
  const n = /^\d+$/.test(String(raw ?? "")) ? Number(raw) : Date.parse(String(raw ?? ""));
  const ms = Number.isFinite(n) ? (n < 1e12 ? n * 1000 : n) : NaN;
  if (!Number.isFinite(ms)) throw new Error(`재시작 시각이 필요하다(--topic 2026-10-04T16:55:51+09:00 또는 epoch): ${raw ?? "(없음)"}`);
  return { restart_ms: ms, restart: isoLocal(ms), source: "manual" };
}
export const summarize = (v) =>
  `재시작 ${v.restart ?? "?"} · 판정 ${v.verdict ?? "?"}${v.check?.reasons?.length ? `(${v.check.reasons.join(",")})` : ""} · 당직 대조 ${v.cmp?.agreement ?? "?"}${v.cmp?.kind ? `(${v.cmp.kind})` : ""}`;

export function build({ checkpointer, tools }) {
  // 실제 모드 스레드는 돌리지 않는다 — D0 는 그림자 전용(장부 쓰기는 D1, 주인님 결재 뒤)
  const shadowOnly = () => { if (tools.mode !== "shadow") throw tools.hold("D0 는 그림자 전용 — 실제 모드 스레드는 돌리지 않는다(D1 은 주인님 결재 뒤)", "d0_shadow_only"); };

  function wait(s) {
    shadowOnly();
    if (!Number.isFinite(s.restart_ms)) throw new Error("재시작 시각(restart_ms)이 없다");
    const due = s.restart_ms + waitMs();
    if (tools.now() < due) throw tools.pending(`재시작 뒤 대기 — ${isoLocal(due)} 이후 확인`);
    return { log: ["wait"] };
  }

  async function verify(s) {
    const now = tools.now();
    const port = gatewayPort();
    const gw = await probeGateway(tools.run, now, port);
    const health = gw.up ? await healthOk(tools.run, port) : { ok: false, detail: "포트 주인 없음" };
    const P = paths();
    const tr = scanTranscripts(P.claudeProjects, s.restart_ms, now);
    const gl = scanGatewayLogs(P, s.restart_ms, now);
    const reasons = [], unknown = [];
    if (!gw.up) reasons.push("gateway_down");
    else {
      if (s.pid_before && gw.pid === s.pid_before) reasons.push("same_pid");
      if (gw.startMs != null && gw.startMs < s.restart_ms - START_TOL_MS) reasons.push("started_before_restart");
      if (gw.startMs == null) unknown.push("start_unreadable");
      if (!health.ok) reasons.push("health_not_ok");
    }
    if (tr.fail > 0) reasons.push("tool_authority_closed");
    if (gl.hits > 0) reasons.push("gwlog_authority_closed");
    if (!tr.readable) unknown.push("transcripts_unreadable");
    // 틱 고리가 본 새 게이트웨이(pid_seen)가 또 바뀌었다 — 이 재시작은 다음 재시작에 덮였다(그 재시작은 자기 스레드가 본다)
    const superseded = !!(gw.up && s.pid_seen && gw.pid !== s.pid_seen && gw.startMs != null && s.start_seen_ms != null && gw.startMs > s.start_seen_ms + 5000);
    if (superseded) unknown.push("superseded");
    const verdict = superseded ? "unknown" : reasons.length ? "broken" : unknown.length ? "unknown" : "ok";
    const check = {
      up: gw.up, pid: gw.pid, gw_start: isoLocal(gw.startMs), new_pid: gw.up && s.pid_before ? gw.pid !== s.pid_before : null,
      health: health.ok, health_detail: health.detail, probe_err: gw.err,
      tool_fail: tr.fail, tool_fail_methods: tr.methods, tool_ok: tr.ok, transcripts: tr.files, transcripts_skipped: tr.skipped,
      gwlog_fail: gl.hits, gwlog_files: gl.files, delay_s: Math.round((now - s.restart_ms) / 1000), reasons, unknown,
    };
    return { verdict, check, verified_at: now, log: [`verify ${verdict}`] };
  }

  async function record(s) {
    shadowOnly();
    const c = s.check ?? {};
    tools.dutyVerify({ phase: "verify", verdict: s.verdict, restart: s.restart, source: s.source, trigger: s.trigger, outcome: s.outcome,
      pid_before: s.pid_before, pid_after: c.pid, gw_start: c.gw_start, new_pid: c.new_pid, up: c.up, health: c.health,
      tool_fail: c.tool_fail, tool_fail_methods: c.tool_fail_methods, tool_ok: c.tool_ok, gwlog_fail: c.gwlog_fail,
      delay_s: c.delay_s, reasons: c.reasons, unknown: c.unknown, agreement: "pending" });
    const verified = s.verdict === "ok" ? "true" : s.verdict === "broken" ? "false" : "unknown";
    const key = `would append ledger line key=${LEDGER_KEY} verified=${verified} restart=${s.restart}`;
    // 그림자에서는 fn 을 부르지 않고 effects.jsonl 에 '했을 일'만 남는다. fn 은 혹시 불려도 장부를 쓰지 않고 실패한다(D1 전까지).
    const r = await tools.effect(key, "duty.ledger_append", () => { throw new Error("D0 그림자 — 당직 장부 쓰기는 구현하지 않았다(D1 결재 뒤)"); });
    return { shadow_effect: r.shadow ? key : null, log: ["record"] };
  }

  function compare(s) {
    const now = tools.now();
    const P = paths();
    let text = null;
    try { text = fs.readFileSync(P.ledger, "utf8"); } catch { /* 장부 없음 — 판정 줄도 없다 */ }
    const d = text == null ? null : nextDutyJudgement(text, s.restart_ms);
    const until = s.restart_ms + compareWindowMs();
    if (!d && now < until) throw tools.pending(`다음 당직 판정 대기(장부에 ${LEDGER_KEY} 줄 없음) — ${isoLocal(until)}까지`);
    let agreement, kind;
    const duty = d ? (d.verified ? "ok" : "broken") : null;
    if (!d) { agreement = "none"; kind = "no_duty_line"; }
    else if (s.verdict === "unknown") { agreement = "n/a"; kind = "ours_unknown"; }
    else if (duty === s.verdict) { agreement = true; kind = "same"; }
    else if (duty === "broken" && d.firstSeen != null && d.firstSeen > (s.verified_at ?? 0)) { agreement = false; kind = "later_break"; }
    else { agreement = false; kind = "mismatch"; }
    const survival = measureSurvival(tools.stateDir, s.restart_ms, now);
    const cmp = { agreement, kind, duty, duty_ts: d ? isoLocal(d.ts) : null, duty_first_seen: d?.firstSeen ? isoLocal(d.firstSeen) : null, duty_mode: d?.mode ?? null };
    tools.dutyVerify({ phase: "compare", verdict: s.verdict, restart: s.restart, source: s.source, ...cmp, survival });
    // 판정 M2: 확인을 끝냈다고 할 수 있는 것은 도구 경로 판정이 났을 때(ok·broken)뿐 — unknown 은 확인 못 한 완료로 남긴다
    const verify_log = s.verdict === "ok" || s.verdict === "broken"
      ? `duty-verify 재시작 ${s.restart} 판정 ${s.verdict}(근거: 포트 주인·새 pid·/health·대화 기록 권한 끊김 ${s.check?.tool_fail ?? "?"}·게이트웨이 로그 ${s.check?.gwlog_fail ?? "?"}) · 당직 대조 ${agreement} — metrics lg.duty.verify`
      : null;
    return { cmp, survival, verify_log, log: [`compare ${agreement}`] };
  }

  return new StateGraph(State)
    .addNode("wait", wait)
    .addNode("verify", verify)
    .addNode("record", record)
    .addNode("compare", compare)
    .addEdge(START, "wait")
    .addEdge("wait", "verify")
    .addEdge("verify", "record")
    .addEdge("record", "compare")
    .addEdge("compare", END)
    .compile({ checkpointer });
}
