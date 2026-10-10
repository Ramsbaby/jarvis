// claude.test.mjs — Claude 부르기: 깨끗한 환경·고정 인자, 호출 상한(보류), Fable 차단. 가짜 claude 로만 돈다(실호출 없음).
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { sandbox, run, fakeClaude, statusJson, counts, at, T0, DAY } from "./helpers.mjs";
import { checkModel, claudeArgs, createClaude } from "../lib/claude.mjs";
import { loadConfig } from "../lib/config.mjs";
import { Store } from "../lib/store.mjs";

const ALLOWED_ENV = new Set(["HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ"]);

test("깨끗한 환경변수·고정 인자·빈 작업 폴더로 부른다 — 키·토큰·추적·프록시 변수는 넘기지 않는다", (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb);
  const leaky = {
    LG_CLAUDE_BIN: fake.bin,
    ANTHROPIC_API_KEY: "fake-should-not-pass", ANTHROPIC_AUTH_TOKEN: "fake", CLAUDE_CODE_OAUTH_TOKEN: "fake",
    CLAUDECODE: "1", CLAUDE_CONFIG_DIR: path.join(sb.dir, "other-config"), LANGSMITH_TRACING: "true",
    NODE_OPTIONS: "--trace-warnings", HTTPS_PROXY: "http://127.0.0.1:9",
  };
  const r = run(sb.env, ["start", "smoke", "l1", "--llm"], { extraEnv: leaky });
  assert.equal(r.code, 0, r.out + r.err);
  assert.match(r.first, /^WAITING l1 .*초안: 가짜 요약 문장/);

  const calls = fake.calls();
  assert.equal(calls.length, 1);
  const [c] = calls;
  assert.deepEqual(c.args, claudeArgs("haiku", [], { maxBudgetUsd: 1 }), "호출당 상한(기본 1달러)까지 고정 인자다");
  // 0b: 격리는 --restricted(사용자·프로젝트 설정·훅·사용자 규칙 무시, 파일 도구는 작업 폴더 안). 옛 --setting-sources project 는 규칙이 실렸다(실측)
  for (const f of ["--restricted", "--strict-mcp-config", "--no-session-persistence", "--output-format", "json"]) assert.ok(c.args.includes(f), f);
  assert.ok(!c.args.includes("--setting-sources"), "--restricted 와 섞지 않는다");
  const extra = Object.keys(c.env).filter((k) => !ALLOWED_ENV.has(k) && !k.startsWith("__CF"));
  assert.deepEqual(extra, [], "허용 목록 밖의 환경변수가 넘어갔다");
  assert.equal(c.env.HOME, os.userInfo().homedir, "로그인은 진짜 홈에 묶여 있다");
  // 0b: 작업 폴더는 홈 밖 임시 폴더(TMPDIR 아래 lg-claude-cwd*) — 진짜 홈·시험 홈 어디에도 속하지 않는다
  const cwd = fs.realpathSync(c.cwd);
  assert.match(path.basename(cwd), /^lg-claude-cwd/);
  for (const h of [os.userInfo().homedir, sb.home]) assert.ok(!cwd.startsWith(`${fs.realpathSync(h)}/`), `홈 밖이어야 한다: ${cwd}`);
  assert.deepEqual(fs.readdirSync(c.cwd), [], "작업 폴더는 비어 있다(project 설정·훅 없음)");
  assert.match(c.input, /요약하라/);
  assert.equal(statusJson(sb).llm.today, 1);
});

test("하루 상한에 닿으면 HELD(종료 0)로 보류, 다음 날 retry 로 이어간다", (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb);
  const env = { ...sb.env, LG_CLAUDE_BIN: fake.bin, LG_LLM_MAX_PER_DAY: "1" };
  assert.match(run(env, ["start", "smoke", "h1", "--llm"], at(T0)).first, /^WAITING h1 /);
  const held = run(env, ["start", "smoke", "h2", "--llm"], at(T0));
  assert.equal(held.code, 0, "보류는 경보 소음이 아니다");
  assert.match(held.first, /^HELD h2 LLM 호출 하루 상한 1회에 닿음/);
  assert.equal(JSON.parse(run(env, ["status", "h2", "--json"], at(T0)).out).status, "held");
  assert.equal(fake.calls().length, 1, "상한을 넘긴 호출은 claude 를 부르지 않는다");

  assert.match(run(env, ["retry", "h2"], at(T0 + 3_600_000)).first, /^HELD h2 /);
  const next = run(env, ["retry", "h2"], at(T0 + DAY));
  assert.equal(next.code, 0);
  assert.match(next.first, /^WAITING h2 .*가짜 요약 문장/);
  assert.equal(fake.calls().length, 2);
  assert.equal(counts(sb).collect, 2, "보류 뒤 재개는 collect 를 다시 돌리지 않는다(스레드 2개 = 2회)");
});

test("스레드 상한 0 이면 즉시 HELD, claude 를 한 번도 부르지 않는다", (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb);
  const r = run({ ...sb.env, LG_CLAUDE_BIN: fake.bin, LG_LLM_MAX_PER_THREAD: "0" }, ["start", "smoke", "z1", "--llm"]);
  assert.equal(r.code, 0);
  assert.match(r.first, /^HELD z1 LLM 호출 스레드 상한 0회에 닿음/);
  assert.equal(fake.calls().length, 0);
});

test("Fable 차단: 요청 모델 이름과 응답 모델 둘 다 본다", (t) => {
  for (const ok of ["haiku", "sonnet", "opus", "claude-haiku-4-5-20251001", "claude-sonnet-5-5"]) assert.equal(checkModel(ok), ok);
  for (const bad of ["fable", "Fable", "claude-fable-5-1", "best", "", undefined, "gpt-5"]) assert.throws(() => checkModel(bad), { name: "LlmModelBlocked" }, String(bad));

  const sb = sandbox(t);
  const fake = fakeClaude(sb, "fable");
  const r = run({ ...sb.env, LG_CLAUDE_BIN: fake.bin }, ["start", "smoke", "f1", "--llm"]);
  assert.equal(r.code, 1);
  assert.match(r.first, /^ERROR f1 failed 응답 모델이 Fable 이다/);
  assert.equal(JSON.parse(run(sb.env, ["status", "f1", "--json"]).out).status, "failed");
});

test("claude 가 실패하면 ERROR(종료 1), 그 호출도 상한에 센다", (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb, "fail");
  const r = run({ ...sb.env, LG_CLAUDE_BIN: fake.bin }, ["start", "smoke", "x1", "--llm"]);
  assert.equal(r.code, 1);
  assert.match(r.first, /^ERROR x1 failed claude 출력이 JSON 이 아니다\(코드 1\): 가짜 실패/);
  assert.equal(statusJson(sb).llm.today, 1);
});

test("출력이 한글 글자 한가운데서 끊겨 와도 깨지지 않는다", (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb, "split");
  const r = run({ ...sb.env, LG_CLAUDE_BIN: fake.bin }, ["start", "smoke", "u1", "--llm"]);
  assert.equal(r.code, 0, r.out + r.err);
  assert.match(r.first, /초안: 한글이 조각 경계에 걸린다$/);
  assert.doesNotMatch(r.out, /�/);
});

test("기본 모델은 sonnet, 모델을 안 주면 sonnet 으로 부른다", async (t) => {
  const sb = sandbox(t);
  const fake = fakeClaude(sb);
  const cfg = loadConfig({ HOME: sb.home, LG_STATE_DIR: sb.state, LG_CLAUDE_BIN: fake.bin });
  const store = new Store(cfg);
  t.after(() => store.close());
  const llm = createClaude({ store, cfg, now: () => T0, thread: "m1" });
  const res = await llm.ask("한 단어로 답하라");
  assert.equal(res.text, "가짜 요약 문장");
  assert.deepEqual(fake.calls()[0].args, claudeArgs("sonnet", [], { maxBudgetUsd: 1 }));
  await assert.rejects(llm.ask("x", { model: "fable" }), { name: "LlmModelBlocked" });
  assert.equal(fake.calls().length, 1, "차단된 모델은 부르지도, 상한을 쓰지도 않는다");
  assert.equal(store.llmCounts(T0, "m1").thread, 1);
});
