#!/usr/bin/env node
// lg-watch.mjs — 판정 집계(lg-report --json)를 읽어 기준 밖이면 사람이 읽을 한국어 요약을 내고 지시함(orders.md)에 '- [ ]' 를 올린다.
//   이상이 없으면 정확히 NO_REPLY 만 낸다(예약 잡 알림이 조용히 끝난다).
//   node scripts/lg-watch.mjs [--hours 24] [--bench-hours 168] [--dry-run]     (예약 잡: sh infra/graphs/lg.sh watch)
// 왜(10-06): lg-report 를 읽는 사람·잡이 없어 디스크 보류 37회·벤치 '숨긴 정답 통과' 미측정·그림자에 묻힌 QA 발견이 주인님이 묻기 전까지 아무에게도 안 보였다.
// 보는 것(창: 기본 최근 24시간, 벤치는 7일, M4 는 전체 기록):
//   틱 0회 · M2 검증 없는 완료 · M3 중복·결과 모름(최근 기록이 창 안인 key) · M4 버려진 대기·보류 · M7 주인님 선발견 · M1 끊긴 뒤 버려짐 · Fable 호출
//   · 보류(같은 사유 하루 HELD_DAY_MAX 회 이상 또는 연속 HELD_STREAK_MAX 틱 이상, 야간 금지 quiet 는 설계상 보류라 뺌, 위험 사유는 1회부터)
//   · 벤치 M8 기준 미달·한 번도 안 잰 칸 · 고스톱 실기 QA 상급 발견(오늘·어제 signals.json)이 지시함에 없음
// 지시함 중복 0: 줄 끝 표식 [lg-watch:<열쇠>] 가 붙은 열린 줄('- [ ]')이 있으면 다시 올리지 않는다(닫힌 뒤 다시 생기면 새로 올린다).
// 쓰는 것은 지시함 끝에 덧붙이기뿐이다. 판정 기록·당직 장부·감지기는 읽기만 한다.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { hasOrderId } from "../graphs/gostop-qa.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPORT = path.join(HERE, "..", "lg-report.mjs");
export const HELD_DAY_MAX = 6; // 같은 사유 보류가 창 안에서 6회(틱 3시간 치) 이상
export const HELD_STREAK_MAX = 4; // 같은 사유로 연달아 4틱(2시간) 이상
export const HELD_EXPECTED = new Set(["quiet"]); // 01:30~04:30 야간 금지 — 설계상 매일 6~7틱
export const HELD_SERIOUS = new Set(["code_defect", "effect_unknown", "hook_leak", "stuck"]); // 1회라도 사람이 볼 것
// LLM 호출만 막는 사유(10-10) — 실행기는 돌고 LLM 을 안 쓰는 단계는 간다. 알림 글을 '일을 멈췄다'로 쓰지 않는다
export const HELD_LLM_ONLY = new Set(["usage_high", "usage_unreadable", "usage_stale", "login", "usage_limit", "token_cap", "token_thread", "llm_day", "llm_thread"]);
const REPORT_HINT = "node ~/projects/jarvis/infra/graphs/lg-report.mjs --hours 24";

const kstDay = (ms) => new Date(ms + 9 * 3_600_000).toISOString().slice(0, 10);
const kstStamp = (ms) => new Date(ms + 9 * 3_600_000).toISOString().slice(0, 16).replace("T", " ");
const list = (xs, n = 5) => (xs.length > n ? `${xs.slice(0, n).join(" · ")} 외 ${xs.length - n}` : xs.join(" · "));

export const ordersPath = (env = process.env) =>
  path.resolve(env.LG_WATCH_ORDERS || path.join(env.HOME || os.homedir(), ".openclaw", "workspace", "state", "duty", "orders.md"));
export const qaRoot = (env = process.env) =>
  path.resolve(env.GQA_STATE || path.join(env.HOME || os.homedir(), ".openclaw", "workspace", "state", "gostop-play", "qa-auto"));

function report(args) {
  const r = spawnSync(process.execPath, [REPORT, "--json", ...args], { encoding: "utf8", env: process.env, timeout: 60_000 });
  if (r.status !== 0) throw new Error(`lg-report ${args.join(" ")} 실패(코드 ${r.status ?? r.signal}): ${String(r.stderr ?? "").trim().split("\n")[0]}`);
  return JSON.parse(r.stdout);
}

// 고스톱 실기 QA 상급 발견 중 지시함에 없는 것 — 오늘·어제(KST) 신호 파일
export function qaHighMissing(root, ordersText, days) {
  const out = [];
  for (const d of days) {
    let j = null;
    try { j = JSON.parse(fs.readFileSync(path.join(root, d, "signals.json"), "utf8")); } catch { continue; }
    for (const s of j?.signals ?? []) {
      if (s.severity !== "상") continue;
      const id = String(s.sigkey ?? "").split(":")[1];
      if (id && !hasOrderId(ordersText, id) && !out.some((x) => x.id === id)) out.push({ id, day: d, report: String(s.report ?? "").slice(0, 80) });
    }
  }
  return out;
}

// 기준 밖 항목 → [{ key, title, detail }]. day = 창(최근 hours), all = 전체 기록, bench = 벤치 창
export function findIssues({ day, all, bench, qaMissing = [] }) {
  const out = [];
  const add = (key, title, detail) => out.push({ key, title, detail });
  if (!day.ticks) add("ticks0", `최근 ${day.range.hours ?? 24}시간 틱 0회`, `실행기 틱(graphs: lg-tick, 30분마다)이 한 번도 돌지 않았다. 마지막 틱 ${all.last_tick ?? "없음"}`);
  if (day.m2.unverified > 0) {
    const xs = day.m2.unverified_list.map((x) => `${x.thread}(${x.graph})`);
    add("m2", `검증 없이 끝난 일 ${day.m2.unverified}건(완료 ${day.m2.done}건 중)`, `그래프가 끝날 때 확인 기록(verify_log)을 남기지 못했다 — 확인 실패이거나 포기한 일: ${list(xs)}`);
  }
  const dupKeys = (all.m3.dup_list ?? []).filter((x) => Date.parse(x.last_ts) >= Date.parse(day.range.since ?? 0));
  if (dupKeys.length) add("m3", `같은 부수효과가 두 번 실행됨 ${dupKeys.length}건`, `멱등 키 중복: ${list(dupKeys.map((x) => `${x.kind} ${x.key}`))}`);
  const unknown = (all.m3.unknown_list ?? []).filter((x) => Date.parse(x.last_ts) >= Date.parse(day.range.since ?? 0));
  if (unknown.length) add("m3u", `시작만 되고 결과를 모르는 부수효과 ${unknown.length}건`, `확인 전에는 다시 내지 않고 보류 중: ${list(unknown.map((x) => `${x.kind} ${x.key}`))}`);
  if (all.m4.abandoned_unreported > 0) add("m4", `48시간 넘게 보고 없이 남은 일 ${all.m4.abandoned_unreported}건`, `끝나지도 만료 보고되지도 않았다: ${list(all.m4.list)}`);
  if (day.m7.incidents?.length) add("m7", `주인님이 먼저 찾은 루프 고장 ${day.m7.incidents.length}건`, `당직 장부 found_by owner: ${list(day.m7.incidents.map((x) => `${x.day} ${x.key}`))} — 같은 종류를 감시가 먼저 잡게 고칠 것`);
  if (day.m1.abandoned > 0) add("m1", `끊긴 뒤 이어 가지 못하고 버려진 일 ${day.m1.abandoned}건`, `끊긴 스레드 ${day.m1.interrupted}건 중 이어 감 ${day.m1.continued}`);
  if (day.m6.fable_calls > 0) add("fable", `금지된 Fable 모델 호출 ${day.m6.fable_calls}회`, "모델 정책 위반(분류·요약 haiku, 분석·검토 sonnet, 수정안 opus)");
  for (const [reason, n] of Object.entries(day.held ?? {})) {
    if (HELD_EXPECTED.has(reason)) continue;
    const st = day.held_streak?.[reason] ?? { max: 0, current: 0 };
    if (HELD_SERIOUS.has(reason) || n >= HELD_DAY_MAX || st.max >= HELD_STREAK_MAX) {
      add(`held:${reason}`, `보류 '${reason}' ${n}회(최장 연속 ${st.max}틱${st.current ? ` · 지금도 ${st.current}틱째` : ""})`,
        `${HELD_LLM_ONLY.has(reason) ? "이 사유로 LLM 호출이 막혔다 — LLM 을 안 쓰는 단계는 진행하고, LLM 을 부르는 스레드만 보류된다" : "실행기가 이 사유로 일을 멈췄다"}(기준: 하루 ${HELD_DAY_MAX}회 또는 연속 ${HELD_STREAK_MAX}틱${HELD_SERIOUS.has(reason) ? " — 위험 사유는 1회부터" : ""})`);
    }
  }
  const m8 = bench.m8;
  if (m8.runs && (m8.below.length || m8.unmeasured.length)) {
    const parts = [...m8.below.map((k) => `${k} 미달(${k === "ai_misjudge" ? `${m8.ai_misjudge}건` : `${m8.rates[k]}%`})`), ...m8.unmeasured.map((k) => `${k} 한 번도 안 잼`)];
    add("m8", `벤치 기준 밖(최근 ${bench.range.hours ?? "?"}시간 ${m8.runs}회): ${parts.join(" · ")}`,
      `PLAN M8 ① 그림자 기준 재현 ${m8.criteria.reproduced_min}%↑ · 숨긴 정답 통과 ${m8.criteria.hidden_pass_min}%↑ · AI 분기 오판 0. '안 잼'은 0%가 아니라 그 칸을 적는 코드가 없다는 뜻`);
  }
  if (qaMissing.length) add("qa-high", `고스톱 실기 QA 상급 발견 ${qaMissing.length}건이 수리 목록에 없음`, `${list(qaMissing.map((x) => `${x.id}(${x.day}) ${x.report}`), 4)}`);
  return out;
}

// 지시함에 덧붙인다. 같은 열쇠의 열린 줄이 있으면 건너뛴다. → { added, open }
export function postOrders(file, issues, now) {
  const cur = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
  const openLines = cur.split("\n").filter((l) => /^\s*- \[ \]/.test(l));
  const added = [], open = [];
  for (const it of issues) {
    if (openLines.some((l) => l.includes(`[lg-watch:${it.key}]`))) { open.push(it); continue; }
    added.push(it);
  }
  if (added.length) {
    const head = `## ${kstStamp(now)} — 랭그래프 감시(lg-watch)`;
    const lines = added.map((it) => `- [ ] (당직 몫) **랭그래프 이상 — ${it.title}:** ${it.detail}. 확인 \`${REPORT_HINT}\` [lg-watch:${it.key}]`);
    fs.appendFileSync(file, `${cur && !cur.endsWith("\n") ? "\n" : ""}\n${head}\n${lines.join("\n")}\n`);
  }
  return { added, open };
}

export function main(argv = process.argv.slice(2), env = process.env) {
  const flag = (k, d) => { const i = argv.indexOf(`--${k}`); return i >= 0 ? argv[i + 1] : d; };
  const hours = Number(flag("hours", 24)), benchHours = Number(flag("bench-hours", 168));
  const now = Date.now();
  const day = report(["--hours", String(hours)]);
  const all = report([]);
  const bench = report(["--hours", String(benchHours)]);
  const file = ordersPath(env);
  const ordersText = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
  const qaMissing = qaHighMissing(qaRoot(env), ordersText, [kstDay(now), kstDay(now - 86_400_000)]);
  const issues = findIssues({ day, all, bench, qaMissing });
  if (!issues.length) return "NO_REPLY";
  const { added, open } = argv.includes("--dry-run") ? { added: [], open: [] } : postOrders(file, issues, now);
  const L = [`랭그래프 감시 — 기준 밖 ${issues.length}건. 지시함에 새로 ${added.length}건 올렸습니다${open.length ? `(${open.length}건은 이미 열려 있음)` : ""}${argv.includes("--dry-run") ? " (시험 실행 — 지시함은 쓰지 않음)" : ""}.`];
  for (const it of issues) L.push(`• ${it.title} — ${it.detail}`);
  L.push(`자세히: ${REPORT_HINT}`);
  return L.join("\n");
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.stdout.write(`${main()}\n`);
  } catch (e) {
    process.stdout.write(`랭그래프 감시 실패 — ${String(e?.message ?? e).split("\n")[0]}\n`);
    process.exit(1);
  }
}
