// gates.mjs — 틱 관문(PLAN §3). 사유는 metrics 에 남긴다. 두 갈래다(10-10):
//   틱을 세우는 관문(paused·disk·quiet) — 하나라도 걸리면 그 틱은 스레드를 진행하지 않고 HOLD(종료 0)로 끝난다.
//   LLM 예산 관문(usage_*·login·usage_limit·token_cap) — 구독 한도를 지키려는 것이라 LLM 호출만 막는다. 틱은 돌고, LLM 을 부르려는
//     순간에 그 스레드만 보류된다(lib/claude.mjs reserve). 10-09 token_cap 39틱·10-10 usage_high 29틱 동안 토큰을 안 쓰는
//     QA 단계(빌드·판 두기·분석)까지 틱째 서서 매일 40판이 10판·0판에서 멈췄다.
//   paused      PAUSED 파일이 있다(전체 정지)
//   disk        디스크 여유 < 경고선 15GiB + 사본 예상(LG_COPY_EST_GIB) + 1GiB  (감지기와 같은 재는 법: statvfs bavail, 데이터 볼륨)
//   usage_*     주간 사용량 ≥ 80% · 못 읽음 · 13시간 넘게 묵음. 출처는 감지기(orchestrator-scan.py scan_usage → usage_findings)가
//               `claude -p /usage` 로 받아 대시보드 스냅샷(state/orchestrator/latest.md)의 '클로드 사용량' 줄에 쓰는 값이다. 읽기만 한다.
//               스냅샷은 정규 회차(08·11·14·17·20시)에만 다시 쓰이므로 밤에는 02시 무렵부터 08시까지 '묵음'으로 쉰다.
//   login       클로드 로그인 만료 표식(호출 오류 문구로 판정, lib/claude.mjs) — 표식 뒤 6시간이 지나면 한 번 다시 시도해 본다
//   usage_limit 사용량 한도(429) 표식 — 1시간 뒤 다시 시도
//   token_cap   오늘 쓴 토큰(입력·출력·캐시 모두) ≥ 하루 상한
//   quiet       01:30~04:30 (야간 소크 시간 — 새 일을 시작하지 않는다)
import fs from "node:fs";

const GiB = 2 ** 30;

// started=true: 이미 시작한 일을 이어 갈 때 — 사본·여유는 그 일이 쓰라고 떼어 둔 몫이라 건강선만 본다(10-05: QA 가 자기가 켠
//   에뮬레이터·녹화로 15.6GiB 가 되자 16.2 관문에 걸려 2시간 반 스스로 멈췄다). 새로 시작할 때는 건강선 + 사본 + 여유.
export function diskGate(g, statfs = fs.statfsSync, { started = false } = {}) {
  const need = started ? g.diskFloorGiB : g.diskFloorGiB + g.copyEstGiB + g.diskMarginGiB;
  let free;
  try {
    const s = statfs(g.diskPath);
    free = (Number(s.bavail) * Number(s.bsize)) / GiB;
  } catch (e) {
    return { gate: "disk", detail: `디스크 여유를 못 읽음(${g.diskPath}): ${e.code ?? e.message}` };
  }
  if (!(free >= need)) {
    const why = started ? `건강선 ${g.diskFloorGiB}` : `경고선 ${g.diskFloorGiB} + 사본 ${g.copyEstGiB} + ${g.diskMarginGiB}`;
    return { gate: "disk", detail: `디스크 여유 ${free.toFixed(1)}GiB < ${Math.round(need * 100) / 100}GiB(${why})` };
  }
  return null;
}

// latest.md: 머리 '# 자비스 오케스트레이터 스냅샷 — 2026-10-03 14:00 KST' · 줄 '| 클로드 사용량 | session 45% · week (all models) 69% · week (Fable) 100% |'
export function parseUsage(text) {
  const head = /^#\s.*스냅샷\s*—\s*(\d{4}-\d{2}-\d{2})\s+(\d{2}):(\d{2})\s*KST/m.exec(text);
  const at = head ? Date.parse(`${head[1]}T${head[2]}:${head[3]}:00+09:00`) : null;
  const row = /^\|\s*클로드 사용량\s*\|\s*(.+?)\s*\|\s*$/m.exec(text);
  const scopes = [];
  if (row) {
    for (const part of row[1].split("·")) {
      const m = /^(.+?)\s+(\d{1,3})%$/.exec(part.trim());
      if (m) scopes.push({ scope: m[1].trim(), pct: Number(m[2]) });
    }
  }
  // 주간 한도: week 로 시작하는 범위 중 Fable 은 뺀다(Fable 은 쓰지 않는다 — 금지 모델). 'all models' 와 모델별 주간이 남는다.
  const weekly = scopes.filter((s) => /^week\b/i.test(s.scope) && !/fable/i.test(s.scope));
  return { at, scopes, weekly, maxWeekly: weekly.length ? Math.max(...weekly.map((s) => s.pct)) : null };
}

export function usageGate(g, now) {
  let text, mtime;
  try { text = fs.readFileSync(g.usagePath, "utf8"); mtime = fs.statSync(g.usagePath).mtimeMs; } catch (e) {
    return { gate: "usage_unreadable", detail: `사용량 스냅샷을 못 읽음(${e.code ?? e.message})` };
  }
  const u = parseUsage(text);
  const at = u.at ?? mtime;
  if (u.maxWeekly == null) return { gate: "usage_unreadable", detail: "스냅샷에 주간 사용량 줄이 없다(감지기 사용량 조회 실패?)" };
  if (now - at > g.usageMaxAgeMs) return { gate: "usage_stale", detail: `사용량 값이 ${((now - at) / 3_600_000).toFixed(1)}시간 묵음(기준 ${g.usageMaxAgeMs / 3_600_000}시간)` };
  if (u.maxWeekly >= g.usageMaxPct) return { gate: "usage_high", detail: `주간 사용량 ${u.maxWeekly}% ≥ ${g.usageMaxPct}%` };
  return null;
}

export function llmHoldGate(cfg, now) {
  let h;
  try { h = JSON.parse(fs.readFileSync(cfg.llmHoldPath, "utf8")); } catch { return null; }
  const wait = h.reason === "login" ? cfg.gates.loginRecheckMs : cfg.gates.limitRecheckMs;
  if (Number.isFinite(h.at) && now - h.at < wait) {
    return { gate: h.reason === "login" ? "login" : "usage_limit", detail: `${h.reason === "login" ? "클로드 로그인 만료" : "사용량 한도"} 표식(${Math.round((now - h.at) / 60_000)}분 전) — ${String(h.detail ?? "").slice(0, 120)}` };
  }
  return null; // 기다림이 지났다 — 이번 틱에 한 번 다시 해 본다(성공하면 표식이 지워진다)
}

export function quietGate(g, now) {
  if (!g.quiet) return null;
  const d = new Date(now);
  const m = d.getHours() * 60 + d.getMinutes();
  const [a, b] = g.quiet;
  const inside = a <= b ? m >= a && m < b : m >= a || m < b;
  return inside ? { gate: "quiet", detail: `야간 소크 시간(${fmt(a)}~${fmt(b)})` } : null;
}
const fmt = (m) => `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;

export function tokenGate(cfg, store, now) {
  const used = store.dayTokens(now);
  return used >= cfg.llm.dayTokenCap ? { gate: "token_cap", detail: `오늘 토큰 ${used} ≥ 하루 상한 ${cfg.llm.dayTokenCap}` } : null;
}

export const paused = (cfg) => fs.existsSync(cfg.pausedPath);
export const liveMode = (cfg) => (fs.existsSync(cfg.livePath) ? "live" : "shadow");

// LLM 예산 관문의 이름 — 이 사유로 보류된 스레드는 관문이 풀릴 때까지 틱이 다시 돌리지 않는다
export const LLM_GATES = new Set(["usage_high", "usage_unreadable", "usage_stale", "login", "usage_limit", "token_cap"]);
export const isLlmGate = (g) => LLM_GATES.has(g?.gate ?? g);

// LLM 을 부르기 직전에 보는 관문(주간 사용량·로그인·한도 표식). 하루 토큰 상한은 장부가 자리를 잡으며 같이 본다(store.reserveLlmCall).
export function llmCallGates(cfg, now) {
  return [usageGate(cfg.gates, now), llmHoldGate(cfg, now)].filter(Boolean);
}

// 관문 전부. 돌려주는 값: 걸린 것들의 배열(비면 통과). 틱을 세우는 것과 LLM 만 막는 것은 isLlmGate 로 가른다.
export function checkGates(cfg, store, now) {
  const out = [];
  if (paused(cfg)) out.push({ gate: "paused", detail: "PAUSED 스위치가 켜져 있다" });
  for (const r of [diskGate(cfg.gates), usageGate(cfg.gates, now), llmHoldGate(cfg, now), tokenGate(cfg, store, now), quietGate(cfg.gates, now)]) if (r) out.push(r);
  return out;
}
