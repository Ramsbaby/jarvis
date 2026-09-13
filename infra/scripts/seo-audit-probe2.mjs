#!/usr/bin/env node
/** 떠 있는 브라우저에서 페이지 전체 텍스트를 길게 뽑거나 특정 요소를 클릭한다. */
import { chromium } from '/Users/ramsbaby/projects/ramsbaby-blog-starter/node_modules/playwright/index.mjs';

const [, , cmd, arg, arg2] = process.argv;
const browser = await chromium.connectOverCDP('http://localhost:9222');
const ctx = browser.contexts()[0];
const pages = ctx.pages();
const page = pages[pages.length - 1];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  if (cmd === 'fulltext') {
    const start = parseInt(arg || '0', 10);
    const len = parseInt(arg2 || '4000', 10);
    const t = await page.evaluate(() => document.body.innerText);
    console.log(`[전체 ${t.length}자 중 ${start}~${start + len}]`);
    console.log(t.slice(start, start + len));
  } else if (cmd === 'table') {
    // 표 형태 데이터만 추출
    const rows = await page.evaluate(() => {
      const out = [];
      document.querySelectorAll('table tr, [role="row"]').forEach((r) => {
        const cells = [...r.querySelectorAll('td,th,[role="cell"],[role="columnheader"]')]
          .map((c) => c.innerText.trim())
          .filter(Boolean);
        if (cells.length) out.push(cells.join(' | '));
      });
      return out;
    });
    console.log(rows.slice(0, 60).join('\n'));
  } else if (cmd === 'click') {
    await page.getByText(arg, { exact: false }).first().click({ timeout: 15000 });
    await sleep(3000);
    console.log(`클릭: ${arg}\n현재 URL: ${page.url()}`);
  } else if (cmd === 'goto') {
    await page.goto(arg, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await sleep(3500);
    console.log(`URL: ${page.url()}\n제목: ${await page.title()}`);
  }
} finally {
  await browser.close();
}
