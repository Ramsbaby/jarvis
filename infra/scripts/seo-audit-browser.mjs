#!/usr/bin/env node
/**
 * seo-audit-browser.mjs — SEO 진단용 유인(有人) 브라우저 런처
 *
 * 주인님이 직접 로그인하셔야 하는 콘솔(Google Search Console 등)을 진단할 때 사용한다.
 * 화면이 보이는 크로미움을 전용 프로필로 띄우고 CDP 포트를 열어,
 * 이후 자비스가 별도 프로세스에서 같은 창에 붙어 조작·계측할 수 있게 한다.
 *
 * 사용:
 *   node seo-audit-browser.mjs            # 브라우저 띄우고 대기 (백그라운드 실행)
 *
 * 붙는 쪽:
 *   const b = await chromium.connectOverCDP('http://localhost:9222')
 *
 * 프로필은 ~/.jarvis/seo-audit-profile 에 남으므로 로그인 세션이 재실행 후에도 유지된다.
 */
import { chromium } from '/Users/ramsbaby/projects/ramsbaby-blog-starter/node_modules/playwright/index.mjs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { mkdirSync } from 'node:fs';

const PROFILE = join(homedir(), '.jarvis', 'seo-audit-profile');
const PORT = 9222;
const START_URL = 'https://search.google.com/search-console';

mkdirSync(PROFILE, { recursive: true });

const ctx = await chromium.launchPersistentContext(PROFILE, {
  headless: false,
  viewport: null,
  locale: 'ko-KR',
  timezoneId: 'Asia/Seoul',
  args: [
    `--remote-debugging-port=${PORT}`,
    '--start-maximized',
    '--disable-blink-features=AutomationControlled',
  ],
});

const page = ctx.pages()[0] || (await ctx.newPage());
await page.goto(START_URL, { waitUntil: 'domcontentloaded', timeout: 60000 }).catch((e) => {
  console.error(`[seo-browser] 초기 이동 실패(무시하고 대기): ${e.message}`);
});

console.log(`[seo-browser] READY  프로필=${PROFILE}  CDP=http://localhost:${PORT}`);
console.log('[seo-browser] 주인님 로그인을 기다립니다. 창을 닫으면 종료됩니다.');

ctx.on('close', () => {
  console.log('[seo-browser] 브라우저가 닫혔습니다. 종료합니다.');
  process.exit(0);
});

// 창이 닫힐 때까지 유지
await new Promise(() => {});
