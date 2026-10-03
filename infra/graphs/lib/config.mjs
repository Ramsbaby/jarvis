// config.mjs — 설정은 환경변수로만 바꾼다. 기본값이 운영값이다.
import os from "node:os";
import path from "node:path";

function num(env, key, dflt) {
  const v = env[key];
  if (v === undefined || v === "") return dflt;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) throw new Error(`${key} 는 0 이상의 숫자여야 한다: ${v}`);
  return n;
}

export function loadConfig(env = process.env) {
  const home = env.HOME || os.homedir();
  const stateDir = path.resolve(env.LG_STATE_DIR || path.join(home, ".openclaw-data", "runtime", "state", "graphs"));
  return {
    stateDir,
    dbPath: path.resolve(env.LG_DB || path.join(stateDir, "checkpoints.db")),
    pendingPath: path.join(stateDir, "pending.jsonl"),
    approvalTtlMs: num(env, "LG_APPROVAL_TTL_HOURS", 48) * 3_600_000,
    gcDays: num(env, "LG_GC_DAYS", 14),
    lockStaleMs: num(env, "LG_LOCK_STALE_MIN", 360) * 60_000, // 살아 있는 pid 라도 이보다 오래 쥔 잠금은 버려진 것으로 본다
    busyTimeoutMs: num(env, "LG_BUSY_TIMEOUT_MS", 15_000),
    testMode: env.LG_TEST_MODE === "1",
    llm: {
      perThread: num(env, "LG_LLM_MAX_PER_THREAD", 5),
      perDay: num(env, "LG_LLM_MAX_PER_DAY", 20),
      defaultModel: env.LG_LLM_MODEL || "sonnet",
      timeoutMs: num(env, "LG_LLM_TIMEOUT_SEC", 300) * 1000,
      bin: env.LG_CLAUDE_BIN || null,
    },
  };
}

// 시계. 시험은 LG_NOW(ISO 또는 epoch ms)로 시간을 주입한다 — 승인 기한·gc·하루 상한이 이 값을 쓴다.
// 시험 모드(LG_TEST_MODE=1)에서만 받는다. 운영에 남은 LG_NOW 가 기한·상한을 조용히 비틀지 않게 오류로 멈춘다.
export function clock(env = process.env) {
  const v = env.LG_NOW;
  if (!v) return () => Date.now();
  if (env.LG_TEST_MODE !== "1") throw new Error("LG_NOW 는 시험 모드(LG_TEST_MODE=1)에서만 쓴다");
  const t = /^\d+$/.test(v) ? Number(v) : Date.parse(v);
  if (!Number.isFinite(t)) throw new Error(`LG_NOW 를 읽지 못함: ${v}`);
  return () => t;
}

// 이 기기 시간대의 ISO 시각(오프셋 포함) — 알림을 읽는 사람이 바로 읽게.
export function iso(ms) {
  const off = -new Date(ms).getTimezoneOffset();
  const pad = (n) => String(Math.trunc(Math.abs(n))).padStart(2, "0");
  return `${new Date(ms + off * 60_000).toISOString().slice(0, 19)}${off < 0 ? "-" : "+"}${pad(off / 60)}:${pad(off % 60)}`;
}
