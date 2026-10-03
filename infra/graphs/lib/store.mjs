// store.mjs — 체크포인트 DB 한 파일에 실행기 장부(스레드 등록·잠금·LLM 호출 수)를 같이 둔다.
// 정본은 그래프 체크포인트다. 등록부는 목록·기한·알림을 위한 장부이고, 실행기가 그래프 상태로 맞춘다(run.mjs reconcile).
// 잠금도 SQLite 즉시 트랜잭션으로 잡는다 — 파일 잠금은 '죽은 pid 인계' 때 두 프로세스가 동시에 넘겨받는 틈이 있다.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { iso } from "./config.mjs";
import { allowSpawn } from "./guard.mjs";

const require = createRequire(import.meta.url);
const Database = require("better-sqlite3");
const DAY = 86_400_000;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS lg_threads (
  thread_id TEXT PRIMARY KEY,
  graph TEXT NOT NULL,
  status TEXT NOT NULL,          -- queued · running · continue · waiting · held · failed · gave_up · expired · blocked · done
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,   -- 진척이 있을 때만 갱신(같은 이유로 되풀이하는 보류·실패는 갱신하지 않는다) — gc 기준
  run_started_at INTEGER,        -- 마지막 실행(start·resume·retry·틱)을 시작한 때 — 고장 복구 때 기한의 하한
  interrupt_id TEXT,             -- 지금 답을 기다리는 interrupt 의 열쇠(id + 질문). 답을 적용하면 비운다
  waiting_since INTEGER,
  deadline_at INTEGER,
  question TEXT,
  decision TEXT,
  note TEXT,
  notified INTEGER NOT NULL DEFAULT 1,   -- 만료를 아직 알리지 않았으면 0
  mode TEXT,                     -- shadow · live — 시작 때 LIVE 스위치로 고정한다
  input_json TEXT,               -- 대기열(queued) 스레드의 시작 입력
  progress_at INTEGER,           -- 마지막으로 단계를 끝낸 때 — 보류 48시간 기한의 기준
  fail_sig TEXT,                 -- 마지막 실패의 서명(노드 + 오류 모양). 같은 서명이 되풀이되면 센다
  fail_count INTEGER NOT NULL DEFAULT 0,
  hold_reason TEXT,              -- held 의 까닭: llm_budget · token_cap · login · usage_limit · code_defect · node · effect_unknown · paused
  hold_ref TEXT,                 -- code_defect 때 코드 지문 — 코드가 바뀌어야 다시 시도한다
  answer TEXT,                   -- answer 명령이 적은 답(approved·rejected). 틱이 적용하면 비운다
  answer_key TEXT,               -- 그 답이 가리키는 질문 열쇠(interrupt_id) — 질문이 바뀌면 옛 답은 쓰지 않는다
  answered_at INTEGER,
  waiting_notified TEXT,         -- WAITING 알림을 낸 질문 열쇠(같은 질문을 틱마다 다시 알리지 않게)
  stuck_key TEXT,                -- STUCK 알림을 낸 잠금(pid:잡은 때)
  question_seq INTEGER NOT NULL DEFAULT 0,  -- 이 스레드에서 몇 번째 질문인가(WAITING 의 '질문 #N') — 같은 문구로 다시 물어도 번호가 바뀐다
  next_nodes TEXT                -- 마지막으로 멈춘 때의 다음 노드(배포로 노드가 사라지면 '끝남'으로 오인하지 않게)
);
CREATE TABLE IF NOT EXISTS lg_locks (
  thread_id TEXT PRIMARY KEY,
  pid INTEGER NOT NULL,
  token TEXT NOT NULL,
  acquired_at INTEGER NOT NULL,
  pstart TEXT                    -- 잠근 프로세스의 시작 시각(ps lstart). 같은 pid 를 다른 프로세스가 받아도 살아 있다고 보지 않게
);
CREATE TABLE IF NOT EXISTS lg_llm_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts INTEGER NOT NULL,
  day TEXT NOT NULL,
  thread_id TEXT NOT NULL,
  node TEXT,
  model TEXT,
  in_tok INTEGER, out_tok INTEGER, cc_tok INTEGER, cr_tok INTEGER, cost_usd REAL   -- 응답의 usage — 하루 토큰 상한에 쓴다
);
CREATE TABLE IF NOT EXISTS lg_notices (   -- 틱 알림함: 상태 변경과 같은 트랜잭션으로 넣고, 표준 출력에 낸 뒤 지운다(도중에 죽어도 다음 틱이 낸다)
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  thread_id TEXT,
  kind TEXT NOT NULL,
  line TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS lg_llm_calls_day ON lg_llm_calls(day);
CREATE INDEX IF NOT EXISTS lg_llm_calls_thread ON lg_llm_calls(thread_id);
`;

// 판이 오를 때 빠진 칸을 더한다(기존 DB 를 버리지 않고). 칸을 지우거나 바꾸는 변경은 여기서 하지 않는다.
const SCHEMA_VERSION = 4;
const COLUMNS = {
  lg_threads: [["run_started_at", "INTEGER"], ["interrupt_id", "TEXT"], ["notified", "INTEGER NOT NULL DEFAULT 1"],
    ["mode", "TEXT"], ["input_json", "TEXT"], ["progress_at", "INTEGER"], ["fail_sig", "TEXT"], ["fail_count", "INTEGER NOT NULL DEFAULT 0"],
    ["hold_reason", "TEXT"], ["hold_ref", "TEXT"], ["answer", "TEXT"], ["answer_key", "TEXT"], ["answered_at", "INTEGER"],
    ["waiting_notified", "TEXT"], ["stuck_key", "TEXT"], ["question_seq", "INTEGER NOT NULL DEFAULT 0"], ["next_nodes", "TEXT"]],
  lg_locks: [["pstart", "TEXT"]],
  lg_llm_calls: [["in_tok", "INTEGER"], ["out_tok", "INTEGER"], ["cc_tok", "INTEGER"], ["cr_tok", "INTEGER"], ["cost_usd", "REAL"]],
};

export const TERMINAL = new Set(["done", "expired", "blocked", "gave_up"]);

// 프로세스 시작 시각(같은 기기·같은 형식으로만 비교한다). 없는 pid 면 null.
// 못 읽으면(ps 실패) null — 부르는 쪽은 null 을 '살아 있음(넘겨받지 않음)'으로 본다(S1). 시험은 LG_TEST_PS_FAIL=1 로 실패를 흉내 낸다.
export function procStart(pid) {
  if (process.env.LG_TEST_MODE === "1" && process.env.LG_TEST_PS_FAIL === "1") return null;
  const r = allowSpawn(() => spawnSync("/bin/ps", ["-o", "lstart=", "-p", String(pid)], { env: { LC_ALL: "C", TZ: "UTC", PATH: "/bin:/usr/bin" }, encoding: "utf8" }));
  return r.status === 0 ? r.stdout.trim() || null : null;
}
const MY_START = procStart(process.pid);

export function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === "EPERM"; }
}

export const localDay = (ms) => new Date(ms).toLocaleDateString("sv-SE"); // 이 기기 시간대 기준 YYYY-MM-DD

function tighten(p, mode) {
  try {
    const st = fs.statSync(p);
    if ((st.mode & 0o777) !== mode && st.uid === process.getuid()) fs.chmodSync(p, mode);
  } catch (e) { if (e.code !== "ENOENT") throw e; }
}

const FIELDS = new Set(["status", "run_started_at", "interrupt_id", "waiting_since", "deadline_at", "question", "decision", "note", "notified",
  "mode", "input_json", "progress_at", "fail_sig", "fail_count", "hold_reason", "hold_ref", "answer", "answer_key", "answered_at",
  "waiting_notified", "stuck_key", "question_seq", "next_nodes"]);

export class Store {
  constructor(cfg) {
    this.cfg = cfg;
    fs.mkdirSync(cfg.stateDir, { recursive: true, mode: 0o700 });
    tighten(cfg.stateDir, 0o700);
    fs.mkdirSync(path.dirname(cfg.dbPath), { recursive: true, mode: 0o700 });
    this.db = new Database(cfg.dbPath, { timeout: cfg.busyTimeoutMs });
    this.db.pragma("secure_delete=ON"); // 연결마다 켜야 한다 — 파일에 저장되는 설정이 아니다
    this.db.pragma("journal_mode=WAL");
    this.db.exec(SCHEMA);
    this.migrate();
    this.tightenFiles();
  }

  migrate() {
    if (this.db.pragma("user_version", { simple: true }) >= SCHEMA_VERSION) return;
    this.tx(() => {
      for (const [table, cols] of Object.entries(COLUMNS)) {
        const have = new Set(this.db.prepare(`PRAGMA table_info(${table})`).all().map((c) => c.name));
        for (const [name, decl] of cols) if (!have.has(name)) this.db.exec(`ALTER TABLE ${table} ADD COLUMN ${name} ${decl}`);
      }
      this.db.pragma(`user_version = ${SCHEMA_VERSION}`);
    });
  }

  logPath(thread) { return path.join(this.cfg.stateDir, "logs", `${thread}.log`); }
  tightenFiles() {
    const { dbPath, pendingPath, metricsPath, effectsPath } = this.cfg;
    for (const f of [dbPath, `${dbPath}-wal`, `${dbPath}-shm`, pendingPath, metricsPath, effectsPath]) if (f) tighten(f, 0o600);
  }

  tx(fn) { return this.db.transaction(fn).immediate(); }
  close() { try { this.db.close(); } catch { /* 이미 닫힘 */ } }

  hasTable(name) { return !!this.db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?").get(name); }
  hasCheckpoint(id) {
    return this.hasTable("checkpoints") && !!this.db.prepare("SELECT 1 FROM checkpoints WHERE thread_id=? LIMIT 1").get(id);
  }

  // ── 스레드 등록부 ────────────────────────────────────────────────
  getThread(id) { return this.db.prepare("SELECT * FROM lg_threads WHERE thread_id=?").get(id) ?? null; }
  listThreads() { return this.db.prepare("SELECT * FROM lg_threads ORDER BY created_at, thread_id").all(); }
  // status: running(바로 돌림) 또는 queued(다음 틱이 시작). mode 는 여기서 고정되고 다시 바뀌지 않는다.
  registerThread(id, graph, now, { mode = "shadow", status = "running", input = null } = {}) {
    this.db.prepare(`INSERT INTO lg_threads(thread_id, graph, status, created_at, updated_at, run_started_at, mode, input_json, progress_at)
      VALUES(@id, @graph, @status, @now, @now, @run, @mode, @input, @now)
      ON CONFLICT(thread_id) DO UPDATE SET graph=excluded.graph, status=excluded.status, created_at=excluded.created_at,
        updated_at=excluded.updated_at, run_started_at=excluded.run_started_at, interrupt_id=NULL, waiting_since=NULL,
        deadline_at=NULL, question=NULL, decision=NULL, note=NULL, notified=1, mode=excluded.mode, input_json=excluded.input_json,
        progress_at=excluded.progress_at, fail_sig=NULL, fail_count=0, hold_reason=NULL, hold_ref=NULL, answer=NULL, answer_key=NULL,
        answered_at=NULL, waiting_notified=NULL, stuck_key=NULL, question_seq=0, next_nodes=NULL`)
      .run({ id, graph, status, now, run: status === "running" ? now : null, mode, input: input == null ? null : JSON.stringify(input) });
  }
  // touch=false 면 updated_at 을 그대로 둔다(진척 없는 되풀이가 정리 기준 시각을 미루지 않게).
  updateThread(id, fields, now, { touch = true } = {}) {
    const keys = Object.keys(fields);
    for (const k of keys) if (!FIELDS.has(k)) throw new Error(`모르는 칸: ${k}`);
    const params = { id };
    for (const k of keys) params[k] = fields[k] ?? null;
    const sets = keys.map((k) => `${k}=@${k}`);
    if (touch) { sets.push("updated_at=@updated_at"); params.updated_at = now; }
    if (!sets.length) return;
    this.db.prepare(`UPDATE lg_threads SET ${sets.join(", ")} WHERE thread_id=@id`).run(params);
  }
  effective(row) { return row.status === "running" && !this.lockedLive(row.thread_id) ? "stalled" : row.status; }

  // ── 답 기록(answer) ─────────────────────────────────────────────
  // 잠금 없이 즉시 트랜잭션 하나로 끝난다 — 틱이 다른 스레드를 몇 분 돌리고 있어도 대화 쪽 답이 1초 안에 끝나게.
  // 답은 '지금 걸린 질문 열쇠'에 묶는다. 틱은 같은 열쇠일 때만 적용한다(그 사이 질문이 바뀌면 옛 답은 쓰지 않는다).
  // qid: WAITING 에 보인 '질문 #N'. 첫 질문은 번호 없이도 받는다. 두 번째 질문부터는 번호가 맞아야 받는다 —
  //   같은 문구로 다시 묻는 재확인에 늦게 도착한(되풀이된) 답이 주인님이 못 본 질문을 승인하지 않게(0b 검토 A중4).
  recordAnswer(id, decision, now, qid = null) {
    return this.tx(() => {
      const row = this.getThread(id);
      if (!row) return { ok: false, kind: "not-found", msg: "없는 스레드" };
      if (row.status === "expired") return { ok: false, kind: "expired", msg: "승인 기한이 지나 자동 취소된 스레드 — 새로 start" };
      if (row.interrupt_id == null || !["waiting", "failed", "held", "running"].includes(row.status)) {
        return { ok: false, kind: "not-waiting", msg: `승인 대기 중이 아님(${this.effective(row)})` };
      }
      if (row.deadline_at != null && row.deadline_at <= now) {
        return { ok: false, kind: "expired", msg: `승인 기한(${iso(row.deadline_at)})이 지났다 — 다음 틱이 취소한다` };
      }
      const seq = row.question_seq || 1; // 번호가 생기기 전 판의 대기(0)는 첫 질문으로 본다
      if (qid != null && qid !== seq) return { ok: false, kind: "stale-question", msg: `지금 걸린 질문은 #${seq} 이다(준 번호 #${qid}) — 새 질문을 보고 다시 답한다` };
      if (qid == null && seq > 1) return { ok: false, kind: "need-qid", msg: `이 스레드는 질문이 여러 번 나왔다(지금 #${seq}) — 번호를 붙여 다시: answer ${id} ${decision} ${seq}` };
      if (row.answer != null && row.answer_key === row.interrupt_id) {
        if (row.answer === decision) return { ok: true, kind: "same", row };
        return { ok: false, kind: "already-answered", msg: `이미 ${row.answer} 로 답했다 — 다음 틱이 적용한다` };
      }
      this.db.prepare("UPDATE lg_threads SET answer=?, answer_key=?, answered_at=? WHERE thread_id=?").run(decision, row.interrupt_id, now, id);
      return { ok: true, kind: "recorded", row: this.getThread(id) };
    });
  }

  // ── 스레드별 잠금 ────────────────────────────────────────────────
  // S1(10-03 고침): pid 가 살아 있으면 나이와 상관없이 넘겨받지 않는다. 오래 쥐었으면 lockInfo 가 stuck 으로 알린다.
  #live(row) {
    if (!pidAlive(row.pid)) return false;
    if (row.pstart == null) return true;
    const cur = procStart(row.pid);
    return cur == null || cur === row.pstart; // pid 가 같아도 시작 시각이 다르면 다른 프로세스. 시작 시각을 못 읽으면 살아 있다고 본다(넘겨받지 않는다)
  }
  lockedLive(id) {
    const row = this.db.prepare("SELECT pid, acquired_at, pstart FROM lg_locks WHERE thread_id=?").get(id);
    return !!row && this.#live(row);
  }
  // 잠금 상태: 없음 → null. 살아 있는 주인이 기준 시간(lockStuckMs)보다 오래 쥐었으면 stuck.
  lockInfo(id) {
    const row = this.db.prepare("SELECT pid, acquired_at, pstart FROM lg_locks WHERE thread_id=?").get(id);
    if (!row) return null;
    const live = this.#live(row);
    const age = Date.now() - row.acquired_at; // 잠금 나이는 실제 시계(잡은 프로세스도 실제 시계로 적는다)
    return { pid: row.pid, acquiredAt: row.acquired_at, live, ageMs: age, stuck: live && age >= this.cfg.lockStuckMs };
  }
  // 잡으면 토큰, 다른 살아 있는 프로세스가 쥐고 있으면 null. 죽은 pid(또는 pid 를 물려받은 다른 프로세스)의 잠금만 넘겨받는다.
  acquireLock(id) {
    const token = `${process.pid}-${randomUUID()}`;
    const got = this.tx(() => {
      const row = this.db.prepare("SELECT pid, acquired_at, pstart FROM lg_locks WHERE thread_id=?").get(id);
      if (row && this.#live(row)) return false;
      this.db.prepare(`INSERT INTO lg_locks(thread_id, pid, token, acquired_at, pstart) VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(thread_id) DO UPDATE SET pid=excluded.pid, token=excluded.token, acquired_at=excluded.acquired_at, pstart=excluded.pstart`)
        .run(id, process.pid, token, Date.now(), MY_START);
      return true;
    });
    return got ? token : null;
  }
  releaseLock(id, token) { this.db.prepare("DELETE FROM lg_locks WHERE thread_id=? AND token=?").run(id, token); }

  // ── 승인 기한·만료 알림 ──────────────────────────────────────────
  // 후보만 고른다: 기한이 지난 대기 기록, 또는 실행 중으로 적혔는데 주인이 없는(끊긴) 스레드. 확인·만료는 그래프 상태로 한다.
  sweepCandidates(now) {
    return this.db.prepare(`SELECT * FROM lg_threads WHERE status NOT IN ('done', 'expired', 'blocked', 'gave_up')
      AND ((deadline_at IS NOT NULL AND deadline_at <= ?) OR status = 'running') ORDER BY deadline_at, thread_id`).all(now)
      .filter((r) => !this.lockedLive(r.thread_id));
  }
  // 진척 없이 기한(holdTtl)을 넘긴 보류·이어가기·대기열·실패·끊긴 스레드와, 답을 받고도 진행되지 못한 대기.
  // 기준 시각 = 마지막 단계 완료와 답 기록 중 늦은 쪽. 답 없는 승인 대기는 승인 기한으로 따로 본다(run.mjs sweep).
  idleCandidates(now, ttl) {
    return this.db.prepare(`SELECT * FROM lg_threads WHERE status IN ('queued', 'continue', 'held', 'failed', 'running', 'waiting')
      AND MAX(COALESCE(progress_at, updated_at), COALESCE(answered_at, 0)) + ? <= ? ORDER BY thread_id`).all(ttl, now)
      .filter((r) => !(r.answer == null && r.deadline_at != null)) // 답 없는 승인 대기 기록 — 승인 기한이 정한다
      .filter((r) => !this.lockedLive(r.thread_id));
  }
  openThreads() {
    return this.db.prepare("SELECT * FROM lg_threads WHERE status NOT IN ('done', 'expired', 'blocked', 'gave_up') ORDER BY COALESCE(progress_at, created_at), thread_id").all();
  }
  // ── 틱 알림함 ──────────────────────────────────────────────────
  addNotice(thread, kind, line, now) {
    this.db.prepare("INSERT INTO lg_notices(thread_id, kind, line, created_at) VALUES(?, ?, ?, ?)").run(thread, kind, line, now);
  }
  // 꺼내면서 지운다(겹친 틱이 같은 알림을 두 번 내지 않게). 내지 못하면 restoreNotices 로 되돌린다.
  claimNotices() {
    return this.tx(() => {
      const rows = this.db.prepare("SELECT * FROM lg_notices ORDER BY id").all();
      if (rows.length) this.db.prepare(`DELETE FROM lg_notices WHERE id <= ?`).run(rows.at(-1).id);
      return rows;
    });
  }
  restoreNotices(rows) {
    const st = this.db.prepare("INSERT INTO lg_notices(thread_id, kind, line, created_at) VALUES(?, ?, ?, ?)");
    this.tx(() => { for (const r of rows) st.run(r.thread_id, r.kind, r.line, r.created_at); });
  }
  unnotifiedExpired() {
    return this.db.prepare("SELECT * FROM lg_threads WHERE status='expired' AND notified=0 ORDER BY deadline_at, thread_id").all();
  }
  markNotified(ids) {
    const st = this.db.prepare("UPDATE lg_threads SET notified=1 WHERE thread_id=?");
    this.tx(() => { for (const id of ids) st.run(id); });
  }

  // ── LLM 호출 상한 ───────────────────────────────────────────────
  // 부르기 전에 자리를 잡는다(실패한 호출도 센다 — 재시도 폭주 방지). 하루 토큰 상한도 여기서 본다(이미 넘었으면 부르지 않는다).
  reserveLlmCall({ thread, node, model, now, perThread, perDay, dayTokenCap }) {
    const day = localDay(now);
    return this.tx(() => {
      const nThread = this.db.prepare("SELECT count(*) AS n FROM lg_llm_calls WHERE thread_id=?").get(thread).n;
      if (nThread >= perThread) {
        return { ok: false, reason: `LLM 호출 스레드 상한 ${perThread}회에 닿음 — 이 스레드는 상한(LG_LLM_MAX_PER_THREAD)을 올려야 이어진다`, kind: "llm_thread", ref: String(perThread) };
      }
      const nDay = this.db.prepare("SELECT count(*) AS n FROM lg_llm_calls WHERE day=?").get(day).n;
      if (nDay >= perDay) return { ok: false, reason: `LLM 호출 하루 상한 ${perDay}회에 닿음(${day}) — 다음 날 retry`, kind: "llm_day", ref: day };
      if (dayTokenCap != null) {
        const tok = this.dayTokens(now);
        if (tok >= dayTokenCap) return { ok: false, reason: `하루 토큰 상한 ${dayTokenCap}에 닿음(${day}, 오늘 ${tok}) — 다음 날`, kind: "token_cap", ref: day };
      }
      const r = this.db.prepare("INSERT INTO lg_llm_calls(ts, day, thread_id, node, model) VALUES(?, ?, ?, ?, ?)").run(now, day, thread, node, model);
      return { ok: true, id: Number(r.lastInsertRowid) };
    });
  }
  recordLlmUsage(id, u) {
    this.db.prepare("UPDATE lg_llm_calls SET in_tok=?, out_tok=?, cc_tok=?, cr_tok=?, cost_usd=? WHERE id=?")
      .run(u.in ?? 0, u.out ?? 0, u.cacheCreate ?? 0, u.cacheRead ?? 0, u.costUsd ?? null, id);
  }
  dayTokens(now) {
    return this.db.prepare("SELECT COALESCE(SUM(COALESCE(in_tok,0)+COALESCE(out_tok,0)+COALESCE(cc_tok,0)+COALESCE(cr_tok,0)),0) AS n FROM lg_llm_calls WHERE day=?")
      .get(localDay(now)).n;
  }
  llmCounts(now, thread) {
    const day = this.db.prepare("SELECT count(*) AS n FROM lg_llm_calls WHERE day=?").get(localDay(now)).n;
    const th = thread ? this.db.prepare("SELECT count(*) AS n FROM lg_llm_calls WHERE thread_id=?").get(thread).n : null;
    return { day, thread: th, tokens: this.dayTokens(now) };
  }

  // ── 대기 목록 파일 ──────────────────────────────────────────────
  // 등록부에서 매번 다시 만든다. 즉시 트랜잭션 안에서 쓰고 이름을 바꿔, 동시에 쓰는 프로세스가 서로 덮지 않는다.
  writePending() {
    this.tx(() => {
      const rows = this.db.prepare(
        "SELECT thread_id, graph, question, waiting_since, deadline_at, answer, question_seq FROM lg_threads WHERE status='waiting' ORDER BY waiting_since, thread_id",
      ).all();
      const body = rows.map((r) => JSON.stringify({
        thread: r.thread_id, graph: r.graph, question: r.question, qid: r.question_seq || 1,
        since: r.waiting_since == null ? null : iso(r.waiting_since), deadline: r.deadline_at == null ? null : iso(r.deadline_at),
        ...(r.answer ? { answered: r.answer } : {}),
      })).join("\n");
      const tmp = `${this.cfg.pendingPath}.tmp-${process.pid}`;
      fs.writeFileSync(tmp, body ? `${body}\n` : "", { mode: 0o600 });
      fs.renameSync(tmp, this.cfg.pendingPath);
    });
  }

  // ── 정리 ────────────────────────────────────────────────────────
  // 마지막 진척이 days 일 넘은 스레드와 등록부에 없는 고아 스레드를 지우고 VACUUM. 지운 행의 평문이 파일에 남지 않게 한다.
  // 지우지 않는 것: 승인 대기 중(만료 전), 지금 잠긴 스레드. LLM 호출 기록은 살아 있는 스레드 몫과 최근 2일 몫을 남긴다(상한 초기화 방지).
  // 판정 기록(metrics.jsonl·effects.jsonl)은 건드리지 않는다(S17 — 판정일 + 30일 보존).
  gc(now, days) {
    if (!(Number.isFinite(days) && days >= 1)) throw new Error(`gc 기간은 1일 이상이어야 한다: ${days}`);
    const cutoff = now - days * DAY;
    const res = this.tx(() => {
      const hasCk = this.hasTable("checkpoints");
      const hasWr = this.hasTable("writes");
      const reg = this.db.prepare("SELECT thread_id, status, updated_at, deadline_at FROM lg_threads").all();
      const known = new Set(reg.map((r) => r.thread_id));
      const live = (r) => r.status === "waiting" || (r.deadline_at != null && r.deadline_at > now); // 기한 전 승인 대기
      const old = reg.filter((r) => r.updated_at < cutoff && !live(r)).map((r) => r.thread_id);
      const orphans = hasCk
        ? this.db.prepare("SELECT DISTINCT thread_id FROM checkpoints").all().map((r) => r.thread_id).filter((t) => !known.has(t))
        : [];
      const victims = [...old, ...orphans].filter((t) => !this.lockedLive(t));
      for (const t of victims) {
        if (hasCk) this.db.prepare("DELETE FROM checkpoints WHERE thread_id=?").run(t);
        if (hasWr) this.db.prepare("DELETE FROM writes WHERE thread_id=?").run(t);
        this.db.prepare("DELETE FROM lg_threads WHERE thread_id=?").run(t);
        this.db.prepare("DELETE FROM lg_locks WHERE thread_id=?").run(t);
      }
      this.db.prepare("DELETE FROM lg_llm_calls WHERE ts < ? AND thread_id NOT IN (SELECT thread_id FROM lg_threads)")
        .run(Math.min(cutoff, now - 2 * DAY));
      return {
        victims, deleted: victims.length,
        orphans: orphans.filter((t) => victims.includes(t)).length,
        kept: known.size - old.filter((t) => victims.includes(t)).length,
      };
    });
    for (const t of res.victims) {
      fs.rmSync(this.logPath(t), { force: true }); // 노드 출력 로그도 같이(평문)
      const jobs = path.join(this.cfg.jobsDir ?? path.join(this.cfg.stateDir, "jobs"), t);
      if (path.dirname(jobs) === (this.cfg.jobsDir ?? path.join(this.cfg.stateDir, "jobs"))) fs.rmSync(jobs, { recursive: true, force: true }); // 분리 실행 출력(평문)
    }
    this.db.exec("VACUUM");
    const ck = this.db.pragma("wal_checkpoint(TRUNCATE)")[0] ?? {};
    const wal = `${this.cfg.dbPath}-wal`;
    const walBytes = fs.existsSync(wal) ? fs.statSync(wal).size : 0;
    this.tightenFiles();
    if (ck.busy || walBytes > 0) {
      throw new Error(`정리를 끝내지 못함 — 다른 연결이 DB 를 잡고 있다(busy=${ck.busy ?? "?"}, wal=${walBytes}B). 지운 내용이 아직 파일에 남았을 수 있으니 잠시 뒤 gc 를 다시`);
    }
    const { victims, ...rest } = res;
    return { ...rest, bytes: fs.statSync(this.cfg.dbPath).size };
  }
}
