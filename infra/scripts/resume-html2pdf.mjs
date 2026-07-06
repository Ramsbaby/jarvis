#!/usr/bin/env node
/**
 * resume-html2pdf.mjs — 이력서·포트폴리오(HTML) → 머리말/꼬리말 없는 깔끔한 PDF
 *
 * 왜 만들었나 (2026-06-29):
 *  - resume-sync 스킬은 Chrome `--headless=new --print-to-pdf-no-header`로 PDF를 뽑는다.
 *  - 그런데 Chrome 149의 새 headless 모드에서 `--print-to-pdf-no-header`가 무시되어
 *    인쇄 날짜(머리말)·파일경로 URL·페이지번호(꼬리말)가 모든 페이지에 박힌다.
 *  - playwright `page.pdf({ displayHeaderFooter:false })`는 머리말/꼬리말을 확실히 제거한다.
 *  - preply-html2pdf.mjs와 분리한 이유: 그쪽은 "보람선생님" 브랜딩 푸터·탭 펼치기 등
 *    교재 전용 로직이 박혀 있어 이력서/포트폴리오에 쓰면 안 된다.
 *
 * 사용법:
 *   node resume-html2pdf.mjs <src.html> <out.pdf>
 *
 * 출력: HTML의 @page 여백 설정을 그대로 사용(preferCSSPageSize), 배경색 포함(printBackground).
 */

import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import path from 'path';
import fs from 'fs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// playwright는 infra/discord/node_modules 에 설치돼 있다 (preply-html2pdf.mjs와 동일 경로 규칙).
const require = createRequire(path.join(__dirname, '..', 'discord', 'package.json'));
let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (e) {
  console.error('❌ playwright 모듈을 찾지 못했습니다. infra/discord 에서 설치 여부를 확인하세요.');
  console.error('   ' + e.message);
  process.exit(1);
}

async function convert(src, out) {
  const abs = path.resolve(src);
  if (!fs.existsSync(abs)) {
    console.error(`⚠️  파일 없음: ${abs}`);
    process.exit(1);
  }
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    await page.goto('file://' + abs, { waitUntil: 'load', timeout: 30000 });
    // 외부 이미지가 있어도 최대 4초만 대기 후 진행 (네트워크에 발목 잡히지 않게).
    await page.evaluate(() => Promise.race([
      Promise.all(Array.from(document.images)
        .filter((img) => !img.complete)
        .map((img) => new Promise((res) => { img.onload = img.onerror = res; }))),
      new Promise((res) => setTimeout(res, 4000)),
    ]));
    await page.emulateMedia({ media: 'print' });
    await page.pdf({
      path: out,
      format: 'A4',
      printBackground: true,
      displayHeaderFooter: false, // ← 머리말(날짜)·꼬리말(URL·페이지번호) 제거의 핵심
      preferCSSPageSize: true,    // HTML의 @page { margin } 여백을 그대로 사용
    });
    const kb = Math.round(fs.statSync(out).size / 1024);
    console.log(`✅ ${path.basename(out)} (${kb}KB) — 머리말/꼬리말 없음`);
  } finally {
    await browser.close();
  }
}

const [src, out] = process.argv.slice(2);
if (!src || !out) {
  console.log('📄 사용법: node resume-html2pdf.mjs <src.html> <out.pdf>');
  process.exit(1);
}
convert(src, out).catch((e) => {
  console.error('❌ 변환 실패: ' + e.message);
  process.exit(1);
});
