// config.mjs — 설정은 환경변수로만 바꾼다. 기본값이 운영값이다.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));

function num(env, key, dflt) {
  const v = env[key];
  if (v === undefined || v === "") return dflt;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) throw new Error(`${key} 는 0 이상의 숫자여야 한다: ${v}`);
  return n;
}

// "01:30-04:30" → [90, 270] (자정부터 분). 빈 값이면 끈다. 앞이 뒤보다 크면 자정을 넘는 구간이다.
function timeWindow(env, key, dflt) {
  const v = env[key] ?? dflt;
  if (!v) return null;
  const m = /^(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})$/.exec(String(v).trim());
  if (!m) throw new Error(`${key} 는 HH:MM-HH:MM 형식이어야 한다: ${v}`);
  const [a, b] = [Number(m[1]) * 60 + Number(m[2]), Number(m[3]) * 60 + Number(m[4])];
  if (a >= 1440 || b > 1440 || Number(m[2]) > 59 || Number(m[4]) > 59) throw new Error(`${key} 시각이 이상하다: ${v}`);
  return [a, b];
}

export function loadConfig(env = process.env) {
  const home = env.HOME || os.homedir();
  const stateDir = path.resolve(env.LG_STATE_DIR || path.join(home, ".openclaw-data", "runtime", "state", "graphs"));
  const testMode = env.LG_TEST_MODE === "1";
  // 명령 허용 목록은 저장소 파일이 정본이다. 시험 모드에서만 다른 파일로 바꿀 수 있다(운영에서 환경변수로 목록을 넓히지 못하게).
  if (env.LG_CMD_REGISTRY && !testMode) throw new Error("LG_CMD_REGISTRY 는 시험 모드(LG_TEST_MODE=1)에서만 쓴다");
  // 목록 timeoutSec 상한(3600)의 1.5배 — 기본값이 어느 명령에서도 껍데기의 시간 제한보다 먼저 걸리지 않는다
  const detachMaxSec = num(env, "LG_DETACH_MAX_SEC", 5400);
  if (detachMaxSec <= 0) throw new Error("LG_DETACH_MAX_SEC 는 0보다 커야 한다");
  return {
    home,
    stateDir,
    dbPath: path.resolve(env.LG_DB || path.join(stateDir, "checkpoints.db")),
    pendingPath: path.join(stateDir, "pending.jsonl"),
    metricsPath: path.join(stateDir, "metrics.jsonl"), // 추가 전용 — gc 대상이 아니다(판정일 + 30일 보존)
    effectsPath: path.join(stateDir, "effects.jsonl"), // 추가 전용 — gc 대상이 아니다
    jobsDir: path.join(stateDir, "jobs"), // 분리 실행 작업 폴더(스레드별) — gc 가 스레드와 함께 지운다
    pausedPath: path.join(stateDir, "PAUSED"), // 있으면 전체 정지
    livePath: path.join(stateDir, "LIVE"), // 없으면 그림자. 모드는 스레드 시작 때 고정한다
    llmHoldPath: path.join(stateDir, "llm-hold.json"), // 로그인 만료·사용량 한도 표식(호출 오류 문구로 판정)
    lastGcPath: path.join(stateDir, "last-gc"),
    cmdRegistryPath: path.resolve(env.LG_CMD_REGISTRY || path.join(HERE, "..", "cmd-registry.json")),
    approvalTtlMs: num(env, "LG_APPROVAL_TTL_HOURS", 48) * 3_600_000,
    holdTtlMs: num(env, "LG_HOLD_TTL_HOURS", 48) * 3_600_000, // 진척 없는 보류·이어가기·대기열·실패도 48시간이면 만료
    gcDays: num(env, "LG_GC_DAYS", 14),
    // 살아 있는 pid 의 잠금은 나이와 상관없이 넘겨받지 않는다. 이보다 오래 쥐고 있으면 STUCK 으로 알리고 그 스레드는 건드리지 않는다.
    lockStuckMs: num(env, "LG_LOCK_STUCK_MIN", num(env, "LG_LOCK_STALE_MIN", 30)) * 60_000,
    busyTimeoutMs: num(env, "LG_BUSY_TIMEOUT_MS", 15_000),
    tickBudgetMs: num(env, "LG_TICK_BUDGET_SEC", 480) * 1000, // 이만큼 지나면 다음 노드 앞에 선다(CONTINUE)
    // 틱 안의 LLM·명령이 끝나야 하는 시각(틱 시작부터) — 시간 제한을 이 안으로 줄인다. 잡은 --timeout-seconds 900 으로 등록하고
    // (10-03 실측: 명령형 잡 10분은 기본값이지 상한이 아니다), 남는 5분은 노드 하나가 예산을 넘길 때의 여유로 둔다.
    jobLimitMs: num(env, "LG_JOB_LIMIT_SEC", 600) * 1000,
    detachMaxSec, // 분리 실행 최대 시간 기본값 — 목록에 maxSeconds 가 없을 때
    maxRetries: num(env, "LG_MAX_RETRIES", 3), // 같은 오류 재시도 횟수. 그다음에도 같은 오류면 GAVE_UP
    maxSteps: num(env, "LG_MAX_STEPS", 500), // 스레드 하나의 단계 상한(끝없는 되풀이 방지)
    testMode,
    gates: {
      diskPath: env.LG_DISK_PATH || (fs.existsSync("/System/Volumes/Data") ? "/System/Volumes/Data" : stateDir),
      diskFloorGiB: num(env, "LG_DISK_FLOOR_GIB", 15), // 감지기 경고선
      copyEstGiB: num(env, "LG_COPY_EST_GIB", 1), // 작업 사본 예상 크기 — 1a 에서 실측해 바꾼다
      diskMarginGiB: num(env, "LG_DISK_MARGIN_GIB", 1),
      usagePath: path.resolve(env.LG_USAGE_FILE || path.join(home, ".openclaw", "workspace", "state", "orchestrator", "latest.md")),
      usageMaxPct: num(env, "LG_USAGE_MAX_PCT", 80),
      usageMaxAgeMs: num(env, "LG_USAGE_MAX_AGE_H", 6) * 3_600_000,
      quiet: timeWindow(env, "LG_QUIET", "01:30-04:30"), // 야간 소크 시간 — 새 일을 시작하지 않는다
      loginRecheckMs: num(env, "LG_LOGIN_RECHECK_MIN", 360) * 60_000, // 로그인 만료 표식 뒤 다시 시도해 보기까지
      limitRecheckMs: num(env, "LG_LIMIT_RECHECK_MIN", 60) * 60_000, // 사용량 한도(429) 표식 뒤 다시 시도해 보기까지
    },
    // 사용자 훅 로그 — 자가 시험이 graphs 쪽 claude 호출 흔적(줄)이 0 인지 본다(S6). 훅이 되살아나면 여기에 작업 폴더가 찍힌다.
    hookLogs: (env.LG_HOOK_LOGS !== undefined ? env.LG_HOOK_LOGS.split(":") : ["stop-mistake-extract.log", "session-save.log"].map(
      (f) => path.join(home, ".openclaw-data", "runtime", "logs", f))).filter(Boolean),
    llm: {
      perThread: num(env, "LG_LLM_MAX_PER_THREAD", 5),
      perDay: num(env, "LG_LLM_MAX_PER_DAY", 20),
      // 하루 토큰 상한 — 입력·출력·캐시 생성·캐시 읽기를 모두 더한 값. 그림자 ② 판정(10-28) 때 '하루 최댓값 × 1.5'로 다시 정한다.
      dayTokenCap: num(env, "LG_DAY_TOKEN_CAP", 3_000_000),
      defaultModel: env.LG_LLM_MODEL || "sonnet",
      timeoutMs: num(env, "LG_LLM_TIMEOUT_SEC", 300) * 1000,
      bin: env.LG_CLAUDE_BIN || null,
    },
  };
}

// 시계. 시험은 LG_NOW(ISO 또는 epoch ms)로 시간을 주입한다 — 승인 기한·gc·하루 상한·관문이 이 값을 쓴다.
// 시험 모드(LG_TEST_MODE=1)에서만 받는다. 운영에 남은 LG_NOW 가 기한·상한을 조용히 비틀지 않게 오류로 멈춘다.
// 틱 예산은 이 시계가 아니라 실제 경과 시간으로 잰다(잡 시간 상한은 실제 시간이다).
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
