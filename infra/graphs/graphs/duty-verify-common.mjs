// duty-verify-common.mjs — 당직 D0 그림자(PLAN §13.3) 공용: 경로·읽기 전용 파서·게이트웨이 확인.
// 그래프(duty-verify)와 실행기 틱 고리(lib/duty-intake.mjs)가 함께 쓴다. 여기서는 아무것도 쓰지 않는다(읽기만).
// 명령은 넘겨받은 run(cmdId) 으로만 — 허용 목록 gateway.listen-pid·gateway.proc·gateway.health(읽기 전용).
// OpenClaw CLI 는 부르지 않는다(S15 — 목록에 올릴 수 없다). 살아 있음은 포트 주인(lsof)·프로세스 나이(ps)·HTTP /health 로 본다.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const GRAPH = "duty-verify";
export const LEDGER_KEY = "gateway.tool_authority";
// 감지기(orchestrator-scan.py AUTHORITY_CLOSED)와 같은 문구 — 대화 기록의 오픈클로 도구 실패 본문이 이것으로 시작한다
export const AUTHORITY_CLOSED = "Gateway client authority closed before dispatching";
const MIN = 60_000;
const HOUR = 3_600_000;

const envNum = (k, d) => { const v = Number(process.env[k]); return process.env[k] !== undefined && process.env[k] !== "" && Number.isFinite(v) && v >= 0 ? v : d; };
export const waitMs = () => envNum("LG_DV_WAIT_SEC", 180) * 1000; // 재시작 뒤 이만큼 지나야 확인한다(3분)
export const compareWindowMs = () => envNum("LG_DV_COMPARE_H", 14) * HOUR; // 다음 당직 판정 줄을 기다리는 길이(20시 회차 → 다음 날 08시 + 여유)
export const gatewayPort = () => Math.trunc(envNum("LG_GATEWAY_PORT", 18789));
export const START_TOL_MS = 2 * MIN; // 재시작 기록 시각과 새 프로세스 시작 시각의 허용 차이(기록 줄은 시작보다 2초쯤 앞선다)

const home = () => process.env.HOME || os.homedir();
// 읽는 곳(전부 읽기 전용). 시험은 환경변수로 가짜 파일을 준다.
export function paths() {
  return {
    restartLog: process.env.LG_DV_RESTART_LOG || path.join(home(), ".openclaw", "logs", "gateway-restart.log"),
    claudeProjects: process.env.LG_DV_CLAUDE_PROJECTS || path.join(home(), ".claude", "projects"),
    gwLogDir: process.env.LG_DV_GW_LOG_DIR || "/tmp/openclaw",
    gwLog: process.env.LG_DV_GW_LOG || path.join(home(), "Library", "Logs", "openclaw", "gateway.log"),
    ledger: process.env.LG_DV_DUTY_LEDGER || path.join(home(), ".openclaw", "workspace", "state", "duty", "ledger.jsonl"),
  };
}

// 이 기기 시간대의 ISO 시각(오프셋 포함) — lib/config.mjs iso 와 같은 모양(그래프는 lib 을 가져오지 못한다)
export function isoLocal(ms) {
  if (!Number.isFinite(ms)) return null;
  const off = -new Date(ms).getTimezoneOffset();
  const pad = (n) => String(Math.trunc(Math.abs(n))).padStart(2, "0");
  return `${new Date(ms + off * MIN).toISOString().slice(0, 19)}${off < 0 ? "-" : "+"}${pad(off / 60)}:${pad(off % 60)}`;
}
const localDay = (ms) => new Date(ms).toLocaleDateString("sv-SE");

// ── 재시작 기록(~/.openclaw/logs/gateway-restart.log) ─────────────────────────
// [2026-10-04T07:55:19.921Z] openclaw gateway lifecycle source=safe-rpc action=restart mode=deferred pid=32477 interactive=0
// [2026-10-04T07:55:49Z] openclaw restart attempt source=handoff mode=start-after-exit target=gui/501/ai.openclaw.gateway pid=32477 interactive=0
// [2026-10-04T07:55:51Z] openclaw restart done source=handoff mode=start-after-exit interactive=0
// 'restart attempt' 한 줄 = 실제 재시작 하나(pid 는 내려간 옛 게이트웨이). 요청(lifecycle)은 미뤄질 수 있어 사건으로 세지 않는다.
const LINE_RE = /^\[([^\]]+)\] openclaw (restart (attempt|done|failed)|gateway lifecycle)\b(.*)$/;
export function parseRestartLog(text) {
  const out = [];
  for (const line of String(text ?? "").split("\n")) {
    const m = LINE_RE.exec(line.trim());
    if (!m) continue;
    const t = Date.parse(m[1]);
    if (!Number.isFinite(t)) continue;
    const kv = Object.fromEntries([...m[4].matchAll(/(\w+)=(\S+)/g)].map((x) => [x[1], x[2]]));
    out.push({ t, kind: m[3] ?? "lifecycle", pid: /^\d+$/.test(kv.pid ?? "") ? Number(kv.pid) : null, source: kv.source ?? null, mode: kv.mode ?? null, action: kv.action ?? null });
  }
  return out;
}
// sinceMs 보다 뒤의 재시작 시도. 앞 15분 안의 재시작 요청 줄로 계기(trigger), 뒤 5분 안의 done·failed 로 결과(outcome)를 붙인다.
export function restartEvents(text, sinceMs) {
  const all = parseRestartLog(text);
  const out = [];
  for (let i = 0; i < all.length; i++) {
    const e = all[i];
    if (e.kind !== "attempt" || !(e.t > sinceMs)) continue;
    const req = all.slice(0, i).reverse().find((x) => x.kind === "lifecycle" && x.action === "restart" && e.t - x.t <= 15 * MIN);
    const end = all.slice(i + 1).find((x) => (x.kind === "done" || x.kind === "failed") && x.t - e.t <= 5 * MIN);
    out.push({ t: e.t, pid: e.pid, mode: e.mode, trigger: req ? `${req.source ?? "?"}:${req.mode ?? "?"}` : null, outcome: end?.kind ?? null });
  }
  return out;
}

// ── 게이트웨이 확인(명령은 넘겨받은 run 으로만) ───────────────────────────────
// ps etime: [[dd-]hh:]mm:ss → 초
export function parseEtime(s) {
  const m = /^(?:(\d+)-)?(?:(\d{1,2}):)?(\d{1,2}):(\d{2})$/.exec(String(s ?? "").trim());
  if (!m) return null;
  return Number(m[1] ?? 0) * 86400 + Number(m[2] ?? 0) * 3600 + Number(m[3]) * 60 + Number(m[4]);
}
export function firstPid(stdout) {
  const m = /^\s*(\d+)\s*$/m.exec(String(stdout ?? ""));
  return m ? Number(m[1]) : null;
}
// { up, pid, startMs, err } — up = 게이트웨이 포트에 LISTEN 하는 프로세스가 있다. startMs 는 지금 - 프로세스 나이(초 단위)
export async function probeGateway(run, nowMs, port = gatewayPort()) {
  const r = await run("gateway.listen-pid", { spec: `TCP:${port}` });
  const pid = r.code === 0 ? firstPid(r.stdout) : null;
  if (!pid) return { up: false, pid: null, startMs: null, err: r.code === 1 || r.code === 0 ? null : `lsof 코드 ${r.code}` };
  const p = await run("gateway.proc", { pid: String(pid) });
  const line = String(p.stdout ?? "").split("\n").map((l) => l.trim().split(/\s+/)).find((x) => Number(x[0]) === pid);
  const age = p.code === 0 && line ? parseEtime(line[1]) : null;
  return { up: true, pid, startMs: age == null ? null : Math.floor(nowMs / 1000) * 1000 - age * 1000, err: age == null ? `ps 코드 ${p.code}` : null };
}
export async function healthOk(run, port = gatewayPort()) {
  const r = await run("gateway.health", { url: `http://127.0.0.1:${port}/health` });
  if (r.code !== 0) return { ok: false, detail: `curl 코드 ${r.code}` };
  try { const j = JSON.parse(String(r.stdout).trim()); return { ok: j?.ok === true, detail: j?.ok === true ? "ok" : "ok 아님" }; } catch { return { ok: false, detail: "JSON 아님" }; }
}

// ── 대화 기록의 오픈클로 도구 결과(감지기 authority_failures 옮김) ──────────────
// 오류로 표시된 도구 결과 중 본문이 그 문구로 시작하고 도구가 mcp__openclaw__* 인 것만 실패로 센다(문구를 인용한 대화는 세지 않음).
// 이름을 모르는 도구 결과는 감지기처럼 오픈클로로 본다(실패 쪽). 성공(오류 아님)은 이름을 아는 mcp__openclaw__* 만 센다.
const MAX_FILE = 64 * 1024 * 1024;
function walkJsonl(dir, sinceMs, depth = 0, out = []) {
  if (depth > 4) return out;
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walkJsonl(p, sinceMs, depth + 1, out);
    else if (e.isFile() && e.name.endsWith(".jsonl")) {
      try { const st = fs.statSync(p); if (st.mtimeMs >= sinceMs - MIN) out.push({ p, size: st.size }); } catch { /* 지워짐 */ }
    }
  }
  return out;
}
export function scanTranscripts(dir, sinceMs, untilMs = Infinity) {
  const res = { readable: fs.existsSync(dir), files: 0, skipped: 0, fail: 0, ok: 0, methods: [] };
  if (!res.readable) return res;
  const methods = new Set();
  for (const { p, size } of walkJsonl(dir, sinceMs)) {
    if (size > MAX_FILE) { res.skipped++; continue; }
    let text;
    try { text = fs.readFileSync(p, "utf8"); } catch { res.skipped++; continue; }
    res.files++;
    const names = new Map();
    for (const line of text.split("\n")) {
      if (!line.includes('"tool_use"') && !line.includes('"tool_result"') && !line.includes(AUTHORITY_CLOSED)) continue;
      let d;
      try { d = JSON.parse(line); } catch { continue; }
      const content = d?.message && typeof d.message === "object" ? d.message.content : null;
      if (!Array.isArray(content)) continue;
      const t = Date.parse(d.timestamp ?? "");
      for (const c of content) {
        if (!c || typeof c !== "object") continue;
        if (c.type === "tool_use") { names.set(c.id, String(c.name ?? "")); continue; }
        if (c.type !== "tool_result" || !(t > sinceMs && t <= untilMs)) continue;
        if (c.is_error) {
          let body = c.content;
          if (Array.isArray(body)) body = body.map((x) => (x && typeof x === "object" ? x.text ?? "" : "")).join(" ");
          body = String(body ?? "").trim();
          if (!body.startsWith(AUTHORITY_CLOSED)) continue;
          if (!(names.get(c.tool_use_id) ?? "mcp__openclaw__").startsWith("mcp__openclaw__")) continue;
          res.fail++;
          const m = /dispatching ([\w.]+)/.exec(body);
          methods.add(m ? m[1].replace(/\.$/, "") : "?");
        } else if ((names.get(c.tool_use_id) ?? "").startsWith("mcp__openclaw__")) res.ok++;
      }
    }
  }
  res.methods = [...methods].sort().slice(0, 5);
  return res;
}

// ── 게이트웨이 로그의 같은 문구(보조) ─────────────────────────────────────────
// /tmp/openclaw/openclaw-YYYY-MM-DD.log(재시작 날 ~ 오늘) + ~/Library/Logs/openclaw/gateway.log, 각 끝 8MB 만 읽는다.
const TAIL = 8 * 1024 * 1024;
const TS_RE = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})/;
function readTail(file) {
  let fd;
  try {
    fd = fs.openSync(file, "r");
    const size = fs.fstatSync(fd).size;
    const len = Math.min(size, TAIL);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, size - len);
    return buf.toString("utf8");
  } catch { return null; } finally { if (fd !== undefined) try { fs.closeSync(fd); } catch { /* 이미 닫힘 */ } }
}
export function scanGatewayLogs(P, sinceMs, untilMs) {
  const files = [];
  for (let d = sinceMs - 86_400_000; d <= untilMs + 86_400_000; d += 86_400_000) {
    const f = path.join(P.gwLogDir, `openclaw-${localDay(d)}.log`);
    if (!files.includes(f)) files.push(f);
  }
  files.push(P.gwLog);
  const res = { files: 0, hits: 0 };
  for (const f of files) {
    const text = readTail(f);
    if (text == null) continue;
    res.files++;
    for (const line of text.split("\n")) {
      if (!line.includes("authority closed")) continue;
      const m = TS_RE.exec(line);
      const t = m ? Date.parse(m[0]) : NaN;
      if (t > sinceMs && t <= untilMs) res.hits++;
    }
  }
  return res;
}

// ── 당직 장부(읽기만) — 재시작 뒤 첫 gateway.tool_authority 판정 줄 ─────────────
// 장부 ts 는 당직이 손으로 적어 실제 기록 시각보다 늦을 수 있다(10-04 16:57 줄은 16:55 재시작보다 뒤 ts). 그래서 '이 재시작을 부른 줄'
// (verified 가 true 가 아니고, first_seen 이 재시작 이전이고, 조치에 재시작이 적힌 줄)은 판정으로 보지 않는다.
export function nextDutyJudgement(text, restartMs) {
  for (const line of String(text ?? "").split("\n")) {
    if (!line.includes(LEDGER_KEY)) continue;
    let r;
    try { r = JSON.parse(line); } catch { continue; }
    if (r?.key !== LEDGER_KEY) continue;
    const ts = Date.parse(r.ts ?? "");
    if (!(ts > restartMs)) continue;
    const firstSeen = Date.parse(r.first_seen ?? "");
    const cause = r.verified !== true && Number.isFinite(firstSeen) && firstSeen <= restartMs && /재시작|restart/i.test(String(r.fix ?? ""));
    if (cause) continue;
    return { ts, firstSeen: Number.isFinite(firstSeen) ? firstSeen : null, verified: r.verified === true, mode: String(r.mode ?? "").slice(0, 20) };
  }
  return null;
}

// ── 재시작 생존 실측(PLAN §3 미실측 항목) — 실행기 기록(metrics.jsonl)·분리 실행 폴더를 읽기만 ──────
function readJsonl(file) {
  let text;
  try { text = fs.readFileSync(file, "utf8"); } catch { return []; }
  const out = [];
  for (const l of text.split("\n")) { if (!l.trim()) continue; try { out.push(JSON.parse(l)); } catch { /* 끊긴 줄 */ } }
  return out;
}
// 분리 실행 껍데기가 적는 시각(result.json endedAt · heartbeat t). 못 읽으면 파일 수정 시각
const stamp = (p, k) => {
  try { const v = JSON.parse(fs.readFileSync(p, "utf8"))?.[k]; if (Number.isFinite(v)) return v; } catch { /* 없음·깨짐 */ }
  try { return fs.statSync(p).mtimeMs; } catch { return null; }
};
// 재시작 직전 heartbeat 에 적힌 열린 스레드·분리 실행이 재시작 뒤에 이어 갔는지.
//   스레드: progressed(재시작 뒤 단계를 끝냄·끝남) · waiting(답을 기다리는 대기 — 잃지 않음) · stalled(진척 없음) · ended_before(재시작 전에 끝남)
//   분리 실행: survived(재시작 뒤 결과를 썼거나 heartbeat 가 이어짐) · killed(결과 없이 멈춤) · finished_before · gone(폴더 정리됨)
export function measureSurvival(stateDir, restartMs, nowMs) {
  const ev = readJsonl(path.join(stateDir, "metrics.jsonl"));
  const hbs = ev.filter((r) => r.ev === "lg.restart.heartbeat");
  const pre = hbs.filter((r) => r.t < restartMs).at(-1);
  const post = hbs.find((r) => r.t >= restartMs);
  const out = { measured: !!pre, hb_before: pre ? isoLocal(pre.t) : null, hb_after: post ? isoLocal(post.t) : null, tick_after: !!post,
    first_tick_s: post ? Math.round((post.t - restartMs) / 1000) : null, gw_changed: !!(pre && post && pre.gw_pid && post.gw_pid && pre.gw_pid !== post.gw_pid),
    open: 0, progressed: 0, waiting: 0, stalled: 0, ended_before: 0, interrupted: 0, resumed: 0, jobs: 0, jobs_survived: 0, jobs_killed: 0, jobs_finished_before: 0, jobs_gone: 0 };
  if (!pre) return out;
  const ENDS = new Set(["done", "expired", "gave_up"]);
  for (const entry of pre.open ?? []) {
    const [status, thread] = String(entry).split(" ");
    if (!thread) continue;
    const rs = ev.filter((r) => r.thread === thread && r.t > pre.t);
    if (rs.some((r) => ENDS.has(r.ev) && r.t < restartMs)) { out.ended_before++; continue; }
    out.open++;
    const after = rs.filter((r) => r.t >= restartMs);
    const cut = post?.t ?? nowMs;
    const intr = rs.filter((r) => r.ev === "interrupted" && r.t <= cut);
    out.interrupted += intr.length ? 1 : 0;
    if (intr.length && rs.some((r) => r.ev === "node_end" && r.ok && r.t > intr[0].t)) out.resumed++;
    if (after.some((r) => (r.ev === "node_end" && r.ok) || r.ev === "done")) out.progressed++;
    else if (status === "waiting" && !after.some((r) => ENDS.has(r.ev))) out.waiting++;
    else out.stalled++;
  }
  const jobsDir = path.join(stateDir, "jobs");
  for (const entry of pre.jobs ?? []) {
    const [id] = String(entry).split(" ");
    const parts = String(id).split("/");
    if (parts.length !== 3 || parts.some((x) => !x || x === "." || x === "..")) continue;
    out.jobs++;
    const dir = path.join(jobsDir, ...parts);
    if (!fs.existsSync(dir)) { out.jobs_gone++; continue; }
    const res = stamp(path.join(dir, "result.json"), "endedAt");
    const hb = stamp(path.join(dir, "heartbeat"), "t");
    if (res != null && res < restartMs) out.jobs_finished_before++;
    else if ((res != null && res >= restartMs) || (hb != null && hb > restartMs + 35_000)) out.jobs_survived++;
    else out.jobs_killed++;
  }
  return out;
}
