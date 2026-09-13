#!/usr/bin/env node
/** Search Console 상단 'URL 검사' 창에 주소를 넣고 결과를 읽는다. */
import { chromium } from '/Users/ramsbaby/projects/ramsbaby-blog-starter/node_modules/playwright/index.mjs';

const target = process.argv[2];
const browser = await chromium.connectOverCDP('http://localhost:9222');
const ctx = browser.contexts()[0];
const page = ctx.pages()[ctx.pages().length - 1];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  await page.goto(
    'https://search.google.com/search-console?resource_id=https%3A%2F%2Fblog.ramsbaby.com%2F',
    { waitUntil: 'domcontentloaded', timeout: 60000 }
  );
  await sleep(4000);

  // 상단 검사 입력창 찾기 (placeholder 또는 aria-label 기반)
  const box = page.locator(
    'input[aria-label*="검사"], input[placeholder*="검사"], input[placeholder*="URL"], input[type="text"]'
  ).first();
  await box.click({ timeout: 20000 });
  await box.fill(target);
  await page.keyboard.press('Enter');
  console.log(`검사 요청: ${target}`);

  // 결과 로딩 대기 (검사에 시간이 걸린다)
  for (let i = 0; i < 20; i++) {
    await sleep(3000);
    const t = await page.evaluate(() => document.body.innerText);
    if (/색인이 생성되지 않음|색인에 등록됨|URL이 Google에|데이터를 가져오는 중이 아님|검색됨/.test(t)) {
      const idx = t.search(/URL이 Google에|색인이 생성되지 않음|색인에 등록됨/);
      console.log('--- 검사 결과 ---');
      console.log(t.slice(Math.max(0, idx - 100), idx + 1200));
      break;
    }
    if (i === 19) console.log('(20회 대기해도 결과 미표시 — 화면 확인 필요)');
  }
} catch (e) {
  console.error(`실패: ${e.message}`);
} finally {
  await browser.close();
}
