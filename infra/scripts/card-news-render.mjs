#!/usr/bin/env node
/**
 * card-news-render.mjs — 카드뉴스 HTML(카드별 div)을 정사각형 PNG(인스타/틱톡용)로 개별 캡처.
 * 사용법: node card-news-render.mjs <html경로> <출력디렉토리> <파일접두사>
 * HTML 안의 .card 요소를 id 순서대로 순회하며 각각 element screenshot을 찍는다.
 */
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import path from 'path';
import fs from 'fs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.join(__dirname, '..', 'discord', 'package.json'));
const { chromium } = require('playwright');

async function main() {
  const [, , src, outDir, prefix] = process.argv;
  if (!src || !outDir || !prefix) {
    console.error('사용법: card-news-render.mjs <html> <출력디렉토리> <파일접두사>');
    process.exit(1);
  }
  const abs = path.resolve(src.replace(/^~/, process.env.HOME));
  if (!fs.existsSync(abs)) { console.error('파일 없음: ' + abs); process.exit(1); }
  fs.mkdirSync(outDir, { recursive: true });

  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1200, height: 1450 }, deviceScaleFactor: 3 });
  await page.goto('file://' + abs, { waitUntil: 'load', timeout: 30000 });
  await page.waitForTimeout(300);

  const ids = await page.evaluate(() => [...document.querySelectorAll('.card')].map((e) => e.id));
  const out = [];
  for (let i = 0; i < ids.length; i++) {
    const id = ids[i];
    const el = page.locator('#' + id);
    const box = await el.boundingBox();
    if (!box || box.width < 100 || box.height < 100) {
      out.push({ id, ok: false, reason: 'bad-boundingbox', box });
      continue;
    }
    const file = path.join(outDir, `${prefix}_${String(i).padStart(2, '0')}_${id}.png`);
    await el.screenshot({ path: file });
    const size = fs.statSync(file).size;
    out.push({ id, ok: true, file, size, box });
  }
  await browser.close();
  console.log(JSON.stringify({ total: ids.length, out }, null, 1));
}
main();
