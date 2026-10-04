// duty-intake.mjs — 당직 D0 그림자(PLAN §13.3)의 틱 고리. 새 잡 없이 lg-tick 이 틱마다(관문 앞, PAUSED 면 안 함) 부른다.
//   ① 게이트웨이 확인(허용 목록 gateway.listen-pid·gateway.proc — 읽기 전용) → 기록 lg.restart.heartbeat
//      { gw_pid, gw_start, gw_up, open: ["<상태> <스레드>"…], jobs: ["<스레드>/<노드>/<시도> <pid>"…] } — 재시작 생존 실측(PLAN §3)의 바탕
//   ② 재시작 접수: 재시작 기록(~/.openclaw/logs/gateway-restart.log)의 'restart attempt' 줄(커서 뒤) + 기록에 없는 pid 바뀜(죽음·launchd 재기동)
//      → 재시작마다 duty-verify 스레드 하나 'dv-<재시작 초>'(그림자 고정, 대기열). 이미 있으면 다시 올리지 않는다(멱등)
// 상태 파일 <상태 폴더>/duty-verify/intake.json { cursor_ms, gw, recent }. 처음(파일 없음)에는 지금부터 본다(지난 재시작은 올리지 않는다).
// 끄기: <상태 폴더>/DUTY_VERIFY_OFF 파일(또는 LG_DUTY_VERIFY=0). 시험 모드에서는 LG_DUTY_VERIFY=1 일 때만 돈다.
import fs from "node:fs";
import path from "node:path";
import { iso } from "./config.mjs";
import { createRun } from "./run.mjs";
import { GRAPH, paths, probeGateway, restartEvents, gatewayPort } from "../graphs/duty-verify-common.mjs";

export const offPath = (cfg) => path.join(cfg.stateDir, "DUTY_VERIFY_OFF");
export const intakePath = (cfg) => path.join(cfg.stateDir, "duty-verify", "intake.json");

export function dutyEnabled(cfg, env = process.env) {
  if (fs.existsSync(offPath(cfg)) || env.LG_DUTY_VERIFY === "0") return false;
  return cfg.testMode ? env.LG_DUTY_VERIFY === "1" : true;
}

function readState(file) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; }
}
function writeState(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(obj), { mode: 0o600 });
  fs.renameSync(tmp, file);
}

// 돌고 있는 분리 실행(jobs/<스레드>/<노드>/<시도>/ 에 meta.json 이 있고 result.json 이 없음)
export function runningJobs(jobsDir, max = 10) {
  const out = [];
  const dirs = (p) => { try { return fs.readdirSync(p, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name); } catch { return []; } };
  for (const t of dirs(jobsDir)) for (const n of dirs(path.join(jobsDir, t))) for (const a of dirs(path.join(jobsDir, t, n))) {
    const d = path.join(jobsDir, t, n, a);
    if (!fs.existsSync(path.join(d, "meta.json")) || fs.existsSync(path.join(d, "result.json"))) continue;
    let pid = null;
    try { pid = JSON.parse(fs.readFileSync(path.join(d, "meta.json"), "utf8")).pid ?? null; } catch { /* 쓰는 중 */ }
    out.push(`${t}/${n}/${a} ${pid}`);
    if (out.length >= max) return out;
  }
  return out;
}

// 틱마다 한 번. 돌려주는 값은 시험·--verbose 용 요약. 오류는 부른 쪽(run.mjs)이 기록하고 틱은 계속 간다.
export async function dutyTick({ cfg, store, metric, now, registry, timeLeft = null, graphExists = () => true }) {
  if (!dutyEnabled(cfg)) return { off: true };
  const run = createRun({ cfg, registry, thread: "_duty-intake", mode: "shadow", timeLeft });
  const t = now();
  const gw = await probeGateway(run, t, gatewayPort());
  metric("lg.restart.heartbeat", {
    gw_pid: gw.pid, gw_start: gw.startMs != null ? iso(gw.startMs) : null, gw_start_ms: gw.startMs, gw_up: gw.up, gw_err: gw.err,
    open: store.openThreads().map((r) => `${r.status} ${r.thread_id}`).slice(0, 15),
    jobs: runningJobs(cfg.jobsDir),
  });

  const file = intakePath(cfg);
  const st = readState(file);
  const gwRec = gw.up && gw.pid ? { pid: gw.pid, start_ms: gw.startMs, t } : null;
  if (!st) { // 처음 — 지금부터 본다
    writeState(file, { cursor_ms: t, gw: gwRec, recent: [], boot: iso(t) });
    return { boot: true, gw, created: [] };
  }
  let text = "";
  try { text = fs.readFileSync(paths().restartLog, "utf8"); } catch { /* 기록 파일 없음 — pid 바뀜만 본다 */ }
  const evs = restartEvents(text, st.cursor_ms ?? t);
  const cands = evs.map((e) => ({ t: e.t, pid_before: e.pid, source: "restart_log", trigger: e.trigger, outcome: e.outcome }));
  const prev = st.gw;
  // 기록에 없는 재시작(죽음·launchd 재기동·기록 실패): 지난 틱의 게이트웨이와 pid(또는 시작 시각)가 다르다.
  // 옛 게이트웨이가 시작한 뒤 ~ 새 게이트웨이 시작 + 2분 사이에 재시작 기록이 있으면(이번 또는 지난 틱이 이미 올림) 같은 재시작이다.
  if (prev?.pid && gwRec && (gwRec.pid !== prev.pid || (gwRec.start_ms != null && prev.start_ms != null && Math.abs(gwRec.start_ms - prev.start_ms) > 5000))) {
    const known = [...(st.recent ?? []), ...evs.map((e) => e.t)];
    const lo = prev.start_ms ?? prev.t ?? 0, hi = (gwRec.start_ms ?? t) + 120_000;
    if (!known.some((x) => x > lo && x <= hi)) cands.push({ t: gwRec.start_ms ?? t, pid_before: prev.pid, source: "pid_change", trigger: null, outcome: null });
  }
  const created = [];
  if (cands.length && graphExists(GRAPH)) {
    for (const c of cands) {
      const thread = `dv-${Math.floor(c.t / 1000)}`;
      const input = { restart_ms: c.t, restart: iso(c.t), source: c.source, trigger: c.trigger, outcome: c.outcome, pid_before: c.pid_before,
        pid_seen: gwRec?.pid ?? null, start_seen_ms: gwRec?.start_ms ?? null };
      store.tx(() => {
        if (store.getThread(thread) || store.hasCheckpoint(thread)) return;
        store.registerThread(thread, GRAPH, t, { mode: "shadow", status: "queued", input }); // 그림자 고정 — LIVE 스위치와 상관없이
        metric("start", { thread, graph: GRAPH, mode: "shadow", queued: true, by: "duty-intake", source: c.source });
        created.push(thread);
      });
    }
  }
  writeState(file, {
    cursor_ms: Math.max(st.cursor_ms ?? 0, ...evs.map((e) => e.t)),
    gw: gwRec ?? prev ?? null,
    recent: [...(st.recent ?? []), ...cands.map((c) => c.t)].slice(-50),
    boot: st.boot,
  });
  return { boot: false, gw, created };
}
