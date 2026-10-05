// metrics.mjs — 판정용 기록(S17). 추가 전용 JSONL 한 파일(metrics.jsonl). gc 대상이 아니다(판정일 + 30일 보존).
// 원문(질문·프롬프트·출력)은 적지 않는다 — 스레드·노드 이름, 숫자, 사유 낱말만. 개인정보가 평문으로 쌓이지 않게(S4).
// 한 줄은 한 번의 쓰기(O_APPEND)로 남긴다 — 여러 프로세스가 같이 써도 줄이 섞이지 않게 줄을 짧게 유지한다(4KB 미만).
import fs from "node:fs";
import path from "node:path";
import { iso } from "./config.mjs";

// 사건 이름 — lg-report.mjs 가 이 이름으로 센다. 새 사건을 더하면 README 의 표와 함께 고친다.
export const EVENTS = new Set([
  "start", "node_start", "node_end", "continue", "interrupted", "resumed", "waiting", "answered", "expired", "held",
  "gave_up", "done", "llm", "effect", "stuck", "tick", "gc", "failed", "bench", "fault", "sandbox_violation",
  "reclaim", // 디스크 관문 자가 회복(10-05) — 치운 폴더·건너뛴 이유
  "lg.duty.verify", "lg.restart.heartbeat", // 당직 D0 그림자(PLAN §13.3) — 재시작 뒤 확인 판정 · 틱마다 게이트웨이 pid·시작 시각(재시작 생존 실측)
]);

const MAX_LINE = 3800;

function clip(v) {
  if (typeof v === "string") return v.replace(/\s+/g, " ").slice(0, 300);
  if (Array.isArray(v)) return v.slice(0, 20).map(clip);
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).slice(0, 30).map(([k, x]) => [k, clip(x)]));
  return v;
}

// 시험·운영 모두 같은 함수. now 는 주입 시계(기한·하루 집계와 같은 시계)다.
export function createMetrics({ file, now }) {
  let fd = null;
  const open = () => {
    if (fd !== null) return fd;
    fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
    fd = fs.openSync(file, "a", 0o600);
    return fd;
  };
  const metric = (ev, fields = {}) => {
    if (!EVENTS.has(ev)) throw new Error(`모르는 기록 사건: ${ev}`);
    const t = now();
    let line = JSON.stringify({ ts: iso(t), t, ev, ...clip(fields) });
    if (line.length > MAX_LINE) line = JSON.stringify({ ts: iso(t), t, ev, truncated: true, thread: clip(fields.thread) });
    try { fs.writeSync(open(), `${line}\n`); } catch (e) {
      // 기록 실패가 그래프 실행을 막지 않는다. 다만 조용히 버리지 않고 표준 오류에 한 줄 남긴다(알림 묶음은 깨질 수 있다).
      process.stderr.write(`metrics 기록 실패: ${e.message}\n`);
    }
  };
  metric.close = () => { if (fd !== null) { try { fs.closeSync(fd); } catch { /* 이미 닫힘 */ } fd = null; } };
  return metric;
}

// 읽기(집계·시험용). 깨진 줄은 건너뛴다(추가 전용 파일의 마지막 줄이 쓰다 끊겼을 수 있다).
export function readJsonl(file) {
  if (!fs.existsSync(file)) return [];
  const out = [];
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try { out.push(JSON.parse(line)); } catch { /* 끊긴 줄 */ }
  }
  return out;
}
