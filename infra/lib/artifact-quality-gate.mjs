#!/usr/bin/env node
// artifact-quality-gate.mjs — 산출물 배포 전 품질 게이트 (자비스 진화 계획 기둥2)
//
// 2026-07-10 신설. 교재·이력서·리포트 HTML/PDF를 배포·업로드 전에 코드로 검사한다.
// 배경: 7월 오답 최다 재발(68건) = 산출물 품질 결함 (정답 사전노출·PDF 클리핑·포맷 깨짐).
//   텍스트 룰로는 못 막으므로 배포 직전 코드 게이트로 강제.
//
// 사용법:
//   node artifact-quality-gate.mjs <파일...>
//   node artifact-quality-gate.mjs --json <파일>     # 기계 판독용 JSON 출력
//   exit 0 = 전부 통과, exit 1 = 결함 발견(배포 중단 신호)
//
// 검사 (HTML 학생 교재):
//   1. answer-leak-button  : 정답 버튼(checkDrill/checkQuiz(this,true)) 라벨에 체크마크(✓✔✅) 하드코딩
//                            → 클릭 전부터 정답 노출 (2026-07-08 캐서린 교재 사고 재현 방지)
//   2. answer-leak-visible : 정답 해설 요소의 class에 'show'가 정적으로 박혀 기본 노출
//   3. answer-hidden-missing: 정답 해설 class를 쓰면서 그것을 기본 숨김(display:none)하는 CSS 부재
//   4. truncated           : </html> 로 안 끝남 (생성 중 잘림 — API 오류 유실 사고 방지)
//   5. tag-balance         : <div>/<script> 개폐 불일치
// 검사 (PDF):
//   6. pdf-open            : pdfinfo로 열리고 페이지 > 0
//   7. pdf-clipping        : (best-effort) 마지막 페이지 렌더 후 우/하단 가장자리 클리핑 휴리스틱

import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { basename, extname } from 'node:path';
import { tmpdir } from 'node:os';

const ANSWER_CLASSES = ['drill-explain', 'answer-reveal', 'quiz-answer', 'answer-box'];
const CHECK_MARKS = ['✓', '✔', '✅', '✔️'];

// ── HTML 검사 ────────────────────────────────────────────────────────────────

function checkHtml(html, findings) {
  // 1. 정답 버튼 라벨에 체크마크 하드코딩
  const trueBtnRe = /<button[^>]*(?:checkDrill|checkQuiz)\(this,\s*true\)[^>]*>([\s\S]*?)<\/button>/gi;
  let m;
  while ((m = trueBtnRe.exec(html)) !== null) {
    const label = m[1];
    if (CHECK_MARKS.some((c) => label.includes(c))) {
      findings.push({
        check: 'answer-leak-button',
        severity: 'block',
        detail: `정답 버튼 라벨에 체크마크 노출: "${label.trim().slice(0, 40)}"`,
      });
    }
  }

  // 2. 정답 해설 요소 class에 'show' 정적 박힘 (CSS 규칙 아닌 HTML 요소만)
  //    class="..." 속성 안에 answer-class + show 동시 존재 → 기본 노출
  const classAttrRe = /class\s*=\s*"([^"]*)"/gi;
  while ((m = classAttrRe.exec(html)) !== null) {
    const cls = m[1];
    const tokens = cls.split(/\s+/);
    const hasAnswer = ANSWER_CLASSES.some((a) => tokens.includes(a));
    if (hasAnswer && tokens.includes('show')) {
      findings.push({
        check: 'answer-leak-visible',
        severity: 'block',
        detail: `정답 해설 요소가 기본 노출됨 (class="${cls.slice(0, 50)}")`,
      });
    }
  }

  // 3. 정답 해설 class 사용하는데 기본 숨김 CSS 부재
  for (const ac of ANSWER_CLASSES) {
    const usedInHtml = new RegExp(`class\\s*=\\s*"[^"]*\\b${ac}\\b`, 'i').test(html);
    if (!usedInHtml) continue;
    // 해당 class를 display:none 으로 기본 숨기는 CSS 규칙 존재?
    const hideCssRe = new RegExp(`\\.${ac}\\s*\\{[^}]*display\\s*:\\s*none`, 'i');
    if (!hideCssRe.test(html)) {
      findings.push({
        check: 'answer-hidden-missing',
        severity: 'block',
        detail: `.${ac} 정답 해설을 기본 숨김(display:none)하는 CSS 규칙 부재 → 항상 노출`,
      });
    }
  }

  // 4. 잘림 (생성 중 유실)
  if (!/<\/html>\s*$/i.test(html.trimEnd())) {
    findings.push({
      check: 'truncated',
      severity: 'block',
      detail: '</html>로 끝나지 않음 — 생성 중 잘림(API 오류 유실) 의심',
    });
  }

  // 5. 태그 개폐 불일치 (div, script)
  for (const tag of ['div', 'script']) {
    const open = (html.match(new RegExp(`<${tag}[\\s>]`, 'gi')) || []).length;
    const close = (html.match(new RegExp(`</${tag}>`, 'gi')) || []).length;
    if (open !== close) {
      findings.push({
        check: 'tag-balance',
        severity: 'warn',
        detail: `<${tag}> 개폐 불일치: 열림 ${open} / 닫힘 ${close}`,
      });
    }
  }
}

// ── PDF 검사 ─────────────────────────────────────────────────────────────────

function checkPdf(path, findings) {
  // 6. 열림 + 페이지 수
  let pages = 0;
  try {
    const info = execFileSync('pdfinfo', [path], { encoding: 'utf-8', timeout: 15000 });
    const pm = info.match(/Pages:\s*(\d+)/);
    pages = pm ? parseInt(pm[1], 10) : 0;
  } catch (e) {
    findings.push({ check: 'pdf-open', severity: 'block', detail: `pdfinfo 실패: ${e.message.slice(0, 60)}` });
    return;
  }
  if (pages < 1) {
    findings.push({ check: 'pdf-open', severity: 'block', detail: '페이지 0개 — 빈 PDF' });
    return;
  }

  // 7. 클리핑 휴리스틱 (best-effort): 마지막 페이지 렌더 후 우/하단 2px 테두리에 잉크 존재
  let ppm = null;
  try {
    ppm = execFileSync('which', ['pdftoppm'], { encoding: 'utf-8' }).trim();
  } catch { ppm = null; }
  if (!ppm) {
    findings.push({ check: 'pdf-clipping', severity: 'info', detail: 'pdftoppm 부재 — 클리핑 검사 건너뜀' });
    return;
  }
  try {
    const outBase = `${tmpdir()}/aqg-${basename(path, '.pdf')}-${pages}`;
    execFileSync('pdftoppm', ['-png', '-r', '60', '-f', String(pages), '-l', String(pages), path, outBase], { timeout: 20000 });
    // 렌더 산출 파일 경로 추정 (pdftoppm은 -<page> 접미사 붙임)
    const candidates = [`${outBase}-${pages}.png`, `${outBase}-${String(pages).padStart(2, '0')}.png`, `${outBase}.png`];
    const png = candidates.find((c) => existsSync(c));
    if (!png) {
      findings.push({ check: 'pdf-clipping', severity: 'info', detail: '렌더 산출 못 찾음 — 클리핑 검사 불가' });
      return;
    }
    // PNG 가장자리 잉크 검사는 별도 파이썬 위임 (순수 JS PNG 디코드 회피 — Simplicity)
    const py = `
import sys
try:
    from PIL import Image
except Exception:
    print("noPIL"); sys.exit(0)
im = Image.open("${png}").convert("L")
w,h = im.size
px = im.load()
def inked(xs, ys):
    n=0
    for x in xs:
        for y in ys:
            if px[x,y] < 200: n+=1
    return n
edge = 2
right = inked(range(w-edge,w), range(0,h))
bottom = inked(range(0,w), range(h-edge,h))
# 가장자리에 잉크가 유의미하게 있으면 클리핑 의심
print("clip" if (right > h*0.08 or bottom > w*0.08) else "ok")
`;
    let verdict = 'ok';
    try {
      verdict = execFileSync('python3', ['-c', py], { encoding: 'utf-8', timeout: 15000 }).trim();
    } catch { verdict = 'noPy'; }
    if (verdict === 'clip') {
      findings.push({ check: 'pdf-clipping', severity: 'warn', detail: `마지막 페이지 우/하단 가장자리에 내용이 닿음 — 클리핑(짤림) 의심` });
    } else if (verdict === 'noPIL' || verdict === 'noPy') {
      findings.push({ check: 'pdf-clipping', severity: 'info', detail: 'PIL 부재 — 클리핑 휴리스틱 건너뜀 (pip install pillow 시 활성)' });
    }
  } catch (e) {
    findings.push({ check: 'pdf-clipping', severity: 'info', detail: `렌더 실패 — 클리핑 검사 건너뜀: ${e.message.slice(0, 50)}` });
  }
}

// ── 메인 ─────────────────────────────────────────────────────────────────────

function gateFile(path) {
  const findings = [];
  if (!existsSync(path)) {
    return { path, ok: false, findings: [{ check: 'not-found', severity: 'block', detail: '파일 없음' }] };
  }
  const ext = extname(path).toLowerCase();
  if (ext === '.html' || ext === '.htm') {
    checkHtml(readFileSync(path, 'utf-8'), findings);
  } else if (ext === '.pdf') {
    checkPdf(path, findings);
  } else {
    findings.push({ check: 'unsupported', severity: 'info', detail: `미지원 확장자(${ext}) — 검사 건너뜀` });
  }
  const blocking = findings.filter((f) => f.severity === 'block' || f.severity === 'warn');
  return { path, ok: blocking.length === 0, findings };
}

const args = process.argv.slice(2);
const jsonOut = args.includes('--json');
const files = args.filter((a) => a !== '--json');

if (files.length === 0) {
  console.error('사용법: node artifact-quality-gate.mjs [--json] <파일...>');
  process.exit(2);
}

const results = files.map(gateFile);
const allOk = results.every((r) => r.ok);

if (jsonOut) {
  console.log(JSON.stringify({ ok: allOk, results }, null, 2));
} else {
  for (const r of results) {
    const icon = r.ok ? '✅' : '🔴';
    console.log(`${icon} ${basename(r.path)}`);
    for (const f of r.findings) {
      const si = f.severity === 'block' ? '🔴' : f.severity === 'warn' ? '🟡' : 'ℹ️';
      console.log(`   ${si} [${f.check}] ${f.detail}`);
    }
  }
  console.log(allOk ? '\n✅ 품질 게이트 통과 — 배포 가능' : '\n🔴 품질 게이트 실패 — 배포 중단 권고');
}

process.exit(allOk ? 0 : 1);
