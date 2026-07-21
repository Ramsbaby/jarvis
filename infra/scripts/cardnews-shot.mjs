#!/usr/bin/env node
// cardnews-shot.mjs — 카드뉴스 HTML(.card 섹션들)을 개별 정사각형 PNG로 스크린샷.
// 사용: node cardnews-shot.mjs <html> <outDir> <prefix>
// 각 .card 요소를 deviceScaleFactor 2로 캡처 → 1080x1080 카드가 2160x2160 PNG로 저장됨(인스타/틱톡 업로드 품질).
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import path from 'path';
import fs from 'fs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.join(__dirname, '..', 'discord', 'package.json'));
const { chromium } = require('playwright');

async function main() {
  const [src, outDir, prefix] = process.argv.slice(2);
  if (!src || !outDir) { console.error('사용법: cardnews-shot.mjs <html> <outDir> [prefix]'); process.exit(1); }
  const abs = path.resolve(src.replace(/^~/, process.env.HOME));
  if (!fs.existsSync(abs)) { console.error('파일 없음: ' + abs); process.exit(1); }
  fs.mkdirSync(outDir, { recursive: true });

  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 1200, height: 1200 }, deviceScaleFactor: 3 });
    await page.goto('file://' + abs, { waitUntil: 'load', timeout: 30000 });
    await page.waitForTimeout(300);

    const cards = await page.locator('.card').all();
    if (!cards.length) { console.error('❌ .card 요소를 찾지 못함'); process.exit(2); }

    const results = [];
    for (let i = 0; i < cards.length; i++) {
      const n = String(i + 1).padStart(2, '0');
      const outPath = path.join(outDir, `${prefix || 'card'}_${n}.png`);
      await cards[i].screenshot({ path: outPath });
      const sz = fs.statSync(outPath).size;
      results.push({ index: i + 1, file: outPath, bytes: sz });
    }
    console.log(JSON.stringify({ ok: true, count: results.length, results }, null, 2));
  } finally {
    await browser.close();
  }
}

main().catch((e) => { console.error('❌ ' + e.message); process.exit(1); });
