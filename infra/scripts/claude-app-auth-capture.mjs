#!/usr/bin/env node
/**
 * claude-app-auth-capture.mjs — claude.ai 로그인 세션 1회 캡처
 *
 * 주인님이 직접 1회 실행 (headed 모드). Playwright 브라우저가 열리면
 * 평소대로 claude.ai 로그인. 자비스가 storageState를 디스크에 저장.
 * 이후 export-runner는 이 state를 재사용하여 자동 로그인.
 *
 * 쿠키 만료 시 (보통 2~3개월) 다시 1회 실행 필요.
 *
 * Usage:
 *   node claude-app-auth-capture.mjs
 */

import playwright from '/Users/ramsbaby/jarvis/infra/discord/node_modules/playwright/index.js';
const { chromium } = playwright;
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';

const HOME = homedir();
const STATE_FILE = join(HOME, 'jarvis/runtime/state/claude-app-auth.json');
const POLL_INTERVAL_MS = 3000;
const MAX_WAIT_MS = 10 * 60 * 1000; // 10분 한도

async function main() {
  console.log('🔐 claude.ai 로그인 세션 캡처 시작');
  console.log('   Chromium 창 열림 → 평소대로 로그인하시면 자비스가 자동 감지·저장');
  console.log('   최대 대기 10분. 로그인 완료 시 즉시 자동 종료.');

  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();
  await page.goto('https://claude.ai/login');

  const start = Date.now();
  let saved = false;
  while (Date.now() - start < MAX_WAIT_MS) {
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
    let cookies;
    try { cookies = await context.cookies('https://claude.ai'); } catch { break; }
    // 진짜 로그인 판정: claude.ai의 sessionKey 쿠키 존재
    const hasSession = cookies.some((c) => c.name === 'sessionKey' && c.value?.length > 20);
    if (hasSession) {
      await page.waitForTimeout(2000); // 추가 쿠키 set-cookie 안정화
      mkdirSync(dirname(STATE_FILE), { recursive: true });
      await context.storageState({ path: STATE_FILE });
      const url = await page.url().catch(() => '?');
      console.log(`\n✅ 세션 저장 완료: ${STATE_FILE}`);
      console.log(`   감지 URL: ${url}`);
      console.log(`   claude.ai 쿠키 개수: ${cookies.length} (sessionKey 확인됨)`);
      saved = true;
      break;
    }
    process.stdout.write('.');
  }

  if (!saved) {
    console.error('\n❌ 10분 내 로그인 완료 안 됨. 다시 실행해주세요.');
  }
  await browser.close();
  process.exit(saved ? 0 : 1);
}

main().catch((e) => {
  console.error('❌ 에러:', e.message);
  process.exit(1);
});
