#!/usr/bin/env node
/**
 * preply-vision-check.mjs — 교재 스크린샷을 "보람 선생님 눈"으로 검토하는 2층 렌더 아이(LLM 비전).
 *
 * 왜 (2026-07-06):
 *  - 1층(preply-render-check.mjs)은 정답 노출·A4·글씨를 DOM 상태로 기계 판정한다.
 *  - 2층은 스크린샷을 Claude 비전에게 보람 페르소나로 검토시켜, 기계가 못 잡는 주관적 품질
 *    (레이아웃 답답함·질문/정답 텍스트 중복·영어뜻 병기·전반 완성도)까지 전송 전에 잡는다.
 *  - 블랙리스트(소스 grep)가 아니라 "보람이 볼 화면을 자비스가 먼저 본다" → 새 불만도 예방.
 *
 * 안전: API 실패·rate limit(429)·토큰 만료 시 exit 1(비차단). 1층·verify가 이미 방어하므로
 *       비전 실패가 전송을 막지 않는다(가용성 우선). verdict=FAIL일 때만 exit 2(전송 차단).
 *
 * 사용법: node preply-vision-check.mjs <html>
 * 출력: JSON { verdict, issues[] }  · exit 0=PASS / 2=FAIL / 1=검사불가(비차단)
 */
import { readFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import os from 'node:os';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const HOME = os.homedir();
const TOKEN_PATH = path.join(HOME, '.claude-bot', '.long-lived-token');
const MODEL = 'claude-sonnet-5';

const PERSONA = `당신은 Preply 한국어 강사 '보람'입니다. 학생에게 곧 보낼 한국어 교재의 스크린샷을 검토합니다.
학생 눈으로 아래를 엄격히 점검하고, 문제를 빠짐없이 찾으세요. 당신은 이런 실수에 매우 예민합니다:

1. [치명] 퀴즈·문제에 정답이 클릭 전부터 보이는가? 정답 표시(✓·"정답")가 화면에 노출됐는가?
2. [치명] 퀴즈 보기(선택지)에 영어 뜻이 병기돼 정답을 유추할 수 있는가?
3. [치명] 질문과 정답 선택지에 똑같은 한글이 들어가 답이 뻔한가? 정답이 두 개로 보이는가?
4. 단어·예문에 영어 뜻이 빠졌는가? (단어카드엔 영어 뜻이 있어야 함)
5. 문화 비교에 영어 설명이 있는가?
6. 글씨가 너무 작아 답답한가? 요약본/숙제라면 A4 한 장에 꽉 찼는가(넘치거나 빈 공간이 많은가)?
7. 전반적으로 학생에게 자신 있게 보낼 수 있는 완성 상태인가?

문제가 하나도 없으면 verdict를 "PASS"로. 하나라도 있으면 "FAIL"로 하고 issues에 구체적으로 적으세요.
반드시 아래 JSON만 출력하세요(설명 문장 금지):
{"verdict":"PASS"|"FAIL","issues":[{"level":"FAIL"|"WARN","msg":"무엇이 문제인지 한 문장"}]}`;

function fail(msg, code = 1) { console.error(msg); process.exit(code); }

async function callVision(imgB64) {
  if (!existsSync(TOKEN_PATH)) return { skip: '격리 토큰 없음' };
  const token = readFileSync(TOKEN_PATH, 'utf8').trim();
  const body = {
    model: MODEL,
    max_tokens: 1024,
    messages: [{
      role: 'user',
      content: [
        { type: 'image', source: { type: 'base64', media_type: 'image/png', data: imgB64 } },
        { type: 'text', text: PERSONA },
      ],
    }],
  };
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
          authorization: `Bearer ${token}`,
          'anthropic-beta': 'oauth-2025-04-20',
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
        },
        body: JSON.stringify(body),
      });
      if (res.status === 429 || res.status >= 500) {
        await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
        continue;
      }
      if (!res.ok) return { skip: `API ${res.status}` };
      const data = await res.json();
      const text = (data.content || []).filter((c) => c.type === 'text').map((c) => c.text).join('');
      return { text };
    } catch (e) {
      await new Promise((r) => setTimeout(r, 1500 * (attempt + 1)));
    }
  }
  return { skip: 'rate limit/네트워크 (재시도 소진)' };
}

async function main() {
  const html = process.argv[2];
  if (!html) fail('사용법: preply-vision-check.mjs <html>');
  // 1층 렌더 체커로 스크린샷 확보 (exit code 무관하게 stdout 획득)
  const r = spawnSync('node', [path.join(__dirname, 'preply-render-check.mjs'), html], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  let shot;
  try { shot = JSON.parse(r.stdout).screenshot; } catch { fail('스크린샷 생성 실패 (렌더 체커 출력 파싱 불가) — 비전 검사 건너뜀', 1); }
  if (!shot || !existsSync(shot)) fail('스크린샷 파일 없음 — 비전 검사 건너뜀', 1);

  const imgB64 = readFileSync(shot).toString('base64');
  // API 이미지 한도(~5MB base64) 초과 시 비차단 스킵
  if (imgB64.length > 5 * 1024 * 1024) { console.log(JSON.stringify({ verdict: 'SKIP', issues: [{ level: 'WARN', msg: '스크린샷이 커서 비전 검사 생략 (1층 렌더 검사로 대체)' }] })); process.exit(1); }

  const out = await callVision(imgB64);
  if (out.skip) { console.log(JSON.stringify({ verdict: 'SKIP', reason: out.skip, issues: [] })); process.exit(1); }

  // 모델 응답에서 JSON 추출
  let parsed;
  try {
    const m = out.text.match(/\{[\s\S]*\}/);
    parsed = JSON.parse(m ? m[0] : out.text);
  } catch { console.log(JSON.stringify({ verdict: 'SKIP', reason: '응답 JSON 파싱 실패', raw: (out.text || '').slice(0, 200), issues: [] })); process.exit(1); }

  const issues = Array.isArray(parsed.issues) ? parsed.issues : [];
  const isFail = parsed.verdict === 'FAIL' || issues.some((i) => i.level === 'FAIL');
  console.log(JSON.stringify({ verdict: isFail ? 'FAIL' : 'PASS', issues }, null, 1));
  process.exit(isFail ? 2 : 0);
}

main();
