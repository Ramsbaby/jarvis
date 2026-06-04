#!/usr/bin/env node
/**
 * claude-app-export-runner.mjs — claude.ai 데이터 export 자동 실행
 *
 * 매일 11:00 KST 크론 실행. claude.ai 데이터 설정 페이지 진입 후:
 *   - Download 버튼 보이면 클릭 → zip ~/Downloads 저장 → 기존 ingest 트리거
 *   - Request 버튼 보이면 클릭 → 다음날 자동 재체크
 *   - Pending 상태면 skip
 *
 * 쿠키 만료 시 자비스 위키 facts에 alert 적재 + Discord 알림.
 *
 * Usage:
 *   node claude-app-export-runner.mjs                 # 일반 자동 실행
 *   DEBUG=1 node claude-app-export-runner.mjs         # headed + 디버그
 *
 * Exit: 항상 0.
 * Log: ~/jarvis/runtime/logs/claude-app-export.log
 */

import playwright from '/Users/ramsbaby/jarvis/infra/discord/node_modules/playwright/index.js';
const { chromium } = playwright;
import {
  readFileSync, existsSync, mkdirSync, writeFileSync,
  appendFileSync, statSync, readdirSync,
} from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { spawn } from 'node:child_process';

const HOME           = homedir();
const STATE_FILE     = join(HOME, 'jarvis/runtime/state/claude-app-auth.json');
const DOWNLOADS_DIR  = join(HOME, 'Downloads');
const LOG_FILE       = join(HOME, 'jarvis/runtime/logs/claude-app-export.log');
const STATUS_FILE    = join(HOME, 'jarvis/runtime/state/claude-app-export-status.json');
const SETTINGS_URL   = 'https://claude.ai/settings/data-privacy-controls';
const TIMEOUT_MS     = 60_000;
const HEADLESS       = process.env.DEBUG !== '1';

function kstTimestamp() {
  return new Date().toLocaleString('sv-SE', { timeZone: 'Asia/Seoul' });
}

function log(level, msg, meta = {}) {
  const ts = kstTimestamp();
  const metaStr = Object.keys(meta).length ? ' ' + JSON.stringify(meta) : '';
  const line = `[${ts} KST] [claude-app-export] [${level.toUpperCase()}] ${msg}${metaStr}\n`;
  try {
    mkdirSync(dirname(LOG_FILE), { recursive: true });
    appendFileSync(LOG_FILE, line);
  } catch {}
  if (level === 'error' || process.env.DEBUG) process.stderr.write(line);
}

function saveStatus(status) {
  try {
    mkdirSync(dirname(STATUS_FILE), { recursive: true });
    writeFileSync(STATUS_FILE, JSON.stringify({ ...status, ts: kstTimestamp() }, null, 2));
  } catch {}
}

function triggerIngest(zipPath) {
  // 비동기 fire-and-forget
  const child = spawn(
    process.execPath,
    [join(HOME, 'jarvis/infra/scripts/wiki-ingest-claude-app.mjs'), zipPath],
    { detached: true, stdio: 'ignore' }
  );
  child.unref();
  log('info', 'ingest triggered', { zipPath });
}

async function findButtonByText(page, candidateTexts) {
  for (const text of candidateTexts) {
    const btn = page.locator(`button:has-text("${text}"), a:has-text("${text}")`).first();
    try {
      if (await btn.isVisible({ timeout: 2000 })) {
        return { button: btn, text };
      }
    } catch {}
  }
  return null;
}

async function main() {
  if (!existsSync(STATE_FILE)) {
    log('error', 'no auth state — run claude-app-auth-capture.mjs first', { STATE_FILE });
    saveStatus({ status: 'no-auth', error: 'storage state missing' });
    console.log(JSON.stringify({ status: 'no-auth' }));
    return;
  }

  log('info', 'start');
  const browser = await chromium.launch({ headless: HEADLESS });
  const context = await browser.newContext({
    storageState: STATE_FILE,
    viewport: { width: 1280, height: 800 },
    acceptDownloads: true,
  });
  const page = await context.newPage();

  let result = { status: 'unknown' };

  try {
    await page.goto(SETTINGS_URL, { timeout: TIMEOUT_MS, waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(3000); // 동적 콘텐츠 로딩

    if (page.url().includes('/login') || page.url().includes('/signin')) {
      log('error', 'session expired — re-auth needed');
      saveStatus({ status: 'session-expired' });
      result = { status: 'session-expired' };
      // TODO: Discord alert 호출 (jarvis-system 채널)
      return;
    }

    // 1. Download 버튼이 있으면 우선 처리
    const downloadBtn = await findButtonByText(page, [
      'Download export', 'Download data', '다운로드', 'Download',
    ]);

    if (downloadBtn) {
      log('info', 'download button found', { text: downloadBtn.text });
      const downloadPromise = page.waitForEvent('download', { timeout: TIMEOUT_MS });
      await downloadBtn.button.click();
      const download = await downloadPromise;
      const dst = join(DOWNLOADS_DIR, download.suggestedFilename());
      await download.saveAs(dst);
      log('info', 'download saved', { dst });
      result = { status: 'downloaded', file: dst };
      triggerIngest(dst);
      saveStatus({ status: 'downloaded', file: dst });
      return;
    }

    // 2. Request 버튼 있으면 클릭
    const requestBtn = await findButtonByText(page, [
      'Request export', 'Request data export', '내보내기 요청', 'Export data',
    ]);

    if (requestBtn) {
      log('info', 'request button found', { text: requestBtn.text });
      await requestBtn.button.click();
      await page.waitForTimeout(2000);
      // 확인 모달이 있으면 confirm 클릭
      const confirmBtn = await findButtonByText(page, [
        'Confirm', 'Yes', '확인', 'Continue', 'Request',
      ]);
      if (confirmBtn) {
        await confirmBtn.button.click();
        log('info', 'confirm clicked', { text: confirmBtn.text });
      }
      result = { status: 'requested' };
      saveStatus({ status: 'requested' });
      log('info', 'export requested — check again tomorrow');
      return;
    }

    // 3. Pending 상태 추정 (24시간 처리 중)
    const pendingIndicator = await findButtonByText(page, [
      'Pending', 'Processing', '처리 중', 'Preparing',
    ]);
    if (pendingIndicator) {
      log('info', 'pending — check tomorrow');
      result = { status: 'pending' };
      saveStatus({ status: 'pending' });
      return;
    }

    log('warn', 'no recognizable button on page');
    result = { status: 'unknown-page' };
    saveStatus({ status: 'unknown-page' });
  } catch (e) {
    log('error', 'fatal', { err: e.message });
    result = { status: 'error', error: e.message };
    saveStatus({ status: 'error', error: e.message });
  } finally {
    await browser.close();
    console.log(JSON.stringify(result));
  }
}

main().catch((e) => {
  log('error', 'unhandled', { err: e.message });
  console.log(JSON.stringify({ status: 'error', error: e.message }));
  process.exit(0);
});
