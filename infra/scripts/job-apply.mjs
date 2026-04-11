#!/usr/bin/env node
/**
 * Jarvis Job Apply — Puppeteer + Claude 브라우저 자동 지원
 *
 * Usage: node job-apply.mjs <URL>
 *
 * 1. 공고 페이지 접속 → 지원 방식 자동 감지
 * 2. 폼 기반: claude -p로 폼 분석 → 필드 매핑 → 자동 채움
 * 3. 이메일 기반: 지원 메일 본문 생성 + Gmail 작성 창
 * 4. 제출은 항상 사용자가 직접 (자동 제출 없음)
 */

import puppeteer from 'puppeteer-core';
import { readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { homedir, tmpdir } from 'node:os';
import { execSync } from 'node:child_process';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const CRAWL_DIR = join(BOT_HOME, 'state', 'job-crawl');
const SCREENSHOT_DIR = join(CRAWL_DIR, 'screenshots');
const APPS_FILE = join(CRAWL_DIR, 'applications.json');
const CHROME_PATH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

mkdirSync(SCREENSHOT_DIR, { recursive: true });

const url = process.argv[2];

if (!url || url.startsWith('-')) {
  console.error('Usage: node job-apply.mjs <URL>');
  process.exit(1);
}

// ── 이력서 데이터 로드 ────────────────────────────────────────────────────
const RESUME_DATA = {
  name: '이정우',
  email: 'ms6698@naver.com',
  phone: '010-4597-9002',
  github: 'https://github.com/Ramsbaby',
  blog: 'https://ramsbaby.netlify.app',
  experience: '9년',
  currentCompany: 'Company-A',
  currentRole: 'Backend Engineer',
  skills: 'Java, Kotlin, Spring Boot, Spring 6, JPA, Kafka, Redis, AWS, Docker, Kubernetes, MySQL, gRPC, Datadog',
};

const RESUME_PDF = join(homedir(), 'openclaw/memory/career/resume_이정우.pdf');
const CAREER_MD = join(homedir(), 'Jarvis-Vault/05-career/resume-data.md');

// ── 지원 방식 감지 ────────────────────────────────────────────────────────
async function detectApplyMethod(page) {
  return await page.evaluate(() => {
    const body = document.body.innerText.toLowerCase();
    const html = document.documentElement.innerHTML;

    // 1. 지원하기 버튼 (폼 기반)
    const applyBtn = [...document.querySelectorAll('button, a, [role=button]')].find(el => {
      const t = el.textContent.trim();
      return /^(지원하기|지원|Apply Now|Apply|접수)$/i.test(t);
    });
    if (applyBtn) {
      return { method: 'form', element: applyBtn.tagName, text: applyBtn.textContent.trim(), href: applyBtn.href || '' };
    }

    // 2. mailto 링크 (이메일 기반)
    const mailtoLink = document.querySelector('a[href^="mailto:"]');
    if (mailtoLink) {
      const email = mailtoLink.href.replace('mailto:', '').split('?')[0];
      return { method: 'email', email, text: mailtoLink.textContent.trim() };
    }

    // 3. 이메일 패턴 탐지 (텍스트에서)
    const emailMatch = body.match(/[\w.+-]+@[\w-]+\.[\w.]+/);
    if (emailMatch && (body.includes('제출') || body.includes('지원') || body.includes('이력서'))) {
      return { method: 'email', email: emailMatch[0], text: '텍스트에서 감지' };
    }

    // 4. 외부 지원 링크
    const extLink = [...document.querySelectorAll('a')].find(a =>
      /recruit|apply|career|hiring|talent/i.test(a.href) && a.href !== location.href
    );
    if (extLink) {
      return { method: 'external', url: extLink.href, text: extLink.textContent.trim() };
    }

    return { method: 'unknown' };
  });
}

// ── 이메일 지원 처리 ──────────────────────────────────────────────────────
async function handleEmailApply(page, applyInfo) {
  const email = applyInfo.email;
  const jobTitle = await page.evaluate(() => {
    const h1 = document.querySelector('h1');
    return h1 ? h1.textContent.trim().split('|')[0].trim() : document.title;
  });
  const company = await page.evaluate(() => {
    const t = document.title;
    return t.includes('|') ? t.split('|').pop().trim() : '';
  });

  // 지원 메일 본문 생성
  const subject = `[지원] ${jobTitle} - 이정우`;
  const body = `안녕하세요, ${company} 채용팀께.

${jobTitle} 포지션에 지원하는 이정우입니다.

9년간 SaaS·O2O·IoT 플랫폼을 개발하며 장애에 강하고 운영이 편한 시스템을 설계해왔습니다.
현재 Company-A에서 Backend Engineer로 재직 중이며, 이전에는 토스랩(Company-B)에서 2년 8개월간 서버 개발을 담당했습니다.

주요 기술: Java, Kotlin, Spring Boot, Kafka, Redis, AWS, MSA
경력: 총 9년 (Company-A 1년+, 토스랩 2년 8개월, 하몬소프트 4년 8개월)

이력서를 첨부합니다. 검토 후 연락 주시면 감사하겠습니다.

이정우 드림
${RESUME_DATA.phone} | ${RESUME_DATA.email}
GitHub: ${RESUME_DATA.github}
Blog: ${RESUME_DATA.blog}`;

  return { email, subject, body, jobTitle, company };
}

// ── Claude로 폼 필드 매핑 ────────────────────────────────────────────────
function askClaudeForMapping(fields, pageText) {
  const prompt = `너는 채용 지원 폼 자동 채움 도우미야.
아래 "폼 필드 목록"과 "지원자 정보"를 보고, 각 필드에 어떤 값을 넣어야 하는지 JSON 배열로 반환해.

## 지원자 정보
- 이름: ${RESUME_DATA.name}
- 이메일: ${RESUME_DATA.email}
- 전화번호: ${RESUME_DATA.phone}
- GitHub: ${RESUME_DATA.github}
- 블로그: ${RESUME_DATA.blog}
- 경력: ${RESUME_DATA.experience}
- 현 직장: ${RESUME_DATA.currentCompany}
- 현 직무: ${RESUME_DATA.currentRole}
- 기술스택: ${RESUME_DATA.skills}

## 페이지 텍스트 (참고용, 앞 2000자)
${pageText.slice(0, 2000)}

## 폼 필드 목록
${JSON.stringify(fields, null, 2)}

## 응답 규칙
1. 반드시 JSON 배열만 출력. 설명/마크다운 없음.
2. 각 항목: {"selector": "CSS 선택자", "value": "입력할 값", "action": "type|select|skip"}
3. selector는 id가 있으면 "#id", 없으면 "[name=\\"name\\"]" 사용
4. file input(type=file)은 action: "file"로 표시
5. 매핑할 수 없는 필드는 action: "skip"
6. select(드롭다운)는 가장 적절한 option value를 value에 넣고 action: "select"
7. textarea에는 간단한 자기소개(3줄 이내)를 작성해도 좋음

JSON 배열만 출력:`;

  const tmpFile = join(tmpdir(), `jarvis-job-apply-prompt-${Date.now()}.txt`);
  try {
    writeFileSync(tmpFile, prompt, 'utf-8');
    const result = execSync(
      `cat "${tmpFile}" | claude -p 2>/dev/null`,
      { timeout: 90000, maxBuffer: 1024 * 1024, encoding: 'utf-8' },
    );
    // JSON 배열 추출 (앞뒤 텍스트 제거)
    const match = result.match(/\[[\s\S]*\]/);
    if (match) return JSON.parse(match[0]);
    console.error('[Claude] JSON 파싱 실패, 하드코딩 폴백 사용');
  } catch (e) {
    console.error(`[Claude] 호출 실패: ${e.message}, 하드코딩 폴백 사용`);
  } finally {
    try { unlinkSync(tmpFile); } catch {}
  }
  return null;
}

// ── 폴백: 하드코딩 매핑 (claude -p 실패 시) ──────────────────────────────
function hardcodedMapping(fields) {
  return fields.map(field => {
    const key = `${field.label} ${field.name} ${field.placeholder} ${field.id}`.toLowerCase();
    let value = '';
    let action = 'skip';

    if (field.type === 'file') return { selector: field.id ? `#${field.id}` : `[name="${field.name}"]`, value: '', action: 'file' };
    if (field.tag === 'SELECT') return { selector: field.id ? `#${field.id}` : `[name="${field.name}"]`, value: '', action: 'skip' };

    if (/이름|name/i.test(key)) value = RESUME_DATA.name;
    else if (/이메일|email/i.test(key)) value = RESUME_DATA.email;
    else if (/전화|phone|tel|휴대/i.test(key)) value = RESUME_DATA.phone;
    else if (/github/i.test(key)) value = RESUME_DATA.github;
    else if (/블로그|blog|포트폴리오|portfolio/i.test(key)) value = RESUME_DATA.blog;
    else if (/경력.*년|experience/i.test(key)) value = RESUME_DATA.experience;

    if (value) action = 'type';
    const selector = field.id ? `#${field.id}` : `[name="${field.name}"]`;
    return { selector, value, action };
  });
}

// ── 폼 기반 지원 처리 ─────────────────────────────────────────────────────
async function handleFormApply(page, applyInfo) {
  // 지원 버튼 클릭
  if (applyInfo.href) {
    await page.goto(applyInfo.href, { waitUntil: 'networkidle2', timeout: 20000 });
  } else {
    await page.evaluate((text) => {
      const btn = [...document.querySelectorAll('button, a, [role=button]')].find(el =>
        el.textContent.trim() === text
      );
      if (btn) btn.click();
    }, applyInfo.text);
  }
  await new Promise(r => setTimeout(r, 3000));

  // 폼 필드 분석
  const fields = await page.evaluate(() => {
    const inputs = [...document.querySelectorAll('input, textarea, select')];
    return inputs.map(el => ({
      tag: el.tagName,
      type: el.type || '',
      name: el.name || '',
      placeholder: el.placeholder || '',
      label: el.closest('label')?.textContent?.trim()?.slice(0, 50) || '',
      id: el.id || '',
      required: el.required,
      options: el.tagName === 'SELECT' ? [...el.options].map(o => ({ value: o.value, text: o.textContent.trim() })) : [],
    }));
  });

  // 페이지 텍스트 추출 (Claude 컨텍스트용)
  const pageText = await page.evaluate(() => document.body.innerText);

  // Claude로 필드 매핑 시도 → 실패 시 하드코딩 폴백
  console.log('🤖 Claude에게 폼 필드 매핑 요청 중...');
  let mapping = askClaudeForMapping(fields, pageText);
  const usedClaude = !!mapping;
  if (!mapping) {
    mapping = hardcodedMapping(fields);
  }
  console.log(`📋 매핑 완료 (${usedClaude ? 'Claude AI' : '하드코딩 폴백'}): ${mapping.filter(m => m.action !== 'skip').length}/${fields.length} 필드`);

  // 매핑 결과로 폼 채움
  let filledCount = 0;
  for (const m of mapping) {
    if (m.action === 'skip' || !m.selector) continue;

    try {
      if (m.action === 'type' && m.value) {
        await page.type(m.selector, m.value, { delay: 30 });
        filledCount++;
      } else if (m.action === 'select' && m.value) {
        await page.select(m.selector, m.value);
        filledCount++;
      } else if (m.action === 'file' && existsSync(RESUME_PDF)) {
        const fileInput = await page.$(m.selector);
        if (fileInput) {
          await fileInput.uploadFile(RESUME_PDF);
          filledCount++;
        }
      }
    } catch { /* selector not found — skip */ }
  }

  console.log(`✏️  ${filledCount}개 필드 채움 완료`);
  return { fields, mapping, filledCount, usedClaude };
}

// ── Discord 전송 ──────────────────────────────────────────────────────────
async function sendDiscord(content, imagePath = null) {
  try {
    const monitoring = JSON.parse(readFileSync(join(BOT_HOME, 'config', 'monitoring.json'), 'utf-8'));
    const webhook = monitoring.webhooks?.jarvis || monitoring.webhook?.url;
    if (!webhook) return;

    if (imagePath && existsSync(imagePath)) {
      // 이미지 첨부 전송
      const FormData = (await import('node:buffer')).Buffer ? null : null; // Node 18+ built-in
      const blob = readFileSync(imagePath);
      const boundary = '----FormBoundary' + Date.now();
      const body = Buffer.concat([
        Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="content"\r\n\r\n${content}\r\n`),
        Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="screenshot.png"\r\nContent-Type: image/png\r\n\r\n`),
        blob,
        Buffer.from(`\r\n--${boundary}--\r\n`),
      ]);
      await fetch(webhook, {
        method: 'POST',
        headers: { 'Content-Type': `multipart/form-data; boundary=${boundary}` },
        body,
      });
    } else {
      await fetch(webhook, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ content: content.slice(0, 2000), username: 'Jarvis Job Apply' }),
      });
    }
  } catch (e) { console.error('[Discord]', e.message); }
}

// ── 지원 이력 저장 ────────────────────────────────────────────────────────
function saveApplication(entry) {
  let apps = [];
  try { apps = JSON.parse(readFileSync(APPS_FILE, 'utf-8')); } catch {}
  apps.push({ ...entry, timestamp: new Date().toISOString() });
  writeFileSync(APPS_FILE, JSON.stringify(apps, null, 2));
}

// ── 메인 ──────────────────────────────────────────────────────────────────
async function main() {
  console.log(`🚀 Jarvis Job Apply — ${url}\n`);

  // Puppeteer를 visible 모드로 실행 — 사용자가 화면에서 직접 확인 가능
  const browser = await puppeteer.launch({
    executablePath: CHROME_PATH,
    headless: false,
    defaultViewport: null,
    args: ['--no-sandbox', '--disable-blink-features=AutomationControlled', '--start-maximized'],
  });
  console.log('🖥️  Mac 화면에 Chrome 창을 열었습니다.');

  const page = await browser.newPage();
  await page.goto(url, { waitUntil: 'networkidle2', timeout: 30000 });
  await new Promise(r => setTimeout(r, 4000));

  // 공고 정보 추출
  const jobTitle = await page.evaluate(() => {
    const h = document.querySelector('h1, h2');
    return h ? h.textContent.trim().split('|')[0].trim() : document.title;
  });
  console.log(`📋 공고: ${jobTitle}`);

  // 지원 방식 감지
  const applyInfo = await detectApplyMethod(page);
  console.log(`🔍 지원 방식: ${applyInfo.method}`);

  let result = {};
  const screenshotPath = join(SCREENSHOT_DIR, `apply-${Date.now()}.png`);

  if (applyInfo.method === 'email') {
    // ⛔ 이메일 자동화 금지 — 이메일 방식 공고는 수동 지원 필요
    console.log(`⛔ 이메일 방식 공고입니다. 자동 지원 불가.`);
    console.log(`   수신 주소: ${applyInfo.email}`);
    console.log(`   직접 이력서를 첨부하여 발송하세요.`);

    await sendDiscord(
      `⛔ **이메일 방식 — 수동 지원 필요**\n` +
      `공고: ${jobTitle}\n` +
      `수신 주소: ${applyInfo.email}\n\n` +
      `자동 발송하지 않습니다. 직접 이력서 첨부 후 전송하세요.`,
    );
    result = { method: 'email', skipped: true, reason: '이메일 방식 수동 지원 필요', email: applyInfo.email };

  } else if (applyInfo.method === 'form') {
    // 폼 기반 지원
    console.log('📝 폼 기반 지원 — 필드 자동 채움 시작');
    const formResult = await handleFormApply(page, applyInfo);
    await new Promise(r => setTimeout(r, 2000));
    await page.screenshot({ path: screenshotPath, fullPage: false });

    result = { method: 'form', fields: formResult.fields, filledCount: formResult.filledCount, usedClaude: formResult.usedClaude, screenshotPath };

    await sendDiscord(
      `📝 **폼 자동 채움 완료** — ${jobTitle}\n` +
      `매핑: ${formResult.usedClaude ? 'Claude AI' : '하드코딩 폴백'}\n` +
      `필드 ${formResult.fields.length}개 감지, ${formResult.filledCount}개 채움\n` +
      `브라우저에서 확인 후 직접 제출해주세요.`,
      screenshotPath,
    );

    console.log('\n⏸️  폼 자동 채움 완료. 브라우저에서 내용 확인 후 직접 제출해주세요.');

  } else if (applyInfo.method === 'external') {
    console.log(`🔗 외부 링크 감지: ${applyInfo.url}`);
    await page.goto(applyInfo.url, { waitUntil: 'networkidle2', timeout: 20000 });
    await new Promise(r => setTimeout(r, 3000));
    await page.screenshot({ path: screenshotPath, fullPage: false });

    result = { method: 'external', url: applyInfo.url, screenshotPath };
    await sendDiscord(`🔗 **외부 지원 페이지** — ${jobTitle}\n${applyInfo.url}`, screenshotPath);

  } else {
    console.log('❓ 지원 방식을 감지하지 못했습니다.');
    await page.screenshot({ path: screenshotPath, fullPage: false });
    result = { method: 'unknown', screenshotPath };
    await sendDiscord(`❓ **지원 방식 미감지** — ${jobTitle}\n페이지를 직접 확인해주세요.\n${url}`, screenshotPath);
  }

  // 지원 이력 저장
  saveApplication({ url, jobTitle, ...result });

  // 브라우저를 열어둔 채로 종료 — 사용자가 확인 후 직접 제출
  browser.disconnect();
  console.log('\n✅ 완료. Mac 화면의 Chrome에서 내용 확인 후 직접 제출해주세요.');
  console.log('   (브라우저는 열린 상태로 유지됩니다)');
}

main().catch(e => { console.error('Fatal:', e); process.exit(1); });
