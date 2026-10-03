// fake-claude.cjs — 시험용 가짜 claude. 실제 모델을 부르지 않는다.
// helpers.fakeClaude() 가 만든 실행 파일(#!node, 셸 없음)이 require 해서 부른다 — 셸이 끼면 PWD·SHLVL 이 더해져 환경 시험이 흐려진다.
// 받은 인자·환경·입력·작업 폴더를 log 에 적고, mode 에 따라 답한다.
//   ok · fable · fail · split (0a) / tokens: 실제 모양의 usage·비용 / auth: 로그인 만료 문구 / limit: 사용량 한도(429) 문구 / slow: 1.5초 뒤 답
const fs = require("node:fs");

module.exports = function fake(log, mode) {
  const env = { ...process.env };
  const input = fs.readFileSync(0, "utf8");
  // 1b: 프롬프트 종류(script 모드가 몇 번째 호출인지 센다)
  const kind = /진단가/.test(input) ? "diag" : /결함을 재현하는 시험만/.test(input) ? "repro" : /규칙 결함을 고치는/.test(input) ? "fix" : /검토자/.test(input) ? "review" : "other";
  const prior = fs.existsSync(log) ? fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((r) => r.kind === kind).length : 0;
  fs.appendFileSync(log, `${JSON.stringify({ args: process.argv.slice(2), env, cwd: process.cwd(), input, kind })}\n`);
  // script (1b): '<log>.script.json' = { diag, repro:[{files,remove}], fix:[…], review:[…] } — 같은 종류 n 번째 호출은 n 번째 항목(넘치면 마지막)
  if (mode === "script") {
    const sc = JSON.parse(fs.readFileSync(`${log}.script.json`, "utf8"));
    const args = process.argv.slice(2);
    const model = args[args.indexOf("--model") + 1] ?? "sonnet";
    const pick = (a) => (Array.isArray(a) && a.length ? a[Math.min(prior, a.length - 1)] : null);
    const res = { type: "result", subtype: "success", is_error: false, result: "끝", modelUsage: { [`claude-${model}-5-5`]: { inputTokens: 1000, outputTokens: 100 } }, total_cost_usd: 0, duration_ms: 3 };
    if (kind === "diag") res.structured_output = sc.diag;
    else if (kind === "review") res.structured_output = pick(sc.review);
    else if (kind === "repro" || kind === "fix") {
      // 진짜 CLI 처럼: -p 에서 쓰기 허락 모드가 없으면 Write·Edit 는 거부된다(파일을 쓰지 않는다)
      if (args[args.indexOf("--permission-mode") + 1] !== "acceptEdits" || args.indexOf("--permission-mode") < 0) {
        process.stdout.write(JSON.stringify({ ...res, result: "쓰기 권한 요청이 승인되지 않아 파일을 만들지 못했다", permission_denials: [{ tool_name: "Write" }] }));
        return;
      }
      const step = pick(sc[kind]) ?? {};
      for (const [rel, text] of Object.entries(step.files ?? {})) { fs.mkdirSync(require("node:path").dirname(rel), { recursive: true }); fs.writeFileSync(rel, text); }
      for (const rel of step.remove ?? []) fs.rmSync(rel, { force: true });
      if (step.fail) { process.stdout.write(JSON.stringify({ ...res, is_error: true, subtype: "error_during_execution", result: "가짜 실패" })); return; }
    } else res.result = "가짜 요약 문장";
    process.stdout.write(JSON.stringify(res));
    return;
  }
  if (mode === "fail") {
    process.stderr.write("가짜 실패: 인증 오류 흉내\n");
    process.exit(1);
  }
  if (mode === "auth") { // 실제 CLI 가 로그인 만료 때 내는 모양(JSON 결과의 오류)
    process.stdout.write(JSON.stringify({ type: "result", subtype: "success", is_error: true, result: "Failed to authenticate. API Error: 401 OAuth token has expired. Please run /login" }));
    return;
  }
  if (mode === "limit") {
    process.stdout.write(JSON.stringify({ type: "result", subtype: "success", is_error: true, result: "Claude AI usage limit reached|1760000000" }));
    return;
  }
  // diag · diag-text · diag-bad (1a): 진단 프롬프트면 '<log>.answer.json' 을 구조화 출력으로(diag-text 는 본문 속 코드 울타리로,
  // diag-bad 는 형식에 안 맞는 글로) 답한다. 그 밖(요약)은 짧은 글.
  if (/^diag/.test(mode) && /정해진 JSON 으로만 답한다/.test(input)) {
    let ans = {};
    try { ans = JSON.parse(fs.readFileSync(`${log}.answer.json`, "utf8")); } catch { /* 빈 답 */ }
    const res = { type: "result", subtype: "success", is_error: false, modelUsage: { "claude-sonnet-5-5": { inputTokens: 900, outputTokens: 120 } }, total_cost_usd: 0, duration_ms: 5 };
    if (mode === "diag") Object.assign(res, { result: "진단을 마쳤다", structured_output: ans });
    else if (mode === "diag-text") Object.assign(res, { result: "결과:\n```json\n" + JSON.stringify(ans) + "\n```" });
    else Object.assign(res, { result: "원인을 모르겠다" });
    process.stdout.write(JSON.stringify(res));
    return;
  }
  const model = mode === "fable" ? "claude-fable-5-1" : "claude-haiku-4-5-20251001";
  const usage = mode === "tokens"
    ? { inputTokens: 100, outputTokens: 50, cacheReadInputTokens: 1000, cacheCreationInputTokens: 200, costUSD: 0.0012 }
    : { inputTokens: 1, outputTokens: 1 };
  const body = JSON.stringify({
    type: "result", subtype: "success", is_error: false, result: mode === "split" ? "한글이 조각 경계에 걸린다" : "가짜 요약 문장",
    modelUsage: { [model]: usage }, total_cost_usd: mode === "tokens" ? 0.0012 : 0, duration_ms: 1,
  });
  if (mode === "split") { // '글' 의 3바이트 한가운데서 끊어 두 번에 나눠 보낸다
    const buf = Buffer.from(body);
    const cut = buf.indexOf(Buffer.from("글")) + 1;
    fs.writeSync(1, buf.subarray(0, cut));
    setTimeout(() => fs.writeSync(1, buf.subarray(cut)), 150);
    return;
  }
  if (mode === "slow") { setTimeout(() => process.stdout.write(body), 1500); return; }
  process.stdout.write(body);
};
