#!/usr/bin/env node
/**
 * seo-audit-probe.mjs — 떠 있는 유인 브라우저(seo-audit-browser.mjs)에 붙어 조사한다.
 *
 * 사용:
 *   node seo-audit-probe.mjs state                 # 현재 탭/로그인 상태
 *   node seo-audit-probe.mjs goto <url>            # 이동 후 제목 보고
 *   node seo-audit-probe.mjs shot <파일경로>        # 스크린샷
 *   node seo-audit-probe.mjs siteindex <도메인>     # 구글 site: 색인 수 조회
 *   node seo-audit-probe.mjs text                  # 현재 페이지 본문 텍스트 발췌
 */
import { chromium } from '/Users/ramsbaby/projects/ramsbaby-blog-starter/node_modules/playwright/index.mjs';

const [, , cmd, arg] = process.argv;
const browser = await chromium.connectOverCDP('http://localhost:9222');
const ctx = browser.contexts()[0];
const pages = ctx.pages();
const page = pages[pages.length - 1];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  if (cmd === 'state') {
    console.log(`탭 수: ${pages.length}`);
    for (const p of pages) console.log(`  - ${p.url().slice(0, 110)}  | ${(await p.title()).slice(0, 70)}`);
  } else if (cmd === 'goto') {
    await page.goto(arg, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await sleep(2500);
    console.log(`URL  : ${page.url()}`);
    console.log(`제목 : ${await page.title()}`);
  } else if (cmd === 'shot') {
    await page.screenshot({ path: arg, fullPage: false });
    console.log(`저장: ${arg}`);
  } else if (cmd === 'siteindex') {
    await page.goto(`https://www.google.com/search?q=site:${encodeURIComponent(arg)}&num=100&hl=ko`, {
      waitUntil: 'domcontentloaded',
      timeout: 60000,
    });
    await sleep(3500);
    const info = await page.evaluate(() => {
      const el = document.querySelector('#result-stats');
      const results = document.querySelectorAll('#search a[href^="http"] h3');
      const body = document.body.innerText.slice(0, 900);
      return { stats: el ? el.innerText : null, count: results.length, body };
    });
    console.log(`결과 통계줄: ${info.stats || '(없음)'}`);
    console.log(`페이지 내 결과 링크 수: ${info.count}`);
    console.log(`--- 본문 발췌 ---\n${info.body}`);
  } else if (cmd === 'text') {
    const t = await page.evaluate(() => document.body.innerText.slice(0, 3000));
    console.log(t);
  } else {
    console.log('알 수 없는 명령:', cmd);
  }
} finally {
  await browser.close(); // CDP 연결만 끊음. 실제 창은 유지됨.
}
