#!/usr/bin/env node
/**
 * seo-request-indexing.mjs — Search Console URL 검사에서 '색인 생성 요청'을 누른다.
 * 구글 일일 할당량(속성당 약 10건)이 있으므로 목록을 짧게 유지할 것.
 *
 * 사용: node seo-request-indexing.mjs <url> [<url> ...]
 */
import { chromium } from '/Users/ramsbaby/projects/ramsbaby-blog-starter/node_modules/playwright/index.mjs';

const PROP = 'https://search.google.com/search-console?resource_id=https%3A%2F%2Fblog.ramsbaby.com%2F';
const urls = process.argv.slice(2);
const browser = await chromium.connectOverCDP('http://localhost:9222');
const ctx = browser.contexts()[0];
const page = ctx.pages()[ctx.pages().length - 1];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const bodyText = () => page.evaluate(() => document.body.innerText);

const waitFor = async (re, maxSec) => {
  for (let i = 0; i < maxSec / 3; i++) {
    await sleep(3000);
    if (re.test(await bodyText())) return true;
  }
  return false;
};

let ok = 0, quota = false;

for (const [i, url] of urls.entries()) {
  if (quota) { console.log(`[${i + 1}/${urls.length}] 건너뜀 (할당량 소진): ${url}`); continue; }
  try {
    await page.goto(PROP, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await sleep(3500);

    const box = page.locator('input[aria-label*="검사"], input[type="text"]').first();
    await box.click({ timeout: 20000 });
    await box.press('Control+a').catch(() => {});
    await box.pressSequentially(url, { delay: 15 });
    await page.keyboard.press('Enter');

    const loaded = await waitFor(/URL이 Google에|색인에 등록됨|색인이 생성되지 않음/, 75);
    if (!loaded) { console.log(`[${i + 1}/${urls.length}] ⚠️ 검사 결과 미표시: ${url}`); continue; }

    const req = page.getByRole('button', { name: /색인 생성 요청|REQUEST INDEXING/i }).first();
    if (!(await req.count().catch(() => 0))) {
      console.log(`[${i + 1}/${urls.length}] ⚠️ 요청 버튼 없음(이미 색인?): ${url}`);
      continue;
    }
    await req.click({ timeout: 20000 });

    // 처리 대기 (테스트 진행 → 대기열 추가)
    const done = await waitFor(/색인 생성이 요청됨|대기열에 추가|이미 대기열|할당량|quota/i, 130);
    const t = await bodyText();
    if (/할당량|quota/i.test(t)) {
      quota = true;
      console.log(`[${i + 1}/${urls.length}] 🛑 일일 할당량 소진: ${url}`);
    } else if (done) {
      ok++;
      console.log(`[${i + 1}/${urls.length}] ✅ 색인 요청됨: ${url}`);
    } else {
      console.log(`[${i + 1}/${urls.length}] ⚠️ 확인 문구 미검출: ${url}`);
    }

    const close = page.getByRole('button', { name: /확인|닫기|OK|GOT IT/i }).first();
    if (await close.count().catch(() => 0)) await close.click({ timeout: 6000 }).catch(() => {});
    await sleep(2500);
  } catch (e) {
    console.log(`[${i + 1}/${urls.length}] ❌ 실패(${e.message.slice(0, 60)}): ${url}`);
  }
}

console.log(`\n=== 요약: 요청 성공 ${ok}건 / 시도 ${urls.length}건 ${quota ? '(할당량 소진으로 중단)' : ''} ===`);
await browser.close();
