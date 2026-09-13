#!/usr/bin/env node
// cron-exit-mask-audit.mjs — "성공으로 위장된 실패" 탐지
//
// 배경: 2026-09-02 실측. cron-safe-wrapper 가 gtimeout 을 못 찾아 타임아웃 보호가
// 무효화됐는데 4,620회 전부 exit=0 으로 기록됐다. scorecard-enforcer.sh 는
// `command not found` 117회 직후 "전송 완료"를 찍었다.
// 종료코드만 보는 감시는 이 계급을 영원히 못 잡는다.
//
// 판정: stderr/로그에 실패 지문이 있는데 종료 상태가 성공이면 MASKED.
// 사용: node infra/scripts/cron-exit-mask-audit.mjs [--json] [--days N]

import fs from "node:fs";
import path from "node:path";

const HOME = process.env.HOME;
const BOT_HOME = process.env.BOT_HOME || path.join(HOME, ".openclaw-data", "runtime");
const LOG_DIR = path.join(BOT_HOME, "logs");
const LEDGER = path.join(BOT_HOME, "ledger", "exit-mask-audit.jsonl");

const args = process.argv.slice(2);
const asJson = args.includes("--json");
const days = Number((args.find((a) => a.startsWith("--days=")) || "--days=7").split("=")[1]) || 7;
const CUTOFF = Date.now() - days * 864e5;

// 실패 지문 — stderr 에 이게 있으면 종료코드가 0이어도 실패로 계상한다.
const FAIL_MARKS = [
  [/command not found/i,            "명령어 없음"],
  [/No such file or directory/i,    "파일 없음"],
  [/unbound variable/i,             "미정의 변수"],
  [/Traceback \(most recent/i,      "파이썬 예외"],
  [/Permission denied/i,            "권한 거부"],
  [/running without timeout/i,      "타임아웃 보호 무효"],
  [/FAILED:UNKNOWN/,                "원인불명 실패"],
  [/DEPRECATED/,                    "폐기된 코드경로"],
  [/JSON (파싱|parse) 실패/i,        "JSON 파싱 실패"],
  [/exit(=| )12[46]/,               "타임아웃 종료"],
];
// 성공 신호 — 이게 같이 있으면 "위장"이다.
const OK_MARKS = /exit=0|DONE\b|✅|성공|완료|SUCCESS/;

const stat = (f) => { try { return fs.statSync(f); } catch { return null; } };

// 로그 줄에서 날짜를 뽑는다. 못 뽑으면 null → 날짜 미상은 거르지 않는다.
const DATE_RE = /(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}:\d{2}))?/;
function lineDate(ln) {
  const m = DATE_RE.exec(ln);
  if (!m) return null;
  const t = Date.parse(m[2] ? `${m[1]}T${m[2]}:00Z` : `${m[1]}T00:00:00Z`);
  return Number.isNaN(t) ? null : t;
}

const findings = [];
let scanned = 0;

for (const name of fs.readdirSync(LOG_DIR)) {
  if (!name.endsWith(".log")) continue;
  const file = path.join(LOG_DIR, name);
  const st = stat(file);
  if (!st || !st.isFile() || st.mtimeMs < CUTOFF || st.size === 0) continue;
  scanned++;

  const buf = fs.readFileSync(file, "utf8");
  const text = buf.length > 2_000_000 ? buf.slice(-2_000_000) : buf;
  const lines = text.split("\n");

  const hits = new Map();   // 지문 → {n, sample, last}
  let okCount = 0;
  for (const ln of lines) {
    // 줄 자체의 날짜로 거른다. 파일 mtime 만 보면 몇 달 전 줄이 섞인다.
    const ld = lineDate(ln);
    if (ld !== null && ld < CUTOFF) continue;
    if (OK_MARKS.test(ln)) okCount++;
    for (const [re, label] of FAIL_MARKS) {
      if (!re.test(ln)) continue;
      const cur = hits.get(label) || { n: 0, sample: ln.trim().slice(0, 120), last: "" };
      cur.n++;
      if (ld !== null) { const d = new Date(ld).toISOString().slice(0, 10); if (d > cur.last) { cur.last = d; cur.sample = ln.trim().slice(0, 120); } }
      hits.set(label, cur);
    }
  }
  if (hits.size === 0 || okCount === 0) continue;

  const task = name.replace(/(-err)?\.log$/, "");
  for (const [label, v] of hits) {
    findings.push({ task, mark: label, count: v.n, okCount, sample: v.sample, log: name });
  }
}

findings.sort((a, b) => b.count - a.count);

if (asJson) {
  console.log(JSON.stringify({ ts: new Date().toISOString(), days, scanned, findings }, null, 2));
} else {
  console.log(`exit 0 위장 감사 — 최근 ${days}일 · 로그 ${scanned}개 스캔\n`);
  if (findings.length === 0) {
    console.log("  위장 사례 없음");
  } else {
    console.log(`  ⚠️ ${findings.length}건 (실패 지문 + 성공 기록 동시 존재)\n`);
    for (const f of findings.slice(0, 25)) {
      console.log(`  ${String(f.count).padStart(5)}회  ${f.mark.padEnd(16)} ${f.task}`);
      console.log(`         최종 ${f.last} · 성공기록 ${f.okCount}회`);
      console.log(`         ${f.sample}`);
    }
    if (findings.length > 25) console.log(`\n  … 외 ${findings.length - 25}건`);
  }
}

try {
  fs.mkdirSync(path.dirname(LEDGER), { recursive: true });
  fs.appendFileSync(LEDGER, JSON.stringify({
    ts: new Date().toISOString(), days, scanned,
    total: findings.length,
    top: findings.slice(0, 10).map(({ task, mark, count, last }) => ({ task, mark, count, last })),
  }) + "\n");
} catch { /* 원장 기록 실패는 감사 자체를 막지 않는다 */ }

process.exit(findings.length > 0 ? 1 : 0);
