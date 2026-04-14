#!/usr/bin/env node
/**
 * Jarvis Job Crawler — standalone (Puppeteer + API)
 * Chrome 확장 없이 독립 실행. 크롤링 결과를 JSON + Discord로 전송.
 *
 * Usage: node job-crawl.mjs [--discord] [--json-only]
 */

import puppeteer from 'puppeteer-core';
import { writeFileSync, readFileSync, existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const BOT_HOME = process.env.BOT_HOME || join(homedir(), '.jarvis');
const RESULT_DIR = join(BOT_HOME, 'state', 'job-crawl');
const RESULT_FILE = join(RESULT_DIR, 'latest.json');
const SEEN_FILE = join(RESULT_DIR, 'seen.json');
const CHROME_PATH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const sendToDiscord = process.argv.includes('--discord');
const jsonOnly = process.argv.includes('--json-only');

mkdirSync(RESULT_DIR, { recursive: true });

// ─── 대상 사이트 ──────────────────────────────────────────────────────────
const SITES = [
  { id: 'hyundai-autoever', company: '현대오토에버', url: 'https://career.hyundai-autoever.com/ko/apply', parser: 'link', linkPattern: '/ko/o/' },
  { id: 'skcareers', company: 'SK(텔레콤/하이닉스)', url: 'https://www.skcareers.com/Recruit/Index?searchText=백엔드', parser: 'link', linkPattern: '/Recruit/Detail/' },
  { id: 'kakao', company: '카카오', url: 'https://careers.kakao.com/jobs?part=TECHNOLOGY&page=1', parser: 'link', linkPattern: '/jobs/' },
  { id: 'kakaobank', company: '***', url: 'https://recruit.kakaobank.com/jobs', parser: 'link', linkPattern: '/jobs/' },
  { id: 'kakaoent', company: '카카오엔터테인먼트', url: 'https://careers.kakaoent.com/ko/main', parser: 'link', linkPattern: '/ko/o/' },
  { id: 'kakaogames', company: '카카오게임즈', url: 'https://recruit.kakaogames.com/ko/joinjuskr', parser: 'link', linkPattern: '/o/' },
  { id: 'naver', company: '네이버', url: 'https://recruit.navercorp.com/rcrt/list.do?entTypeCd=&jobCd=3010001%2C3010002%2C3010003&sysType=normal', parser: 'link', linkPattern: 'annoId' },
  { id: 'naver-cloud', company: '네이버 클라우드', url: 'https://recruit.navercloudcorp.com/rcrt/list.do', parser: 'link', linkPattern: 'annoId' },
  { id: 'krafton', company: '크래프톤', url: 'https://krafton.com/careers/jobs/?category=Engineering', parser: 'link', linkPattern: '/jobs/' },
  { id: 'toss', company: '토스', url: 'https://toss.im/career/jobs', parser: 'link', linkPattern: 'job-detail' },
  { id: 'daangn', company: '당근', url: 'https://about.daangn.com/jobs/', parser: 'link', linkPattern: '/jobs/' },
  { id: 'hyundai-motor', company: '현대자동차', url: 'https://talent.hyundai.com/apply/applyList.hc', parser: 'link', linkPattern: 'applyView' },
  { id: 'kia', company: '기아', url: 'https://career.kia.com/notic/noticList.kc', parser: 'link', linkPattern: 'applyView.kc' },
  { id: 'lge', company: 'LG전자', url: 'https://careers.lg.com/channel/detail/lge/job_openings', parser: 'link', linkPattern: 'jobNoticeId' },
  { id: 'woowa', company: '우아한형제들(배민)', url: 'https://career.woowahan.com/recruitment/?category=jobGroupCode&tag=BA005001', parser: 'link', linkPattern: 'recruitment' },
  { id: 'lgcns', company: 'LG CNS', url: 'https://www.lgcns.com/content/lgcns/kr/careers/jobs.html', parser: 'auto' },
  { id: 'kt', company: 'KT', url: 'https://recruit.kt.com/applicant/recruitment/list.do', parser: 'auto' },
  { id: 'samsung-elec', company: '삼성전자', url: 'https://www.samsungcareers.com/hr/', parser: 'auto' },
  { id: 'line', company: '라인(LINE)', url: 'https://careers.linecorp.com/jobs?co=Korea&cl=Engineering', parser: 'link', linkPattern: '/jobs/' },
  { id: 'coupang', company: '쿠팡', url: 'https://www.coupang.jobs/contents/job-search/?search_keyword=backend&search_area=true', parser: 'link', linkPattern: '/job/' },
  { id: 'dunamu', company: '두나무(업비트)', url: 'https://www.dunamu.com/careers/jobs', parser: 'link', linkPattern: '/careers/' },
  { id: 'yeogi', company: '여기어때', url: 'https://gccompany.career.greetinghr.com/ko/apply', parser: 'link', linkPattern: '/o/' },
  { id: 'kbank', company: '케이뱅크', url: 'https://recruit.kbanknow.com/Recruit', parser: 'link', linkPattern: '/Recruit/' },
  { id: 'nhn', company: 'NHN', url: 'https://careers.nhn.com/recruits', parser: 'auto' },
  { id: 'nexon', company: '넥슨', url: 'https://career.nexon.com/user/recruit/member/postList?joinCorp=NX', parser: 'auto' },
  { id: 'ncsoft', company: 'NC소프트', url: 'https://careers.ncsoft.com/apply/list', parser: 'link', linkPattern: '/apply/' },
  { id: 'hyundaicard', company: '현대카드', url: 'https://careerhyundai.recruiter.co.kr/career/home', parser: 'auto' },
  { id: 'lguplus', company: 'LG유플러스', url: 'https://careers.lg.com/channel/detail/lgu/job_openings', parser: 'link', linkPattern: 'jobNoticeId' },
  { id: 'kakao-enterprise', company: '카카오엔터프라이즈', url: 'https://careers.kakaoenterprise.com/ko/job', parser: 'link', linkPattern: '/ko/job/' },
  { id: 'musinsa', company: '무신사', url: 'https://www.musinsacareers.com/ko', parser: 'auto' },
];

// ── GreetingHR API 사이트 (탭 불필요, HTTP 직접 호출) ──────────────────────
const GREETINGHR_SITES = [
  { id: 'kurly', company: '컬리', wid: 6012, baseUrl: 'https://kurly.career.greetinghr.com/ko/o/' },
  { id: 'banksalad', company: '뱅크샐러드', wid: 5130, baseUrl: 'https://banksalad.career.greetinghr.com/ko/o/' },
  { id: 'kakao-mobility', company: '카카오모빌리티', wid: 14346, baseUrl: 'https://kakaomobility.career.greetinghr.com/ko/o/' },
  { id: 'bucketplace', company: '오늘의집(버킷플레이스)', wid: 1671, baseUrl: 'https://bucketplace.career.greetinghr.com/ko/o/' },
  { id: 'zigbang', company: '직방', wid: 1724, baseUrl: 'https://zigbang.career.greetinghr.com/ko/o/' },
  { id: 'socar', company: '쏘카', wid: 455, baseUrl: 'https://socar.career.greetinghr.com/ko/o/' },
  { id: 'company-c', company: 'Company-C', wid: 14605, baseUrl: 'https://company-c.career.greetinghr.com/ko/o/' },
];

// ── NineHire API (카카오스타일) ─────────────────────────────────────────────
const NINEHIRE_SITES = [
  { id: 'kakaostyle', company: '카카오스타일(지그재그)', apiUrl: 'https://api.ninehire.com/identity-access/homepage/recruitments?companyId=1573cfe0-2c72-11ef-950a-65a32c77a0c3&page=1&countPerPage=100', baseUrl: 'https://career.kakaostyle.com/job_posting/' },
];

// ── 키워드 ─────────────────────────────────────────────────────────────────
const BACKEND_KW = [
  'java', 'spring', '백엔드', 'backend', '서버 개발', '서버개발',
  'springboot', 'webflux', 'jvm', 'msa', 'microservice', '마이크로서비스',
  'server 엔지니어', 'platform engineer', '플랫폼 개발',
  '서버 엔지니어', '서버엔지니어', '서버개발자', '서버 개발자',
  'kotlin', 'golang', 'go 언어', 'node.js', 'nodejs', 'python',
  '시스템 개발', '시스템개발', 'api 개발', '클라우드 엔지니어',
];
const EXCLUDE_KW = [
  '석사', '박사', 'phd', '석·박사', '석박사',
  '연구원', 'research engineer', 'research scientist', 'researcher',
  '프론트엔드', 'frontend', 'front-end',
  'ios', 'android', '모바일 앱',
  'data scientist', 'ml engineer', 'machine learning engineer',
  '디자이너', 'designer', 'devrel', '기술영업', '솔루션즈 아키텍트',
];

function isBackendJob(title) {
  if (!title) return false;
  const lower = title.toLowerCase();
  if (EXCLUDE_KW.some(k => lower.includes(k.toLowerCase()))) return false;
  return BACKEND_KW.some(k => lower.includes(k.toLowerCase()));
}

function makeId(str) {
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    hash = ((hash << 5) - hash) + str.charCodeAt(i);
    hash |= 0;
  }
  return Math.abs(hash).toString(36);
}

function loadSeen() {
  try { return new Set(JSON.parse(readFileSync(SEEN_FILE, 'utf-8'))); } catch { return new Set(); }
}
function saveSeen(seen) {
  writeFileSync(SEEN_FILE, JSON.stringify([...seen].slice(-3000)));
}

// ── API 크롤링 (GreetingHR) ───────────────────────────────────────────────
async function crawlGreetingHR(site) {
  try {
    const r = await fetch(`https://api.greetinghr.com/ats/career/workspaces/${site.wid}/openings?page=0&pageSize=100`);
    const d = await r.json();
    return (d?.data?.datas || [])
      .filter(o => o.title && (o.openingId || o.id))
      .map(o => ({ title: o.title, url: `${site.baseUrl}${o.openingId || o.id}`, company: site.company }));
  } catch (e) {
    console.error(`  [API] ${site.company} 실패: ${e.message}`);
    return [];
  }
}

// ── API 크롤링 (NineHire) ─────────────────────────────────────────────────
async function crawlNineHire(site) {
  try {
    const r = await fetch(site.apiUrl);
    const d = await r.json();
    return (d?.results || [])
      .filter(o => o.addressKey && o.title)
      .map(o => ({ title: o.title, url: `${site.baseUrl}${o.addressKey}`, company: site.company }));
  } catch (e) {
    console.error(`  [API] ${site.company} 실패: ${e.message}`);
    return [];
  }
}

// ── Puppeteer DOM 크롤링 ──────────────────────────────────────────────────
async function crawlWithBrowser(browser, site) {
  const page = await browser.newPage();
  try {
    await page.setUserAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36');
    await page.goto(site.url, { waitUntil: 'networkidle2', timeout: 30000 });
    // SPA 렌더링 대기
    await new Promise(r => setTimeout(r, 5000));

    const jobs = await page.evaluate((siteData) => {
      const results = [];
      const seen = new Set();

      function extractTitle(a) {
        const h = a.querySelector('h1,h2,h3,h4,h5');
        if (h) { const t = h.textContent.trim(); if (t.length > 3 && t.length < 100) return t; }
        const titleEl = a.querySelector('[class*="position"],[class*="Position"],[class*="title"],[class*="Title"],[class*="name"],[class*="Name"]');
        if (titleEl) { const t = titleEl.textContent.trim(); if (t.length > 3 && t.length < 100) return t; }
        const full = a.textContent.replace(/\s+/g, ' ').trim();
        return full.split(/[・|/\t\n]/)[0].trim().slice(0, 80);
      }

      if (siteData.parser === 'link' && siteData.linkPattern) {
        document.querySelectorAll(`a[href*="${siteData.linkPattern}"]`).forEach(a => {
          const title = extractTitle(a);
          const url = a.href;
          if (title && title.length > 3 && title.length < 150 && !title.includes('<') && !seen.has(url)) {
            seen.add(url);
            results.push({ title, url, company: siteData.company });
          }
        });
        // onclick fallback
        if (results.length === 0) {
          document.querySelectorAll('[onclick]').forEach(el => {
            const onclick = el.getAttribute('onclick') || '';
            const m = onclick.match(/location\.href\s*=\s*['"]([^'"]+)['"]/);
            if (!m || !m[1].includes(siteData.linkPattern)) return;
            const title = extractTitle(el);
            const url = m[1].startsWith('http') ? m[1] : location.origin + m[1];
            if (title && title.length > 3 && !seen.has(url)) { seen.add(url); results.push({ title, url, company: siteData.company }); }
          });
        }
      }

      // auto-detect fallback
      if (results.length === 0) {
        const JOB_KW = ['job', 'career', 'recruit', 'position', 'opening', 'hire', 'talent', '채용', '공고', 'apply'];
        document.querySelectorAll('a[href]').forEach(a => {
          const fullUrl = a.href;
          if (!fullUrl || !fullUrl.startsWith('http')) return;
          try {
            const u = new URL(fullUrl);
            const path = u.pathname;
            if (/\.(css|js|png|jpg|gif|svg|ico|woff|pdf)$/i.test(path)) return;
            if (path.split('/').filter(Boolean).length < 2) return;
            const hasNumId = /\/\d{3,}/.test(path) || /[?&](id|seq|no|idx)=\d+/.test(u.search);
            const hasKw = JOB_KW.some(k => (path + u.search).toLowerCase().includes(k));
            if (!hasNumId && !hasKw) return;
            if (seen.has(fullUrl)) return;
            seen.add(fullUrl);
            const title = extractTitle(a);
            if (title && title.length > 3 && title.length < 150 && !title.includes('<')) {
              results.push({ title, url: fullUrl, company: siteData.company });
            }
          } catch {}
        });
      }

      return results;
    }, { parser: site.parser, linkPattern: site.linkPattern, company: site.company });

    return jobs;
  } catch (e) {
    console.error(`  [Browser] ${site.company} 실패: ${e.message}`);
    return [];
  } finally {
    await page.close();
  }
}

// ── Discord 전송 ──────────────────────────────────────────────────────────
async function sendDiscordMsg(content) {
  try {
    const { config } = await import('dotenv');
    config({ path: join(BOT_HOME, '.env') });
    const webhook = process.env.DISCORD_WEBHOOK_CAREER || process.env.FAMILY_DISCORD_WEBHOOK;
    if (!webhook) {
      // 봇 토큰 + 채널 ID로 전송
      const token = process.env.DISCORD_TOKEN;
      const channelId = '1471694919339868190'; // jarvis-career
      if (!token) { console.log('[Discord] 토큰 없음, 스킵'); return; }
      await fetch(`https://discord.com/api/v10/channels/${channelId}/messages`, {
        method: 'POST',
        headers: { Authorization: `Bot ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ content: content.slice(0, 2000) }),
      });
    } else {
      await fetch(webhook, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ content: content.slice(0, 2000) }) });
    }
  } catch (e) { console.error('[Discord]', e.message); }
}

// ── 메인 ──────────────────────────────────────────────────────────────────
async function main() {
  console.log(`🤖 Jarvis Job Crawler — standalone (${new Date().toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })})`);

  const seen = loadSeen();
  const allJobs = [];
  const siteResults = [];

  // Phase 1: API 직접 호출 (빠름, 브라우저 불필요)
  console.log('\n📡 Phase 1: API 직접 호출...');
  for (const site of GREETINGHR_SITES) {
    const jobs = await crawlGreetingHR(site);
    const backend = jobs.filter(j => isBackendJob(j.title));
    const newJobs = backend.filter(j => { const id = makeId(j.url); if (seen.has(id)) return false; seen.add(id); return true; });
    allJobs.push(...backend.map(j => ({ ...j, isNew: newJobs.some(n => n.url === j.url) })));
    siteResults.push({ company: site.company, total: jobs.length, backend: backend.length, new: newJobs.length });
    console.log(`  ✅ ${site.company}: ${jobs.length}건 (백엔드 ${backend.length}, 신규 ${newJobs.length})`);
  }

  for (const site of NINEHIRE_SITES) {
    const jobs = await crawlNineHire(site);
    const backend = jobs.filter(j => isBackendJob(j.title));
    const newJobs = backend.filter(j => { const id = makeId(j.url); if (seen.has(id)) return false; seen.add(id); return true; });
    allJobs.push(...backend.map(j => ({ ...j, isNew: newJobs.some(n => n.url === j.url) })));
    siteResults.push({ company: site.company, total: jobs.length, backend: backend.length, new: newJobs.length });
    console.log(`  ✅ ${site.company}: ${jobs.length}건 (백엔드 ${backend.length}, 신규 ${newJobs.length})`);
  }

  // Phase 2: Puppeteer 브라우저 크롤링
  console.log('\n🌐 Phase 2: 브라우저 크롤링...');
  const browser = await puppeteer.launch({
    executablePath: CHROME_PATH,
    headless: 'new',
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-blink-features=AutomationControlled'],
  });

  const BATCH = 3;
  for (let i = 0; i < SITES.length; i += BATCH) {
    const batch = SITES.slice(i, i + BATCH);
    const results = await Promise.all(batch.map(s => crawlWithBrowser(browser, s)));

    for (let k = 0; k < batch.length; k++) {
      const site = batch[k];
      const jobs = results[k];
      const backend = jobs.filter(j => isBackendJob(j.title));
      const newJobs = backend.filter(j => { const id = makeId(j.url); if (seen.has(id)) return false; seen.add(id); return true; });
      allJobs.push(...backend.map(j => ({ ...j, isNew: newJobs.some(n => n.url === j.url) })));
      const emoji = jobs.length > 0 ? '✅' : '⚠️';
      siteResults.push({ company: site.company, total: jobs.length, backend: backend.length, new: newJobs.length });
      console.log(`  ${emoji} ${site.company}: ${jobs.length}건 (백엔드 ${backend.length}, 신규 ${newJobs.length})`);
    }
  }

  await browser.close();
  saveSeen(seen);

  // 결과 저장
  const result = {
    timestamp: new Date().toISOString(),
    totalBackend: allJobs.length,
    totalNew: allJobs.filter(j => j.isNew).length,
    jobs: allJobs,
    siteResults,
  };
  writeFileSync(RESULT_FILE, JSON.stringify(result, null, 2));
  console.log(`\n📊 결과: 백엔드 ${result.totalBackend}건 (신규 ${result.totalNew}건)`);
  console.log(`💾 저장: ${RESULT_FILE}`);

  // Discord 전송
  if (sendToDiscord && !jsonOnly) {
    const lines = siteResults.map(r => {
      if (r.total < 0) return `- ❌ ${r.company}: 오류`;
      if (r.total === 0) return `- ⚠️ ${r.company}: 0건`;
      if (r.new === 0) return `- 🔵 ${r.company}: ${r.total}건 (백엔드 ${r.backend}), 신규 없음`;
      return `- ✅ ${r.company}: ${r.total}건 (백엔드 ${r.backend}), 🆕 ${r.new}건`;
    });
    await sendDiscordMsg(`🤖 **크롤링 완료** (${new Date().toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' })})\n백엔드 매칭: **${result.totalBackend}건** (🆕 신규 ${result.totalNew}건)\n\n${lines.join('\n')}`);
  }
}

main().catch(e => { console.error('Fatal:', e); process.exit(1); });
