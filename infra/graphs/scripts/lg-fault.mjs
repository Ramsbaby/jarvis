#!/usr/bin/env node
// lg-fault.mjs — 고장 주입 도구(PLAN §5 1a · 2a '고장 주입 주 2회' · 2b 'M1·M3·M4 위반 0(고장 주입 포함)').
// 루프가 끊겨도 이어 가는지(재개 M1)를 운영 중에 일부러 확인한다. 우리 것임을 증명한 프로세스만 끈다.
//   node scripts/lg-fault.mjs list                        살아 있는 분리 실행과 잠금 주인(틱) 보기
//   node scripts/lg-fault.mjs kill-job <스레드> [노드]     그 스레드의 살아 있는 분리 실행 묶음을 SIGKILL — 결과 없이 죽음(dead) → 그래프가 다시 띄운다
//   node scripts/lg-fault.mjs kill-tick [<스레드>]         그 스레드(없으면 아무) 잠금을 쥔 살아 있는 실행기를 SIGKILL — 끊김 → 다음 틱이 interrupted 로 잇는다
// 증명: 분리 실행은 meta.json 의 pid·시작 시각(ps lstart)이 지금 프로세스와 같을 때, 실행기는 잠금 행의 pid·시작 시각이 같고
//   명령줄이 이 실행기(run.mjs)일 때만 끈다. 주입마다 metrics.jsonl 에 fault 한 줄(kind·스레드·노드)을 남긴다 — lg-report 의 M1 이 '주입 뒤 이어 감'을 센다.
import "../lib/env-guard.mjs";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { loadConfig, clock } from "../lib/config.mjs";
import { Store, pidAlive, procStart } from "../lib/store.mjs";
import { createMetrics } from "../lib/metrics.mjs";
import { allowSpawn } from "../lib/guard.mjs";

const cfg = loadConfig();
const now = clock();
const [cmd, thread, nodeArg] = process.argv.slice(2);
const out = (o) => process.stdout.write(`${JSON.stringify(o)}\n`);
const readJson = (f) => { try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch { return null; } };
const cmdline = (pid) => allowSpawn(() => spawnSync("/bin/ps", ["-o", "command=", "-p", String(pid)], { encoding: "utf8", env: { PATH: "/bin:/usr/bin", LC_ALL: "C" } })).stdout.trim();

// 살아 있는 분리 실행: jobs/<스레드>/<노드>/<시도>/meta.json 중 결과가 없고 껍데기가 우리 것인 것
function liveJobs(onlyThread) {
  const jobs = [];
  if (!fs.existsSync(cfg.jobsDir)) return jobs;
  for (const th of fs.readdirSync(cfg.jobsDir)) {
    if (onlyThread && th !== onlyThread) continue;
    const tdir = path.join(cfg.jobsDir, th);
    for (const node of fs.existsSync(tdir) ? fs.readdirSync(tdir) : []) {
      if (node === "_scratch") continue;
      const ndir = path.join(tdir, node);
      if (!fs.statSync(ndir).isDirectory()) continue;
      for (const att of fs.readdirSync(ndir)) {
        const dir = path.join(ndir, att);
        const meta = readJson(path.join(dir, "meta.json"));
        if (!meta || fs.existsSync(path.join(dir, "result.json")) || fs.existsSync(path.join(dir, "kill.json"))) continue;
        const ours = Number.isInteger(meta.pid) && meta.pid > 1 && pidAlive(meta.pid) && !!meta.pstart && procStart(meta.pid) === meta.pstart;
        if (ours) jobs.push({ thread: th, node, attempt: att, pid: meta.pid, dir });
      }
    }
  }
  return jobs;
}

function liveLocks(store, onlyThread) {
  const rows = store.db.prepare("SELECT thread_id, pid, pstart, acquired_at FROM lg_locks").all();
  return rows.filter((r) => (!onlyThread || r.thread_id === onlyThread) && r.pid !== process.pid && pidAlive(r.pid)
    && r.pstart && procStart(r.pid) === r.pstart && /run\.mjs/.test(cmdline(r.pid)));
}

const store = new Store(cfg);
const metric = createMetrics({ file: cfg.metricsPath, now });
let code = 0;
try {
  if (cmd === "list") {
    out({ jobs: liveJobs(thread).map(({ dir, ...j }) => j), locks: liveLocks(store, thread).map((r) => ({ thread: r.thread_id, pid: r.pid })) });
  } else if (cmd === "kill-job") {
    if (!thread) throw new Error("kill-job <스레드> [노드]");
    const jobs = liveJobs(thread).filter((j) => !nodeArg || j.node === nodeArg);
    if (!jobs.length) { out({ ok: false, why: "살아 있는 분리 실행이 없다", thread }); code = 1; }
    for (const j of jobs) {
      try { process.kill(-j.pid, "SIGKILL"); } catch (e) { if (e.code !== "ESRCH") throw e; } // 껍데기는 자기 묶음의 우두머리 — 묶음째
      metric("fault", { kind: "kill-job", thread: j.thread, node: j.node, attempt: Number(j.attempt) || null });
      out({ ok: true, kind: "kill-job", thread: j.thread, node: j.node, attempt: j.attempt, pid: j.pid });
    }
  } else if (cmd === "kill-tick") {
    const locks = liveLocks(store, thread);
    if (!locks.length) { out({ ok: false, why: "잠금을 쥔 살아 있는 실행기가 없다", thread: thread ?? null }); code = 1; }
    for (const r of locks.slice(0, 1)) {
      process.kill(r.pid, "SIGKILL");
      metric("fault", { kind: "kill-tick", thread: r.thread_id, pid: r.pid });
      out({ ok: true, kind: "kill-tick", thread: r.thread_id, pid: r.pid });
    }
  } else {
    out({ ok: false, why: "사용: lg-fault.mjs list | kill-job <스레드> [노드] | kill-tick [<스레드>]" });
    code = 2;
  }
} finally {
  store.close();
}
process.exitCode = code;
