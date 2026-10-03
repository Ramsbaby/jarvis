// fake-claude.cjs — 시험용 가짜 claude. 실제 모델을 부르지 않는다.
// helpers.fakeClaude() 가 만든 실행 파일(#!node, 셸 없음)이 require 해서 부른다 — 셸이 끼면 PWD·SHLVL 이 더해져 환경 시험이 흐려진다.
// 받은 인자·환경·입력·작업 폴더를 log 에 적고, mode 에 따라 답한다.
//   ok · fable · fail · split (0a) / tokens: 실제 모양의 usage·비용 / auth: 로그인 만료 문구 / limit: 사용량 한도(429) 문구 / slow: 1.5초 뒤 답
const fs = require("node:fs");

module.exports = function fake(log, mode) {
  const env = { ...process.env };
  const input = fs.readFileSync(0, "utf8");
  fs.appendFileSync(log, `${JSON.stringify({ args: process.argv.slice(2), env, cwd: process.cwd(), input })}\n`);
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
