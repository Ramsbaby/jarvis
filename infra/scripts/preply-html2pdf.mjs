#!/usr/bin/env node
/**
 * preply-html2pdf.mjs — 보람님 한국어 교재(HTML) → 학생 배포용 PDF 변환기
 *
 * 왜 만들었나 (2026-06-25):
 *  - Preply 채팅이 HTML 첨부를 차단 → 학생에게 못 보냄 → PDF가 현실적 대안
 *  - 그냥 PDF로 뽑으면 ① 활성 탭만 보이고 ② 카드가 페이지 경계에서 잘리고
 *    ③ 퀴즈/워크시트 정답(✓·굵은 글씨)이 노출되는 3대 문제 발생
 *  - 이 스크립트는 위 3가지를 모두 막는다:
 *      ① 모든 탭(.tab-content)을 강제로 펼침
 *      ② 카드·박스 단위로 break-inside:avoid 주입 (잘림 방지)
 *      ③ 페이지 JS를 끝까지 실행시킨 뒤 PDF 생성 (정답 숨김 보장)
 *
 * 사용법:
 *   node preply-html2pdf.mjs <a.html> [b.html ...]
 *   node preply-html2pdf.mjs ~/Desktop/뿌리를찾아서_Part1_Unit1-4.html
 *
 * 출력: 입력 파일과 같은 폴더에 "<원본이름>.pdf" 생성 (이모지 진행 표시)
 *
 * 주의: 데이터+동적렌더(JS로 유닛을 그리는) 구조 교재는 한 유닛만 찍힐 수 있다.
 *       그런 교재는 정적 HTML로 재생성 후 변환할 것 (봇 가드 참조).
 */

import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import path from 'path';
import fs from 'fs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
// playwright는 infra/discord/node_modules 에 설치돼 있다 (경로 하드코딩 금지 규칙 준수: 상대경로 기준)
const require = createRequire(path.join(__dirname, '..', 'discord', 'package.json'));
let chromium;
try {
  ({ chromium } = require('playwright'));
} catch (e) {
  console.error('❌ playwright 모듈을 찾지 못했습니다. infra/discord 에서 설치 여부를 확인하세요.');
  console.error('   ' + e.message);
  process.exit(1);
}

// 카드/박스가 페이지 경계에서 잘리지 않도록 break-inside 적용 + 모든 탭 펼침
const PRINT_CSS = `
  nav, .unit-tabs, .tabs, .unit-selector { display: none !important; }
  .tab-content { display: block !important; }
  .vcard, .quiz-item, .key-point, .culture-box, .dialog-box,
  .ws-block, .rp-card, .word-card, .warn-box, .exercise-box, .extra-examples,
  .grammar-detail, .obj-box, .d-line, .sec, .word-grid > *, .phrase-card,
  .practice-card, .match-card, .concept-box, .mistake-box, .because-row {
    break-inside: avoid !important;
    page-break-inside: avoid !important;
  }
  .unit { page-break-after: always !important; box-shadow: none !important; }
  .unit:last-child { page-break-after: auto !important; }
`;

async function convertOne(browser, htmlPath) {
  const abs = path.resolve(htmlPath);
  if (!fs.existsSync(abs)) {
    console.error(`⚠️  파일 없음: ${abs}`);
    return { ok: false, path: abs, error: 'ENOENT' };
  }
  const outPath = abs.replace(/\.html?$/i, '') + '.pdf';
  const page = await browser.newPage();
  try {
    // domcontentloaded 까지만 — 교재 사진(unsplash 등 외부 이미지)에 networkidle 이 발목 잡히지 않게.
    await page.goto('file://' + abs, { waitUntil: 'domcontentloaded', timeout: 30000 });
    // 교재 JS(정답 마커 ✓ 제거, 워크시트 strong→클릭 변환) 실행 + 이미지 일부 로딩 대기.
    // 이미지는 최대 5초만 기다리고, 안 떠도 PDF 생성은 진행 (정답 숨김 JS 는 즉시 끝남).
    await page.waitForTimeout(800);
    await page.evaluate(() => {
      return Promise.race([
        Promise.all(Array.from(document.images)
          .filter((img) => !img.complete)
          .map((img) => new Promise((res) => { img.onload = img.onerror = res; }))),
        new Promise((res) => setTimeout(res, 4000)),
      ]);
    });

    // 모든 탭 펼치기 (정적 교재 대상). 동적 교재는 한 유닛만 렌더될 수 있음.
    await page.evaluate(() => {
      document.querySelectorAll('.tab-content').forEach((el) => {
        el.style.display = 'block';
        el.classList.add('active');
      });
    });

    await page.addStyleTag({ content: PRINT_CSS });
    await page.emulateMedia({ media: 'print' });

    await page.pdf({
      path: outPath,
      format: 'A4',
      printBackground: true,
      margin: { top: '12mm', bottom: '12mm', left: '10mm', right: '10mm' },
    });

    // [2026-07-05 가드] PDF 생성 후 검증
    const stats = fs.statSync(outPath);
    const sizeBytes = stats.size;
    const sizeKB = Math.round(sizeBytes / 1024);

    // 검증 1: 파일 크기 (10KB 미만 = 손상/렌더링 실패 의심)
    if (sizeBytes < 10 * 1024) {
      console.error(`⚠️  PDF 크기 이상: ${path.basename(outPath)} (${sizeKB}KB < 10KB 임계) — 렌더링 실패 의심`);
      return { ok: false, path: abs, error: 'SMALL_PDF', size: sizeKB };
    }

    // 검증 2: PDF 매직 넘버 확인 (손상 파일 탐지)
    const head = Buffer.alloc(4);
    const fd = fs.openSync(outPath, 'r');
    fs.readSync(fd, head, 0, 4, 0);
    fs.closeSync(fd);
    const magic = head.toString('ascii', 0, 4);
    if (!magic.startsWith('%PDF')) {
      console.error(`❌ PDF 손상: ${path.basename(outPath)} — 매직 넘버 ${JSON.stringify(magic)} (기대값: %PDF)`);
      return { ok: false, path: abs, error: 'INVALID_PDF', size: sizeKB };
    }

    console.log(`✅ ${path.basename(outPath)} (${sizeKB}KB) — 검증 완료`);
    // [2026-07-22 cluster cl-8a2b1b50fcd5ba63] 저널 훅: 파이프라인 체크포인트 저널에 실측 기록.
    // best-effort — 훅이 없거나 실패해도 렌더 자체 성공/실패 결과는 그대로 유지 (파괴 금지).
    try {
      const guard = path.join(process.env.HOME || '', 'jarvis', 'infra', 'guards', 'pdf-pipeline-checkpoint.sh');
      if (fs.existsSync(guard)) {
        const { spawnSync } = await import('child_process');
        spawnSync('bash', [guard, 'pdf-checkpoint', outPath], { timeout: 15000, stdio: 'ignore' });
      }
    } catch { /* 저널 훅 실패는 삼킨다 */ }
    return { ok: true, path: outPath, size: sizeKB };
  } catch (e) {
    console.error(`❌ 변환 실패: ${path.basename(abs)} — ${e.message}`);
    return { ok: false, path: abs, error: 'CONVERSION_ERROR', message: e.message };
  } finally {
    await page.close();
  }
}

async function main() {
  const files = process.argv.slice(2).filter((a) => !a.startsWith('--'));
  if (files.length === 0) {
    console.log('📄 사용법: node preply-html2pdf.mjs <a.html> [b.html ...]');
    process.exit(0);
  }
  console.log(`🖨️  교재 ${files.length}개 PDF 변환 시작...`);
  // 시스템 Chrome 사용 — playwright 번들 headless-shell 미설치 환경에서도 동작.
  let browser;
  try {
    browser = await chromium.launch({ args: ['--no-sandbox', '--disable-setuid-sandbox'] });
  } catch (e) {
    console.error('❌ Chrome 실행 실패. macOS에 Google Chrome 설치가 필요합니다.');
    console.error('   ' + e.message.split('\n')[0]);
    process.exit(1);
  }
  const results = [];
  try {
    for (const f of files) {
      results.push(await convertOne(browser, f));
    }
  } finally {
    await browser.close();
  }
  const ok = results.filter((r) => r.ok).length;
  console.log(`\n🌟 완료: ${ok}/${results.length}개 성공`);
  if (ok < results.length) process.exit(1);
}

main();
