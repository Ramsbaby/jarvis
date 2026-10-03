// store.mjs — 체크포인트 DB 한 파일에 실행기 장부(스레드 등록·잠금·LLM 호출 수)를 같이 둔다.
// 정본은 그래프 체크포인트다. 등록부는 목록·기한·알림을 위한 장부이고, 실행기가 그래프 상태로 맞춘다(run.mjs reconcile).
// 잠금도 SQLite 즉시 트랜잭션으로 잡는다 — 파일 잠금은 '죽은 pid 인계' 때 두 프로세스가 동시에 넘겨받는 틈이 있다.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { iso } from "./config.mjs";

const require = createRequire(import.meta.url);
const Database = require("better-sqlite3");
const DAY = 86_400_000;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS lg_threads (
  thread_id TEXT PRIMARY KEY,
  graph TEXT NOT NULL,
  status TEXT NOT NULL,          -- running · waiting · done · expired · held · failed · blocked
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,   -- 진척이 있을 때만 갱신(같은 이유로 되풀이하는 보류·실패는 갱신하지 않는다) — gc 기준
  run_started_at INTEGER,        -- 마지막 실행(start·resume·retry)을 시작한 때 — 고장 복구 때 기한의 하한
  interrupt_id TEXT,             -- 지금 답을 기다리는 interrupt 의 열쇠(id + 질문). 답을 적용하면 비운다
  waiting_since INTEGER,
  deadline_at INTEGER,
  question TEXT,
  decision TEXT,
  note TEXT,
  notified INTEGER NOT NULL DEFAULT 1   -- 만료를 아직 알리지 않았으면 0
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
  model TEXT
);
CREATE INDEX IF NOT EXISTS lg_llm_calls_day ON lg_llm_calls(day);
CREATE INDEX IF NOT EXISTS lg_llm_calls_thread ON lg_llm_calls(thread_id);
`;

// 판이 오를 때 빠진 칸을 더한다(기존 DB 를 버리지 않고). 칸을 지우거나 바꾸는 변경은 여기서 하지 않는다.
const SCHEMA_VERSION = 2;
const COLUMNS = {
  lg_threads: [["run_started_at", "INTEGER"], ["interrupt_id", "TEXT"], ["notified", "INTEGER NOT NULL DEFAULT 1"]],
  lg_locks: [["pstart", "TEXT"]],
};

// 프로세스 시작 시각(같은 기기·같은 형식으로만 비교한다). 없는 pid 면 null.
export function procStart(pid) {
  const r = spawnSync("/bin/ps", ["-o", "lstart=", "-p", String(pid)], { env: { LC_ALL: "C", TZ: "UTC", PATH: "/bin:/usr/bin" }, encoding: "utf8" });
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

const FIELDS = new Set(["status", "run_started_at", "interrupt_id", "waiting_since", "deadline_at", "question", "decision", "note", "notified"]);

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
    const { dbPath, pendingPath } = this.cfg;
    for (const f of [dbPath, `${dbPath}-wal`, `${dbPath}-shm`, pendingPath]) tighten(f, 0o600);
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
  registerThread(id, graph, now) {
    this.db.prepare(`INSERT INTO lg_threads(thread_id, graph, status, created_at, updated_at, run_started_at) VALUES(?, ?, 'running', ?, ?, ?)
      ON CONFLICT(thread_id) DO UPDATE SET graph=excluded.graph, status='running', created_at=excluded.created_at,
        updated_at=excluded.updated_at, run_started_at=excluded.run_started_at, interrupt_id=NULL, waiting_since=NULL,
        deadline_at=NULL, question=NULL, decision=NULL, note=NULL, notified=1`)
      .run(id, graph, now, now, now);
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

  // ── 스레드별 잠금 ────────────────────────────────────────────────
  #live(row) {
    if (!pidAlive(row.pid) || Date.now() - row.acquired_at >= this.cfg.lockStaleMs) return false;
    if (row.pstart == null) return true;
    const cur = procStart(row.pid);
    return cur == null || cur === row.pstart; // pid 가 같아도 시작 시각이 다르면 다른 프로세스. 시작 시각을 못 읽으면 살아 있다고 본다(넘겨받지 않는다)
  }
  lockedLive(id) {
    const row = this.db.prepare("SELECT pid, acquired_at, pstart FROM lg_locks WHERE thread_id=?").get(id);
    return !!row && this.#live(row);
  }
  // 잡으면 토큰, 다른 살아 있는 프로세스가 쥐고 있으면 null. 죽은 pid(또는 pid 를 물려받은 다른 프로세스)의 잠금은 넘겨받는다.
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
    return this.db.prepare(`SELECT * FROM lg_threads WHERE status NOT IN ('done', 'expired', 'blocked')
      AND ((deadline_at IS NOT NULL AND deadline_at <= ?) OR status = 'running') ORDER BY deadline_at, thread_id`).all(now)
      .filter((r) => !this.lockedLive(r.thread_id));
  }
  unnotifiedExpired() {
    return this.db.prepare("SELECT * FROM lg_threads WHERE status='expired' AND notified=0 ORDER BY deadline_at, thread_id").all();
  }
  markNotified(ids) {
    const st = this.db.prepare("UPDATE lg_threads SET notified=1 WHERE thread_id=?");
    this.tx(() => { for (const id of ids) st.run(id); });
  }

  // ── LLM 호출 상한 ───────────────────────────────────────────────
  // 부르기 전에 자리를 잡는다(실패한 호출도 센다 — 재시도 폭주 방지).
  reserveLlmCall({ thread, node, model, now, perThread, perDay }) {
    const day = localDay(now);
    return this.tx(() => {
      const nThread = this.db.prepare("SELECT count(*) AS n FROM lg_llm_calls WHERE thread_id=?").get(thread).n;
      if (nThread >= perThread) {
        return { ok: false, reason: `LLM 호출 스레드 상한 ${perThread}회에 닿음 — 이 스레드는 상한(LG_LLM_MAX_PER_THREAD)을 올려야 이어진다` };
      }
      const nDay = this.db.prepare("SELECT count(*) AS n FROM lg_llm_calls WHERE day=?").get(day).n;
      if (nDay >= perDay) return { ok: false, reason: `LLM 호출 하루 상한 ${perDay}회에 닿음(${day}) — 다음 날 retry` };
      this.db.prepare("INSERT INTO lg_llm_calls(ts, day, thread_id, node, model) VALUES(?, ?, ?, ?, ?)").run(now, day, thread, node, model);
      return { ok: true };
    });
  }
  llmCounts(now, thread) {
    const day = this.db.prepare("SELECT count(*) AS n FROM lg_llm_calls WHERE day=?").get(localDay(now)).n;
    const th = thread ? this.db.prepare("SELECT count(*) AS n FROM lg_llm_calls WHERE thread_id=?").get(thread).n : null;
    return { day, thread: th };
  }

  // ── 대기 목록 파일 ──────────────────────────────────────────────
  // 등록부에서 매번 다시 만든다. 즉시 트랜잭션 안에서 쓰고 이름을 바꿔, 동시에 쓰는 프로세스가 서로 덮지 않는다.
  writePending() {
    this.tx(() => {
      const rows = this.db.prepare(
        "SELECT thread_id, graph, question, waiting_since, deadline_at FROM lg_threads WHERE status='waiting' ORDER BY waiting_since, thread_id",
      ).all();
      const body = rows.map((r) => JSON.stringify({
        thread: r.thread_id, graph: r.graph, question: r.question,
        since: r.waiting_since == null ? null : iso(r.waiting_since), deadline: r.deadline_at == null ? null : iso(r.deadline_at),
      })).join("\n");
      const tmp = `${this.cfg.pendingPath}.tmp-${process.pid}`;
      fs.writeFileSync(tmp, body ? `${body}\n` : "", { mode: 0o600 });
      fs.renameSync(tmp, this.cfg.pendingPath);
    });
  }

  // ── 정리 ────────────────────────────────────────────────────────
  // 마지막 진척이 days 일 넘은 스레드와 등록부에 없는 고아 스레드를 지우고 VACUUM. 지운 행의 평문이 파일에 남지 않게 한다.
  // 지우지 않는 것: 승인 대기 중(만료 전), 지금 잠긴 스레드. LLM 호출 기록은 살아 있는 스레드 몫과 최근 2일 몫을 남긴다(상한 초기화 방지).
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
    for (const t of res.victims) fs.rmSync(this.logPath(t), { force: true }); // 노드 출력 로그도 같이(평문)
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
