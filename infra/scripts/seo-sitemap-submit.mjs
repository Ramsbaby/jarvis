#!/usr/bin/env node
/**
 * seo-sitemap-submit.mjs — Search Console 사이트맵 제출 (검증 포함)
 * 사용: node seo-sitemap-submit.mjs sitemap-0.xml
 *       node seo-sitemap-submit.mjs --list
 */
import { chromium } from '/Users/ramsbaby/projects/ramsbaby-blog-starter/node_modules/playwright/index.mjs';

const PROP = 'https%3A%2F%2Fblog.ramsbaby.com%2F';
const target = process.argv[2];
const browser = await chromium.connectOverCDP('http://localhost:9222');
const ctx = browser.contexts()[0];
const page = ctx.pages()[ctx.pages().length - 1];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const rows = async () => {
  const r = await page.evaluate(() => {
    const out = [];
    document.querySelectorAll('table tr, [role="row"]').forEach((tr) => {
      const c = [...tr.querySelectorAll('td,th,[role="cell"],[role="columnheader"]')]
        .map((x) => x.innerText.trim()).filter(Boolean);
      if (c.length) out.push(c.join(' | '));
    });
    return out;
  });
  return r.slice(0, 20);
};

try {
  await page.goto(`https://search.google.com/search-console/sitemaps?resource_id=${PROP}`, {
    waitUntil: 'domcontentloaded', timeout: 60000,
  });
  await sleep(5000);

  const before = await rows();
  console.log(`제출 전 행 수: ${before.length - 1}`);

  if (target && target !== '--list') {
    const box = page.locator('input[aria-label*="사이트맵"]').first();
    await box.click({ timeout: 15000 });
    await box.press('Control+a').catch(() => {});
    await box.pressSequentially(target, { delay: 60 });
    await sleep(1200);

    const val = await box.inputValue();
    console.log(`입력값 확인: "${val}"`);
    if (val !== target) throw new Error(`입력 불일치: "${val}"`);

    const btn = page.getByRole('button', { name: /^제출$/ }).first();
    const disabled = await btn.isDisabled().catch(() => null);
    console.log(`제출 버튼 비활성 여부: ${disabled}`);
    await btn.click({ timeout: 15000 });

    // 확인 다이얼로그 대기
    await sleep(7000);
    const dlg = await page.evaluate(() => {
      const d = document.querySelector('[role="dialog"], [role="alertdialog"]');
      return d ? d.innerText.slice(0, 400) : null;
    });
    console.log(`다이얼로그: ${dlg ? dlg.replace(/\n+/g, ' / ') : '(없음)'}`);

    const ok = page.getByRole('button', { name: /확인|닫기|OK|GOT IT|got it/i }).first();
    if (await ok.count().catch(() => 0)) await ok.click({ timeout: 8000 }).catch(() => {});
    await sleep(6000);
  }

  await page.goto(`https://search.google.com/search-console/sitemaps?resource_id=${PROP}`, {
    waitUntil: 'domcontentloaded', timeout: 60000,
  });
  await sleep(6000);
  const after = await rows();
  console.log('--- 제출 후 현황 ---');
  console.log(after.join('\n'));
} catch (e) {
  console.error(`실패: ${e.message}`);
} finally {
  await browser.close();
}
