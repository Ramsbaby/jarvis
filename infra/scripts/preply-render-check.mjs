#!/usr/bin/env node
/**
 * preply-render-check.mjs — 교재를 실제 브라우저로 렌더해 "보람님이 보는 화면 상태"를 검사한다.
 *
 * 왜 만들었나 (2026-07-06):
 *  - verify(preply-student.sh)는 HTML *소스*를 grep한다. 그런데 보람님 불만은 전부 "화면에 보이는 것".
 *  - 정답 메커니즘 클래스가 answer-box/ans-reveal/answer-reveal로 제각각이라 소스 검사가 6일간 뚫렸다.
 *  - 렌더 아이는 클래스명과 무관하게 "정답이 클릭 전에 실제로 화면에 보이는가"를 렌더 상태로 판정한다.
 *    → 새 클래스명·새 구조가 나와도 "화면에 정답이 보이면" 잡힌다 (블랙리스트 → 렌더 상태 검사).
 *
 * 사용법: node preply-render-check.mjs <html>   (FAIL 있으면 exit 2 → send 게이트 차단)
 * 출력: JSON { file, fail, warn, issues[], screenshot }
 */
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import path from 'path';
import fs from 'fs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.join(__dirname, '..', 'discord', 'package.json'));
const { chromium } = require('playwright');

async function main() {
  const src = process.argv[2];
  if (!src) { console.error('사용법: preply-render-check.mjs <html>'); process.exit(1); }
  const abs = path.resolve(src.replace(/^~/, process.env.HOME));
  if (!fs.existsSync(abs)) { console.error('파일 없음: ' + abs); process.exit(1); }
  const base = path.basename(abs);
  const isHW = /요약본|숙제|정답지|summary|homework|hw/i.test(base);

  const browser = await chromium.launch();
  const issues = [];
  try {
    const page = await browser.newPage({ viewport: { width: 900, height: 1273 } });
    await page.goto('file://' + abs, { waitUntil: 'load', timeout: 30000 });
    await page.waitForTimeout(500);

    // 1) 정답 실제 노출 — 클래스명 무관, 렌더 visible + "정답" 텍스트 기준.
    //    수업교재/정답지 구분: 정답지(answer sheet)는 정답이 보이는 게 정상이라 제외.
    const isAnswerSheet = /정답지|answer[-_]?key|answer[-_]?sheet/i.test(base);
    if (!isAnswerSheet) {
      const exposed = await page.evaluate(() => {
        const sels = '.answer-box,.ans-reveal,.answer-reveal,.answer,[class*="answer"],[class*="reveal"],[id*="ans-"]';
        const out = [];
        document.querySelectorAll(sels).forEach((el) => {
          const s = window.getComputedStyle(el);
          const visible = el.offsetParent !== null && s.display !== 'none'
            && s.visibility !== 'hidden' && parseFloat(s.opacity || '1') > 0.1;
          const txt = (el.textContent || '').trim();
          if (visible && /정답|answer/i.test(txt) && txt.length > 3) out.push(txt.replace(/\s+/g, ' ').slice(0, 45));
        });
        return out;
      });
      if (exposed.length) {
        issues.push({ level: 'FAIL', msg: `정답이 클릭 전에 화면에 노출 ${exposed.length}곳: "${exposed[0]}…" (보람님이 보는 실제 화면 — 클래스 무관 렌더 판정)` });
      }
    }

    // 1b) [2026-07-10 보강] 옵션 버튼 라벨에 체크마크(✓✔✅) 사전 노출 — 렌더 아이 빈틈(2026-07-08 사고 벡터).
    //     정답 옵션 버튼에 ✓가 클릭 전부터 보이면 정답이 노출된다. 이 벡터는 answer 계열 선택자·"정답"
    //     텍스트에 안 걸려 기존 (1) 검사가 놓쳤다. 상호작용 옵션 버튼의 렌더 텍스트를 직접 검사한다.
    if (!isAnswerSheet) {
      const markedBtns = await page.evaluate(() => {
        const sels = 'button[onclick*="checkDrill"],button[onclick*="checkQuiz"],.drill-btn,.quiz-opt,.quiz-btn,.opt-btn';
        const marks = ['✓', '✔', '✅', '✔️'];
        const out = [];
        document.querySelectorAll(sels).forEach((el) => {
          const s = window.getComputedStyle(el);
          const visible = el.offsetParent !== null && s.display !== 'none'
            && s.visibility !== 'hidden' && parseFloat(s.opacity || '1') > 0.1;
          const txt = (el.textContent || '').trim();
          if (visible && marks.some((m) => txt.includes(m))) out.push(txt.replace(/\s+/g, ' ').slice(0, 45));
        });
        return out;
      });
      if (markedBtns.length) {
        issues.push({ level: 'FAIL', msg: `옵션 버튼에 정답 표시(✓) 사전 노출 ${markedBtns.length}곳: "${markedBtns[0]}" (클릭 전부터 정답이 보임 — 2026-07-08 사고 벡터)` });
      }
    }

    // 2) 요약본/숙제 = A4 1장 밀도 (넘침·여백 둘 다 불만).
    if (isHW) {
      await page.emulateMedia({ media: 'print' });
      const h = await page.evaluate(() => document.documentElement.scrollHeight);
      const A4 = 1123; // A4 세로 @96dpi 근사
      const pages = h / A4;
      if (pages > 1.15) issues.push({ level: 'WARN', msg: `A4 ${pages.toFixed(1)}장 — 1장 초과, 잘림 위험 (보람님 "1장에 꽉 차게")` });
      else if (pages < 0.72) issues.push({ level: 'WARN', msg: `A4 ${pages.toFixed(1)}장 — 여백 과다 (보람님 "꽉 차게 답답")` });
      await page.emulateMedia({ media: 'screen' });
    }

    // 3) 본문 글씨 너무 작음 (보람님 "글씨 크게" 반복) — 본문 텍스트 중 12px 미만 비율.
    const tinyRatio = await page.evaluate(() => {
      const els = [...document.querySelectorAll('p,li,td,div,span')].filter((e) => (e.textContent || '').trim().length > 8 && e.children.length === 0);
      if (!els.length) return 0;
      const tiny = els.filter((e) => parseFloat(window.getComputedStyle(e).fontSize) < 12).length;
      return tiny / els.length;
    });
    if (tinyRatio > 0.35) issues.push({ level: 'WARN', msg: `본문 ${Math.round(tinyRatio * 100)}%가 12px 미만 작은 글씨 (보람님 "글씨 크게")` });

    // 증거 스크린샷 (2단계 비전 검토에도 재사용)
    const shot = '/tmp/preply-render-' + base.replace(/\.html$/, '') + '.png';
    await page.screenshot({ path: shot, fullPage: true });

    const fail = issues.filter((i) => i.level === 'FAIL').length;
    const warn = issues.filter((i) => i.level === 'WARN').length;
    console.log(JSON.stringify({ file: base, fail, warn, issues, screenshot: shot }, null, 1));
    await browser.close();
    process.exit(fail > 0 ? 2 : 0);
  } catch (e) {
    console.error('렌더 검사 실패: ' + e.message);
    await browser.close();
    process.exit(1);
  }
}
main();
